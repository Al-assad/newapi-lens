import SwiftUI

struct AccountsView: View {
    @EnvironmentObject private var store: LensStore
    @State private var draft = APIAccountDraft()
    @State private var resyncAccount: APIAccount?
    @State private var resyncStartDate = Date()
    @State private var isPresentingEditor = false
    @State private var isPresentingResyncSheet = false
    @State private var editorError: String?
    @State private var editorSuccessMessage: String?
    @State private var isTesting = false
    @State private var isSubmitting = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("账户")
                            .font(.title2.weight(.semibold))
                            .foregroundStyle(LensTheme.primaryText)
                    }

                    Spacer()

                    Button {
                        draft = APIAccountDraft()
                        editorError = nil
                        editorSuccessMessage = nil
                        isTesting = false
                        isSubmitting = false
                        isPresentingEditor = true
                    } label: {
                        Label("新增账户", systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if store.accounts.isEmpty {
                    EmptyStateCard(
                        title: "还没有账户",
                        message: "首次安装不会预置任何账户。先新增一个 new-api 账户，再进行统计和趋势查看。",
                        actionTitle: "新增第一个账户"
                    ) {
                        draft = APIAccountDraft()
                        editorError = nil
                        editorSuccessMessage = nil
                        isTesting = false
                        isSubmitting = false
                        isPresentingEditor = true
                    }
                } else {
                    VStack(spacing: 14) {
                        ForEach(store.accounts) { account in
                            AccountRow(
                                account: account,
                                syncStatus: store.syncStatusByAccountID[account.id],
                                onEdit: {
                                    draft = APIAccountDraft(account: account)
                                    editorError = nil
                                    editorSuccessMessage = nil
                                    isTesting = false
                                    isSubmitting = false
                                    isPresentingEditor = true
                                },
                                onResync: {
                                    resyncAccount = account
                                    resyncStartDate = store.defaultResyncStartDate()
                                    isPresentingResyncSheet = true
                                },
                                onDelete: {
                                    store.deleteAccount(account)
                                }
                            )
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 14)
            .padding(.bottom, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(LensTheme.windowBackground)
        .sheet(isPresented: $isPresentingEditor) {
            NavigationStack {
                AccountEditorView(
                    draft: $draft,
                    errorMessage: $editorError,
                    successMessage: $editorSuccessMessage,
                    isTesting: $isTesting,
                    isSubmitting: $isSubmitting,
                    onCancel: { isPresentingEditor = false },
                    onSubmit: {
                        editorError = nil
                        editorSuccessMessage = nil
                        isSubmitting = true
                        defer { isSubmitting = false }
                        store.saveAccount(from: draft)
                        isPresentingEditor = false
                    },
                    onTest: {
                        editorError = nil
                        editorSuccessMessage = nil
                        isTesting = true
                        defer { isTesting = false }
                        do {
                            try await store.testAccount(draft)
                            editorSuccessMessage = "连接成功，可以继续添加账户。"
                        } catch {
                            editorError = error.localizedDescription
                        }
                    }
                )
            }
            .frame(minWidth: 520, minHeight: 420)
        }
        .sheet(isPresented: $isPresentingResyncSheet) {
            NavigationStack {
                ResyncRangeView(
                    accountName: resyncAccount?.name ?? "",
                    startDate: $resyncStartDate,
                    onCancel: {
                        isPresentingResyncSheet = false
                        resyncAccount = nil
                    },
                    onConfirm: {
                        guard let account = resyncAccount else { return }
                        isPresentingResyncSheet = false
                        resyncAccount = nil
                        Task {
                            await store.resyncAccount(account, startDate: resyncStartDate)
                        }
                    }
                )
            }
            .frame(minWidth: 420, minHeight: 240)
        }
    }
}

private struct AccountEditorView: View {
    @Binding var draft: APIAccountDraft
    @Binding var errorMessage: String?
    @Binding var successMessage: String?
    @Binding var isTesting: Bool
    @Binding var isSubmitting: Bool
    let onCancel: () -> Void
    let onSubmit: () async -> Void
    let onTest: () async -> Void

    private var primaryActionTitle: String {
        "保存"
    }

    private var hasRequiredFields: Bool {
        !draft.name.isEmpty && !draft.host.isEmpty && !draft.userID.isEmpty && !draft.token.isEmpty
    }

    var body: some View {
        Form {
            Section("基本信息") {
                EditorTextFieldRow(
                    title: "账户名称",
                    help: "给这个账户起一个便于识别的名字，比如“主账号”或“工作账号”",
                    placeholder: "主账号",
                    text: $draft.name
                )
            }

            Section("连接配置") {
                EditorTextFieldRow(
                    title: "服务地址",
                    help: "填写你的 new-api 服务地址，不需要带 /api/... 这类路径",
                    placeholder: "api.example.com 或 https://api.example.com",
                    text: $draft.host
                )
                EditorTextFieldRow(
                    title: "用户 ID",
                    help: "填写该账户在 new-api 平台里的用户 ID",
                    placeholder: "12345",
                    text: $draft.userID
                )
                EditorSecureFieldRow(
                    title: "访问令牌",
                    help: "填写该账户的 new-api 平台 Token，用于读取余额和消费统计",
                    placeholder: "mtuvgH7m2UGmtuvgH7m2UG",
                    text: $draft.token
                )
            }

            if let errorMessage {
                Section {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                        .font(.callout)
                }
            }

            if let successMessage {
                Section {
                    Text(successMessage)
                        .foregroundStyle(.green)
                        .font(.callout)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(draft.id == nil ? "新增账户" : "编辑账户")
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 12) {
                Spacer()

                Button("取消", action: onCancel)
                    .disabled(isTesting || isSubmitting)
                    .buttonStyle(.bordered)

                Button {
                    Task { await onTest() }
                } label: {
                    HStack(spacing: 6) {
                        if isTesting {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text("测试连接")
                    }
                }
                .disabled(isTesting || isSubmitting || !hasRequiredFields)
                .buttonStyle(.bordered)

                Button {
                    Task { await onSubmit() }
                } label: {
                    HStack(spacing: 6) {
                        if isSubmitting {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text(primaryActionTitle)
                    }
                }
                .disabled(isTesting || isSubmitting || !hasRequiredFields)
                .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(LensTheme.barBackground)
        }
    }
}

private struct ResyncRangeView: View {
    let accountName: String
    @Binding var startDate: Date
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        Form {
            Section("全量同步范围") {
                Text("选择 \(accountName) 的全量同步起始日期。系统会从这一天开始，按月导出 CSV 后覆盖当前本地数据。")
                    .font(.callout)
                    .foregroundStyle(LensTheme.secondaryText)

                DatePicker(
                    "起始日期",
                    selection: $startDate,
                    displayedComponents: .date
                )
                .datePickerStyle(.field)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("重新覆盖同步")
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 12) {
                Spacer()
                Button("取消", action: onCancel)
                    .buttonStyle(.bordered)
                Button("开始同步", action: onConfirm)
                    .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(LensTheme.barBackground)
        }
    }
}
