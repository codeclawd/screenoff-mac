import AppKit
import CoreGraphics
import IOKit
import os

private let log = Logger(subsystem: "com.codeclawd.screenoff", category: "brightness")

// Brightness for every connected display.
// - External monitors: DDC/CI over the cable (VCP code 0x10, luminance). Apple silicon only.
//   The method follows MonitorControl (MIT License, https://github.com/MonitorControl/MonitorControl).
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
    private static let luminance: UInt8 = 0x10

    // Returns (current, max) brightness, or nil if the monitor didn't answer.
    func readBrightness() -> (current: Int, max: Int)? {
        guard let write = Private.avWrite, let read = Private.avRead else { return nil }
        var packet = Self.packet([Self.luminance])
        for _ in 0..<5 {
            for _ in 0..<2 {
                usleep(10_000)
                _ = write(service, Self.chip, Self.dataAddress, &packet, UInt32(packet.count))
            }
            usleep(50_000)
            var reply = [UInt8](repeating: 0, count: 11)
            if read(service, Self.chip, 0, &reply, UInt32(reply.count)) == 0,
               reply[0..<10].reduce(UInt8(0x50), ^) == reply[10] {
                let max = Int(reply[6]) << 8 | Int(reply[7])
                let current = Int(reply[8]) << 8 | Int(reply[9])
                if max > 0 { return (current, max) }
            }
            usleep(20_000)
        }
        return nil
    }

    func writeBrightness(_ value: Int) -> Bool {
        guard let write = Private.avWrite else { return false }
        var packet = Self.packet([Self.luminance, UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)])
        for _ in 0..<5 {
            usleep(10_000)
            if write(service, Self.chip, Self.dataAddress, &packet, UInt32(packet.count)) == 0 { return true }
            usleep(20_000)
        }
        return false
    }

    // DDC/CI frame: length byte, payload, then an XOR checksum over the monitor's address (0x6E),
    // the host's address (0x51, sent as the I2C sub-address) and every byte before it.
    private static func packet(_ payload: [UInt8]) -> [UInt8] {
        let body = [UInt8(0x80 | (payload.count + 1)), UInt8(payload.count)] + payload
        return body + [body.reduce(UInt8(chip << 1) ^ UInt8(dataAddress), ^)]
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

    private enum Control {
        case builtIn
        case ddc(DDCChannel, max: Int)
    }

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
                newControls[id] = .ddc(channel, max: 100)
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

    // Reads each display's brightness on the brightness queue, so reads never overlap a write.
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
                    let reading = channel.readBrightness()
                    log.notice("display \(id, privacy: .public) DDC brightness \(reading?.current ?? -1, privacy: .public)/\(reading?.max ?? -1, privacy: .public)")
                    DispatchQueue.main.async {
                        if let reading, self.controls[id] != nil { self.controls[id] = .ddc(channel, max: reading.max) }
                        self.update(id, value: reading.map { Double($0.current) / Double($0.max) })
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

    private func flush() {
        guard !writing, let (id, value) = pending.first.map({ ($0.key, $0.value) }) else { return }
        pending[id] = nil
        guard let control = controls[id] else { return flush() }
        writing = true
        queue.async {
            switch control {
            case .builtIn:
                _ = Private.setBrightness?(id, Float(value))
            case .ddc(let channel, let max):
                if !channel.writeBrightness(Int((value * Double(max)).rounded())) {
                    log.error("display \(id, privacy: .public) DDC write failed")
                }
            }
            DispatchQueue.main.async {
                self.writing = false
                self.flush()
            }
        }
    }
}
