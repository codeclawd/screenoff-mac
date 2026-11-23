// Renders the real panel view to PNG without a screen (used for the README images).
// Build: swiftc scripts/snapshot/main.swift Sources/PanelView.swift Sources/Brightness.swift -o build/snapshot
import AppKit
import SwiftUI

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
let brightness = BrightnessModel()
var waited = 0.0
while brightness.rows.contains(where: { $0.value == nil && !$0.unsupported }) && waited < 5 {
    RunLoop.current.run(until: Date().addingTimeInterval(0.1)); waited += 0.1
}
for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
    let host = NSHostingView(rootView: SleepPanelView(onSleep: {}, onQuit: {}, opensAtLogin: true, setOpensAtLogin: { $0 }, brightness: brightness)
        .environment(\.controlActiveState, .key))
    host.appearance = NSAppearance(named: appearance)
    let size = host.fittingSize
    let scale: CGFloat = 2
    let pad: CGFloat = 40
    let canvas = NSView(frame: NSRect(x: 0, y: 0, width: size.width + pad * 2, height: size.height + pad * 2))
    canvas.appearance = host.appearance
    let card = NSView(frame: NSRect(x: pad, y: pad, width: size.width, height: size.height))
    card.wantsLayer = true
    card.layer?.cornerRadius = 14
    card.layer?.cornerCurve = .continuous
    card.layer?.masksToBounds = true
    card.layer?.backgroundColor = (name == "light" ? NSColor(white: 0.96, alpha: 1) : NSColor(white: 0.17, alpha: 1)).cgColor
    card.layer?.borderWidth = 0.5
    card.layer?.borderColor = NSColor(white: name == "light" ? 0 : 1, alpha: 0.12).cgColor
    host.frame = card.bounds
    card.addSubview(host)
    canvas.addSubview(card)
    let window = NSWindow(contentRect: canvas.frame, styleMask: .borderless, backing: .buffered, defer: false)
    window.contentView = canvas
    window.backingType = .buffered
    window.layoutIfNeeded()
    canvas.layoutSubtreeIfNeeded()
    RunLoop.current.run(until: Date().addingTimeInterval(0.3))
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(canvas.bounds.width * scale), pixelsHigh: Int(canvas.bounds.height * scale),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = canvas.bounds.size
    NSAppearance(named: appearance)!.performAsCurrentDrawingAppearance {
        canvas.cacheDisplay(in: canvas.bounds, to: rep)
    }
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "docs/panel-\(name).png"))
    print("docs/panel-\(name).png", size)
}
