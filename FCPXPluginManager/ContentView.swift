import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Main View

struct ContentView: View {
    @StateObject private var viewModel = PluginViewModel()
    @State private var selectedSidebar: SidebarItem = .all
    @State private var showTrashConfirmation = false
    @State private var searchText = ""
    @State private var didInitialScan = false
    // 批量结果一律用可滚动、可关闭的窗口显示，绝不再用关不掉的大弹窗
    @State private var batchResult: BatchResult?
    // 恢复/启用前的冲突预检：先告诉用户会全部跳过，再让他选
    @State private var conflictChoice: ConflictChoice?
    // 系统命令面板：所有用户安装的插件需要管理员密码，给用户一段可复制的命令
    @State private var showSystemCommandSheet = false
    @State private var systemCommandText = ""
    @State private var systemCommandSummary = ""
    // 一键禁用 / 一键启用 / 撤销 的确认
    @State private var showDisableAllConfirmation = false
    @State private var showEnableAllConfirmation = false
    @State private var showUndoConfirmation = false
    @State private var showLogSheet = false
    /// 一键禁用/启用当前选中的范围：.all 或某个具体分类
    @State private var pendingDisableCategory: PluginCategory = .all
    @State private var pendingEnableCategory: PluginCategory = .all
    // 插件详情 / 改名
    @State private var detailPlugin: PluginItem?
    @State private var renameTarget: PluginItem?
    // 正在等管理员授权，避免用户重复点
    @State private var isApplyingAdmin = false
    // 删除是最后手段，批量删除一律二次确认
    @State private var showDeleteBackupsConfirmation = false
    @State private var pendingBackupDeleteSelection: [BackupItem] = []
    @State private var showDeleteDisabledConfirmation = false
    @State private var showRestoreAllBackupsConfirmation = false
    // 译名表导入预览
    @State private var importPreview: ImportMapPreview?
    // 改名台账（恢复原名）
    @State private var showRenameLedger = false
    // 连接你的 Agent（内置命令行）说明与安装
    @State private var showCLITool = false
    // 语言切换：以中文原文为 key，切换后整棵视图重建
    @StateObject private var localization = Localization.shared
    @FocusState private var searchFocused: Bool
    // 操作后的轻量提示（带撤销）
    @State private var actionToast: ActionToast?
    // 工程扫描
    @State private var showProjectScan = false
    /// 拖放面板：先拖文件，找不到文件再点「打开工程…」
    @State private var showProjectScanPanel = false
    @State private var projectScanError: String?
    @State private var showDisableUnusedConfirmation = false
    @State private var isScanningProject = false
    // 拖文件进来时高亮
    @State private var isDropTargeted = false
    // 插件列表的「来源 / 安装范围」筛选
    @State private var pluginFilter: PluginFilter = .all

    // 选中状态：插件用路径作为稳定标识，备份/禁用记录用各自目录路径
    @State private var selectedBackupPaths: Set<String> = []
    @State private var selectedDisabledPaths: Set<String> = []

    private var isBackupView: Bool { selectedSidebar.isBackup }
    private var isDisabledView: Bool { selectedSidebar.isDisabled }

    /// 真正停用（原位置已经不存在）的数量
    private var effectiveDisabledCount: Int {
        viewModel.disabledItems.filter(\.isEffective).count
    }

    /// 只是复制了一份、原文件还在，FCP 仍会加载的数量
    private var pendingDisabledItems: [DisabledItem] {
        viewModel.disabledItems.filter { !$0.isEffective }
    }

    /// 只有拿到原路径的记录才谈得上「停用」；缺 .metadata 的老记录无从执行
    private var actionablePendingItems: [DisabledItem] {
        pendingDisabledItems.filter { !$0.isRecordIncomplete }
    }

    // MARK: - 过滤

    var filteredPlugins: [PluginItem] {
        guard let catFilter = selectedSidebar.categoryFilter else { return [] }
        let results: [PluginItem]
        if searchText.isEmpty {
            results = viewModel.plugins
        } else {
            results = viewModel.plugins.filter {
                $0.name.localizedCaseInsensitiveContains(searchText) ||
                $0.path.localizedCaseInsensitiveContains(searchText)
            }
        }
        switch catFilter {
        case .all: return results.filter(pluginFilter.matches)
        default: return results.filter { $0.category == catFilter && pluginFilter.matches($0) }
        }
    }

    var filteredBackups: [BackupItem] {
        if searchText.isEmpty {
            return viewModel.backups
        }
        return viewModel.backups.filter {
            $0.name.localizedCaseInsensitiveContains(searchText) ||
            $0.originalPath.localizedCaseInsensitiveContains(searchText)
        }
    }

    var filteredBackupByCategory: [BackupItem] {
        guard let catFilter = selectedSidebar.categoryFilter, catFilter != .all else {
            return filteredBackups
        }
        return filteredBackups.filter { $0.category == catFilter }
    }

    var filteredDisabled: [DisabledItem] {
        if searchText.isEmpty {
            return viewModel.disabledItems
        }
        return viewModel.disabledItems.filter {
            $0.name.localizedCaseInsensitiveContains(searchText) ||
            $0.originalPath.localizedCaseInsensitiveContains(searchText)
        }
    }

    var selectedPluginCount: Int {
        filteredPlugins.filter { viewModel.selectedPluginIDs.contains($0.path) }.count
    }

    var selectedBackupCount: Int {
        let displayBackups = isBackupView ? filteredBackups : filteredBackupByCategory
        return displayBackups.filter { selectedBackupPaths.contains($0.backupPath) }.count
    }

    var selectedDisabledCount: Int {
        filteredDisabled.filter { selectedDisabledPaths.contains($0.entryPath) }.count
    }

    // MARK: - 弹窗文案

    /// 按范围取出要禁用的插件
    private func plugins(in scope: PluginCategory) -> [PluginItem] {
        scope == .all ? viewModel.plugins : viewModel.plugins.filter { $0.category == scope }
    }

    /// 按范围取出已禁用的插件
    private func disabledItems(in scope: PluginCategory) -> [DisabledItem] {
        scope == .all ? viewModel.disabledItems : viewModel.disabledItems.filter { $0.category == scope }
    }

    private var disableScopeTitle: String {
        pendingDisableCategory == .all ? T("全部") : pendingDisableCategory.displayName
    }

    private var enableScopeTitle: String {
        pendingEnableCategory == .all ? T("全部") : pendingEnableCategory.displayName
    }

    var disableConfirmTitle: String {
        pendingDisableCategory == .all ? T("停用第三方插件") : T("停用%@", pendingDisableCategory.displayName)
    }

    var enableConfirmTitle: String {
        pendingEnableCategory == .all ? T("全部启用") : T("启用%@", pendingEnableCategory.displayName)
    }

    var disableAllMessage: String {
        let candidates = viewModel.batchDisableCandidates(in: pendingDisableCategory, includeApple: false)
        let targets = candidates.targets
        guard !targets.isEmpty else {
            return T("「%@」范围里没有可停用的插件。\n（Apple 自带 %@ 个默认跳过，受保护 %@ 个）",
                     disableScopeTitle, candidates.skippedApple, candidates.skippedProtected)
        }

        let globalCount = targets.filter(\.isSystemLevel).count
        let userCount = targets.count - globalCount
        let unknownCount = targets.filter { $0.origin == .unknown }.count

        var text = T("将停用「%@」的 %@ 个插件：", disableScopeTitle, targets.count)
        for category in PluginCategory.allCases where category != .all {
            let group = targets.filter { $0.category == category }
            guard !group.isEmpty else { continue }
            text += T("\n• %@ %@ 个", category.displayName, group.count)
        }
        text += T("\n\n其中所有用户安装 %@ 个（需要管理员授权），仅当前用户安装 %@ 个。", globalCount, userCount)
        if unknownCount > 0 {
            text += T("\n有 %@ 个读不到签名信息，来源未知，按第三方插件处理。", unknownCount)
        }
        if candidates.skippedApple > 0 {
            text += T("\n\nApple 自带的 %@ 个已跳过，不会停用。", candidates.skippedApple)
        }
        if candidates.skippedProtected > 0 {
            text += T("\n受保护名单里的 %@ 个已自动跳过（收藏或当前工程正在使用）。", candidates.skippedProtected)
        }
        text += T("\n\n插件文件不会真正删除，之后可以一键启用回来。")
        if fcpIsRunning {
            text += T("\n\n检测到 Final Cut Pro 正在运行，建议先退出。")
        }
        return text
    }

    var enableAllMessage: String {
        let items = disabledItems(in: pendingEnableCategory)
        guard !items.isEmpty else { return T("「%@」范围里没有被禁用的插件。", enableScopeTitle) }

        let globalCount = items.filter(\.isSystemLevel).count
        let userCount = items.count - globalCount
        var text: String

        if pendingEnableCategory == .all {
            var lines: [String] = []
            for category in PluginCategory.allCases where category != .all {
                let group = items.filter { $0.category == category }
                guard !group.isEmpty else { continue }
                lines.append(T("• %@ %@ 个", category.displayName, group.count))
            }
            text = T("将恢复启用全部 %@ 个已禁用插件：\n%@\n", items.count, lines.joined(separator: "\n"))
        } else {
            text = T("将恢复启用「%@」分类的 %@ 个插件。", pendingEnableCategory.displayName, items.count)
        }
        text += T("\n• 仅当前用户安装的 %@ 个，直接放回原目录\n• 所有用户安装的 %@ 个，需要管理员授权才能放回\n", userCount, globalCount)

        let redundant = items.filter { $0.hasPayload && $0.originalExists }.count
        if redundant > 0 {
            text += T("\n\n其中 %@ 个是「没真正停用」的记录：原插件一直在用，启用时会把多余的副本移到废纸篓（可还原），原插件不动。", redundant)
        }
        text += T("\n\n启用不会删除正在使用的插件。")
        if fcpIsRunning {
            text += T("\n\n检测到 Final Cut Pro 正在运行，建议先退出。")
        }
        return text
    }

    var undoMessage: String {
        guard let record = viewModel.lastUndoableOperation else { return "" }
        return T("将撤销「%@」这次操作。\n\n能恢复的先恢复，遇到同名插件会跳过并且不覆盖。", record.summary)
    }

    // MARK: - 工程扫描相关

    /// 当前扫描工程的历史停用批次（新的在前）
    private var currentProjectBatches: [ProjectBatch] {
        guard let scan = viewModel.projectScan else { return [] }
        return viewModel.batches(forProjectPath: scan.fileURL.path)
    }

    /// Apple 自带插件总数（只做提示，不参与一键禁用）
    private var applePluginCount: Int {
        viewModel.plugins.filter { $0.origin == .apple }.count
    }

    /// 默认「一键全部禁用」会处理的数量（第三方 + 来源未知，不含 Apple 与保护名单）
    private var thirdPartyDisableCount: Int {
        viewModel.batchDisableCandidates(in: .all, includeApple: false).targets.count
    }

    /// 当前工程实际用到的、本机已安装的插件
    private var projectUsedPlugins: [PluginItem] {
        guard let scan = viewModel.projectScan else { return [] }
        return viewModel.plugins.filter { scan.usedPaths.contains($0.path) }
    }

    /// 本工程没用到的插件（已排除收藏/工程保护）
    private var projectUnusedCandidates: [PluginItem] {
        viewModel.projectUnusedCandidates()
    }

    /// 本工程没用到的 Apple 自带插件：默认不动，只在确认框里告知
    private var projectAppleSkippedUnused: [PluginItem] {
        guard let scan = viewModel.projectScan, scan.parsed else { return [] }
        return viewModel.plugins.filter {
            !scan.usedPaths.contains($0.path) && $0.origin == .apple
        }
    }

    private var disableUnusedAlertTitle: String {
        viewModel.projectScan?.bundle != nil ? T("停用未使用的插件") : T("停用本工程未使用的插件")
    }

    private var disableUnusedMessage: String {
        guard let scan = viewModel.projectScan, scan.parsed else {
            return T("还没有成功扫描工程，无法判断哪些插件没用到。")
        }
        let targets = projectUnusedCandidates
        guard !targets.isEmpty else {
            return T("这个工程没用到的插件都已经停用，或都在保护名单里，没有需要处理的。")
        }

        let scopeText: String
        if let bundle = scan.bundle {
            scopeText = bundle.wholeLibrary
                ? T("整库用到 %@ 个插件，已自动进保护名单。", scan.usedPaths.count)
                : T("已选 %@，用到 %@ 个插件，已自动进保护名单。", bundle.selectionLabel, scan.usedPaths.count)
        } else {
            scopeText = T("工程「%@」依赖的 %@ 个插件已自动进保护名单，不会被停用。", scan.projectName, scan.usedPaths.count)
        }
        var text = scopeText
        text += T("\n\n将停用未使用的 %@ 个插件：", targets.count)
        for category in PluginCategory.allCases where category != .all {
            let group = targets.filter { $0.category == category }
            guard !group.isEmpty else { continue }
            text += T("\n• %@ %@ 个", category.displayName, group.count)
        }
        if !projectAppleSkippedUnused.isEmpty {
            text += T("\n\n本次不会动 Apple 自带的 %@ 个。", projectAppleSkippedUnused.count)
        }
        text += T("\n\n风险提示：只停用「本工程没用到的」插件。若停用工程正在使用的插件，FCP 会提示「缺少效果」，参数也有丢失风险，所以本应用不会那样做。")
        text += T("\n\n插件文件不会真正删除，之后可以一键启用回来。")
        if fcpIsRunning {
            text += T("\n\n检测到 Final Cut Pro 正在运行，建议先退出。")
        }
        return text
    }

