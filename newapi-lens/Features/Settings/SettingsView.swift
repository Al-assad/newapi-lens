import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var store: LensStore
    @AppStorage("appearanceMode") private var appearanceModeRawValue = AppAppearanceMode.system.rawValue

    private var appearanceMode: Binding<AppAppearanceMode> {
        Binding(
            get: { AppAppearanceMode(rawValue: appearanceModeRawValue) ?? .system },
            set: { appearanceModeRawValue = $0.rawValue }
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("设置")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(LensTheme.primaryText)

                settingsGrid
            }
            .padding(.horizontal, 20)
            .padding(.top, 14)
            .padding(.bottom, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(LensTheme.windowBackground)
    }

    private var settingsGrid: some View {
        VStack(alignment: .leading, spacing: 16) {
            autoUpdatePanel
            appearancePanel
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var autoUpdatePanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("自动更新")
                .font(.headline)
                .foregroundStyle(LensTheme.primaryText)

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("开启自动更新")
                        .foregroundStyle(LensTheme.primaryText)
                    Text("按设定间隔自动刷新账户数据。")
                        .font(.caption)
                        .foregroundStyle(LensTheme.secondaryText)
                }
                Spacer()
                Toggle("", isOn: $store.isAutoRefreshEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }

            Stepper(value: $store.autoRefreshIntervalMinutes, in: 1...240) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("更新时间隔")
                            .foregroundStyle(LensTheme.primaryText)
                        Text(store.isAutoRefreshEnabled ? "每 \(store.autoRefreshIntervalMinutes) 分钟自动刷新一次" : "开启自动更新后可调整间隔")
                            .font(.caption)
                            .foregroundStyle(LensTheme.secondaryText)
                    }
                    Spacer()
                    Text("\(store.autoRefreshIntervalMinutes) 分钟")
                        .foregroundStyle(LensTheme.secondaryText)
                }
            }
            .disabled(!store.isAutoRefreshEnabled)

            Text(store.isAutoRefreshPaused
                 ? "覆盖同步期间已暂停自动更新，结束后仅恢复定时器。"
                 : "自动更新不会影响手动刷新和重新覆盖同步。")
                .font(.caption)
                .foregroundStyle(LensTheme.secondaryText)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .panelStyle(cornerRadius: 18)
    }

    private var appearancePanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("外观")
                .font(.headline)
                .foregroundStyle(LensTheme.primaryText)

            HStack(alignment: .center, spacing: 12) {
                Text("主题")
                    .foregroundStyle(LensTheme.primaryText)

                Spacer()

                Picker("主题", selection: appearanceMode) {
                    ForEach(AppAppearanceMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 420)
            }

            Text("浅色主题已全局适配，深色和跟随系统会自动切换整套界面配色。")
                .font(.caption)
                .foregroundStyle(LensTheme.secondaryText)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .panelStyle(cornerRadius: 18)
    }
}
