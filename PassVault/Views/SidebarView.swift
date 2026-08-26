import SwiftUI

struct SidebarView: View {
    @EnvironmentObject private var store: VaultStore
    /// iOS の List は選択をオプショナルでしか受け取れないため、
    /// macOS と共通にするためこちらもオプショナルにしてある。
    @Binding var selection: SidebarSelection?

    var body: some View {
        List(selection: $selection) {
            Section {
                row(.all)
                row(.favorites)
            }

            Section("カテゴリ") {
                ForEach(ItemCategory.allCases) { category in
                    let selection = SidebarSelection.category(category)
                    if store.count(for: selection) > 0 {
                        row(selection)
                    }
                }
            }

            Section("セキュリティ") {
                NavigationLink(value: SidebarSelection.watchtower) {
                    Label {
                        HStack {
                            Text("Watchtower")
                            Spacer()
                            if !store.findings.isEmpty {
                                Text("\(store.findings.count)")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Capsule().fill(.red))
                            }
                        }
                    } icon: {
                        Image(systemName: "shield.lefthalf.filled")
                            .foregroundStyle(store.findings.isEmpty ? Color.green : Color.orange)
                    }
                }
                .tag(SidebarSelection.watchtower)
            }

            if !store.tags.isEmpty {
                Section("タグ") {
                    ForEach(store.tags, id: \.self) { tag in
                        row(.tag(tag))
                    }
                }
            }

            Section {
                row(.trash)
            }
        }
        .navigationTitle("PassVault")
        #if os(macOS)
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 300)
        #endif
    }

    private func row(_ selection: SidebarSelection) -> some View {
        NavigationLink(value: selection) {
            Label {
                HStack {
                    Text(selection.title)
                    Spacer()
                    Text("\(store.count(for: selection))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            } icon: {
                Image(systemName: selection.symbol)
            }
        }
        .tag(selection)
    }
}
