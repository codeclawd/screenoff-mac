// Draws docs/social-preview.png (1280x640), the image GitHub, X and Slack show for the repo link.
// Usage: swift scripts/make-social.swift   (run from the repo root after scripts/snapshot)
import AppKit

let W: CGFloat = 1280, H: CGFloat = 640
let icon = NSImage(contentsOfFile: "docs/icon.png")!
let panel = NSImage(contentsOfFile: "docs/panel-dark.png")!
let image = NSImage(size: NSSize(width: W, height: H), flipped: false) { rect in
    NSGradient(colors: [NSColor(red: 0.20, green: 0.18, blue: 0.48, alpha: 1),
                        NSColor(red: 0.04, green: 0.04, blue: 0.11, alpha: 1)])!.draw(in: rect, angle: -60)

    icon.draw(in: NSRect(x: 84, y: 430, width: 120, height: 120))
    func line(_ s: String, _ size: CGFloat, _ weight: NSFont.Weight, _ alpha: CGFloat, _ y: CGFloat) {
        NSAttributedString(string: s, attributes: [
            .font: NSFont.systemFont(ofSize: size, weight: weight),
            .foregroundColor: NSColor.white.withAlphaComponent(alpha),
        ]).draw(at: NSPoint(x: 90, y: y))
    }
    line("ScreenOff", 88, .bold, 1, 300)
    line("Sleep your Mac's display.", 40, .medium, 0.88, 222)
    line("Keep your agents running.", 40, .medium, 0.88, 172)
    line("Free · macOS menu bar app · Apple silicon & Intel", 22, .regular, 0.55, 70)

    // The real panel, as rendered by scripts/snapshot (it has 40 pt of transparent margin).
    let ph: CGFloat = 560
    let pw = ph * panel.size.width / panel.size.height
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.5)
    shadow.shadowBlurRadius = 40
    shadow.shadowOffset = NSSize(width: 0, height: -12)
    shadow.set()
    panel.draw(in: NSRect(x: W - pw - 40, y: (H - ph) / 2, width: pw, height: ph))
    return true
}
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W), pixelsHigh: Int(H), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = NSSize(width: W, height: H)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
image.draw(in: NSRect(x: 0, y: 0, width: W, height: H))
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "docs/social-preview.png"))
print("docs/social-preview.png")
