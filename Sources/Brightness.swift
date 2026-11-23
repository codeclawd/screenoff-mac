import AppKit
import CoreGraphics
import IOKit
import os

private let log = Logger(subsystem: "com.codeclawd.screenoff", category: "brightness")

// Brightness for every connected display, done by the display's own hardware.
// - External monitors: DDC/CI over the cable. Apple silicon only. The method follows MonitorControl
//   (MIT License, https://github.com/MonitorControl/MonitorControl). Many monitors still glow at
//   brightness 0, so the bottom of the slider then lowers the monitor's contrast as well.
// - Built-in display: Apple's DisplayServices.
// Every Apple function used here is private, so each is looked up at runtime. If one is missing,
// that display simply gets no slider.
private enum Private {
    typealias AVCreate = @convention(c) (CFAllocator?, io_service_t) -> Unmanaged<CFTypeRef>?
    typealias AVI2C = @convention(c) (CFTypeRef, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> IOReturn
    typealias InfoDict = @convention(c) (CGDirectDisplayID) -> Unmanaged<CFDictionary>?
    typealias GetBrightness = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    typealias SetBrightness = @convention(c) (CGDirectDisplayID, Float) -> Int32

    static func symbol<T>(_ library: String?, _ name: String, as type: T.Type) -> T? {
        guard let handle = dlopen(library, RTLD_NOW), let sym = dlsym(handle, name) else { return nil }
        return unsafeBitCast(sym, to: type)
    }

    static let avCreate = symbol(nil, "IOAVServiceCreateWithService", as: AVCreate.self)
    static let avWrite = symbol(nil, "IOAVServiceWriteI2C", as: AVI2C.self)
    static let avRead = symbol(nil, "IOAVServiceReadI2C", as: AVI2C.self)
    static let infoDict = symbol("/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay",
                                 "CoreDisplay_DisplayCreateInfoDictionary", as: InfoDict.self)
    static let dsLibrary = "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices"
    static let getBrightness = symbol(dsLibrary, "DisplayServicesGetBrightness", as: GetBrightness.self)
    static let setBrightness = symbol(dsLibrary, "DisplayServicesSetBrightness", as: SetBrightness.self)
}

// One DDC/CI connection to an external monitor.
struct DDCChannel {
    let service: CFTypeRef
    private static let chip: UInt32 = 0x37
    private static let dataAddress: UInt32 = 0x51
    static let brightness: UInt8 = 0x10
    static let contrast: UInt8 = 0x12

    // Returns (current, max) for a VCP code, or nil if the monitor didn't answer. Monitors disagree
    // on the request checksum: most follow the DDC/CI spec (seed 0x6E ^ 0x51), some only answer
    // MonitorControl's variant (seed 0x6E), so try both.
    func read(_ code: UInt8) -> (current: Int, max: Int)? {
        guard let write = Private.avWrite, let read = Private.avRead else { return nil }
        for seed in [UInt8(Self.chip << 1) ^ UInt8(Self.dataAddress), UInt8(Self.chip << 1)] {
            var packet = Self.packet([code], seed: seed)
            for _ in 0..<3 {
                for _ in 0..<2 {
                    usleep(10_000)
                    _ = write(service, Self.chip, Self.dataAddress, &packet, UInt32(packet.count))
                }
                usleep(50_000)
                var reply = [UInt8](repeating: 0, count: 11)
                if read(service, Self.chip, 0, &reply, UInt32(reply.count)) == 0,
                   reply[0..<10].reduce(UInt8(0x50), ^) == reply[10], reply[2] == 0x02, reply[3] == 0, reply[4] == code {
                    let max = Int(reply[6]) << 8 | Int(reply[7])
                    let current = Int(reply[8]) << 8 | Int(reply[9])
                    if max > 0 { return (min(current, max), max) }
                }
                usleep(20_000)
            }
        }
        return nil
    }

    func write(_ code: UInt8, _ value: Int) -> Bool {
        guard let write = Private.avWrite else { return false }
        var packet = Self.packet([code, UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)],
                                 seed: UInt8(Self.chip << 1) ^ UInt8(Self.dataAddress))
        for _ in 0..<5 {
            usleep(10_000)
            if write(service, Self.chip, Self.dataAddress, &packet, UInt32(packet.count)) == 0 { return true }
            usleep(20_000)
        }
        return false
    }

    // DDC/CI frame: length byte, payload, then an XOR checksum over the addresses and every byte.
    private static func packet(_ payload: [UInt8], seed: UInt8) -> [UInt8] {
        let body = [UInt8(0x80 | (payload.count + 1)), UInt8(payload.count)] + payload
        return body + [body.reduce(seed, ^)]
    }

    // Pairs each external DCPAVServiceProxy with the framebuffer above it in the IOKit registry,
    // keyed by that framebuffer's registry path (the same string CoreDisplay reports as the
    // display's IODisplayLocation).
    static func channelsByLocation() -> [String: DDCChannel] {
        #if arch(arm64)
        guard let create = Private.avCreate else { return [:] }
        var iterator = io_iterator_t()
        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        defer { IOObjectRelease(root) }
        guard IORegistryEntryCreateIterator(root, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively), &iterator) == KERN_SUCCESS else { return [:] }
        defer { IOObjectRelease(iterator) }

