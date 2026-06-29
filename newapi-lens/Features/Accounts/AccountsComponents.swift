import SwiftUI

struct AccountRow: View {
    let account: APIAccount
    let syncStatus: AccountSyncStatus?
    let onEdit: () -> Void
    let onResync: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Circle()
                .fill(Color.accentColor)
                .frame(width: 10, height: 10)
                .padding(.top, 6)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(account.name)
                        .font(.body.weight(.medium))
                        .foregroundStyle(LensTheme.primaryText)
                    if !account.isConfigured {
                        StatusBadge(text: "未配置", tint: .orange)
                    }
                }

                Text(account.host.isEmpty ? "未配置 Host" : account.host)
                    .font(.callout)
                    .foregroundStyle(LensTheme.secondaryText)

                HStack(spacing: 14) {
                    Label(account.userID.isEmpty ? "User 未配置" : "User \(account.userID)", systemImage: "person.text.rectangle")
                    if let syncStatus {
                        Label(syncStatus.message, systemImage: "arrow.triangle.2.circlepath")
                    } else {
                        Label("最近同步 \(account.lastSync)", systemImage: "clock")
                    }
                }
                .font(.caption)
                .foregroundStyle(LensTheme.secondaryText)

                if let currentDayLabel = syncStatus?.currentDayLabel {
                    Text("当前日期 \(currentDayLabel)")
                        .font(.caption)
                        .foregroundStyle(LensTheme.tertiaryText)
                }

                if let syncStatus,
                   let detectProgress = syncStatus.detectProgress,
                   let syncProgress = syncStatus.syncProgress {
                    SyncStageProgressView(
                        detectProgress: detectProgress,
                        syncProgress: syncProgress
                    )
                    .padding(.top, 4)
                }
            }

            Spacer()

            HStack(spacing: 10) {
                Button {
                    onResync()
                } label: {
                    HStack(spacing: 6) {
                        if syncStatus != nil {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text(syncStatus == nil ? "重新覆盖同步" : "同步中")
                    }
                }
                .disabled(syncStatus != nil || !account.isConfigured)
                .buttonStyle(.borderedProminent)

                Button("编辑", action: onEdit)
                    .disabled(syncStatus != nil)
                    .buttonStyle(.bordered)
                Button("删除", role: .destructive, action: onDelete)
                    .disabled(syncStatus != nil)
                    .buttonStyle(.borderless)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panelStyle(cornerRadius: 18)
    }
}

private struct SyncStageProgressView: View {
    let detectProgress: AccountSyncProgress
    let syncProgress: AccountSyncProgress

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            StageProgressRow(progress: detectProgress, tint: .orange)
            StageProgressRow(progress: syncProgress, tint: .accentColor)
        }
    }
}

private struct StageProgressRow: View {
    let progress: AccountSyncProgress
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(progress.stage.rawValue)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(LensTheme.secondaryText)
                Spacer()
                Text("\(progress.completed)/\(progress.total)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(LensTheme.tertiaryText)
            }

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule(style: .continuous)
                        .fill(LensTheme.mutedFill)
                    Capsule(style: .continuous)
                        .fill(tint.gradient)
                        .frame(width: max(8, geometry.size.width * progress.fraction))
                }
            }
            .frame(height: 8)
        }
    }
}

struct EditorTextFieldRow: View {
    let title: String
    let help: String
    let placeholder: String
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.body.weight(.medium))
                .foregroundStyle(LensTheme.primaryText)

            Text(help)
                .font(.caption)
                .foregroundStyle(LensTheme.secondaryText)

            TextField("", text: $text, prompt: Text(placeholder).foregroundStyle(LensTheme.tertiaryText))
                .textFieldStyle(.roundedBorder)
        }
        .padding(.vertical, 2)
    }
}

struct EditorSecureFieldRow: View {
    let title: String
    let help: String
    let placeholder: String
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.body.weight(.medium))
                .foregroundStyle(LensTheme.primaryText)

            Text(help)
                .font(.caption)
                .foregroundStyle(LensTheme.secondaryText)

            SecureField("", text: $text, prompt: Text(placeholder).foregroundStyle(LensTheme.tertiaryText))
                .textFieldStyle(.roundedBorder)
        }
        .padding(.vertical, 2)
    }
}
