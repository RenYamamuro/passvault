import SwiftUI

/// 保管庫全体の弱点を並べる画面。通信は一切せず、端末内の情報だけで判断する。
struct WatchtowerView: View {
    @EnvironmentObject private var store: VaultStore
    @Binding var selectedItemID: VaultItem.ID?

    private var grouped: [(kind: WatchtowerFinding.Kind, findings: [WatchtowerFinding])] {
        WatchtowerFinding.Kind.allCases.compactMap { kind in
            let matching = store.findings.filter { $0.kind == kind }
            return matching.isEmpty ? nil : (kind, matching)
        }
    }

    var body: some View {
        List(selection: $selectedItemID) {
            if store.findings.isEmpty {
                Section {
                    HStack(spacing: 10) {
                        Image(systemName: "checkmark.shield.fill")
                            .font(.title2)
                            .foregroundStyle(.green)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("問題は見つかりませんでした").font(.callout.weight(.medium))
                            Text("使い回し・推測されやすいパスワード・長く変えていないパスワードのいずれもありません。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.vertical, 6)
                }
            }

            ForEach(grouped, id: \.kind) { group in
                Section {
                    ForEach(group.findings) { finding in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(finding.itemTitle).lineLimit(1)
                            Text(finding.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        .padding(.vertical, 2)
                        .tag(finding.itemID)
                    }
                } header: {
                    Label("\(group.kind.title)（\(group.findings.count)）", systemImage: group.kind.symbol)
                } footer: {
                    Text(group.kind.explanation)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Watchtower")
    }
}