        var channels: [String: DDCChannel] = [:]
        var framebufferPath: String?
        while case let entry = IOIteratorNext(iterator), entry != IO_OBJECT_NULL {
            defer { IOObjectRelease(entry) }
            var nameBuffer = [CChar](repeating: 0, count: 128)
            IORegistryEntryGetName(entry, &nameBuffer)
            let name = String(cString: nameBuffer)
            if name == "AppleCLCD2" || name == "IOMobileFramebufferShim" {
                var pathBuffer = [CChar](repeating: 0, count: 512)
                IORegistryEntryGetPath(entry, kIOServicePlane, &pathBuffer)
                framebufferPath = String(cString: pathBuffer)
            } else if name == "DCPAVServiceProxy", let path = framebufferPath {
                let location = IORegistryEntryCreateCFProperty(entry, "Location" as CFString, kCFAllocatorDefault,
                                                               IOOptionBits(kIORegistryIterateRecursively))?.takeRetainedValue() as? String
                if location == "External", let service = create(kCFAllocatorDefault, entry)?.takeRetainedValue() {
                    channels[path] = DDCChannel(service: service)
                }
                framebufferPath = nil
            }
        }
        return channels
        #else
        return [:]
        #endif
    }
}

final class BrightnessModel: ObservableObject {
    struct Row: Identifiable {
        let id: CGDirectDisplayID
        let name: String
        var value: Double?        // 0...1, nil while reading
        var unsupported = false   // the monitor didn't answer DDC
    }

    // What the monitor can do, learned from the first read.
    struct Hardware {
        var read = false           // false until the first successful read; no writes before it
        var brightnessMax = 100
        var contrastMax = 0        // 0 = contrast not controllable
        var contrastNormal = 0     // the user's own contrast, restored above the dim range
    }

