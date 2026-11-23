import SwiftUI

struct SleepPanelView: View {
    var onSleep: () -> Void
    var onQuit: () -> Void
    @State var opensAtLogin: Bool
    var setOpensAtLogin: (Bool) -> Bool
    @ObservedObject var brightness: BrightnessModel

    @State private var sleeping = false

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 6) {
                Image(systemName: sleeping ? "moon.zzz.fill" : "moon.stars.fill")
                    .symbolRenderingMode(.hierarchical)
                    .font(.system(size: 36))
                    .foregroundStyle(.tint)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(height: 44)
                Text(sleeping ? "Good night" : "Sleep display")
                    .font(.headline)
                Text("Turns the screen off.\nYour Mac keeps running.")
                    .font(.subheadline)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 20)

            Button(action: sleep) {
                Text("Sleep Display").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 14)

            if !brightness.rows.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(brightness.rows) { row in
                        BrightnessRow(row: row) { brightness.set(row.id, to: $0) }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }

            Divider()

            HStack {
                Toggle("Open at Login", isOn: Binding(
                    get: { opensAtLogin },
                    set: { opensAtLogin = setOpensAtLogin($0) }
                ))
                .toggleStyle(.checkbox)
                Spacer()
                Button("Quit", action: onQuit)
                    .buttonStyle(.plain)
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
        }
        .frame(width: 240)
    }

    private func sleep() {
        guard !sleeping else { return }
        withAnimation { sleeping = true }
        onSleep()
    }
}

private struct BrightnessRow: View {
    let row: BrightnessModel.Row
    let onChange: (Double) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(row.name)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if row.unsupported {
                Text("Brightness control not supported")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .frame(height: 20, alignment: .leading)
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "sun.min").foregroundStyle(.secondary)
                    Slider(value: Binding(get: { row.value ?? 0.5 }, set: onChange), in: 0...1)
                        .controlSize(.small)
                        .disabled(row.value == nil)
                        .accessibilityLabel("Brightness of \(row.name)")
                    Image(systemName: "sun.max").foregroundStyle(.secondary)
                }
                .font(.caption)
                .frame(height: 20)
            }
        }
    }
}
