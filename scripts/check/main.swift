// Hardware brightness check on the real external monitors. For each one:
// slider 0.65 -> brightness ~50% at normal contrast, slider 0.15 -> brightness 0 and contrast
// at half of normal, slider 0 -> contrast 0, restoreAll -> normal contrast, then back to the start.
// Your screen goes dark for a couple of seconds.
// Build: xcrun swiftc scripts/check/main.swift Sources/Brightness.swift -o build/brightness-check
import AppKit

_ = NSApplication.shared
let model = BrightnessModel()
func spin(_ seconds: Double) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
func waitForValues(_ m: BrightnessModel) {
    var waited = 0.0
    while m.rows.contains(where: { $0.value == nil && !$0.unsupported }) && waited < 6 { spin(0.1); waited += 0.1 }
}
waitForValues(model)
let channels = DDCChannel.channelsByLocation()
var failed = false
func expect(_ ok: Bool, _ what: String) { print(ok ? "ok  " : "FAIL", what); if !ok { failed = true } }

// Every external monitor has exactly one DDC channel; read its raw levels straight from the monitor.
func raw(_ code: UInt8) -> (current: Int, max: Int)? { channels.values.first?.read(code) }

for row in model.rows where CGDisplayIsBuiltin(row.id) == 0 {
    guard channels.count == 1 else { print("skip: raw checks need exactly one external monitor"); break }
    let start = row.value ?? 1
    let normal = raw(DDCChannel.contrast)?.current ?? -1
    print("\(row.name): start slider \(start), contrast \(normal)")

    model.set(row.id, to: 0.65); spin(1)
    let b = raw(DDCChannel.brightness), c = raw(DDCChannel.contrast)
    expect(b.map { abs($0.current * 100 / $0.max - 50) <= 1 } ?? false, "slider 0.65 -> brightness 50 (got \(b?.current ?? -1))")
    expect(c?.current == normal, "slider 0.65 keeps normal contrast (got \(c?.current ?? -1))")

    model.set(row.id, to: 0.15); spin(1)
    let b2 = raw(DDCChannel.brightness), c2 = raw(DDCChannel.contrast)
    expect(b2?.current == 0, "slider 0.15 -> brightness 0 (got \(b2?.current ?? -1))")
    expect(abs((c2?.current ?? -99) - normal / 2) <= 1, "slider 0.15 -> contrast half of \(normal) (got \(c2?.current ?? -1))")

    model.set(row.id, to: 0); spin(1)
    expect(raw(DDCChannel.contrast)?.current == 0, "slider 0 -> contrast 0")

    let reread = BrightnessModel(); waitForValues(reread)
    expect(reread.rows.first(where: { $0.id == row.id })?.value == 0, "a fresh read shows the slider at 0")

    // As if the app crashed while dimmed: a new model must still know the user's normal contrast.
    reread.set(row.id, to: 0.65); spin(1)
    expect(raw(DDCChannel.contrast)?.current == normal, "after a restart, dragging up restores contrast \(normal)")

    model.set(row.id, to: 0); spin(1)
    model.restoreAll(); spin(0.5)
    expect(raw(DDCChannel.contrast)?.current == normal, "restoreAll puts contrast back to \(normal)")
    let afterQuit = BrightnessModel(); waitForValues(afterQuit)
    afterQuit.restoreAll()
    expect(raw(DDCChannel.contrast)?.current == normal, "restoreAll with nothing dimmed leaves contrast alone")

    model.set(row.id, to: start); spin(1)
}
print(failed ? "FAIL" : "PASS")
exit(failed ? 1 : 0)