    /// 底部轻提示：操作完告诉用户做了什么，并给一个撤销按钮
    private func actionToastView(_ toast: ActionToast) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Text(toast.text)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(2)
            if toast.undoTitle != nil, viewModel.lastUndoableOperation != nil {
                Button(toast.undoTitle ?? T("撤销")) {
                    withAnimation(.easeInOut(duration: 0.2)) { actionToast = nil }
                    undoLastOperation()
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .hoverTint(cornerRadius: 6)
            }
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { actionToast = nil }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(4)
            }
            .buttonStyle(.plain)
            .hoverTint(cornerRadius: 8)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.secondary.opacity(0.18)))
        .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
        .padding(.horizontal, 20)
    }

    /// Final Cut Pro 正在运行时提醒先退出，避免改了不生效
    private var fcpIsRunning: Bool {
        !NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.apple.FinalCut")
            .isEmpty
    }

    private var fcpRunningNote: String {
        fcpIsRunning ? T("\n\n检测到 Final Cut Pro 正在运行，建议先退出，否则改动可能不生效。") : ""
    }

    /// 空列表时告诉用户到底扫了哪些目录，方便排查
    private var scanSummary: String {
        guard !viewModel.scanLocations.isEmpty else {
            return T("点击右下角「刷新」按钮扫描插件")
        }
        let existing = viewModel.scanLocations.filter { $0.exists }
        var lines = existing.map { location in
            location.readable
                ? T("%@：%@ 个", location.label, location.foundCount)
                : T("%@：无访问权限，读不到里面的插件", location.label)
        }
        let missingCount = viewModel.scanLocations.count - existing.count
        if missingCount > 0 {
            lines.append(T("另有 %@ 个常见位置没有对应文件夹", missingCount))
        }
        if lines.isEmpty {
            return T("这些插件目录在这台机器上都不存在")
        }
        return T("已扫描 %@ 个位置\n", existing.count) + lines.joined(separator: "\n")
    }

    /// 兜底：个别 macOS 版本上 navigationTitle 不会刷新窗口标题，这里直接改一次
    private func syncWindowTitle() {
        let title = T("FCP 插件管理")
        DispatchQueue.main.async {
            for window in NSApp.windows where window.styleMask.contains(.titled) && !(window is NSPanel) {
                window.title = title
            }
        }
    }

    private func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: - Body

    var body: some View {
        contentWithLayout
            // 标题栏跟着语言走，避免正文英文、标题栏中文
            .navigationTitle(T("FCP 插件管理"))
            .onAppear { syncWindowTitle() }
            .id(localization.language)
            .sheet(item: $batchResult) { result in
                BatchResultSheet(result: result)
            }
            .sheet(item: $conflictChoice) { choice in
                ConflictChoiceSheet(choice: choice) { mode in
                    conflictChoice = nil
                    Task { @MainActor in
                        if !choice.restoreBackups.isEmpty {
                            let targets = mode == .skip
                                ? choice.restoreBackups.filter { !viewModel.restoreTargetExists(for: $0) }
                                : choice.restoreBackups
                            if targets.isEmpty {
                                showResult(T("已跳过"), T("所有备份都因为原位置已有同名插件被跳过，没有改动任何文件。"))
                            } else {
                                await performRestore(targets, overwriteExisting: mode == .overwrite)
                            }
                        }
                    }
                }
            }
            .sheet(isPresented: $showSystemCommandSheet) {
                CommandSheet(
                    title: T("需要管理员权限"),
                    summary: systemCommandSummary,
                    command: systemCommandText
                )
            }
            .sheet(item: $renameTarget) { plugin in
                RenameSheet(plugin: plugin) { name in
                    viewModel.validateNewName(name, for: plugin)
                } onConfirm: { name in
                    renameTarget = nil
                    performRename(plugin, to: name)
                }
            }
            .sheet(item: $detailPlugin) { plugin in
                PluginDetailView(plugin: plugin)
            }
            .sheet(isPresented: $showLogSheet) {
                OperationLogView(records: viewModel.operations) { record in
                    showLogSheet = false
                    Task { @MainActor in
                        await runUndo(record)
                    }
                }
            }
            .sheet(item: $importPreview) { preview in
                ImportMapSheet(preview: preview) { plan in
                    importPreview = nil
                    applyImportPlan(plan)
                } onCancel: {
                    importPreview = nil
                }
            }
            .sheet(isPresented: $showRenameLedger) {
                RenameLedgerView(viewModel: viewModel)
            }
            .onChange(of: selectedSidebar) { _, _ in
                selectedBackupPaths.removeAll()
                selectedDisabledPaths.removeAll()
                if isDisabledView {
                    viewModel.refreshDisabledDirectorySize()
                }
            }
            .onChange(of: viewModel.disabledItems.count) { _, _ in
                if isDisabledView {
                    viewModel.refreshDisabledDirectorySize()
                }
            }
            .task {
                // 打开就自动扫一次，不用再手动点刷新
                if !didInitialScan {
                    didInitialScan = true
                    viewModel.scan()
                }
            }
    }

    private func batchProgressBar(_ progress: BatchProgress) -> some View {
        HStack(spacing: 12) {
            ProgressView(value: Double(progress.completed), total: Double(max(progress.total, 1)))
                .frame(width: 160)
            VStack(alignment: .leading, spacing: 2) {
                Text(progress.title)
                    .font(.system(size: 12, weight: .medium))
                Text(T("已完成 %@ / %@", progress.completed, progress.total))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Button(progress.isCancelling ? T("正在停止…") : T("停止")) {
                viewModel.requestBatchStop()
            }
            .controlSize(.small)
            .disabled(progress.isCancelling || progress.completed >= progress.total)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
        .padding(.bottom, 18)
    }

    private var contentWithLayout: some View {
        VStack(spacing: 0) {
            headerView

            if !pendingDisabledItems.isEmpty {
                pendingBanner
            }

            Divider()

            HStack(spacing: 0) {
                sidebarView
                    .frame(minWidth: 170, idealWidth: 190, maxWidth: 250)

                Divider()

                if isBackupView {
                    backupListView
                        .id("backup-\(selectedSidebar.rawValue)")
                } else if isDisabledView {
                    disabledListView
                        .id("disabled-\(selectedSidebar.rawValue)")
                } else {
                    pluginListView
                        .id("plugin-\(selectedSidebar.rawValue)")
                }
            }

            Divider()

            bottomBar
        }
        .frame(minWidth: 1080, minHeight: 520)
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [8]))
                    .padding(6)
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            handleProjectDrop(providers)
        }
        .overlay(alignment: .bottom) {
            VStack(spacing: 8) {
                if let toast = actionToast {
                    actionToastView(toast)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                if let progress = viewModel.batchProgress {
                    batchProgressBar(progress)
                }
            }
            .padding(.bottom, 56)
            .animation(.easeInOut(duration: 0.2), value: actionToast?.id)
        }
        // 轻提示自动消失，避免一直挡在底部
        .task(id: actionToast?.id) {
            guard let current = actionToast?.id else { return }
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            if actionToast?.id == current {
                withAnimation(.easeInOut(duration: 0.2)) { actionToast = nil }
            }
        }
        .alert(T("确认删除"), isPresented: $showTrashConfirmation) {
            Button(T("取消"), role: .cancel) {}
            Button(T("备份并删除"), role: .destructive) {
                moveSelectedToTrash()
            }
        } message: {
            Text(T("确定要把选中的 %@ 个插件移到废纸篓吗？\n\n会先自动备份，之后可以在「已备份」里还原。删除不会碰你在 FCP 里的工程文件。%@", selectedPluginCount, fcpRunningNote))
        }
        .alert(T("确认全部禁用"), isPresented: $showDisableAllConfirmation) {
            Button(T("取消"), role: .cancel) {}
            Button(disableConfirmTitle, role: .destructive) {
                disableAllPlugins()
            }
        } message: {
            Text(disableAllMessage)
        }
        .alert(T("确认全部启用"), isPresented: $showEnableAllConfirmation) {
            Button(T("取消"), role: .cancel) {}
            Button(enableConfirmTitle) {
                enableAllDisabled()
            }
        } message: {
            Text(enableAllMessage)
        }
        .alert(T("撤销上一步"), isPresented: $showUndoConfirmation) {
            Button(T("取消"), role: .cancel) {}
            Button(T("撤销"), role: .destructive) {
                undoLastOperation()
            }
        } message: {
            Text(undoMessage)
        }
        .alert(disableUnusedAlertTitle, isPresented: $showDisableUnusedConfirmation) {
            Button(T("取消"), role: .cancel) {}
            Button(T("停用 %@ 个", projectUnusedCandidates.count), role: .destructive) {
                disableProjectUnusedPlugins()
            }
        } message: {
            Text(disableUnusedMessage)
        }
        .sheet(isPresented: $showCLITool) {
            CLIToolSheet()
        }
        .sheet(isPresented: $showProjectScanPanel) {
            ProjectScanDropPanel { url in
                acceptProjectFile(url)
            }
        }
        .sheet(isPresented: $showProjectScan) {
            if let bundle = viewModel.projectScan?.bundle {
                LibraryScanSheet(
                    result: viewModel.projectScan,
                    bundle: bundle,
                    usedPlugins: projectUsedPlugins,
                    unusedPlugins: projectUnusedCandidates,
                    appleSkipped: projectAppleSkippedUnused.count,
                    unmatched: viewModel.projectScan?.unmatched ?? [],
                    batches: currentProjectBatches,
                    onSetWholeLibrary: { viewModel.setBundleWholeLibrary($0) },
                    onToggleProject: { viewModel.toggleBundleProject($0) },
                    onRestoreBatch: { restoreBatch($0) },
                    onDisableUnused: {
                        showProjectScan = false
                        showDisableUnusedConfirmation = true
                    }
                )
            } else {
                ProjectScanSheet(
                    result: viewModel.projectScan,
                    usedPlugins: projectUsedPlugins,
                    unusedPlugins: projectUnusedCandidates,
                    appleSkipped: projectAppleSkippedUnused.count,
                    unmatched: viewModel.projectScan?.unmatched ?? [],
                    batches: currentProjectBatches,
                    onRestoreBatch: { restoreBatch($0) },
                    onDisableUnused: {
                        showProjectScan = false
                        showDisableUnusedConfirmation = true
                    }
                )
            }
        }
        .alert(T("工程扫描失败"), isPresented: Binding(
            get: { projectScanError != nil },
            set: { if !$0 { projectScanError = nil } }
        )) {
            Button(T("选择 XML 文件…")) { chooseXMLFile() }
            Button(T("好"), role: .cancel) { projectScanError = nil }
        } message: {
            Text(projectScanError ?? "")
        }
    }

    // MARK: - Header

    private var headerView: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(T("FCP 插件管理"))
                    .font(.title2)
                    .fontWeight(.bold)
                    .lineLimit(1)
                Text(T("管理你的 Final Cut Pro 插件，轻松卸载与恢复"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer()

            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField(T("搜索插件..."), text: $searchText)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .hoverTint(cornerRadius: 8)
                }
            }
            .padding(8)
            .background(Color(.textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            .frame(minWidth: 160, idealWidth: 220, maxWidth: 220)
            .background {
                Button("") { searchFocused = true }
                    .keyboardShortcut("f", modifiers: .command)
                    .opacity(0)
            }

            Divider()
                .frame(height: 24)

            // 工程扫描：点开拖放面板，把文件拖进去是最快的方式
            Button {
                showProjectScanPanel = true
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: viewModel.projectScan?.parsed == true ? "doc.text.magnifyingglass" : "doc.badge.plus")
                    Text(viewModel.projectScan?.parsed == true ? T("工程：%@", viewModel.projectScan?.projectName ?? "") : T("扫描工程"))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 180, alignment: .leading)
                }
                .font(.subheadline)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(
                    (viewModel.projectScan?.parsed == true ? Color.accentColor : Color(.controlBackgroundColor)).opacity(viewModel.projectScan?.parsed == true ? 0.15 : 1),
                    in: Capsule()
                )
            }
            .disabled(isScanningProject)
            .hoverBrighten(isEnabled: !isScanningProject)
            .help(T("选择或拖入 .fcpxml 工程文件或 .fcpbundle 库，扫描它实际用到的插件"))

            if viewModel.projectScan?.parsed == true {
                Button {
                    showProjectScan = true
                } label: {
                    Image(systemName: "info.circle")
                        .font(.system(size: 13))
                }
                .buttonStyle(.borderless)
                .hoverTint(cornerRadius: 5)
                .help(T("查看上次工程扫描结果"))
            }

            // 已经为这个工程停用过插件：给一个显眼的一键恢复入口
            if let pending = viewModel.latestPendingBatchForCurrentProject {
                Button {
                    restoreBatch(pending)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.uturn.backward.circle")
                        Text(T("恢复本工程 %@ 个", pending.pendingCount))
                    }
                    .font(.subheadline)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.green.opacity(0.16), in: Capsule())
                }
                .buttonStyle(.plain)
                .hoverBrighten()
                .help(T("只恢复为这个工程停用的这一批插件"))
            }

            Divider()
                .frame(height: 24)

            Button(action: { viewModel.scan() }) {
                HStack(spacing: 4) {
                    Image(systemName: viewModel.isScanning ? "pause.fill" : "arrow.triangle.2.circlepath")
                    Text(viewModel.isScanning ? T("扫描中...") : T("刷新"))
                }
                .font(.subheadline)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Color(.controlBackgroundColor), in: Capsule())
            }
            .disabled(!isBackupView && selectedPluginCount > 0)
            .hoverBrighten(isEnabled: isBackupView || selectedPluginCount == 0)
            .keyboardShortcut("r", modifiers: .command)

            Menu {
                Button {
                    chooseRenameMap()
                } label: {
                    Label(T("导入译名表…"), systemImage: "square.and.arrow.down")
                }
                Button {
                    viewModel.refreshRenameLedgerStatuses()
                    showRenameLedger = true
                } label: {
                    Label(T("恢复原名…"), systemImage: "arrow.uturn.backward.circle")
                }
                Button {
                    showCLITool = true
                } label: {
                    Label(T("连接你的 Agent…"), systemImage: "sparkles")
                }
                Divider()
                Picker(
                    T("语言"),
                    selection: Binding(
                        get: { localization.language },
                        set: { localization.setLanguage($0) }
                    )
                ) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(language.displayName).tag(language)
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 16))
            }
            .menuStyle(.borderlessButton)
            .frame(width: 32)
            .hoverTint(cornerRadius: 6)
            .help(T("更多操作"))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    /// 顶部红色横幅：一眼看出「还没真正停用」，并按安装范围分别说明
    private var pendingBanner: some View {
        let pending = pendingDisabledItems
        let systemPending = pending.filter { !$0.isRecordIncomplete && $0.isSystemLevel }
        let userPending = pending.filter { !$0.isRecordIncomplete && !$0.isSystemLevel }
        let unknownPending = pending.filter(\.isRecordIncomplete)
        return HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 18))

            VStack(alignment: .leading, spacing: 2) {
                Text(pending.count == 1
                     ? T("还有 1 个插件没有真正停用")
                     : T("还有 %@ 个插件没有真正停用", pending.count))
                    .font(.system(size: 13, weight: .semibold))
                if !systemPending.isEmpty {
                    Text(T("• 所有用户安装的 %@ 个：原文件还在系统目录，Final Cut Pro 会照常加载；输入管理员密码后才会真正移走。", systemPending.count))
                        .font(.caption)
                        .opacity(0.92)
                }
                if !userPending.isEmpty {
                    Text(T("• 仅当前用户安装的 %@ 个：插件仍在原目录（旧版本留下的多余副本），不需要管理员密码，去「已禁用」页处理即可。", userPending.count))
                        .font(.caption)
                        .opacity(0.92)
                }
                if !unknownPending.isEmpty {
                    Text(unknownPending.count == 1
                         ? T("• 另有 1 个老记录缺少原始位置信息，无法判断是否已停用，请在「已禁用」页单独处理。")
                         : T("• 另有 %@ 个老记录缺少原始位置信息，无法判断是否已停用，请在「已禁用」页单独处理。", unknownPending.count))
                        .font(.caption)
                        .opacity(0.92)
                }
            }

            Spacer()

            if !systemPending.isEmpty {
                Button {
                    applyPendingDisables(systemPending)
                } label: {
                    Text(isApplyingAdmin ? T("等待授权...") : T("立即停用（需管理员密码）"))
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.borderedProminent)
                .tint(.white)
                .foregroundStyle(.red)
                .disabled(isApplyingAdmin)

                Button {
                    systemCommandSummary = T("自动授权被系统拦截时，可以复制下面的命令，打开「终端」粘贴执行。执行完回到本应用点「复核」。")
                    systemCommandText = viewModel.manualDisableCommands(for: systemPending)
                    showSystemCommandSheet = true
                } label: {
                    Text(T("复制命令"))
                        .font(.system(size: 12))
                }
                .buttonStyle(.bordered)
                .tint(.white)
                .foregroundStyle(.white)
            } else {
                Button {
                    selectedSidebar = .disabled
                } label: {
                    Text(T("去清理"))
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.borderedProminent)
                .tint(.white)
                .foregroundStyle(.red)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.red.opacity(0.9))
        .foregroundStyle(.white)
    }

    // MARK: - Sidebar

    private var sidebarView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(T("分类"))
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)

            ScrollView {
                VStack(spacing: 2) {
                    ForEach(SidebarItem.allCases.filter { !$0.isBackup && !$0.isDisabled }) { item in
                        sidebarButton(item)
                    }
                    Divider()
                        .padding(.horizontal, 12)
                    Text(T("备份与暂停"))
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                    sidebarButton(.backups)
                    sidebarButton(.disabled)
                }
                .padding(.bottom, 8)
            }
            // 让滚动区吃掉剩余高度：窗口再矮也只滚动它自己，不会把最后一项挤没
            .frame(maxHeight: .infinity)

            VStack(alignment: .leading, spacing: 4) {
                if isBackupView {
                    Text(T("已备份 %@ 个", viewModel.backups.count))
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    if selectedBackupCount > 0 {
                        HStack(spacing: 6) {
                            Button(T("全选")) { toggleSelectAllBackups() }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .font(.caption)

                            Button(T("清空")) { selectedBackupPaths.removeAll() }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .font(.caption)
                        }
                    }
                } else if isDisabledView {
                    Text(T("已真正停用 %@ 个", effectiveDisabledCount))
                        .font(.caption2)
                        .foregroundStyle(effectiveDisabledCount > 0 ? .green : .secondary)
                    if !pendingDisabledItems.isEmpty {
                        Text(T("未生效 %@ 个（原文件还在）", pendingDisabledItems.count))
                            .font(.caption2)
                            .foregroundStyle(.red)
                    }

                    if selectedDisabledCount > 0 {
                        HStack(spacing: 6) {
                            Button(T("全选")) { toggleSelectAllDisabled() }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .font(.caption)

                            Button(T("清空")) { selectedDisabledPaths.removeAll() }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .font(.caption)
                        }
                    }
                } else {
                    Text(T("已选 %@ 个", selectedPluginCount))
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    if selectedPluginCount > 0 {
                        HStack(spacing: 6) {
                            Button(T("全选")) { toggleSelectAll() }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .font(.caption)

                            Button(T("清空")) { clearSelection() }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .font(.caption)
                        }
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
            // 底部统计永远完整显示，不被滚动区压扁
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 8)
    }

    private func sidebarButton(_ item: SidebarItem) -> some View {
        let count: Int
        if item.isBackup {
            count = viewModel.backups.count
        } else if item.isDisabled {
            // 只有原位置真的没了才算停用，避免「已禁用 280」但 FCP 里还能用
            count = effectiveDisabledCount
        } else {
            count = item == .all
                ? viewModel.plugins.count
                : viewModel.plugins.filter { $0.category == item.categoryFilter }.count
        }

        // 分类里另外标出「停用」数量，侧边栏统计才和「已禁用」对得上
        let disabledCount: Int
        if item.isBackup || item.isDisabled {
            disabledCount = 0
        } else if item == .all {
            disabledCount = effectiveDisabledCount
        } else {
            disabledCount = viewModel.disabledItems.filter {
                $0.category == item.categoryFilter && $0.isEffective
            }.count
        }
        // 主数字放右边胶囊里，解释文字放名字下面，一眼能分清总数 / 停用 / 待执行
        let detailText: String?
        if item.isBackup {
            detailText = count == 0 ? nil : T("可恢复 %@ 个", count)
        } else if item.isDisabled {
            if pendingDisabledItems.isEmpty {
                detailText = count == 0 ? nil : T("已真正停用 %@ 个", count)
            } else {
                detailText = T("真正停用 %@ 个 · 未生效 %@ 个", count, pendingDisabledItems.count)
            }
        } else if disabledCount > 0 {
            detailText = T("共 %@ 个 · 停用 %@ 个", count, disabledCount)
        } else {
            detailText = count == 0 ? nil : T("共 %@ 个", count)
        }

        let isSelected = selectedSidebar == item

        return HStack(spacing: 8) {
            Image(systemName: sidebarIcon(for: item))
                .frame(width: 18)
                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.displayName)
                    .font(.system(size: 13, weight: isSelected ? .medium : .regular))
                if let detailText {
                    Text(detailText)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            Text("\(count)")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(Color.secondary.opacity(0.12), in: Capsule())
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            isSelected
                ? Color.accentColor.opacity(0.18)
                : Color.clear
        )
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .contentShape(RoundedRectangle(cornerRadius: 6))
        .hoverTint(cornerRadius: 6)
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.15)) {
                selectedSidebar = item
            }
        }
        .id("sidebar-\(item.rawValue)")
    }

    // MARK: - Plugin List

    private var pluginListView: some View {
        VStack(spacing: 0) {
            HStack {
                Button(action: { toggleSelectAll() }) {
                    Image(systemName: allSelected ? "checkmark.square" : "square")
                        .font(.title3)
                        .foregroundStyle(allSelected ? Color.accentColor : .secondary)
                }
                .buttonStyle(.plain)
                .hoverTint(cornerRadius: 4)
                .keyboardShortcut("a", modifiers: .command)
                .help(Text(T("全选")))

                Text(T("插件名称"))
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 80)
                Text(T("类别"))
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                    .frame(width: 78, alignment: .leading)
                Menu {
                    Picker(T("筛选"), selection: $pluginFilter) {
                        ForEach(PluginFilter.allCases) { filter in
                            Text(filter.title).tag(filter)
                        }
                    }
                } label: {
                    HStack(spacing: 2) {
                        Text(T("来源"))
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8))
                    }
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(pluginFilter == .all ? Color.secondary : Color.accentColor)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .frame(width: 62, alignment: .leading)
                .help(T("按来源或安装范围筛选；「一键全部禁用」默认不含 Apple 自带"))
                Text(T("状态"))
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                    .frame(width: 120, alignment: .leading)
                Text(T("体积"))
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                    .frame(width: 64, alignment: .trailing)
                Spacer().frame(width: 20)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color(.textBackgroundColor))

            Divider()

            if filteredPlugins.isEmpty {
                ContentUnavailableView(
                    searchText.isEmpty ? T("没有插件") : T("无搜索结果"),
                    systemImage: searchText.isEmpty ? "puzzlepiece.extension" : "magnifyingglass",
                    description: Text(searchText.isEmpty
                        ? scanSummary
                        : T("试试其他关键词"))
                )
                .padding()
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(filteredPlugins) { plugin in
                            pluginRow(plugin)
                            if plugin.id != filteredPlugins.last?.id {
                                Divider().padding(.leading, 28)
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func statusLabel(for plugin: PluginItem, pending: DisabledItem?) -> some View {
        if let pending {
            HStack(spacing: 4) {
                Circle()
                    .fill(pending.isEffective ? Color.green : Color.red)
                    .frame(width: 6, height: 6)
                Text(pending.isEffective ? T("已停用") : T("待执行"))
                    .font(.system(size: 11))
                    .foregroundStyle(pending.isEffective ? Color.green : Color.red)
                    .lineLimit(1)
            }
        } else {
            HStack(spacing: 4) {
                Circle()
                    .fill(Color.secondary.opacity(0.4))
                    .frame(width: 6, height: 6)
                Text(T("正常"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var allSelected: Bool {
        filteredPlugins.count > 0 && filteredPlugins.allSatisfy { viewModel.selectedPluginIDs.contains($0.path) }
    }

    private func pluginRow(_ plugin: PluginItem) -> some View {
        let isSelected = viewModel.selectedPluginIDs.contains(plugin.path)
        let pendingDisabled = viewModel.disabledItems.first { $0.originalPath == plugin.path }
        let isFavorite = viewModel.isFavorite(plugin)
        let isProjectProtected = viewModel.isProjectProtected(plugin)

        return HStack(spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    toggleSelection(for: plugin.path)
                }
            } label: {
                Image(systemName: isSelected ? "checkmark.square" : "square")
                    .font(.title3)
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                    .symbolEffect(.bounce, value: isSelected)
            }
            .buttonStyle(.plain)
            .hoverTint(cornerRadius: 4)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(plugin.displayName)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)

                    if isFavorite {
                        Image(systemName: "star.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.yellow)
                            .help(Text(T("已收藏，永不参与批量停用")))
                    }
                    if isProjectProtected {
                        Image(systemName: "shield.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.blue)
                            .help(Text(T("当前扫描的工程正在使用，已自动保护")))
                    }
                }

                let meta = [plugin.version.map { "v\($0)" }, plugin.vendor]
                    .compactMap { $0 }
                    .joined(separator: " · ")
                if !meta.isEmpty {
                    Text(meta)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            Text(plugin.category.displayName)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 78, alignment: .leading)

            // 来源列：只看谁做的，不看装在哪（装在哪在详情页和筛选里看）
            Text(plugin.origin.shortLabel)
                .font(.system(size: 11))
                .foregroundStyle(plugin.origin == .apple ? Color.orange : Color.secondary)
                .lineLimit(1)
                .frame(width: 62, alignment: .leading)
                .help(Text(T("%@ · %@", plugin.origin.displayName, plugin.installScopeDescription)))

            statusLabel(for: plugin, pending: pendingDisabled)
                .frame(width: 120, alignment: .leading)

            Text(plugin.sizeDescription ?? "—")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 64, alignment: .trailing)

            // 收藏：进了收藏就永不参与批量停用
            Button {
                viewModel.toggleFavorite(plugin)
            } label: {
                Image(systemName: isFavorite ? "star.fill" : "star")
                    .font(.caption)
                    .foregroundStyle(isFavorite ? Color.yellow : Color.secondary)
            }
            .buttonStyle(.plain)
            .frame(width: 20)
            .hoverTint(cornerRadius: 4)
            .help(isFavorite ? Text(T("取消收藏")) : Text(T("收藏（永不参与批量停用）")))

            // 行内电源开关：点一下就是停用 / 启用，不会先选中这一行
            Button {
                togglePower(for: plugin, pendingDisabled: pendingDisabled)
            } label: {
                Image(systemName: pendingDisabled == nil ? "power" : "power.circle.fill")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(pendingDisabled == nil ? Color.green : Color.orange)
                    .padding(5)
                    .background(
                        (pendingDisabled == nil ? Color.green : Color.orange).opacity(0.12),
                        in: RoundedRectangle(cornerRadius: 5)
                    )
            }
            .buttonStyle(.plain)
            .hoverBrighten(isEnabled: pendingDisabled?.isRecordIncomplete != true)
            .help(pendingDisabled == nil ? Text(T("停用这个插件")) : Text(T("启用这个插件")))
            .disabled(pendingDisabled != nil && pendingDisabled?.isRecordIncomplete == true)

            Button {
                detailPlugin = plugin
            } label: {
                Image(systemName: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .frame(width: 20)
            .hoverTint(cornerRadius: 4)
            .help(Text(T("查看插件详情")))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            isSelected
                ? Color(.highlightColor).opacity(0.3)
                : Color.clear
        )
        .contentShape(Rectangle())
        .hoverTint(cornerRadius: 6)
        // 点行本身只负责选中，不触发停用，避免误触
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.15)) {
                toggleSelection(for: plugin.path)
            }
        }
        .contextMenu {
            Button(T("查看详情")) {
                detailPlugin = plugin
            }
            Button(T("重命名…")) {
                renameTarget = plugin
            }
            Button(T("显示在访达中")) {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: plugin.path)])
            }
            Button(isFavorite ? T("取消收藏") : T("收藏（永不参与批量停用）")) {
                viewModel.toggleFavorite(plugin)
            }
            Divider()
            if let pendingDisabled {
                Button(T("启用（恢复使用）")) {
                    enableSingle(pendingDisabled)
                }
                .disabled(pendingDisabled.isRecordIncomplete)
            } else {
                Button(T("禁用（暂停使用）")) {
                    disableSingle(plugin)
                }
            }
            Divider()
            Button(T("备份并删除…")) {
                viewModel.selectedPluginIDs.insert(plugin.path)
                showTrashConfirmation = true
            }
            .foregroundStyle(.red)
        }
    }

    /// 行内电源开关：已停用就启用，否则停用
    private func togglePower(for plugin: PluginItem, pendingDisabled: DisabledItem?) {
        if let pendingDisabled {
            guard !pendingDisabled.isRecordIncomplete else { return }
            enableSingle(pendingDisabled)
        } else {
            disableSingle(plugin)
        }
    }

    // MARK: - Backup List

    private var backupListView: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "archivebox")
                    .foregroundStyle(.secondary)
                Text(T("已备份的插件"))
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(T("操作"))
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                    .frame(width: 120, alignment: .trailing)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color(.textBackgroundColor))

            Divider()

            if filteredBackups.isEmpty {
                ContentUnavailableView(
                    searchText.isEmpty ? T("没有备份") : T("无搜索结果"),
                    systemImage: searchText.isEmpty ? "archivebox" : "magnifyingglass",
                    description: Text(searchText.isEmpty
                        ? T("删除插件后会自动备份到这里")
                        : T("试试其他关键词"))
                )
                .padding()
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(filteredBackups) { backup in
                            backupRow(backup)
                            if backup.id != filteredBackups.last?.id {
                                Divider().padding(.leading, 28)
                            }
                        }
                    }
                }
            }
        }
    }

    private func backupRow(_ backup: BackupItem) -> some View {
        let isSelected = selectedBackupPaths.contains(backup.backupPath)

        return HStack(spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    if selectedBackupPaths.contains(backup.backupPath) {
                        selectedBackupPaths.remove(backup.backupPath)
                    } else {
                        selectedBackupPaths.insert(backup.backupPath)
                    }
                }
            } label: {
                Image(systemName: isSelected ? "checkmark.square" : "square")
                    .font(.title3)
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                    .symbolEffect(.bounce, value: isSelected)
            }
            .buttonStyle(.plain)
            .hoverTint(cornerRadius: 4)

            VStack(alignment: .leading, spacing: 2) {
                Text(backup.displayName)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    if backup.isSystemLevel {
                        Text(T("所有用户安装"))
                            .font(.caption2)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 3))
                            .foregroundStyle(.orange)
                    }
                    if !backup.originalPath.isEmpty {
                        Text(T("可恢复"))
                            .font(.caption2)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.green.opacity(0.15), in: RoundedRectangle(cornerRadius: 3))
                            .foregroundStyle(.green)
                    }
                }
            }

            Spacer()

            HStack(spacing: 8) {
                Button {
                    restoreSingleBackup(backup)
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.caption)
                        .padding(5)
                        .background(Color.green.opacity(0.15), in: RoundedRectangle(cornerRadius: 5))
                        .foregroundStyle(.green)
                }
                .buttonStyle(.plain)
                .hoverBrighten()
                .help(Text(T("恢复到原始位置")))

                Button {
                    deleteSingleBackup(backup)
                } label: {
                    Image(systemName: "trash")
                        .font(.caption)
                        .padding(5)
                        .background(Color.red.opacity(0.15), in: RoundedRectangle(cornerRadius: 5))
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
                .hoverBrighten(danger: true)
                .help(Text(T("删除备份")))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            isSelected
                ? Color(.highlightColor).opacity(0.3)
                : Color.clear
        )
        .contextMenu {
            Button(T("显示备份在访达中")) {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: backup.backupPath)])
            }
            Divider()
            Button(T("恢复到原始位置")) {
                restoreSingleBackup(backup)
            }
            Button(T("删除备份"), role: .destructive) {
                deleteSingleBackup(backup)
            }
            .foregroundStyle(.red)
        }
    }

    private func toggleSelectAllBackups() {
        let displayBackups = isBackupView ? filteredBackups : filteredBackupByCategory
        if displayBackups.allSatisfy({ selectedBackupPaths.contains($0.backupPath) }) {
            for backup in displayBackups {
                selectedBackupPaths.remove(backup.backupPath)
            }
        } else {
            for backup in displayBackups {
                selectedBackupPaths.insert(backup.backupPath)
            }
        }
    }

    // MARK: - Disabled List

    private var disabledListView: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "pause.circle")
                    .foregroundStyle(.secondary)
                Text(T("已禁用（暂停使用）的插件"))
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                if let bytes = viewModel.disabledDirectoryBytes, bytes > 0 {
                    Text(T("占用 %@", ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(T("操作"))
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                    .frame(width: 120, alignment: .trailing)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color(.textBackgroundColor))

            Divider()

            if filteredDisabled.isEmpty {
                ContentUnavailableView(
                    searchText.isEmpty ? T("没有被禁用的插件") : T("无搜索结果"),
                    systemImage: searchText.isEmpty ? "pause.circle" : "magnifyingglass",
                    description: Text(searchText.isEmpty
                        ? T("在插件列表点「全部禁用」或右键单个插件即可暂停使用")
                        : T("试试其他关键词"))
                )
                .padding()
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(filteredDisabled) { item in
                            disabledRow(item)
                            if item.id != filteredDisabled.last?.id {
                                Divider().padding(.leading, 28)
                            }
                        }
                    }
                }
            }
        }
    }

    private func disabledRow(_ item: DisabledItem) -> some View {
        let isSelected = selectedDisabledPaths.contains(item.entryPath)

        return HStack(spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    if selectedDisabledPaths.contains(item.entryPath) {
                        selectedDisabledPaths.remove(item.entryPath)
                    } else {
                        selectedDisabledPaths.insert(item.entryPath)
                    }
                }
            } label: {
                Image(systemName: isSelected ? "checkmark.square" : "square")
                    .font(.title3)
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                    .symbolEffect(.bounce, value: isSelected)
            }
            .buttonStyle(.plain)
            .hoverTint(cornerRadius: 4)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.displayName)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)

                HStack(spacing: 6) {
                    if item.isSystemLevel {
                        Text(T("所有用户安装"))
                            .font(.caption2)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 3))
                            .foregroundStyle(.orange)
                    }
                    if item.isEffective {
                        Text(T("已停用（已生效）"))
                            .font(.caption2)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.green.opacity(0.15), in: RoundedRectangle(cornerRadius: 3))
                            .foregroundStyle(.green)
                    } else if item.isRedundantCopy {
                        Text(T("未生效（原插件仍在用）"))
                            .font(.caption2)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.15), in: RoundedRectangle(cornerRadius: 3))
                            .foregroundStyle(.secondary)
                    } else if item.isRecordIncomplete {
                        Text(T("记录信息缺失（原位置未知）"))
                            .font(.caption2)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 3))
                            .foregroundStyle(.orange)
                    } else {
                        Text(T("待执行管理员命令（未生效）"))
                            .font(.caption2)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.red.opacity(0.15), in: RoundedRectangle(cornerRadius: 3))
                            .foregroundStyle(.red)
                    }
                }
            }

            Spacer()

            HStack(spacing: 8) {
                Button {
                    enableSingle(item)
                } label: {
                    Image(systemName: "power.circle.fill")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.orange)
                        .padding(5)
                        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 5))
                }
                .buttonStyle(.plain)
                .hoverBrighten()
                .help(Text(T("启用这个插件（恢复使用）")))

                Button {
                    deleteSingleDisabled(item)
                } label: {
                    Image(systemName: "trash")
                        .font(.caption)
                        .padding(5)
                        .background(Color.red.opacity(0.15), in: RoundedRectangle(cornerRadius: 5))
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
                .hoverBrighten(danger: true)
                .help(Text(T("删除禁用记录（不会动原始插件）")))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            isSelected
                ? Color(.highlightColor).opacity(0.3)
                : Color.clear
        )
        .contextMenu {
            Button(T("显示在访达中")) {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.currentPath)])
            }
            Divider()
            Button(T("启用这个插件")) {
                enableSingle(item)
            }
            Button(T("删除禁用记录"), role: .destructive) {
                deleteSingleDisabled(item)
            }
            .foregroundStyle(.red)
        }
    }

    private func toggleSelectAllDisabled() {
        if filteredDisabled.allSatisfy({ selectedDisabledPaths.contains($0.entryPath) }) {
            for item in filteredDisabled {
                selectedDisabledPaths.remove(item.entryPath)
            }
        } else {
            for item in filteredDisabled {
                selectedDisabledPaths.insert(item.entryPath)
            }
        }
    }

    /// 按钮主体点一下就是「全部第三方」，旁边的小箭头可以按分类挑
    private var disableScopeMenu: some View {
        Menu {
            Button(T("全部第三方插件（%@）", thirdPartyDisableCount)) {
                pendingDisableCategory = .all
                showDisableAllConfirmation = true
            }
            Divider()
            ForEach(PluginCategory.allCases.filter { $0 != .all }) { category in
                let count = plugins(in: category).count
                Button("\(category.rawValue)（\(count)）") {
                    pendingDisableCategory = category
                    showDisableAllConfirmation = true
                }
                .disabled(count == 0)
            }
            if viewModel.projectScan?.parsed == true {
                Divider()
                Button(T("本工程未使用的插件…")) {
                    showProjectScan = true
                }
            }
        } label: {
            Label(T("一键全部禁用"), systemImage: "pause.circle")
                .font(.subheadline)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color.orange.opacity(0.85), in: RoundedRectangle(cornerRadius: 8))
                .foregroundStyle(.white)
                .hoverBrighten()
        } primaryAction: {
            pendingDisableCategory = .all
            showDisableAllConfirmation = true
        }
        .help(applePluginCount > 0
              ? T("默认停用所有第三方插件（含来源未知），Apple 自带的 %@ 个不动", applePluginCount)
              : T("默认停用所有第三方插件（含来源未知）"))
        .fixedSize()
    }

    /// 恢复启用同样支持「全部 / 单个分类」
    private var enableScopeMenu: some View {
        Menu {
            Button(T("全部类别（%@）", viewModel.disabledItems.count)) {
                pendingEnableCategory = .all
                showEnableAllConfirmation = true
            }
            Divider()
            ForEach(PluginCategory.allCases.filter { $0 != .all }) { category in
                let count = disabledItems(in: category).count
                Button("\(category.rawValue)（\(count)）") {
                    pendingEnableCategory = category
                    showEnableAllConfirmation = true
                }
                .disabled(count == 0)
            }
        } label: {
            Label(T("一键全部恢复"), systemImage: "play.fill")
                .font(.subheadline)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(.green, in: RoundedRectangle(cornerRadius: 8))
                .foregroundStyle(.white)
                .hoverBrighten()
        } primaryAction: {
            pendingEnableCategory = .all
            showEnableAllConfirmation = true
        }
        .help(Text(T("把停用的插件全部开回来（全部类别，或只恢复某一类）")))
        .fixedSize()
    }

    // MARK: - Bottom Bar

    private var bottomBar: some View {
        HStack {
            if isBackupView {
                Text(T("共 %@ 个备份，已选 %@ 个", viewModel.backups.count, selectedBackupCount))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer()

                HStack(spacing: 12) {
                    if !viewModel.backups.isEmpty {
                        Button {
                            showRestoreAllBackupsConfirmation = true
                        } label: {
                            Label(T("恢复全部备份 (%@)", viewModel.backups.count), systemImage: "arrow.counterclockwise")
                                .font(.subheadline)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                                .background(.green, in: RoundedRectangle(cornerRadius: 8))
                                .foregroundStyle(.white)
                        }
                        .buttonStyle(.plain)
                        .hoverBrighten()
                    }

                    if selectedBackupCount > 0 {
                        Button {
                            restoreSelectedBackups()
                        } label: {
                            Label(T("恢复选中的 (%@)", selectedBackupCount), systemImage: "arrow.counterclockwise")
                                .font(.subheadline)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(Color.green.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
                                .foregroundStyle(.green)
                        }
                        .buttonStyle(.plain)
                        .hoverBrighten()

                        Button {
                            pendingBackupDeleteSelection = (isBackupView ? filteredBackups : filteredBackupByCategory).filter {
                                selectedBackupPaths.contains($0.backupPath)
                            }
                            showDeleteBackupsConfirmation = true
                        } label: {
                            Image(systemName: "trash")
                                .font(.subheadline)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                        }
                        .buttonStyle(.bordered)
                        .tint(.red)
                        .help(Text(T("删除选中的")))
                    }

                    if !viewModel.backups.isEmpty {
                        Button {
                            pendingBackupDeleteSelection = viewModel.backups
                            showDeleteBackupsConfirmation = true
                        } label: {
                            Text(T("清空所有备份"))
                                .font(.subheadline)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                        }
                        .buttonStyle(.bordered)
                        .tint(.red)
                    }
                }
            } else if isDisabledView {
                Text(T("已真正停用 %@ 个，未生效 %@ 个，已选 %@ 个", effectiveDisabledCount, pendingDisabledItems.count, selectedDisabledCount))
                    .font(.subheadline)
                    .foregroundStyle(pendingDisabledItems.isEmpty ? Color.secondary : Color.red)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer()

                HStack(spacing: 12) {
                    Button {
                        viewModel.refreshDisabledState()
                    } label: {
                        Label(T("复核"), systemImage: "checkmark.seal")
                            .font(.subheadline)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                    }
                    .buttonStyle(.bordered)

                    if !pendingDisabledItems.isEmpty {
                        Button {
                            applyPendingDisables(actionablePendingItems)
                        } label: {
                            Label(actionablePendingItems.isEmpty
                                  ? T("立即停用未生效的")
                                  : T("立即停用未生效的 (%@)", actionablePendingItems.count),
                                  systemImage: "lock.shield")
                                .font(.subheadline)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(Color.red.opacity(0.85), in: RoundedRectangle(cornerRadius: 8))
                                .foregroundStyle(.white)
                        }
                        .buttonStyle(.plain)
                        .disabled(isApplyingAdmin || actionablePendingItems.isEmpty)
                        .hoverBrighten(danger: true)
                        .help(actionablePendingItems.isEmpty
                              ? Text(T("原位置未知，无法停用"))
                              : Text(T("立即停用未生效的插件")))
                    }

                    if selectedDisabledCount > 0 {
                        Button {
                            enableSelectedDisabled()
                        } label: {
                            Label(T("启用选中的 (%@)", selectedDisabledCount), systemImage: "play.circle")
                                .font(.subheadline)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(Color.green.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
                                .foregroundStyle(.green)
                        }
                        .buttonStyle(.plain)
                        .hoverBrighten()

                        Button {
                            showDeleteDisabledConfirmation = true
                        } label: {
                            Image(systemName: "trash")
                                .font(.subheadline)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                        }
                        .buttonStyle(.bordered)
                        .tint(.red)
                        .help(Text(T("删除禁用记录")))
                    }

                    if !viewModel.disabledItems.isEmpty {
                        enableScopeMenu
                    }
                }
            } else {
                Text(T("共 %@ 个插件，已选 %@ 个", viewModel.plugins.count, selectedPluginCount))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer()

                HStack(spacing: 12) {
                    Button {
                        showLogSheet = true
                    } label: {
                        Label(T("操作日志"), systemImage: "list.bullet.rectangle")
                            .font(.subheadline)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Color(.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .hoverBrighten()

                    if viewModel.lastUndoableOperation != nil {
                        Button {
                            showUndoConfirmation = true
                        } label: {
                            Label(T("撤销上一步"), systemImage: "arrow.uturn.backward")
                                .font(.subheadline)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(Color.orange.opacity(0.85), in: RoundedRectangle(cornerRadius: 8))
                                .foregroundStyle(.white)
                        }
                        .buttonStyle(.plain)
                        .hoverBrighten()
                    }

                    if !viewModel.disabledItems.isEmpty {
                        enableScopeMenu
                    }

                    if !viewModel.plugins.isEmpty {
                        disableScopeMenu
                    }

                    if selectedPluginCount > 0 {
                        Button {
                            showTrashConfirmation = true
                        } label: {
                            Label(T("备份并删除 (%@)", selectedPluginCount), systemImage: "archivebox")
                                .font(.subheadline)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                        }
                        .buttonStyle(.bordered)
                        .tint(.red)
                    }
                }
            }
        }
        .padding(12)
        .background(Color(.textBackgroundColor))
        .alert(T("确认恢复全部备份"), isPresented: $showRestoreAllBackupsConfirmation) {
            Button(T("取消"), role: .cancel) {}
            Button(T("恢复全部")) {
                startRestore(viewModel.backups, actionName: T("恢复"))
            }
        } message: {
            Text(T("将把全部 %@ 个备份恢复到原始位置。\n\n如果原位置已经有同名插件，会先跳过并让你选择是否覆盖，不会直接覆盖。%@", viewModel.backups.count, fcpRunningNote))
        }
        .alert(T("确认删除备份"), isPresented: $showDeleteBackupsConfirmation) {
            Button(T("取消"), role: .cancel) {
                pendingBackupDeleteSelection = []
            }
            Button(T("删除"), role: .destructive) {
                let targets = pendingBackupDeleteSelection
                pendingBackupDeleteSelection = []
                deleteBackups(targets)
            }
        } message: {
            Text(T("将删除 %@ 个备份，移入废纸篓后仍可从废纸篓找回。\n\n删除备份不会影响已经安装的插件。", pendingBackupDeleteSelection.count))
        }
        .alert(T("确认删除禁用记录"), isPresented: $showDeleteDisabledConfirmation) {
            Button(T("取消"), role: .cancel) {}
            Button(T("删除记录"), role: .destructive) {
                deleteSelectedDisabled()
            }
        } message: {
            Text(T("只会删掉「已禁用」页里的记录和本地副本。\n\n原位置还有插件的记录，删掉后插件照常使用；已经真正停用的记录，删掉副本后就无法在本应用里一键启用了，请优先用「启用」而不是删除。"))
        }
    }

    // MARK: - Selection

    private func toggleSelection(for path: String) {
        if viewModel.selectedPluginIDs.contains(path) {
            viewModel.selectedPluginIDs.remove(path)
        } else {
            viewModel.selectedPluginIDs.insert(path)
        }
    }

    private func toggleSelectAll() {
        if allSelected {
            for plugin in filteredPlugins {
                viewModel.selectedPluginIDs.remove(plugin.path)
            }
        } else {
            for plugin in filteredPlugins {
                viewModel.selectedPluginIDs.insert(plugin.path)
            }
        }
    }

    private func clearSelection() {
        viewModel.selectedPluginIDs.removeAll()
    }

    // MARK: - Result Helpers

    private var fcpDetails: [String] {
        fcpIsRunning ? [T("Final Cut Pro 正在运行，退出并重新打开后才会生效。")] : []
    }

    private func showResult(
        _ title: String,
        _ summary: String,
        details: [String] = [],
        isError: Bool = false
    ) {
        batchResult = BatchResult(title: title, summary: summary, details: details, isError: isError)
    }

    // MARK: - Delete Plugins

    private func moveSelectedToTrash() {
        let selected = viewModel.plugins.filter { viewModel.selectedPluginIDs.contains($0.path) }
        Task { @MainActor in
            var successCount = 0
            var backupFailItems: [String] = []
            var authBackups: [BackupItem] = []
            var trashFailItems: [String] = []
            var deletedBackups: [BackupItem] = []

            for plugin in selected {
                // 备份失败一律中止，不会走到删除
                let result = await viewModel.backupAndRecycle(plugin)
                switch result {
                case .deleted(let backup):
                    successCount += 1
                    deletedBackups.append(backup)
                case .backupFailed(let error):
                    backupFailItems.append(T("%@（%@）", plugin.displayName, error))
                case .needAuthentication(let backup):
                    authBackups.append(backup)
                case .trashFailed(let error):
                    trashFailItems.append(T("%@：%@", plugin.displayName, error))
                }
            }

            if successCount > 0 {
                viewModel.addOperation(
                    kind: .deletePlugins,
                    summary: T("备份并删除 %@ 个插件", successCount),
                    backups: deletedBackups
                )
            }

            var details: [String] = []
            details += backupFailItems.map { T("备份失败，已跳过删除：%@", $0) }
            details += trashFailItems.map { T("已备份，但移入废纸篓失败：%@", $0) }

            if !authBackups.isEmpty {
                systemCommandText = authBackups.map {
                    T("# 备份：%@\nsudo rm -rf %@", $0.backupPath, AdminCommandBuilder.quote($0.originalPath))
                }.joined(separator: "\n\n")
                systemCommandSummary = T("以下 %@ 个插件装在所有用户目录，已经备份好，但删除原位置需要管理员密码。\n\n复制命令到「终端」执行，或按顶部提示处理。执行完点「刷新」复核。", authBackups.count)
                showSystemCommandSheet = true
            } else {
                let summary: String
                if successCount > 0 {
                    summary = T("已备份并删除 %@ 个插件。重启 Final Cut Pro 后生效。", successCount)
                } else {
                    summary = T("没有删除任何文件。")
                }
                showResult(successCount > 0 ? T("删除完成") : T("没有删除"), summary, details: details, isError: !details.isEmpty)
            }

            viewModel.selectedPluginIDs.removeAll()
            viewModel.scan()
        }
    }

    // MARK: - Disable / Enable

    private func disableSingle(_ plugin: PluginItem) {
        Task { @MainActor in
            switch await viewModel.disablePlugin(plugin) {
            case .disabled(let item):
                viewModel.addOperation(
                    kind: .disablePlugins,
                    summary: T("停用「%@」", item.displayName),
                    disabled: [item]
                )
                actionToast = ActionToast(
                    text: T("已停用「%@」", item.displayName),
                    undoTitle: T("撤销"),
                    detail: fcpIsRunning ? T("重启 Final Cut Pro 后生效") : nil
                )
            case .needAuthentication(let item, _):
                viewModel.addOperation(
                    kind: .disablePlugins,
                    summary: T("停用「%@」（待授权）", item.displayName),
                    disabled: [item]
                )
                applyPendingDisables([item])
            case .failure(let error):
                showResult(T("停用失败"), T("「%@」没有改动：%@", plugin.displayName, error), isError: true)
            }
            viewModel.scan()
        }
    }

    private func disableAllPlugins() {
        let scope = pendingDisableCategory
        let targets = viewModel.batchDisableCandidates(in: scope, includeApple: false).targets
        guard !targets.isEmpty else {
            showResult(T("没有可停用的插件"), T("这个范围里没有可停用的插件（可能都已停用，或在保护名单里）。"))
            return
        }
        let scopeTitle = disableScopeTitle

        Task { @MainActor in
            let outcome = await viewModel.disableAll(targets)
            if !outcome.disabledNames.isEmpty || !outcome.adminItems.isEmpty {
                viewModel.addOperation(
                    kind: .disablePlugins,
                    summary: T("一键停用（%@）：立即生效 %@ 个，待授权 %@ 个", scopeTitle, outcome.disabledNames.count, outcome.adminItems.count),
                    disabled: outcome.disabledItems + outcome.adminItems
                )
            }

            let details: [String] = outcome.failures
            var authorizedCount = 0

            // 所有用户安装的插件立刻用一次管理员授权真正移走，避免「看起来禁用了其实没动」
            if !outcome.adminItems.isEmpty {
                let admin = await viewModel.applyPendingDisables(outcome.adminItems)
                authorizedCount = admin.succeededCount
                if admin.succeededCount < outcome.adminItems.count {
                    systemCommandText = viewModel.manualDisableCommands(for: outcome.adminItems)
                    systemCommandSummary = T("自动授权没有完成：%@\n\n可以复制下面的命令手动执行，执行完回到本应用点「复核」。", admin.message)
                    showSystemCommandSheet = true
                }
            }

            let effectiveNow = outcome.disabledNames.count + authorizedCount
            // 成功就只用底部轻提示，不再弹结果窗口；有失败才展开明细
            if effectiveNow > 0 && details.isEmpty && (outcome.adminItems.isEmpty || authorizedCount == outcome.adminItems.count) {
                actionToast = ActionToast(
                    text: T("已停用 %@ 个插件", effectiveNow),
                    undoTitle: T("撤销"),
                    detail: fcpIsRunning ? T("重启 Final Cut Pro 后生效") : nil
                )
            } else if effectiveNow > 0 || outcome.failures.isEmpty {
                var summary = T("「%@」范围里已真正停用 %@ 个插件。", scopeTitle, effectiveNow)
                if !outcome.adminItems.isEmpty && authorizedCount < outcome.adminItems.count {
                    summary += T("还有 %@ 个还没生效，见顶部红色提示。", outcome.adminItems.count - authorizedCount)
                }
                summary += T("\n重启 Final Cut Pro 后生效。")
                if showSystemCommandSheet == false {
                    showResult(T("停用完成"), summary, details: details + fcpDetails, isError: !details.isEmpty)
                }
                actionToast = ActionToast(
                    text: T("已停用 %@ 个插件", effectiveNow),
                    undoTitle: T("撤销"),
                    detail: nil
                )
            } else if showSystemCommandSheet == false {
                showResult(T("停用失败"), T("没有停用任何插件。"), details: details, isError: true)
            }

            viewModel.selectedPluginIDs.removeAll()
            viewModel.scan()
        }
    }

    /// 停用「本工程没用到」的插件（Apple 自带与保护名单默认跳过）
    private func disableProjectUnusedPlugins() {
        let targets = projectUnusedCandidates
        guard !targets.isEmpty else {
            showResult(T("没有可停用的插件"), T("没用到的插件都已停用，或都在保护名单里。"))
            return
        }
        Task { @MainActor in
            let batchName = viewModel.currentScanBatchName
            let outcome = await viewModel.disableAll(targets)
            if !outcome.disabledNames.isEmpty {
                viewModel.addOperation(
                    kind: .disablePlugins,
                    summary: T("停用「%@」未使用的 %@ 个插件", batchName, outcome.disabledNames.count),
                    disabled: outcome.disabledItems
                )
            }
            var details = outcome.failures

            // 装在 /Library 的第三方插件同样要参与，需要一次管理员授权才真正生效
            var adminSucceeded: [DisabledItem] = []
            if !outcome.adminItems.isEmpty {
                let admin = await viewModel.applyPendingDisables(outcome.adminItems)
                let entryPaths = Set(outcome.adminItems.map(\.entryPath))
                adminSucceeded = viewModel.disabledItems.filter {
                    entryPaths.contains($0.entryPath) && $0.isEffective
                }
                if admin.succeededCount < outcome.adminItems.count {
                    details.append(T("有 %@ 个所有用户安装的插件没有移走（管理员授权未完成）。", outcome.adminItems.count - admin.succeededCount))
                }
            }

            // 记成这一工程的批次：以后可以只恢复这一批，不影响别的停用项
            if let scan = viewModel.projectScan, !(outcome.disabledItems + adminSucceeded).isEmpty {
                viewModel.recordProjectBatch(
                    projectName: batchName,
                    projectPath: scan.fileURL.path,
                    disabled: outcome.disabledItems + adminSucceeded,
                    includedSystem: targets.contains(where: \.isSystemLevel)
                )
            }

            let count = outcome.disabledNames.count + adminSucceeded.count
            if count > 0 && details.isEmpty {
                actionToast = ActionToast(
                    text: T("已停用 %@ 个未使用的插件（可一键恢复）", count),
                    undoTitle: T("撤销"),
                    detail: fcpIsRunning ? T("重启 Final Cut Pro 后生效") : nil
                )
            } else if count > 0 {
                actionToast = ActionToast(text: T("已停用 %@ 个插件", count), undoTitle: T("撤销"), detail: nil)
                showResult(T("停用完成"), T("已停用 %@ 个未使用的插件。", count), details: details, isError: false)
            } else {
                showResult(T("停用失败"), T("没有停用任何插件。"), details: details, isError: true)
            }
            viewModel.scan()
        }
    }

    /// 只恢复某一批次停用的插件：不碰其它停用项，也不碰手动停用的插件
    private func restoreBatch(_ batch: ProjectBatch) {
        // 恢复是一次点击就执行，不再连环确认
        showProjectScan = false
        Task { @MainActor in
            let outcome = await viewModel.restoreProjectBatch(batch.id)
            viewModel.scan()

            var detail = fcpIsRunning ? T("重启 Final Cut Pro 后生效") : nil
            if outcome.cancelled {
                detail = T("已按你的要求停止，剩余插件保持停用状态")
            }
            actionToast = ActionToast(
                text: T("「%@」%@", batch.projectName, outcome.summary),
                undoTitle: nil,
                detail: detail
            )

            if !outcome.failed.isEmpty || !outcome.skipped.isEmpty {
                showResult(
                    T("批次恢复结果"),
                    T("「%@」%@。", batch.projectName, outcome.summary),
                    details: outcome.notes,
                    isError: !outcome.failed.isEmpty
                )
            }
        }
    }

    /// 用管理员授权真正移走所有用户安装的插件；取消时给可复制的命令
    private func applyPendingDisables(_ items: [DisabledItem]) {
        guard !isApplyingAdmin else { return }
        isApplyingAdmin = true
        Task { @MainActor in
            defer { isApplyingAdmin = false }
            let outcome = await viewModel.applyPendingDisables(items)
            if outcome.succeededCount > 0 {
                viewModel.addOperation(
                    kind: .disablePlugins,
                    summary: T("真正停用 %@ 个所有用户安装的插件", outcome.succeededCount)
                )
                showResult(
                    T("已停用"),
                    T("已把 %@ 个插件移出系统目录。", outcome.succeededCount),
                    details: fcpDetails
                )
            } else {
                systemCommandText = viewModel.manualDisableCommands(for: items)
                systemCommandSummary = T("没有停用成功：%@\n\n可以复制下面的命令，打开「终端」粘贴执行。执行完回到本应用点「复核」。", outcome.message)
                showSystemCommandSheet = true
            }
            viewModel.scan()
        }
    }

    private func enableSingle(_ item: DisabledItem) {
        Task { @MainActor in
            await performEnable([item], quiet: true)
        }
    }

    private func enableSelectedDisabled() {
        let items = viewModel.disabledItems.filter { selectedDisabledPaths.contains($0.entryPath) }
        Task { @MainActor in
            await performEnable(items)
        }
    }

    private func enableAllDisabled() {
        let items = disabledItems(in: pendingEnableCategory)
        Task { @MainActor in
            await performEnable(items)
        }
    }

    /// 恢复：先预检冲突，全部冲突时明确告诉用户会全部跳过，让用户选
    @MainActor
    private func performEnable(_ items: [DisabledItem], overwriteExisting: Bool = false, quiet: Bool = false) async {
        guard !items.isEmpty else {
            showResult(T("没有可恢复的插件"), T("没有选中任何插件。"))
            return
        }

        // 原位置还有插件的记录不再需要「覆盖」决策：插件本来就在用，
        // 启用这一动作只会把多余副本移进废纸篓，原插件不动。
        var adminItems: [DisabledItem] = []
        var failures: [String] = []
        var enabledCount = 0
        var warningItems: [String] = []

        for item in items {
            switch await viewModel.enableDisabled(item, overwriteExisting: overwriteExisting) {
            case .success:
                enabledCount += 1
            case .successWithWarning(let warning):
                enabledCount += 1
                warningItems.append(T("%@：%@", item.displayName, warning))
            case .targetExists:
                failures.append(T("%@：原始位置已存在", item.displayName))
            case .needAuthentication:
                adminItems.append(item)
            case .failure(let error):
                failures.append(T("%@：%@", item.displayName, error))
            }
        }

        var authorizedCount = 0
        if !adminItems.isEmpty {
            let admin = await viewModel.applyPendingEnables(adminItems)
            authorizedCount = admin.succeededCount
            if admin.succeededCount < adminItems.count {
                systemCommandText = viewModel.manualEnableCommands(for: adminItems)
                systemCommandSummary = T("自动授权没有完成：%@\n\n可以复制下面的命令手动执行。执行完回到本应用点「复核」。", admin.message)
                showSystemCommandSheet = true
            }
        }

        if enabledCount + authorizedCount > 0 {
            viewModel.addOperation(
                kind: .enablePlugins,
                summary: T("恢复 %@ 个插件", enabledCount + authorizedCount)
            )
        }

        let totalRestored = enabledCount + authorizedCount
        var summary = T("已恢复启用 %@ 个插件。", totalRestored)
        if !adminItems.isEmpty && authorizedCount < adminItems.count {
            summary += T("还有 %@ 个需要管理员授权。", adminItems.count - authorizedCount)
        }
        summary += T("\n重启 Final Cut Pro 后生效。")
        if showSystemCommandSheet {
            systemCommandSummary += "\n\n\(summary)"
        } else if quiet && totalRestored > 0 && failures.isEmpty && warningItems.isEmpty {
            // 单个开关点了就恢复，用底部轻提示，不打扰
            actionToast = ActionToast(
                text: T("已启用「%@」", items.first?.displayName ?? ""),
                undoTitle: nil,
                detail: fcpIsRunning ? T("重启 Final Cut Pro 后生效") : nil
            )
        } else {
            showResult(
                totalRestored > 0 ? T("恢复完成") : T("没有恢复"),
                summary,
                details: failures + warningItems + (totalRestored > 0 ? fcpDetails : []),
                isError: !failures.isEmpty
            )
        }

        selectedDisabledPaths.removeAll()
        viewModel.scan()
    }


    private func deleteSingleDisabled(_ item: DisabledItem) {
        Task { @MainActor in
            switch await viewModel.deleteDisabled(item) {
            case .success:
                viewModel.disabledItems.removeAll { $0.entryPath == item.entryPath }
                selectedDisabledPaths.remove(item.entryPath)
            case .needAuthentication:
                showResult(T("删除失败"), T("删除这条禁用记录需要管理员权限。"), isError: true)
            case .failure(let error):
                showResult(T("删除失败"), T("删除禁用记录失败：%@", error), isError: true)
            }
        }
    }

    private func deleteSelectedDisabled() {
        let items = viewModel.disabledItems.filter { selectedDisabledPaths.contains($0.entryPath) }
        guard !items.isEmpty else { return }
        Task { @MainActor in
            var deletedCount = 0
            var failItems: [String] = []
            for item in items {
                switch await viewModel.deleteDisabled(item) {
                case .success:
                    deletedCount += 1
                    viewModel.disabledItems.removeAll { $0.entryPath == item.entryPath }
                case .needAuthentication:
                    failItems.append(T("%@：需要管理员权限", item.displayName))
                case .failure(let error):
                    failItems.append(T("%@：%@", item.displayName, error))
                }
            }
            selectedDisabledPaths.removeAll()
            showResult(
                T("已删除记录"),
                T("已删除 %@ 条禁用记录。", deletedCount),
                details: failItems,
                isError: !failItems.isEmpty
            )
        }
    }

    // MARK: - Project Scan Actions

    /// 校验并开始扫描。返回 nil 表示已接受并开始扫描；返回文字表示类型不对，由面板就地提示。
    private func acceptProjectFile(_ url: URL) -> String? {
        let ext = url.pathExtension.lowercased()
        guard ext == "fcpxml" || ext == "fcpbundle" else {
            return T("这个类型不支持。请拖入 .fcpxml 工程文件，或 .fcpbundle 库。")
        }
        startProjectScan(url)
        return nil
    }

    private func startProjectScan(_ url: URL) {
        let ext = url.pathExtension.lowercased()
        guard ext == "fcpxml" || ext == "fcpbundle" else {
            projectScanError = T("请选择 .fcpxml 工程文件或 .fcpbundle 库。你选中的是：%@", url.lastPathComponent)
            return
        }
        isScanningProject = true
        Task { @MainActor in
            defer { isScanningProject = false }
            do {
                _ = try await viewModel.scanProject(at: url)
                // 拖放面板刚关掉时关闭动画还没结束，直接再弹一个 sheet 会被系统忽略
                try? await Task.sleep(nanoseconds: 250_000_000)
                showProjectScan = true
            } catch {
                projectScanError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    /// 库读不懂时的兜底：让用户直接选一份导出的 XML
    private func chooseXMLFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if let type = UTType(filenameExtension: "fcpxml") {
            panel.allowedContentTypes = [type]
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        startProjectScan(url)
    }

    private func handleProjectDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url else { return }
            Task { @MainActor in
                if let message = acceptProjectFile(url) {
                    projectScanError = message
                }
            }
        }
        return true
    }

    // MARK: - Undo / Log

    private func undoLastOperation() {
        guard let record = viewModel.lastUndoableOperation else { return }
        Task { @MainActor in
            await runUndo(record)
        }
    }

    @MainActor
    private func runUndo(_ record: OperationRecord) async {
        let outcome = await viewModel.undo(record)

        var details = outcome.failures + outcome.needsAuth
        var summary: String
        if outcome.restoredCount > 0 {
            summary = T("已恢复 %@ 个插件。重启 Final Cut Pro 后生效。", outcome.restoredCount)
            details += fcpDetails
        } else if outcome.isComplete {
            summary = T("没有需要恢复的内容。")
        } else {
            summary = T("撤销没有改动任何文件。")
        }
        showResult(T("撤销完成"), summary, details: details, isError: !details.isEmpty)
        viewModel.scan()
    }

    // MARK: - Backup Actions

    private func restoreSingleBackup(_ backup: BackupItem) {
        startRestore([backup], actionName: T("恢复"))
    }

    private func restoreSelectedBackups() {
        let selectedBackups = viewModel.backups.filter { selectedBackupPaths.contains($0.backupPath) }
        guard !selectedBackups.isEmpty else {
            showResult(T("没有可恢复的插件"), T("没有选中任何备份。"))
            return
        }
        startRestore(selectedBackups, actionName: T("恢复"))
    }

    /// 恢复前先预检：全部冲突时直接说清楚「会全部跳过」，让用户选跳过还是覆盖
    @MainActor
    private func startRestore(_ backups: [BackupItem], actionName: String) {
        guard !backups.isEmpty else {
            showResult(T("没有可恢复的插件"), T("没有可以恢复的插件。"))
            return
        }
        let conflicts = backups.filter { viewModel.restoreTargetExists(for: $0) }
        if conflicts.isEmpty {
            Task { @MainActor in
                await performRestore(backups)
            }
            return
        }
        conflictChoice = ConflictChoice(
            title: T("%@ 个备份的原位置已有同名插件", conflicts.count),
            summary: T("按默认「不覆盖」，这 %@ 个会全部跳过；其余 %@ 个可以正常%@。", conflicts.count, backups.count - conflicts.count, actionName),
            names: conflicts.map(\.displayName),
            total: backups.count,
            restoreBackups: backups
        )
    }

    @MainActor
    private func performRestore(_ backups: [BackupItem], overwriteExisting: Bool = false) async {
        guard !backups.isEmpty else { return }

        var successCount = 0
        var authBackups: [BackupItem] = []
        var failItems: [String] = []
        var warningItems: [String] = []
        var stopped = false

        viewModel.beginBatch(T("正在恢复 %lld 个备份", backups.count), total: backups.count)
        for backup in backups {
            let result = await viewModel.restoreBackup(backup, overwriteExisting: overwriteExisting)
            switch result {
            case .success:
                successCount += 1
                viewModel.backups.removeAll { $0.backupPath == backup.backupPath }
                selectedBackupPaths.remove(backup.backupPath)
            case .successWithWarning(let warning):
                successCount += 1
                warningItems.append(T("%@：%@", backup.displayName, warning))
                selectedBackupPaths.remove(backup.backupPath)
            case .targetExists:
                failItems.append(T("%@：目标位置已存在", backup.displayName))
            case .needAuthentication:
                authBackups.append(backup)
            case .failure(let error):
                failItems.append(T("%@：%@", backup.displayName, error))
            }
            if !viewModel.advanceBatch() {
                stopped = true
                break
            }
        }
        viewModel.endBatch()

        if successCount > 0 {
            viewModel.addOperation(kind: .restoreBackups, summary: T("恢复 %@ 个备份", successCount))
        }

        var summary = ""
        if successCount > 0 {
            summary = backups.count == 1
                ? T("已将「%@」恢复到原始位置。", backups[0].displayName)
                : T("已成功恢复 %@ 个插件。", successCount)
            summary += T("\n重启 Final Cut Pro 后生效。")
        } else if !failItems.isEmpty {
            summary = T("没有恢复任何插件。")
        } else if authBackups.isEmpty {
            summary = T("没有可以恢复的插件。")
        }

        if stopped {
            summary += (summary.isEmpty ? "" : "\n") + T("已停止，剩下的没有再处理。")
        }

        if !authBackups.isEmpty {
            systemCommandText = authBackups.map {
                T("# 备份：%@\nsudo ditto %@ %@", $0.backupPath, AdminCommandBuilder.quote($0.backupPath), AdminCommandBuilder.quote($0.originalPath))
            }.joined(separator: "\n\n")
            systemCommandSummary = (summary.isEmpty ? "" : summary + "\n\n") +
                T("以下 %@ 个插件装在所有用户目录，需要管理员密码，未恢复。复制命令到「终端」执行，执行完回到本应用点「刷新」。", authBackups.count)
            showSystemCommandSheet = true
        } else {
            showResult(
                successCount > 0 ? T("恢复完成") : T("没有恢复"),
                summary,
                details: failItems + warningItems + (successCount > 0 ? fcpDetails : []),
                isError: !failItems.isEmpty
            )
        }
        viewModel.scan()
    }

    private func deleteSingleBackup(_ backup: BackupItem) {
        Task { @MainActor in
            switch await viewModel.deleteBackup(backup) {
            case .success:
                viewModel.backups.removeAll { $0.backupPath == backup.backupPath }
                selectedBackupPaths.remove(backup.backupPath)
                viewModel.addOperation(kind: .deleteBackups, summary: T("删除备份「%@」", backup.displayName))
                showResult(T("已删除"), T("备份「%@」已移入废纸篓。", backup.displayName))
            case .needAuthentication:
                showResult(T("删除失败"), T("删除备份需要管理员权限。"), isError: true)
            case .failure(let error):
                showResult(T("删除失败"), T("删除备份失败：%@", error), isError: true)
            }
        }
    }

    /// 批量删除备份只走这一个入口（已经过二次确认）
    private func deleteBackups(_ backups: [BackupItem]) {
        guard !backups.isEmpty else { return }
        Task { @MainActor in
            var deletedCount = 0
            var failItems: [String] = []
            for backup in backups {
                switch await viewModel.deleteBackup(backup) {
                case .success:
                    deletedCount += 1
                    viewModel.backups.removeAll { $0.backupPath == backup.backupPath }
                    selectedBackupPaths.remove(backup.backupPath)
                case .needAuthentication:
                    failItems.append(T("%@：需要管理员权限", backup.displayName))
                case .failure(let error):
                    failItems.append(T("%@：%@", backup.displayName, error))
                }
            }
            selectedBackupPaths.removeAll()
            if deletedCount > 0 {
                viewModel.addOperation(kind: .deleteBackups, summary: T("删除 %@ 个备份", deletedCount))
            }
            showResult(
                T("已删除备份"),
                T("已删除 %@ 个备份，可在废纸篓找回。", deletedCount),
                details: failItems,
                isError: !failItems.isEmpty
            )
        }
    }

    // MARK: - Rename

    private func performRename(_ plugin: PluginItem, to newName: String) {
        Task { @MainActor in
            switch await viewModel.renamePlugin(plugin, to: newName) {
            case .success(let oldPath, let newPath, let updatedBackups):
                viewModel.addOperation(
                    kind: .renamePlugin,
                    summary: T("重命名「%@」→「%@」", URL(fileURLWithPath: oldPath).lastPathComponent, URL(fileURLWithPath: newPath).lastPathComponent),
                    renames: [RenameSnapshot(oldPath: oldPath, newPath: newPath)]
                )
                var details: [String] = []
                if updatedBackups > 0 {
                    details.append(T("已同步更新 %@ 条备份记录的原始路径，旧备份仍能正常恢复。", updatedBackups))
                } else {
                    details.append(T("没有受影响的旧备份。"))
                }
                details.append(T("重启 Final Cut Pro 后，菜单里显示的也是新名字。"))
                showResult(T("已改名"), T("已改名为「%@」。", newName), details: details)
                viewModel.scan()

            case .needAuthentication(let oldPath, let newPath, let reason):
                systemCommandText = AdminCommandBuilder.renameCommand(oldPath: oldPath, newPath: newPath)
                systemCommandSummary = T("「%@」装在所有用户目录，不能在这里直接改名。\n\n原因：%@\n\n复制命令到「终端」执行。执行完回到本应用点「刷新」，列表里应该显示「%@」。\n\n注意：这类改名无法自动记入日志，也不能用「撤销上一步」改回去，需要手动执行反向命令。", plugin.name, reason, newName)
                showSystemCommandSheet = true

            case .failure(let error):
                showResult(T("改名失败"), error, isError: true)
            }
        }
    }

    // MARK: - 导入译名表

    private func chooseRenameMap() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText, .json, .plainText]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = T("选择 CSV 或 JSON 文件，第一列是插件原名或完整路径，第二列是新名字。")
        panel.prompt = T("导入")
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let data = try Data(contentsOf: url)
            let entries = try RenameMapParser.parse(data: data, fileExtension: url.pathExtension)
            let plan = viewModel.buildRenamePlan(entries: entries)
            importPreview = ImportMapPreview(fileName: url.lastPathComponent, plan: plan)
        } catch {
            showResult(T("导入失败"), error.localizedDescription, isError: true)
        }
    }

    private func applyImportPlan(_ plan: RenamePlan) {
        Task { @MainActor in
            let outcome = await viewModel.applyRenamePlan(plan)
            if !outcome.renames.isEmpty {
                viewModel.addOperation(
                    kind: .renamePlugin,
                    summary: T("重命名 %lld 个插件", outcome.renames.count),
                    renames: outcome.renames
                )
            }
            let details = outcome.failures
            if !outcome.adminCommands.isEmpty {
                systemCommandText = outcome.adminCommands.joined(separator: "\n")
                systemCommandSummary = T("装在所有用户目录的插件不能在这里直接改名，下面是可复制的命令：")
                showSystemCommandSheet = true
            }
            showResult(
                T("改名结果"),
                T("已应用 %lld 条改名。", outcome.renames.count),
                details: details,
                isError: !details.isEmpty
            )
            viewModel.scan()
        }
    }

    // MARK: - Helpers

    private func sidebarIcon(for item: SidebarItem) -> String {
        switch item {
        case .all: return "list.bullet"
        case .effects: return "sparkles"
        case .generators: return "film"
        case .transitions: return "arrow.right.arrow.left"
        // 不用 textformat：这个符号会跟系统语言变，中文系统下在英文界面里会画成「格式」
        case .titles: return "text.bubble"
        case .backups: return "archivebox"
        case .disabled: return "pause.circle"
        }
    }
}

// MARK: - Plugin Detail

struct PluginDetailView: View {
    let plugin: PluginItem
    @Environment(\.dismiss) private var dismiss

    private var rows: [(String, String)] {
        var result: [(String, String)] = [
            (T("名称"), plugin.displayName),
            (T("分类"), plugin.category.displayName),
            (T("来源"), plugin.origin.displayName),
            (T("安装范围"), plugin.installScopeDescription),
            (T("安装位置"), plugin.localizedLocation)
        ]
        if let vendor = plugin.vendor {
            result.append((T("厂商/版权"), vendor))
        }
        if let version = plugin.version {
            result.append((T("版本"), version))
        }
        if let bundleID = plugin.bundleIdentifier {
            result.append((T("包标识"), bundleID))
        }
        if let size = plugin.sizeDescription {
            result.append((T("体积"), size))
        }
        if let date = plugin.installDateDescription {
            result.append((T("安装时间"), date))
        }
        result.append((T("完整路径"), plugin.path))
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(T("插件详情"))
                .font(.title3)
                .fontWeight(.semibold)

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        Text(row.0)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .gridColumnAlignment(.trailing)
                        Text(row.1)
                            .font(.system(size: 12))
                            .textSelection(.enabled)
                            .lineLimit(3)
                    }
                }
            }

            Text(T("预览图：暂时不做。读取插件预览需要额外解码包内容，会明显拖慢扫描，收益不大。"))
                .font(.caption2)
                .foregroundStyle(.secondary)

            HStack {
                Button(T("显示在访达中")) {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: plugin.path)])
                }
                Spacer()
                Button(T("关闭")) { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 460)
    }
}

