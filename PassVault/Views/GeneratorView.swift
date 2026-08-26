import SwiftUI

struct GeneratorView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var options = PasswordOptions()
    @State private var generated = ""

    /// 「使う」を押したときの受け取り先。編集画面なら入力欄へ、一覧からならコピー。
    var onUse: (String) -> Void

    private var bits: Double { PasswordGenerator.entropyBits(options) }

    private var noCharacterSet: Bool {
        !options.useLowercase && !options.useUppercase && !options.useDigits && !options.useSymbols
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(generated.isEmpty ? " " : generated)
                            .font(.system(.title3, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(12)
                            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))

                        HStack {
                            strengthBar
                            Spacer()
                            Button {
                                regenerate()
                            } label: {
                                Label("作り直す", systemImage: "arrow.clockwise")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section("長さ") {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("\(options.length) 文字")
                            Spacer()
                            Text("約 \(Int(bits)) ビット")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: Binding(
                            get: { Double(options.length) },
                            set: { options.length = Int($0) }
                        ), in: 8...64, step: 1)
                    }
                }

                Section("使う文字") {
                    Toggle("小文字 a-z", isOn: $options.useLowercase)
                    Toggle("大文字 A-Z", isOn: $options.useUppercase)
                    Toggle("数字 0-9", isOn: $options.useDigits)
                    Toggle("記号 !#$%…", isOn: $options.useSymbols)
                    Toggle("紛らわしい文字を除く（0 O 1 l I など）", isOn: $options.avoidAmbiguous)
                }

                if noCharacterSet {
                    Text("最低1種類は選んでください。")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("パスワード生成")
            #if !os(macOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("使う") {
                        onUse(generated)
                        dismiss()
                    }
                    .disabled(generated.isEmpty)
                }
            }
            .onAppear(perform: regenerate)
            .onChange(of: options) { _, _ in regenerate() }
        }
        #if os(macOS)
        .frame(width: 460, height: 560)
        #endif
    }

    private var strengthBar: some View {
        let level = PasswordStrength.level(bits: bits)
        let color: Color = {
            switch level {
            case .veryWeak, .weak: return .red
            case .fair: return .orange
            case .good: return .green
            case .excellent: return .blue
            }
        }()
        return HStack(spacing: 8) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule().fill(color).frame(width: geo.size.width * min(bits / 128.0, 1.0))
                }
            }
            .frame(width: 100, height: 6)
            Text(level.label)
                .font(.caption)
                .foregroundStyle(color)
                // 幅が足りないと 2 行に折り返して見苦しくなるので固定する
                .lineLimit(1)
                .fixedSize()
        }
    }

    private func regenerate() {
        generated = PasswordGenerator.generate(options)
    }
}
