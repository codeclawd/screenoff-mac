// Brightness round-trip check on the real displays: read, set 70%, read back, restore.
// Build: swiftc scripts/check/main.swift Sources/Brightness.swift -o build/brightness-check
import AppKit

_ = NSApplication.shared
let model = BrightnessModel()
func spin(_ seconds: Double) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
var waited = 0.0
while model.rows.contains(where: { $0.value == nil && !$0.unsupported }) && waited < 5 { spin(0.1); waited += 0.1 }
guard !model.rows.isEmpty else { print("FAIL: no controllable displays"); exit(1) }
var failed = false
for row in model.rows {
    guard let original = row.value else { print("FAIL: \(row.name) unreadable"); failed = true; continue }
    print("\(row.name): read \(Int(original * 100))%")
    model.set(row.id, to: 0.7)
    spin(1.0)
    let check = BrightnessModel()
    waited = 0
    while check.rows.first(where: { $0.id == row.id })?.value == nil && waited < 5 { spin(0.1); waited += 0.1 }
    let after = check.rows.first(where: { $0.id == row.id })?.value ?? -1
    print("\(row.name): after set 70% read back \(Int((after * 100).rounded()))%")
    if abs(after - 0.7) > 0.02 { failed = true }
    model.set(row.id, to: original)
    spin(1.0)
}
print(failed ? "FAIL" : "PASS")
exit(failed ? 1 : 0)