// MARK: - Operation Log

struct OperationLogView: View {
    let records: [OperationRecord]
    let onUndo: (OperationRecord) -> Void
    @Environment(\.dismiss) private var dismiss

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(T("操作日志"))
                .font(.title3)
                .fontWeight(.semibold)

            if records.isEmpty {
                Text(T("还没有操作记录。"))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(records.reversed()) { record in
                            HStack(alignment: .top, spacing: 8) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(record.summary)
                                        .font(.system(size: 12))
                                    Text(T("%@ · %@%@", record.kind.displayName, Self.dateFormatter.string(from: record.date), record.undone ? T(" · 已撤销") : ""))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if record.isUndoable {
                                    Button(T("撤销")) { onUndo(record) }
                                        .buttonStyle(.bordered)
                                        .controlSize(.small)
                                }
                            }
                            Divider()
                        }
                    }
                }
            }

            HStack {
                Spacer()
                Button(T("关闭")) { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 480, minHeight: 360)
    }
}

// MARK: - Action Toast（底部轻提示，可撤销）

struct ActionToast: Identifiable, Equatable {
    let id = UUID()
    let text: String
    /// 传 nil 表示这次操作不能撤销（例如「启用」本身）
    var undoTitle: String?
    /// 附加说明，比如「重启 FCP 后生效」
    var detail: String?

