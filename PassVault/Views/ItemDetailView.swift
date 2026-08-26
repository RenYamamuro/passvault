import SwiftUI

struct ItemDetailView: View {
    @EnvironmentObject private var store: VaultStore

    let item: VaultItem
    var onEdit: () -> Void
    var onToast: (String) -> Void

    @State private var revealedFields: Set<UUID> = []
    @State private var showingHistory = false
    @State private var confirmingDelete = false

    private var findings: [WatchtowerFinding] { store.findings(for: item.id) }
    private var filledFields: [ItemField] { item.fields.filter { !$0.isEmpty } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header

                if item.isTrashed {
                    banner(
                        "この項目はゴミ箱にあります",
                        detail: "元に戻すまで検索結果には出てきません。",
                        color: .secondary,
                        symbol: "trash"
                    )
                }

                if !findings.isEmpty {
                    VStack(spacing: 8) {
                        ForEach(findings) { finding in
                            banner(
                                finding.kind.title,
                                detail: finding.detail,
                                color: .orange,
                                symbol: finding.kind.symbol
                            )
                        }
                    }
                }

                if !filledFields.isEmpty {
                    card {
                        ForEach(Array(filledFields.enumerated()), id: \.element.id) { index, field in
                            if index > 0 { Divider().padding(.leading, 12) }
                            fieldRow(field)
                        }
                    }
                }

                if item.hasOneTimePassword {
                    card {
                        OneTimePasswordRow(secret: item.oneTimePasswordSecret, onToast: onToast)
                    }
                }

                if !item.tags.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(item.tags, id: \.self) { tag in
                            Label(tag, systemImage: "tag")
                                .font(.caption)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(.quaternary.opacity(0.5), in: Capsule())
                        }
                    }
                }

                if !item.notes.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("メモ").font(.caption).foregroundStyle(.secondary)
                        Text(item.notes)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
                    }
                }

                if !item.passwordHistory.isEmpty {
                    passwordHistory
                }

                metadata
            }
            .padding(24)
            .frame(maxWidth: 640, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .navigationTitle(item.displayTitle)
        .toolbar { toolbar }
        .confirmationDialog(
            "「\(item.displayTitle)」を完全に削除しますか？",
            isPresented: $confirmingDelete,
            titleVisibility: .visible
        ) {
            Button("完全に削除", role: .destructive) {
                perform { try store.deletePermanently(item) }
                onToast("完全に削除しました")
            }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("この操作は取り消せません。")
        }
    }

    // MARK: - 各パーツ

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: item.category.symbol)
                .font(.system(size: 22))
                .foregroundStyle(.white)
                .frame(width: 52, height: 52)
                .background(Circle().fill(Color.appAccent))

            VStack(alignment: .leading, spacing: 2) {
                Text(item.displayTitle).font(.title2.weight(.semibold))
                Text(item.category.displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                perform { try store.toggleFavorite(item) }
            } label: {
                Image(systemName: item.isFavorite ? "star.fill" : "star")
                    .font(.title3)
                    .foregroundStyle(item.isFavorite ? Color.yellow : Color.secondary)
            }
            .buttonStyle(.borderless)
            .help(item.isFavorite ? "お気に入りから外す" : "お気に入りに追加")
        }
    }

    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) { content() }
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }

    private func banner(_ title: String, detail: String, color: Color, symbol: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(color)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
    }

    private func fieldRow(_ field: ItemField) -> some View {
        let isRevealed = revealedFields.contains(field.id)
        let concealed = field.kind.isConcealed && !isRevealed

        return HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(field.label).font(.caption).foregroundStyle(.secondary)

                if field.kind == .url, let url = normalizedURL(field.value) {
                    Link(field.value, destination: url)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    Text(concealed ? String(repeating: "•", count: min(max(field.value.count, 8), 24)) : field.displayValue)
                        .font(field.kind.isConcealed ? .system(.body, design: .monospaced) : .body)
                        // 伏せ字のときは中身が「•」なので、選択できても漏れはない
                        .textSelection(.enabled)
                        .lineLimit(field.kind == .multiline ? nil : 1)
                        .truncationMode(.middle)
                        .fixedSize(horizontal: false, vertical: field.kind == .multiline)
                }

                if field.kind == .password {
                    strengthCaption(for: field.value)
                }
            }

            Spacer(minLength: 8)

            if field.kind.isConcealed {
                Button {
                    if isRevealed { revealedFields.remove(field.id) } else { revealedFields.insert(field.id) }
                } label: {
                    Image(systemName: isRevealed ? "eye.slash" : "eye")
                }
                .buttonStyle(.borderless)
                .help(isRevealed ? "隠す" : "表示")
            }

            Button {
                if field.kind.isSecret {
                    Clipboard.copySecret(field.value)
                    onToast("\(field.label)をコピーしました（\(Int(Clipboard.clearAfter))秒で消去）")
                } else {
                    Clipboard.copyPlain(field.value)
                    onToast("\(field.label)をコピーしました")
                }
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help("コピー")
        }
        .padding(12)
    }

    private func strengthCaption(for password: String) -> some View {
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
        return Text("強度: \(level.label)（推定 \(Int(bits)) ビット）")
            .font(.caption2)
            .foregroundStyle(color)
    }

    private var passwordHistory: some View {
        DisclosureGroup(isExpanded: $showingHistory) {
            VStack(spacing: 0) {
                ForEach(Array(item.passwordHistory.enumerated()), id: \.element.id) { index, change in
                    if index > 0 { Divider() }
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(change.value)
                                .font(.system(.callout, design: .monospaced))
                                .textSelection(.enabled)
                            Text("\(change.changedAt.formatted(date: .abbreviated, time: .shortened)) まで使用")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            Clipboard.copySecret(change.value)
                            onToast("以前のパスワードをコピーしました")
                        } label: {
                            Image(systemName: "doc.on.doc")
                        }
                        .buttonStyle(.borderless)
                    }
                    .padding(10)
                }
            }
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
        } label: {
            Text("以前のパスワード（\(item.passwordHistory.count)件）")
                .font(.callout)
        }
    }

    private var metadata: some View {
        Text(
            "更新: \(item.updatedAt.formatted(date: .abbreviated, time: .shortened))　"
            + "作成: \(item.createdAt.formatted(date: .abbreviated, time: .omitted))"
        )
        .font(.caption2)
        .foregroundStyle(.tertiary)
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if item.isTrashed {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    perform { try store.restore(item) }
                    onToast("元に戻しました")
                } label: {
                    Label("元に戻す", systemImage: "arrow.uturn.backward")
                }
            }
            ToolbarItem(placement: .automatic) {
                Button(role: .destructive) { confirmingDelete = true } label: {
                    Label("完全に削除", systemImage: "trash.slash")
                }
            }
        } else {
            ToolbarItem(placement: .primaryAction) {
                Button { onEdit() } label: { Label("編集", systemImage: "pencil") }
            }
            ToolbarItem(placement: .automatic) {
                Button(role: .destructive) {
                    perform { try store.moveToTrash(item) }
                    onToast("ゴミ箱に入れました")
                } label: {
                    Label("ゴミ箱に入れる", systemImage: "trash")
                }
            }
        }
    }

    private func normalizedURL(_ string: String) -> URL? {
        if string.contains("://") { return URL(string: string) }
        return URL(string: "https://" + string)
    }

    private func perform(_ action: () throws -> Void) {
        do { try action() } catch { onToast("失敗: \(error.localizedDescription)") }
    }
}