    // Saved per monitor so a monitor left dimmed (quit, crash, power cut) gets the user's own
    // contrast back. `dimmed` is set only when ScreenOff itself lowers the contrast.
    private struct Saved: Codable {
        var normal: Int
        var dimmed: Bool
    }
    private static func savedKey(_ id: CGDirectDisplayID) -> String? {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return nil }
        return "display-" + (CFUUIDCreateString(nil, uuid) as String)
    }
    private static func loadSaved(_ id: CGDirectDisplayID) -> Saved? {
        guard let key = savedKey(id), let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(Saved.self, from: data)
    }
    private static func store(_ saved: Saved, _ id: CGDirectDisplayID) {
        guard let key = savedKey(id), let data = try? JSONEncoder().encode(saved) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    private enum Control {
        case builtIn
        case ddc(DDCChannel, Hardware)
    }

    // Below this slider value the monitor is already at brightness 0, so the rest of the way down
    // lowers its contrast toward 0. Only used when the monitor's contrast is controllable.
    static let contrastShare = 0.3

    @Published var rows: [Row] = []
    private var controls: [CGDirectDisplayID: Control] = [:]
    private var pending: [CGDirectDisplayID: Double] = [:]
    private var writing = false
    private let queue = DispatchQueue(label: "com.codeclawd.screenoff.brightness")

    // One model lives as long as the app. It lists displays now and again whenever monitors are
    // plugged in or removed; each panel open only re-reads the levels (see readValues).
    init() {
        reloadDisplays()
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.reloadDisplays()
        }
    }

    private func reloadDisplays() {
        let channels = DDCChannel.channelsByLocation()
        var newRows: [Row] = []
        var newControls: [CGDirectDisplayID: Control] = [:]
        for screen in NSScreen.screens {
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { continue }
            if CGDisplayIsBuiltin(id) != 0 {
                guard Private.getBrightness != nil, Private.setBrightness != nil else { continue }
                newControls[id] = .builtIn
            } else if let info = Private.infoDict?(id)?.takeRetainedValue() as NSDictionary?,
                      let path = info["IODisplayLocation"] as? String, let channel = channels[path] {
                // Keep what an earlier read learned about this monitor; only the connection is new.
                if case .ddc(_, let known) = controls[id] { newControls[id] = .ddc(channel, known) }
                else { newControls[id] = .ddc(channel, Hardware()) }
            } else {
                continue
            }
            newRows.append(Row(id: id, name: screen.localizedName))
        }
        rows = newRows
        controls = newControls
        pending = pending.filter { newControls[$0.key] != nil }
        log.notice("brightness rows: \(newRows.map(\.name).joined(separator: ", "), privacy: .public)")
        readValues()
    }

    // Reads each display on the brightness queue, so reads never overlap a write.
    func readValues() {
        let snapshot = controls
        queue.async {
            for (id, control) in snapshot {
                switch control {
                case .builtIn:
                    var level: Float = 0
                    let ok = Private.getBrightness?(id, &level) == 0
                    DispatchQueue.main.async { self.update(id, value: ok ? Double(level) : nil) }
                case .ddc(let channel, _):
                    let brightness = channel.read(DDCChannel.brightness)
                    let contrast = brightness == nil ? nil : channel.read(DDCChannel.contrast)
                    log.notice("display \(id, privacy: .public) brightness \(brightness?.current ?? -1, privacy: .public)/\(brightness?.max ?? -1, privacy: .public) contrast \(contrast?.current ?? -1, privacy: .public)/\(contrast?.max ?? -1, privacy: .public)")
                    DispatchQueue.main.async {
                        guard let brightness, case .ddc(_, let known) = self.controls[id] else { return self.update(id, value: nil) }
                        var hardware = Hardware(read: true, brightnessMax: brightness.max)
                        var value = Double(brightness.current) / Double(brightness.max)
                        let share = Self.contrastShare
                        let saved = Self.loadSaved(id)
                        if let contrast {
                            hardware.contrastMax = contrast.max
                            if let saved, saved.dimmed {
                                hardware.contrastNormal = saved.normal
                                if brightness.current == 0 {
                                    value = share * Double(contrast.current) / Double(max(saved.normal, 1))
                                } else {
                                    value = share + (1 - share) * value
                                }
                            } else {
                                // Not dimmed by us: whatever the monitor shows is the user's normal,
                                // including a change made in the monitor's own menu.
                                hardware.contrastNormal = contrast.current
                                Self.store(Saved(normal: contrast.current, dimmed: false), id)
                                value = share + (1 - share) * value
                            }
                        } else if known.read {
                            // Contrast didn't answer this time; keep what we learned before.
                            hardware.contrastMax = known.contrastMax
                            hardware.contrastNormal = known.contrastNormal
                            if hardware.contrastMax > 0 { value = share + (1 - share) * value }
                        }
                        self.controls[id] = .ddc(channel, hardware)
                        self.update(id, value: value)
                    }
                }
            }
        }
    }

    private func update(_ id: CGDirectDisplayID, value: Double?) {
        // A drag that started while the read was running wins over the older reading.
        guard pending[id] == nil, let index = rows.firstIndex(where: { $0.id == id }) else { return }
        rows[index].value = value
        rows[index].unsupported = value == nil
    }

    // Called on every slider move. Sends only the newest value once the previous write finishes,
    // so dragging never queues up a backlog of slow DDC writes.
    func set(_ id: CGDirectDisplayID, to value: Double) {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        rows[index].value = value
        pending[id] = value
        flush()
    }

    // Slider value -> (brightness, contrast) for the monitor. Contrast is nil when it isn't used.
    static func targets(_ value: Double, _ hw: Hardware) -> (brightness: Int, contrast: Int?) {
        guard hw.contrastMax > 0, hw.contrastNormal > 0 else {
            return (Int((value * Double(hw.brightnessMax)).rounded()), nil)
        }
        let share = contrastShare
        if value >= share {
            return (Int(((value - share) / (1 - share) * Double(hw.brightnessMax)).rounded()), hw.contrastNormal)
        }
        return (0, Int((value / share * Double(hw.contrastNormal)).rounded()))
    }

    private func flush() {
        guard !writing, let (id, value) = pending.first.map({ ($0.key, $0.value) }) else { return }
        pending[id] = nil
        guard let control = controls[id] else { return flush() }
        if case .ddc(_, let hw) = control, !hw.read { return flush() }
        writing = true
        queue.async {
            Self.apply(control, id: id, value: value)
            DispatchQueue.main.async {
                self.writing = false
                self.flush()
            }
        }
    }

    private static func apply(_ control: Control, id: CGDirectDisplayID, value: Double) {
        switch control {
        case .builtIn:
            _ = Private.setBrightness?(id, Float(value))
        case .ddc(let channel, let hw):
            let target = targets(value, hw)
            // Lower brightness before contrast and raise contrast before brightness, so a drag
            // never flashes a bright, washed-out picture on the way.
            let setBrightness = { channel.write(DDCChannel.brightness, target.brightness) }
            let ok: Bool
            if let contrast = target.contrast {
                let setContrast = {
                    guard channel.write(DDCChannel.contrast, contrast) else { return false }
                    store(Saved(normal: hw.contrastNormal, dimmed: contrast < hw.contrastNormal), id)
                    return true
                }
                ok = target.brightness == 0 ? setBrightness() && setContrast() : setContrast() && setBrightness()
            } else {
                ok = setBrightness()
            }
            if !ok { log.error("display \(id, privacy: .public) DDC write failed") }
        }
    }

    // Called when the app quits: put the user's own contrast back on any monitor ScreenOff dimmed.
    // Waits at most 2 seconds so Quit never hangs on a monitor that stopped answering.
    func restoreAll() {
        let snapshot = controls
        let done = DispatchSemaphore(value: 0)
        queue.async {
            for (id, control) in snapshot {
                guard case .ddc(let channel, _) = control, let saved = Self.loadSaved(id), saved.dimmed else { continue }
                if channel.write(DDCChannel.contrast, saved.normal) {
                    Self.store(Saved(normal: saved.normal, dimmed: false), id)
                }
            }
            done.signal()
        }
        _ = done.wait(timeout: .now() + 2)
    }
}