    static func == (lhs: ActionToast, rhs: ActionToast) -> Bool { lhs.id == rhs.id }
}

// MARK: - Project Scan Drop Panel（拖入工程 &= 打开工程）

/// 扫描入口：拖文件是主路径，「打开工程…」只是备用。
/// 拖进来类型不对时在原地提示，不关面板；拖对了就关面板直接开扫。
struct ProjectScanDropPanel: View {
    /// 返回 nil 表示已接受（面板关闭并开始扫描）；返回文字表示类型不对，就地提示
    let onAccept: (URL) -> String?

    @Environment(\.dismiss) private var dismiss
    @State private var isTargeted = false
    @State private var errorMessage: String?

    private let supportedExtensions: Set<String> = ["fcpxml", "fcpbundle"]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "doc.text.magnifyingglass")
                    .foregroundStyle(.blue)
                Text(T("扫描工程"))
                    .font(.headline)
                Spacer()
            }

            dropZone
                .frame(height: 200)

            Text(T("支持 .fcpxml 工程和 .fcpbundle 库。库会先复制到临时目录再只读解析，不会改动原库；只有格式读不懂时才需要导出 XML。"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let errorMessage {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                    Text(errorMessage)
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
            }

            HStack(spacing: 10) {
                Button(T("打开工程…")) { openProjectPicker() }
                    .hoverBrighten(cornerRadius: 6)
                Spacer()
                Button(T("关闭")) { dismiss() }
                    .hoverTint(cornerRadius: 6)
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    // MARK: 拖放区

    private var dropZone: some View {
        VStack(spacing: 10) {
            Image(systemName: isTargeted ? "arrow.down.doc.fill" : "arrow.down.doc")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(isTargeted ? Color.accentColor : Color.secondary)
            Text(T("把工程文件拖到这里"))
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
            Text(T("拖 .fcpxml 工程或 .fcpbundle 库进来，或点下面的「打开工程…」"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(isTargeted ? Color.accentColor.opacity(0.12) : Color(.controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(
                    isTargeted ? Color.accentColor : Color.secondary.opacity(0.45),
                    style: StrokeStyle(lineWidth: isTargeted ? 2 : 1.5, dash: [7])
                )
        )
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            handleDrop(providers)
        }
        .animation(.easeInOut(duration: 0.12), value: isTargeted)
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard !providers.isEmpty else { return false }
        guard providers.count == 1 else {
            errorMessage = T("只支持单个文件，请一次拖一个进来。")
            return true
        }
        guard let provider = providers.first else { return false }

        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            DispatchQueue.main.async {
                guard let url else {
                    errorMessage = T("这个类型不支持。请拖入 .fcpxml 工程文件，或 .fcpbundle 库。")
                    return
                }
                guard supportedExtensions.contains(url.pathExtension.lowercased()) else {
                    errorMessage = T("这个类型不支持。请拖入 .fcpxml 工程文件，或 .fcpbundle 库。")
                    return
                }
                if let message = onAccept(url) {
                    errorMessage = message
                } else {
                    dismiss()
                }
            }
        }
        return true
    }

    // MARK: 系统文件选择（备用路径）

    private func openProjectPicker() {
        let panel = NSOpenPanel()
        panel.title = T("选择工程文件")
        panel.message = T("选择 .fcpxml 工程文件，或一个 .fcpbundle 库")
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if let message = onAccept(url) {
            errorMessage = message
        } else {
            dismiss()
        }
    }
}

// MARK: - Project Scan Sheet（工程扫描结果）

struct ProjectScanSheet: View {
    let result: ProjectScanResult?
    let usedPlugins: [PluginItem]
    let unusedPlugins: [PluginItem]
    let appleSkipped: Int
    let unmatched: [String]
    /// 这个工程的历史停用批次（新的在前）
    let batches: [ProjectBatch]
    let onRestoreBatch: (ProjectBatch) -> Void
    let onDisableUnused: () -> Void

    @Environment(\.dismiss) private var dismiss

    /// 最近一批还没恢复完的（「恢复本次停用的」按钮就针对它）
    private var pendingBatch: ProjectBatch? {
        batches.first(where: \.hasPending)
    }

    private var unusedByCategory: [(PluginCategory, [PluginItem])] {
        PluginCategory.allCases
            .filter { $0 != .all }
            .map { category in (category, unusedPlugins.filter { $0.category == category }) }
            .filter { !$0.1.isEmpty }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "doc.text.magnifyingglass")
                    .foregroundStyle(.blue)
                Text(T("工程扫描结果"))
                    .font(.headline)
                Spacer()
            }

            if let result {
                Text(result.projectName)
                    .font(.title3.bold())
                    .lineLimit(1)

                Text(result.fileURL.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)

                if let warning = result.warning {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text(warning)
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
                } else {
                    HStack(spacing: 10) {
                        statChip(T("本工程用到 %@ 个", usedPlugins.count), color: .blue, icon: "checkmark.shield")
                        statChip(T("未使用 %@ 个", unusedPlugins.count), color: .orange, icon: "pause.circle")
                        if appleSkipped > 0 {
                            statChip(T("Apple 自带跳过 %@ 个", appleSkipped), color: .secondary, icon: "lock.shield")
                        }
                        Spacer()
                    }

                    Text(T("本工程依赖的插件已自动加入保护名单，批量停用时不会碰它们。"))
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if !usedPlugins.isEmpty {
                        Text(T("本工程用到"))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        ScrollView {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(usedPlugins) { plugin in
                                    HStack(spacing: 6) {
                                        Image(systemName: "shield.fill")
                                            .font(.system(size: 9))
                                            .foregroundStyle(.blue)
                                        Text(plugin.displayName)
                                            .font(.system(size: 12))
                                            .lineLimit(1)
                                        Text(plugin.category.displayName)
                                            .font(.system(size: 10))
                                            .foregroundStyle(.secondary)
                                        Spacer()
                                    }
                                }
                            }
                            .padding(8)
                        }
                        .frame(maxHeight: 150)
                        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
                    }

                    if !unusedByCategory.isEmpty {
                        Text(T("本工程未使用（可停用）"))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        ScrollView {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(unusedByCategory, id: \.0) { category, items in
                                    Text(T("%@ · %@ 个", category.displayName, items.count))
                                        .font(.system(size: 11, weight: .medium))
                                        .padding(.top, 2)
                                    ForEach(items) { plugin in
                                        Text(plugin.displayName)
                                            .font(.system(size: 11))
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                        }
                        .frame(maxHeight: 150)
                        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
                    }

                    if !unmatched.isEmpty {
                        Text(T("还有 %@ 个引用没匹配到本机插件（可能来自别的机器或已卸载）：%@", unmatched.count, unmatched.prefix(5).joined(separator: "、")))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }

                    if !batches.isEmpty {
                        Divider()
                        Text(T("这个工程的停用批次"))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        ScrollView {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(batches) { batch in
                                    HStack(spacing: 8) {
                                        Image(systemName: batch.hasPending ? "pause.circle.fill" : "checkmark.circle.fill")
                                            .font(.system(size: 11))
                                            .foregroundStyle(batch.hasPending ? Color.orange : Color.green)
                                        Text(batch.createdAt.formatted(date: .abbreviated, time: .shortened))
                                            .font(.system(size: 11))
                                        Text(T("%@ 个", batch.entries.count))
                                            .font(.system(size: 11))
                                            .foregroundStyle(.secondary)
                                        Text(batchStatusText(batch))
                                            .font(.system(size: 11))
                                            .foregroundStyle(batch.hasPending ? Color.orange : Color.secondary)
                                        Spacer()
                                        if batch.hasPending {
                                            Button(T("恢复这一批")) { onRestoreBatch(batch) }
                                                .buttonStyle(.plain)
                                                .font(.system(size: 11, weight: .semibold))
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 2)
                                                .hoverTint(cornerRadius: 4)
                                        }
                                    }
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                        }
                        .frame(maxHeight: 100)
                        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
                    }
                }
            } else {
                Text(T("还没有扫描工程。"))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            HStack(spacing: 10) {
                Text(T("停用不会删除插件文件，随时可以恢复。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(T("关闭")) { dismiss() }
                if let result, result.parsed {
                    if let pendingBatch {
                        Button(T("恢复本次停用的 %@ 个", pendingBatch.pendingCount)) {
                            onRestoreBatch(pendingBatch)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.green)
                        .hoverBrighten(cornerRadius: 6)
                    }
                    if !unusedPlugins.isEmpty {
                        Button(T("停用未使用的 %@ 个…", unusedPlugins.count)) {
                            onDisableUnused()
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.orange)
                        .hoverBrighten(cornerRadius: 6)
                    }
                }
            }
        }
        .padding(20)
        .frame(width: 660)
    }

    private func batchStatusText(_ batch: ProjectBatch) -> String {
        if batch.isFullyRestored { return T("已恢复") }
        if batch.hasPending {
            return T("待恢复 %@ 个", batch.pendingCount)
        }
        return T("已恢复 %@ 个 · 跳过 %@ 个", batch.restoredCount, batch.skippedCount)
    }

    private func statChip(_ text: String, color: Color, icon: String) -> some View {
        Label(text, systemImage: icon)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(color)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(color.opacity(0.10), in: Capsule())
    }
}

// MARK: - Library Scan Sheet（直接读 .fcpbundle）

/// 拖入真实库后的面板：按事件/工程列出，可看整库或只选某个工程。
struct LibraryScanSheet: View {
    let result: ProjectScanResult?
    let bundle: FCPBundleScanResult
    let usedPlugins: [PluginItem]
    let unusedPlugins: [PluginItem]
    let appleSkipped: Int
    let unmatched: [String]
    let batches: [ProjectBatch]
    let onSetWholeLibrary: (Bool) -> Void
    let onToggleProject: (String) -> Void
    let onRestoreBatch: (ProjectBatch) -> Void
    let onDisableUnused: () -> Void

    @Environment(\.dismiss) private var dismiss

    private var pendingBatch: ProjectBatch? {
        batches.first(where: \.hasPending)
    }

    private var unusedByCategory: [(PluginCategory, [PluginItem])] {
        PluginCategory.allCases
            .filter { $0 != .all }
            .map { category in (category, unusedPlugins.filter { $0.category == category }) }
            .filter { !$0.1.isEmpty }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "externaldrive.badge.magnifyingglass")
                    .foregroundStyle(.blue)
                Text(T("库扫描结果"))
                    .font(.headline)
                Spacer()
                Text(T("只读分析"))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.primary.opacity(0.06), in: Capsule())
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text(bundle.libraryName)
                        .font(.title3.bold())
                        .lineLimit(1)
                    Text(bundle.libraryURL.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)

                    if let notice = bundle.notice {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "lock.doc")
                                .foregroundStyle(.blue)
                            Text(notice)
                                .font(.caption)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                    }

                    if let warning = result?.warning {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            Text(warning)
                                .font(.callout)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
                    }

                    HStack(spacing: 8) {
                        statChip(T("%@ 个事件", bundle.events.count), color: .secondary, icon: "rectangle.stack")
                        statChip(T("%@ 个工程", bundle.projectCount), color: .secondary, icon: "film.stack")
                        statChip(T("用到 %@ 个", usedPlugins.count), color: .blue, icon: "checkmark.shield")
                        statChip(T("未使用 %@ 个", unusedPlugins.count), color: .orange, icon: "pause.circle")
                        if appleSkipped > 0 {
                            statChip(T("Apple 自带跳过 %@ 个", appleSkipped), color: .secondary, icon: "lock.shield")
                        }
                        Spacer()
                    }

                    Text(T("库里的插件依赖已自动加入保护名单，批量停用时不会碰它们。"))
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Divider()

                    Toggle(isOn: Binding(
                        get: { bundle.wholeLibrary },
                        set: { onSetWholeLibrary($0) }
                    )) {
                        Text(T("整库"))
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .toggleStyle(.checkbox)

                    if bundle.events.isEmpty {
                        Text(T("这个库里没有事件。"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(bundle.events) { event in
                            eventRow(event)
                        }
                    }

                    if !usedPlugins.isEmpty {
                        Text(T("库里用到"))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.top, 4)
                        ScrollView {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(usedPlugins) { plugin in
                                    HStack(spacing: 6) {
                                        Image(systemName: "shield.fill")
                                            .font(.system(size: 9))
                                            .foregroundStyle(.blue)
                                        Text(plugin.displayName)
                                            .font(.system(size: 12))
                                            .lineLimit(1)
                                        Text(plugin.category.displayName)
                                            .font(.system(size: 10))
                                            .foregroundStyle(.secondary)
                                        Spacer()
                                    }
                                }
                            }
                            .padding(8)
                        }
                        .frame(maxHeight: 120)
                        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
                    }

                    if !unusedByCategory.isEmpty {
                        Text(T("未使用（可停用）"))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.top, 4)
                        ScrollView {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(unusedByCategory, id: \.0) { category, items in
                                    Text(T("%@ · %@ 个", category.displayName, items.count))
                                        .font(.system(size: 11, weight: .medium))
                                        .padding(.top, 2)
                                    ForEach(items) { plugin in
                                        Text(plugin.displayName)
                                            .font(.system(size: 11))
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                        }
                        .frame(maxHeight: 120)
                        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
                    }

                    if !unmatched.isEmpty {
                        Text(T("还有 %@ 个引用没匹配到本机插件（可能来自别的机器或已卸载）：%@", unmatched.count, unmatched.prefix(5).joined(separator: "、")))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }

                    if !batches.isEmpty {
                        Divider()
                        Text(T("这个库的停用批次"))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        ScrollView {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(batches) { batch in
                                    HStack(spacing: 8) {
                                        Image(systemName: batch.hasPending ? "pause.circle.fill" : "checkmark.circle.fill")
                                            .font(.system(size: 11))
                                            .foregroundStyle(batch.hasPending ? Color.orange : Color.green)
                                        Text(batch.projectName)
                                            .font(.system(size: 11))
                                            .lineLimit(1)
                                        Text(batch.createdAt.formatted(date: .abbreviated, time: .shortened))
                                            .font(.system(size: 11))
                                            .foregroundStyle(.secondary)
                                        Text(T("%@ 个", batch.entries.count))
                                            .font(.system(size: 11))
                                            .foregroundStyle(.secondary)
                                        Spacer()
                                        if batch.hasPending {
                                            Button(T("恢复这一批")) { onRestoreBatch(batch) }
                                                .buttonStyle(.plain)
                                                .font(.system(size: 11, weight: .semibold))
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 2)
                                                .hoverTint(cornerRadius: 4)
                                        }
                                    }
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                        }
                        .frame(maxHeight: 100)
                        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
                    }
                }
            }

            Divider()

            HStack(spacing: 10) {
                Text(T("停用不会删除插件文件，随时可以恢复。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(T("关闭")) { dismiss() }
                if let result, result.parsed {
                    if let pendingBatch {
                        Button(T("恢复本次停用的 %@ 个", pendingBatch.pendingCount)) {
                            onRestoreBatch(pendingBatch)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.green)
                        .hoverBrighten(cornerRadius: 6)
                    }
                    if !unusedPlugins.isEmpty {
                        Button(T("停用未使用的 %@ 个…", unusedPlugins.count)) {
                            onDisableUnused()
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.orange)
                        .hoverBrighten(cornerRadius: 6)
                    }
                }
            }
        }
        .padding(20)
        .frame(width: 720, height: 660)
    }

    @ViewBuilder
    private func eventRow(_ event: FCPBundleEvent) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "rectangle.stack")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Text(event.name)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                Text(T("%@ 个工程", event.projects.count))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                if event.warning != nil {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                }
                Spacer()
            }

            if event.projects.isEmpty {
                Text(T("这个事件里没有工程"))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 20)
            } else {
                ForEach(event.projects) { project in
                    HStack(spacing: 8) {
                        Toggle(isOn: Binding(
                            get: { bundle.selectedProjectIDs.contains(project.id) },
                            set: { _ in onToggleProject(project.id) }
                        )) {
                            EmptyView()
                        }
                        .toggleStyle(.checkbox)
                        .labelsHidden()

                        Text(project.name)
                            .font(.system(size: 11))
                            .lineLimit(1)
                        Text(T("%@ 个效果引用", project.references.count))
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        if project.warning != nil {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(.orange)
                        }
                        Spacer()
                    }
                    .padding(.leading, 20)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func statChip(_ text: String, color: Color, icon: String) -> some View {
        Label(text, systemImage: icon)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(color)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(color.opacity(0.10), in: Capsule())
    }
}

// MARK: - Batch Result (可滚动、可关闭，绝不卡死)

struct BatchResult: Identifiable {
    let id = UUID()
    let title: String
    let summary: String
    let details: [String]
    let isError: Bool
}

struct BatchResultSheet: View {
    let result: BatchResult
    @Environment(\.dismiss) private var dismiss
    @State private var showDetails = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: result.isError ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(result.isError ? .orange : .green)
                Text(result.title)
                    .font(.headline)
            }

            Text(result.summary)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)

            if !result.details.isEmpty {
                HStack(spacing: 8) {
                    Label(
                        result.isError ? T("失败 %@ 项", result.details.count) : T("%@ 条明细", result.details.count),
                        systemImage: result.isError ? "exclamationmark.triangle.fill" : "list.bullet.rectangle"
                    )
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(result.isError ? Color.red : Color.secondary)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(
                        (result.isError ? Color.red : Color.secondary).opacity(0.10),
                        in: Capsule()
                    )
                    Spacer()
                }

                DisclosureGroup(isExpanded: $showDetails) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(Array(result.details.enumerated()), id: \.offset) { _, line in
                                Text(line)
                                    .font(.system(size: 12))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .padding(8)
                    }
                    .frame(minHeight: 90, maxHeight: 240)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
                } label: {
                    Text(T("展开查看每一条原因"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                Spacer()
                Button(T("关闭")) { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 560)
    }
}

// MARK: - Conflict Choice (先预检，再让用户选跳过/覆盖)

enum ConflictResolveMode {
    case skip
    case overwrite
}

struct ConflictChoice: Identifiable {
    let id = UUID()
    let title: String
    let summary: String
    let names: [String]
    let total: Int
    let restoreBackups: [BackupItem]
}

struct ConflictChoiceSheet: View {
    let choice: ConflictChoice
    let onResolve: (ConflictResolveMode) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingOverwrite = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(choice.title)
                .font(.headline)

            Text(choice.summary)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)

            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(choice.names, id: \.self) { name in
                        Text("・\(name)")
                            .font(.system(size: 12))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(8)
            }
            .frame(minHeight: 90, maxHeight: 180)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))

            if confirmingOverwrite {
                Text(T("确认覆盖？现有的同名插件会先移到废纸篓（可在废纸篓还原），原备份不会被动。"))
                    .font(.callout)
                    .foregroundStyle(.red)

                HStack {
                    Button(T("返回")) { confirmingOverwrite = false }
                    Spacer()
                    Button(T("确认覆盖"), role: .destructive) {
                        onResolve(.overwrite)
                        dismiss()
                    }
                }
            } else {
                HStack {
                    Button(T("取消")) { dismiss() }
                    Spacer()
                    if choice.total > choice.names.count {
                        Button(T("跳过冲突的")) {
                            onResolve(.skip)
                            dismiss()
                        }
                    }
                    Button(T("覆盖并继续"), role: .destructive) {
                        confirmingOverwrite = true
                    }
                }
            }
        }
        .padding(20)
        .frame(width: 540)
    }
}