/// ワンタイムパスワードの表示。1 秒ごとに残り時間の輪が縮んでいく。
struct OneTimePasswordRow: View {
    let secret: String
    var onToast: (String) -> Void

    var body: some View {
        if let otp = OneTimePassword.parse(secret) {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let remaining = otp.secondsRemaining(at: context.date)
                let fraction = Double(remaining) / Double(otp.period)

                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("ワンタイムパスワード").font(.caption).foregroundStyle(.secondary)
                        Text(otp.formattedCode(at: context.date))
                            .font(.system(.title2, design: .monospaced).weight(.medium))
                            .monospacedDigit()
                            // 残り 5 秒を切ったら、今コピーすると間に合わないかもと分かるように
                            .foregroundStyle(remaining <= 5 ? Color.orange : Color.primary)
                    }

                    Spacer()

                    ZStack {
                        Circle().stroke(.quaternary, lineWidth: 3)
                        Circle()
                            .trim(from: 0, to: fraction)
                            .stroke(remaining <= 5 ? Color.orange : Color.appAccent,
                                    style: StrokeStyle(lineWidth: 3, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                        Text("\(remaining)")
                            .font(.caption2)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    .frame(width: 28, height: 28)

                    Button {
                        Clipboard.copySecret(otp.code(at: Date()))
                        onToast("ワンタイムパスワードをコピーしました")
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                    .help("コピー")
                }
                .padding(12)
            }
        } else {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text("ワンタイムパスワードの設定を読み取れませんでした")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
