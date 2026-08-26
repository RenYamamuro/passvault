import SwiftUI

struct ItemEditView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: VaultStore

    @State private var draft: VaultItem
    @State private var tagText: String
    @State private var revealedFields: Set<UUID> = []
    @State private var generatingFieldID: UUID?
    @State private var showingAddField = false
    @State private var newFieldLabel = ""
    @State private var newFieldKind: FieldKind = .text

    private let isNew: Bool
    private let onSave: (VaultItem) -> Void

    init(item: VaultItem, onSave: @escaping (VaultItem) -> Void) {
        _draft = State(initialValue: item)
        _tagText = State(initialValue: item.tags.joined(separator: ", "))
        isNew = item.title.isEmpty && item.fields.allSatisfy(\.isEmpty) && item.notes.isEmpty
        self.onSave = onSave
    }

    private var canSave: Bool {
        !draft.title.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledTextField(
                        label: "タイトル",
                        prompt: placeholderTitle,
                        text: $draft.title
                    )
                    LabeledContent("種別") {
                        Label(draft.category.displayName, systemImage: draft.category.symbol)
                            .foregroundStyle(.secondary)
                    }
                }

                if !draft.fields.isEmpty {
                    Section("項目") {
                        ForEach($draft.fields) { $field in
                            fieldEditor($field)
                        }
                        .onDelete { offsets in
                            // テンプレート由来の欄は残し、自分で足した欄だけ消せるようにする
                            let removable = offsets.filter { draft.fields[$0].isCustom }
                            draft.fields.remove(atOffsets: IndexSet(removable))
                        }
                    }
                }

                Section {
                    Button {
                        newFieldLabel = ""
                        newFieldKind = .text
                        showingAddField = true
                    } label: {
                        Label("欄を追加", systemImage: "plus.circle")
                    }
                }

                if draft.category.supportsOneTimePassword {
                    Section {
                        VStack(alignment: .leading, spacing: 6) {
                            TextField(
                                "",
                                text: $draft.oneTimePasswordSecret,
                                prompt: Text("otpauth://totp/... または Base32 のシークレット")
                            )
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.callout, design: .monospaced))
                            #if !os(macOS)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            #endif

                            oneTimePasswordPreview
                        }
                        .padding(.vertical, 2)
                    } header: {
                        Text("ワンタイムパスワード")
                    } footer: {
                        Text("認証アプリの登録画面に出る「手動入力用のキー」か、QRコードの中身（otpauth://…）をそのまま貼り付けてください。")
                    }
                }

                Section {
                    TextField("", text: $tagText, prompt: Text("カンマ区切り（例: 仕事, 経理）"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                    if !store.tags.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(store.tags, id: \.self) { tag in
                                    Button(tag) { appendTag(tag) }
                                        .buttonStyle(.bordered)
                                        .controlSize(.small)
                                }
                            }
                        }
                    }
                } header: {
                    Text("タグ")
                }

                Section("メモ") {
                    TextEditor(text: $draft.notes)
                        .frame(minHeight: 90)
                        .font(.body)
                }
            }
            .formStyle(.grouped)
            .navigationTitle(isNew ? "新規\(draft.category.displayName)" : "編集")
            #if !os(macOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }.disabled(!canSave)
                }
            }
            .sheet(isPresented: Binding(
                get: { generatingFieldID != nil },
                set: { if !$0 { generatingFieldID = nil } }
            )) {
                GeneratorView { generated in
                    if let id = generatingFieldID,
                       let index = draft.fields.firstIndex(where: { $0.id == id }) {
                        draft.fields[index].value = generated
                        revealedFields.insert(id)
                    }
                    generatingFieldID = nil
                }
            }
            .alert("欄を追加", isPresented: $showingAddField) {
                TextField("名前", text: $newFieldLabel)
                Button("追加") {
                    let label = newFieldLabel.trimmingCharacters(in: .whitespaces)
                    guard !label.isEmpty else { return }
                    draft.fields.append(ItemField(label: label, kind: newFieldKind, isCustom: true))
                }
                Button("キャンセル", role: .cancel) {}
            } message: {
                Text("この項目だけに使う欄を追加します。")
            }
        }
        #if os(macOS)
        .frame(width: 520, height: 620)
        #endif
    }

    // MARK: - 各パーツ

    private var placeholderTitle: String {
        switch draft.category {
        case .login: return "GitHub"
        case .secureNote: return "自宅のWi-Fi設定メモ"
        case .creditCard: return "楽天カード"
        case .identity: return "自分のプロフィール"
        case .apiCredential: return "OpenAI API"
        case .wifi: return "自宅ルーター"
        case .license: return "Sketch ライセンス"
        }
    }

    @ViewBuilder
    private func fieldEditor(_ field: Binding<ItemField>) -> some View {
        let kind = field.wrappedValue.kind
        let id = field.wrappedValue.id
        let isRevealed = revealedFields.contains(id)

        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(field.wrappedValue.label).font(.caption).foregroundStyle(.secondary)
                if field.wrappedValue.isCustom {
                    Text("カスタム")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
            }

            HStack(spacing: 8) {
                Group {
                    if kind == .multiline {
                        TextEditor(text: field.value).frame(minHeight: 60)
                    } else if kind.isConcealed && !isRevealed {
                        SecureField("", text: field.value)
                    } else {
                        TextField("", text: field.value)
                    }
                }
                // macOS の Form が確保するラベル欄をなくして、幅を他の入力欄と揃える
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .font(kind.isConcealed ? .system(.body, design: .monospaced) : .body)
                #if !os(macOS)
                .textInputAutocapitalization(kind == .multiline ? .sentences : .never)
                .autocorrectionDisabled(kind != .multiline)
                #endif

                if kind.isConcealed {
                    Button {
                        if isRevealed { revealedFields.remove(id) } else { revealedFields.insert(id) }
                    } label: {
                        Image(systemName: isRevealed ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.borderless)
                }

                if kind == .password {
                    Button {
                        generatingFieldID = id
                    } label: {
                        Image(systemName: "die.face.5")
                    }
                    .buttonStyle(.borderless)
                    .help("パスワードを生成")
                }
            }

            if kind == .password && !field.wrappedValue.isEmpty {
                strengthBar(for: field.wrappedValue.value)
            }
        }
        .padding(.vertical, 2)
    }

    private func strengthBar(for password: String) -> some View {
        let bits = PasswordStrength.estimateBits(password)
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
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule().fill(color)
                        .frame(width: geometry.size.width * min(bits / 128.0, 1.0))
                }
            }
            .frame(height: 4)
            Text(level.label).font(.caption2).foregroundStyle(color)
        }
    }

    @ViewBuilder
    private var oneTimePasswordPreview: some View {
        let trimmed = draft.oneTimePasswordSecret.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            EmptyView()
        } else if let otp = OneTimePassword.parse(trimmed) {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Label(
                    "\(otp.formattedCode(at: context.date))（残り \(otp.secondsRemaining(at: context.date)) 秒）",
                    systemImage: "checkmark.circle.fill"
                )
                .font(.caption)
                .foregroundStyle(.green)
                .monospacedDigit()
            }
        } else {
            Label("この文字列からはコードを作れません", systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }

    // MARK: - 操作

    private func appendTag(_ tag: String) {
        var tags = parsedTags
        guard !tags.contains(tag) else { return }
        tags.append(tag)
        tagText = tags.joined(separator: ", ")
    }

    private var parsedTags: [String] {
        tagText
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private func save() {
        var item = draft
        item.tags = parsedTags
        item.oneTimePasswordSecret = item.oneTimePasswordSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        onSave(item)
        dismiss()
    }
}

private struct LabeledTextField: View {
    let label: String
    let prompt: String
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            // macOS の Form は TextField の第 1 引数を欄の左のラベルとして描く。
            // 入力例をそこに渡すと、値と並んで例文が居座ってしまうので、
            // ラベルは空にして prompt: 側に入れる（両 OS とも欄内の薄い文字になる）。
            TextField("", text: $text, prompt: Text(prompt))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
        }
        .padding(.vertical, 2)
    }
}
