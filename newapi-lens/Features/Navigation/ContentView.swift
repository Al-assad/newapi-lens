import SwiftUI

enum AppSection: String, CaseIterable, Identifiable {
    case data = "数据"
    case accounts = "账户"
    case settings = "设置"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .data: "chart.bar.xaxis"
        case .accounts: "person.2.fill"
        case .settings: "gearshape.fill"
        }
    }
}

struct ContentView: View {
    @EnvironmentObject private var store: LensStore

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 320)
        } detail: {
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(LensTheme.windowBackground)
        }
        .navigationSplitViewStyle(.balanced)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            accountHeader
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .padding(.bottom, 8)
                .frame(maxWidth: .infinity, alignment: .leading)

            List(selection: Binding(
                get: { store.selectedSection },
                set: { if let value = $0 { store.selectedSection = value } }
            )) {
                ForEach(AppSection.allCases) { section in
                    NavigationLink(value: section) {
                        Label(section.rawValue, systemImage: section.icon)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)

            sidebarStatusPanel
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 18)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(LensTheme.sidebarBackground)
    }

    private var accountHeader: some View {
        HStack(spacing: 10) {
            Image("SidebarIcon")
                .resizable()
                .interpolation(.high)
                .frame(width: 42, height: 42)
                .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .strokeBorder(.white.opacity(0.08), lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.18), radius: 6, x: 0, y: 2)

            VStack(alignment: .leading, spacing: 2) {
                Text("NewAPI Lens")
                    .font(.system(size: 17, weight: .semibold))
            }
        }
        .frame(minHeight: 52, alignment: .leading)
    }

    private var sidebarStatusPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(LensTheme.secondaryText)
                Text("数据状态")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(LensTheme.secondaryText)
            }

            Text(store.latestSyncText)
                .font(.caption)
                .foregroundStyle(LensTheme.primaryText)

            Text(store.isLoading ? "同步中..." : "同步正常")
                .font(.caption)
                .foregroundStyle(LensTheme.secondaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panelStyle(cornerRadius: 14)
    }

    @ViewBuilder
    private var detail: some View {
        switch store.selectedSection {
        case .data:
            DataView()
        case .accounts:
            AccountsView()
        case .settings:
            SettingsView()
        }
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
            .frame(width: 1440, height: 900)
    }
}