// MARK: - Command Sheet (大段命令放进可滚动窗口)

struct CommandSheet: View {
    let title: String
    let summary: String
    let command: String
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)

            Text(summary)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)

            ScrollView {
                Text(command)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .frame(minHeight: 140, maxHeight: 320)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))

            HStack {
                Spacer()
                Button(copied ? T("已复制") : T("复制命令")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(command, forType: .string)
                    copied = true
                }
                Button(T("关闭")) { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 640)
    }
}

// MARK: - Rename Sheet

struct RenameSheet: View {
    let plugin: PluginItem
    let validate: (String) -> String?
    let onConfirm: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    private var errorMessage: String? {
        guard !text.isEmpty, text != plugin.name else { return nil }
        return validate(text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(T("重命名「%@」", plugin.name))
                .font(.headline)
            Text(T("会修改真实的文件夹名，Final Cut Pro 菜单里显示的名字也会跟着变。"))
                .font(.callout)
                .foregroundStyle(.secondary)

            TextField(T("新名字"), text: $text)
                .textFieldStyle(.roundedBorder)
                .onAppear { text = plugin.name }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            } else if text != plugin.name {
                Text(T("同目录下不能有同名插件，不会覆盖任何文件。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button(T("取消")) { dismiss() }
                Button(T("改名")) {
                    onConfirm(text)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(text.isEmpty || text == plugin.name || errorMessage != nil)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}

// MARK: - 导入译名表（先预览，再落盘）

struct ImportMapPreview: Identifiable {
    let id = UUID()
    let fileName: String
    let plan: RenamePlan
}

struct ImportMapSheet: View {
    let preview: ImportMapPreview
    let onApply: (RenamePlan) -> Void
    let onCancel: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var showCommands = false

    private var plan: RenamePlan { preview.plan }

    private var adminCommands: [String] {
        plan.items.compactMap { item in
            guard case .adminRequired(let command) = item.status else { return nil }
            return command
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(T("导入译名表"))
                    .font(.title3)
                    .fontWeight(.semibold)
                Text(preview.fileName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 16) {
                summaryChip(T("可改名"), plan.readyCount, .green)
                summaryChip(T("需管理员命令"), plan.adminCount, .orange)
                summaryChip(T("会失败"), plan.failedCount, .red)
                Spacer()
            }

            Divider()

            HStack(spacing: 8) {
                Text(T("原名")).frame(width: 250, alignment: .leading)
                Text(T("新名")).frame(width: 180, alignment: .leading)
                Text(T("结果")).frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(plan.items.enumerated()), id: \.offset) { _, item in
                        HStack(alignment: .top, spacing: 8) {
                            Text(item.entry.key)
                                .font(.system(size: 12))
                                .textSelection(.enabled)
                                .frame(width: 250, alignment: .leading)
                            Text(item.newName)
                                .font(.system(size: 12))
                                .textSelection(.enabled)
                                .frame(width: 180, alignment: .leading)
                            statusLabel(for: item)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.vertical, 5)
                        Divider()
                    }
                }
            }
            .frame(minHeight: 180, maxHeight: 300)

            if !adminCommands.isEmpty {
                DisclosureGroup(isExpanded: $showCommands) {
                    ScrollView {
                        Text(adminCommands.joined(separator: "\n"))
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                    }
                    .frame(height: 110)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
                } label: {
                    Text(T("装在所有用户目录的插件不能在这里直接改名，下面是可复制的命令："))
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            HStack {
                Spacer()
                Button(T("取消")) {
                    dismiss()
                    onCancel()
                }
                Button(T("应用改名")) {
                    onApply(plan)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(plan.readyCount == 0)
            }
        }
        .padding(20)
        .frame(width: 760)
    }

    private func summaryChip(_ title: String, _ count: Int, _ color: Color) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text("\(title) \(count)")
                .font(.system(size: 12, weight: .medium))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(color.opacity(0.10), in: Capsule())
    }

    @ViewBuilder
    private func statusLabel(for item: RenamePlanItem) -> some View {
        switch item.status {
        case .ready:
            Label(T("可以改名"), systemImage: "checkmark.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(.green)
        case .adminRequired:
            Label(T("需管理员命令"), systemImage: "lock.shield")
                .font(.system(size: 12))
                .foregroundStyle(.orange)
        case .failed(let reason):
            Label(reason, systemImage: "xmark.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - 改名台账（恢复原名）

struct RenameLedgerView: View {
    @ObservedObject var viewModel: PluginViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var category: PluginCategory = .all
    @State private var message: String?
    @State private var commandText: String?
    @State private var working = false

    private var entries: [RenameLedgerEntry] {
        viewModel.renameLedgerEntries(in: category)
    }

    private var allEntries: [RenameLedgerEntry] {
        viewModel.renameLedgerEntries(in: .all)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(T("恢复原名"))
                    .font(.title3)
                    .fontWeight(.semibold)
                Text(T("这里记录的是本应用改名之前的真实名字。恢复前如果目标位置已有同名插件，会拒绝并且不覆盖。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let problem = viewModel.renameLedgerProblem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Picker(T("分类"), selection: $category) {
                ForEach(PluginCategory.allCases) { item in
                    Text(item.displayName).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if entries.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 28))
                        .foregroundStyle(.secondary)
                    Text(T("没有可恢复原名的改名记录。"))
                        .font(.callout)
                    Text(T("如果插件是在本应用之外改的名，原名已无从得知，本应用不会猜一个名字。"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(entries) { entry in
                            ledgerRow(entry)
                            Divider()
                        }
                    }
                }
                .frame(minHeight: 180, maxHeight: 320)
            }

            if let message {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let commandText {
                VStack(alignment: .leading, spacing: 4) {
                    Text(T("复制下面的命令到「终端」执行，执行完回到本应用点「复核」："))
                        .font(.caption)
                        .foregroundStyle(.orange)
                    ScrollView {
                        Text(commandText)
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                    }
                    .frame(height: 90)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
                }
            }

            HStack {
                Button {
                    viewModel.refreshRenameLedgerStatuses()
                    viewModel.scan()
                    message = T("已按磁盘实际情况刷新台账状态。")
                } label: {
                    Label(T("复核"), systemImage: "checkmark.seal")
                }
                .disabled(working)

                Button {
                    restoreAll(entries)
                } label: {
                    Label(T("恢复本类原名 (%lld)", entries.count), systemImage: "arrow.uturn.backward")
                }
                .disabled(working || entries.isEmpty)

                if category != .all {
                    Button {
                        restoreAll(allEntries)
                    } label: {
                        Label(T("一键全部恢复原名 (%lld)", allEntries.count), systemImage: "arrow.uturn.backward.circle")
                    }
                    .disabled(working || allEntries.isEmpty)
                }

                Spacer()

                if working {
                    ProgressView()
                        .controlSize(.small)
                }

                Button(T("关闭")) { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 760, height: 560)
    }

    @ViewBuilder
    private func ledgerRow(_ entry: RenameLedgerEntry) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(entry.oldName)  →  \(entry.newName)")
                    .font(.system(size: 12, weight: .medium))
                Text(entry.directory)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(entry.statusDescription)
                .font(.system(size: 11))
                .foregroundStyle(statusColor(entry.status))
                .frame(width: 190, alignment: .leading)

            Button(T("恢复原名")) {
                restore(entry)
            }
            .controlSize(.small)
            .disabled(working || entry.status == .restorePending)
        }
        .padding(.vertical, 7)
    }

    private func statusColor(_ status: RenameLedgerStatus) -> Color {
        switch status {
        case .applied: return .green
        case .renamePending, .restorePending: return .orange
        case .restored: return .secondary
        }
    }

    private func restore(_ entry: RenameLedgerEntry) {
        Task { @MainActor in
            working = true
            message = nil
            commandText = nil
            let outcome = await viewModel.restoreOriginalName(entry)
            working = false
            switch outcome {
            case .success(let oldName):
                viewModel.addOperation(
                    kind: .renamePlugin,
                    summary: T("恢复原名「%@」", oldName),
                    renames: [RenameSnapshot(oldPath: entry.newPath, newPath: entry.oldPath)]
                )
                message = T("已改回原名「%@」。重启 Final Cut Pro 后生效。", oldName)
                viewModel.scan()
            case .needAuthentication(let command):
                commandText = command
                message = T("装在所有用户目录的插件恢复原名需要管理员密码，本应用不会自己提权。")
            case .targetExists(let reason):
                message = reason
            case .failure(let reason):
                message = reason
            }
        }
    }

    private func restoreAll(_ entries: [RenameLedgerEntry]) {
        guard !entries.isEmpty else { return }
        Task { @MainActor in
            working = true
            message = nil
            commandText = nil
            let outcome = await viewModel.restoreOriginalNames(entries)
            working = false

            if !outcome.restored.isEmpty {
                viewModel.addOperation(
                    kind: .renamePlugin,
                    summary: T("恢复 %lld 个插件的原名", outcome.restored.count)
                )
            }
            if !outcome.commands.isEmpty {
                commandText = outcome.commands.joined(separator: "\n")
            }

            var parts: [String] = []
            if !outcome.restored.isEmpty { parts.append(T("已恢复 %lld 个原名。", outcome.restored.count)) }
            if !outcome.commands.isEmpty { parts.append(T("%lld 个所有用户安装的插件需要管理员命令，见下方。", outcome.commands.count)) }
            if !outcome.failures.isEmpty { parts.append(T("%lld 个没有恢复，原因见下方。", outcome.failures.count)) }
            var text = parts.joined(separator: " ")
            if !outcome.failures.isEmpty {
                text += "\n" + outcome.failures.joined(separator: "\n")
            }
            message = text
            viewModel.scan()
        }
    }
}


// MARK: - 来源筛选

/// 插件列表的来源 / 安装范围筛选。
/// 来源看「谁做的」，安装范围看「装给谁用」，两件事分开。
enum PluginFilter: String, CaseIterable, Identifiable {
    case all
    case apple
    case thirdParty
    case unknown
    case allUsers
    case currentUser

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return T("全部")
        case .apple: return T("Apple 自带")
        case .thirdParty: return T("第三方")
        case .unknown: return T("来源未知")
        case .allUsers: return T("所有用户安装")
        case .currentUser: return T("仅当前用户安装")
        }
    }

    func matches(_ plugin: PluginItem) -> Bool {
        switch self {
        case .all: return true
        case .apple: return plugin.origin == .apple
        case .thirdParty: return plugin.origin == .thirdParty
        case .unknown: return plugin.origin == .unknown
        case .allUsers: return plugin.isSystemLevel
        case .currentUser: return !plugin.isSystemLevel
        }
    }
}
