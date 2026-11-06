import Foundation
import Combine

// MARK: - 语言

/// 目前只支持中文和英文。rawValue 会写进 UserDefaults，不要随意改。
enum AppLanguage: String, CaseIterable, Identifiable {
    case chinese = "zh-Hans"
    case english = "en"

    var id: String { rawValue }

    /// 语言名称用各自的语言显示，切错了也能认出来
    var displayName: String {
        switch self {
        case .chinese: return "中文"
        case .english: return "English"
        }
    }
}

// MARK: - 本地化

/// 以中文原文为 key 的本地化表。
///
/// 这样写的原因：现有界面里中文文案已经散在各处，改成 key 反而容易漏。
/// 统一用 `T("中文原文")` 取当前语言文案，切语言时整棵视图重建即可。
final class Localization: ObservableObject {
    static let shared = Localization()

    /// 存进 UserDefaults 的键。切换语言不影响任何插件数据、备份和禁用状态。
    static let storageKey = "FCPPluginManager.language"

    @Published private(set) var language: AppLanguage

    private init() {
        let saved = UserDefaults.standard.string(forKey: Self.storageKey)
        language = AppLanguage(rawValue: saved ?? "") ?? .chinese
    }

    func setLanguage(_ newLanguage: AppLanguage) {
        guard newLanguage != language else { return }
        language = newLanguage
        UserDefaults.standard.set(newLanguage.rawValue, forKey: Self.storageKey)
    }

    func localized(_ key: String) -> String {
        guard language == .english else { return key }
        return Self.normalizedEnglish[Self.normalizePlaceholders(key)] ?? key
    }

    /// 把 %lld / %d / %@ 统一成 {}，这样代码里用哪种占位符都能查到同一条英文。
    private static func normalizePlaceholders(_ text: String) -> String {
        text
            .replacingOccurrences(of: "%lld", with: "{}")
            .replacingOccurrences(of: "%d", with: "{}")
            .replacingOccurrences(of: "%@", with: "{}")
    }

    private static let normalizedEnglish: [String: String] = {
        var map: [String: String] = [:]
        for (key, value) in english {
            map[normalizePlaceholders(key)] = value
        }
        return map
    }()

    // MARK: 英文对照表

    private static let english: [String: String] = [
        // 通用
        "取消": "Cancel",
        "关闭": "Close",
        "全选": "Select All",
        "清空": "Clear",
        "删除": "Delete",
        "撤销": "Undo",
        "刷新": "Refresh",
        "扫描中...": "Scanning...",
        "复制命令": "Copy Command",
        "已复制": "Copied",
        "重命名…": "Rename…",
        "改名": "Rename",
        "操作": "Actions",
        "分类": "Categories",
        "名称": "Name",
        "位置": "Location",
        "版本": "Version",
        "体积": "Size",
        "安装时间": "Installed",
        "厂商/版权": "Vendor / Copyright",
        "包标识": "Bundle ID",
        "完整路径": "Full Path",
        "系统级": "System",
        "可恢复": "Restorable",

        // 分类与位置
        "全部": "All",
        "效果": "Effects",
        "发生器": "Generators",
        "转场": "Transitions",
        "标题": "Titles",
        "已备份": "Backups",
        "已禁用": "Disabled",
        "备份与暂停": "Backups & Paused",
        "系统/效果": "System / Effects",
        "系统/发生器": "System / Generators",
        "系统/标题": "System / Titles",
        "系统/转场": "System / Transitions",
        "用户/效果": "User / Effects",
        "用户/发生器": "User / Generators",
        "用户/标题": "User / Titles",
        "用户/转场": "User / Transitions",
        "系统/插件": "System / Plug-ins",
        "用户/插件": "User / Plug-ins",

        // 主界面
        "FCP 插件管理": "FCP Plugin Manager",
        "管理你的 Final Cut Pro 插件，轻松卸载与恢复": "Manage your Final Cut Pro plug-ins — disable, restore and recover with one click",
        "搜索插件...": "Search plug-ins…",
        "插件名称": "Plugin Name",
        "没有插件": "No plug-ins",
        "无搜索结果": "No results",
        "试试其他关键词": "Try a different keyword",
        "点击右下角「刷新」按钮扫描插件": "Click Refresh at the bottom right to scan for plug-ins",
        "这些插件目录在这台机器上都不存在": "None of these plug-in folders exist on this Mac",
        "已备份的插件": "Backed-up Plug-ins",
        "已禁用（暂停使用）的插件": "Disabled (Paused) Plug-ins",
        "没有备份": "No backups",
        "没有被禁用的插件": "No disabled plug-ins",
        "删除插件后会自动备份到这里": "Plug-ins you delete are backed up here automatically",
        "在插件列表点「全部禁用」或右键单个插件即可暂停使用": "Use “Disable All” or right-click a plug-in to pause it",
        "还没有操作记录。": "No operations yet.",
        "操作日志": "Operation Log",
        "插件详情": "Plugin Details",
        "预览图：暂时不做。读取插件预览需要额外解码包内容，会明显拖慢扫描，收益不大。":
            "Preview images are not supported. Decoding previews from plug-in bundles would noticeably slow down scanning for little benefit.",
        "查看插件详情": "View plugin details",
        "查看详情": "View Details",
        "显示在访达中": "Show in Finder",
        "显示备份在访达中": "Show Backup in Finder",
        "备份并删除…": "Back up & Delete…",
        "备份并删除": "Back up & Delete",
        "禁用（暂停使用）": "Disable (Pause)",
        "重新执行停用": "Retry Disable",
        "启用这个插件": "Enable This Plugin",
        "删除禁用记录": "Delete Disabled Record",
        "删除禁用记录（不会动原始插件）": "Delete disabled record (does not touch the original plug-in)",
        "恢复到原始位置": "Restore to Original Location",
        "删除备份": "Delete Backup",
        "一键全部禁用": "Disable All",
        "一键全部恢复": "Restore All",
        "把停用的插件全部开回来（全部类别，或只恢复某一类）":
            "Re-enable all paused plug-ins (all categories, or just one)",
        "全部类别（%lld）": "All categories (%lld)",
        "%@（%lld）": "%@ (%lld)",
        "已停用（已生效）": "Disabled (Effective)",
        "待执行管理员命令（未生效）": "Waiting for Admin Command (Not Effective)",
        "未生效（原插件仍在用）": "Not Effective (Original Still in Use)",
        "系统级（需要管理员密码）· 版本 %@": "System-level (admin password required) · v%@",
        "系统级（需要管理员密码）": "System-level (admin password required)",
        "版本 %@": "v%@",
        "已备份 %lld 个": "Backups: %lld",
        "已真正停用 %lld 个": "Disabled (effective): %lld",
        "未生效 %lld 个（原文件还在）": "%lld not effective (original still present)",
        "已选 %lld 个": "%lld selected",
        "共 %lld 个备份，已选 %lld 个": "%lld backups, %lld selected",
        "共 %lld 个插件，已选 %lld 个": "%lld plug-ins, %lld selected",
        "已真正停用 %lld 个，未生效 %lld 个，已选 %lld 个":
            "Effective: %lld · Not effective: %lld · Selected: %lld",
        "恢复全部备份 (%lld)": "Restore All Backups (%lld)",
        "恢复选中的 (%lld)": "Restore Selected (%lld)",
        "删除选中的": "Delete Selected",
        "清空所有备份": "Delete All Backups",
        "复核": "Recheck",
        "立即停用未生效的 (%lld)": "Disable Pending Now (%lld)",
        "立即停用未生效的": "Disable Pending Now",
        "立即停用未生效的插件": "Disable the pending plug-ins",
        "原位置未知，无法停用": "Original location unknown — cannot disable",
        "启用选中的 (%lld)": "Enable Selected (%lld)",
        "备份并删除 (%lld)": "Back up & Delete (%lld)",
        "撤销上一步": "Undo Last Step",
        "%lld（停用 %lld）": "%lld (%lld paused)",
        "%lld（未生效 %lld）": "%lld (%lld pending)",

        // 顶部横幅
        "还有 %lld 个插件没有真正停用": "%lld plug-ins are not actually disabled",
        "还有 1 个插件没有真正停用": "1 plug-in is not actually disabled",
        "它们是系统级插件，原文件仍在系统目录，Final Cut Pro 会照常加载。授权后才会真正移走。":
            "They are system-level plug-ins. The originals are still in the system folder, so Final Cut Pro keeps loading them. They only move after you authorize.",
        "• 系统级 %@ 个：原文件还在系统目录，Final Cut Pro 会照常加载；输入管理员密码后才会真正移走。":
            "• System-level: %@. The originals are still in the system folder, so Final Cut Pro keeps loading them. They move only after you enter the admin password.",
        "• 用户级 %@ 个：插件仍在原目录（旧版本留下的多余副本），不需要管理员密码，去「已禁用」页处理即可。":
            "• User-level: %@. The plug-ins are still in their original folder (redundant copies from an older version). No admin password needed — handle them on the “Disabled” page.",
        "去清理": "Clean Up",
        "• 另有 %@ 个老记录缺少原始位置信息，无法判断是否已停用，请在「已禁用」页单独处理。":
            "• %@ older records have no original path, so their status is unknown. Handle them individually on the “Disabled” page.",
        "• 另有 1 个老记录缺少原始位置信息，无法判断是否已停用，请在「已禁用」页单独处理。":
            "• 1 older record has no original path, so its status is unknown. Handle it individually on the “Disabled” page.",
        "记录信息缺失（原位置未知）": "Record Info Missing (original unknown)",
        "等待授权...": "Waiting for authorization…",
        "立即停用（需管理员密码）": "Disable Now (admin password)",
        "需要管理员权限": "Administrator Permission Required",
        "自动授权被系统拦截时，可以复制下面的命令，打开「终端」粘贴执行。执行完回到本应用点「复核」。":
            "If automatic authorization is blocked, copy the command below, paste it into Terminal, then come back and click Recheck.",

        // 确认弹窗
        "确认删除": "Confirm Delete",
        "确定要把选中的 %lld 个插件移到废纸篓吗？\n\n会先自动备份，之后可以在「已备份」里还原。删除不会碰你在 FCP 里的工程文件。%@":
            "Move the %lld selected plug-in(s) to the Trash?\n\nThey are backed up first and can be restored from Backups. Your FCP projects are not touched.%@",
        "确认全部禁用": "Confirm Disable All",
        "确认全部启用": "Confirm Enable All",
        "确认恢复全部备份": "Confirm Restore All Backups",
        "恢复全部": "Restore All",
        "将把全部 %lld 个备份恢复到原始位置。\n\n如果原位置已经有同名插件，会先跳过并让你选择是否覆盖，不会直接覆盖。%@":
            "All %lld backup(s) will be restored to their original locations.\n\nIf a plug-in with the same name already exists there, it is skipped first and you will be asked whether to overwrite. Nothing is overwritten silently.%@",
        "确认删除备份": "Confirm Delete Backups",
        "将删除 %lld 个备份，移入废纸篓后仍可从废纸篓找回。\n\n删除备份不会影响已经安装的插件。":
            "%lld backup(s) will be moved to the Trash and can still be recovered from it.\n\nDeleting backups does not affect installed plug-ins.",
        "确认删除禁用记录": "Confirm Delete Disabled Record",
        "删除记录": "Delete Records",
        "只会删掉「已禁用」页里的记录和本地副本。\n\n原位置还有插件的记录，删掉后插件照常使用；已经真正停用的记录，删掉副本后就无法在本应用里一键启用了，请优先用「启用」而不是删除。":
            "Only records and local copies on the Disabled page are deleted.\n\nIf the original plug-in is still in place, it keeps working. If it was truly disabled, deleting the copy means this app can no longer re-enable it in one click — prefer Enable over Delete.",
        "全部禁用": "Disable All",
        "全部启用": "Enable All",
        "禁用%@": "Disable %@",
        "启用%@": "Enable %@",
        "「%@」范围里没有可禁用的插件。": "No plug-ins can be disabled in “%@”.",
        "「%@」范围里没有被禁用的插件。": "No disabled plug-ins in “%@”.",
        "将暂停使用全部 %lld 个插件：\n%@\n": "Pause all %lld plug-in(s):\n%@\n",
        "• %@ %lld 个（系统级 %lld 个）": "• %@: %lld (system-level: %lld)",
        "将暂停使用「%@」分类的 %lld 个插件：\n• 用户级 %lld 个，直接移入「已禁用」\n• 系统级 %lld 个，复制一份后还需要管理员命令删除原位置\n":
            "Pause %lld plug-in(s) in “%@”:\n• User-level: %lld, moved to Disabled immediately\n• System-level: %lld, require an admin command to remove the originals\n",
        "插件文件不会真正删除，备份不受影响，之后可以按同样的分类一键启用。":
            "Plugin files are not deleted, backups are untouched, and you can re-enable them the same way later.",
        "检测到 Final Cut Pro 正在运行，建议先退出。": "Final Cut Pro is running. Quit it first.",
        "将恢复启用全部 %lld 个已禁用插件：\n%@\n": "Re-enable all %lld disabled plug-in(s):\n%@\n",
        "将恢复启用「%@」分类的 %lld 个插件：\n• 用户级 %lld 个，直接放回原目录\n• 系统级 %lld 个，需要用管理员命令放回\n":
            "Re-enable %lld plug-in(s) in “%@”:\n• User-level: %lld, moved back directly\n• System-level: %lld, require an admin command\n",
        "启用前不会删除任何插件。": "Nothing is deleted when enabling.",
        "将撤销「%@」这次操作。\n\n能恢复的先恢复，遇到同名插件会跳过并且不覆盖。":
            "Undo “%@”.\n\nWhatever can be restored is restored; same-name conflicts are skipped, never overwritten.",
        "\n\n检测到 Final Cut Pro 正在运行，建议先退出，否则改动可能不生效。":
            "\n\nFinal Cut Pro is running. Quit it first, otherwise changes may not take effect.",

        // 扫描摘要
        "%@：%lld 个": "%@: %lld",
        "另有 %lld 个常见位置没有对应文件夹": "%lld other common locations have no matching folder",
        "已扫描 %lld 个位置\n%@": "Scanned %lld location(s)\n%@",

        // 结果窗口
        "已跳过": "Skipped",
        "所有备份都因为原位置已有同名插件被跳过，没有改动任何文件。":
            "All backups were skipped because a same-name plug-in already exists; no files were changed.",
        "所有插件都因为原位置已有同名插件被跳过，没有改动任何文件。":
            "All plug-ins were skipped because a same-name plug-in already exists; no files were changed.",
        "备份失败，已跳过删除：%@": "Backup failed, delete skipped: %@",
        "已备份，但移入废纸篓失败：%@": "Backed up, but moving to Trash failed: %@",
        "以下 %lld 个系统级插件已经备份好，但删除原位置需要管理员密码。\n\n复制命令到「终端」执行，或按顶部提示处理。执行完点「刷新」复核。":
            "%lld system-level plug-in(s) are backed up, but removing the originals needs an admin password.\n\nCopy the commands into Terminal, or follow the banner at the top. Then click Refresh to recheck.",
        "已备份并删除 %lld 个插件。重启 Final Cut Pro 后生效。":
            "Backed up and deleted %lld plug-in(s). Restart Final Cut Pro to apply.",
        "没有删除任何文件。": "No files were deleted.",
        "删除完成": "Delete Complete",
        "没有删除": "Nothing Deleted",
        "已停用": "Disabled",
        "「%@」已移出插件目录，Final Cut Pro 不会再加载。":
            "“%@” was moved out of the plug-in folder. Final Cut Pro will no longer load it.",
        "停用「%@」": "Disable “%@”",
        "停用「%@」（待授权）": "Disable “%@” (pending authorization)",
        "停用失败": "Disable Failed",
        "「%@」没有改动：%@": "“%@” was not changed: %@",
        "一键停用（%@）：立即生效 %lld 个，待授权 %lld 个":
            "Disable All (%@): %lld effective, %lld awaiting authorization",
        "自动授权没有完成：%@\n\n可以复制下面的命令手动执行，执行完回到本应用点「复核」。":
            "Automatic authorization did not complete: %@\n\nCopy the commands below, run them manually, then come back and click Recheck.",
        "「%@」范围里已真正停用 %lld 个插件。": "%lld plug-in(s) in “%@” are now truly disabled.",
        "还有 %lld 个还没生效，见顶部红色提示。": "%lld are still pending — see the red banner at the top.",
        "\n重启 Final Cut Pro 后生效。": "\nRestart Final Cut Pro to apply.",
        "停用完成": "Disable Complete",
        "没有停用任何插件。": "No plug-ins were disabled.",
        "真正停用 %lld 个系统级插件": "Truly disabled %lld system-level plug-in(s)",
        "已把 %lld 个系统级插件移出系统目录。": "Moved %lld system-level plug-in(s) out of the system folder.",
        "没有停用成功：%@\n\n可以复制下面的命令，打开「终端」粘贴执行。执行完回到本应用点「复核」。":
            "Nothing was disabled: %@\n\nCopy the commands below, paste them into Terminal, then come back and click Recheck.",
        "没有可恢复的插件": "Nothing to Restore",
        "没有选中任何插件。": "No plug-ins selected.",
        "没有选中任何备份。": "No backups selected.",
        "没有可以恢复的插件。": "No plug-ins available to restore.",
        "%lld 个插件原位已有同名插件": "%lld plug-in(s) already exist at the original location",
        "%lld 个备份的原位置已有同名插件": "%lld backup(s) have a same-name plug-in at the original location",
        "按默认「不覆盖」，这 %lld 个会跳过；其余 %lld 个可以正常恢复。":
            "By default nothing is overwritten: these %lld are skipped, the other %lld can be restored normally.",
        "按默认「不覆盖」，这 %lld 个会全部跳过；其余 %lld 个可以正常%@。":
            "By default nothing is overwritten: these %lld are skipped, the other %lld can be %@ normally.",
        "%@：原始位置已存在": "%@: original location already exists",
        "%@：目标位置已存在": "%@: target location already exists",
        "恢复 %lld 个插件": "Restored %lld plug-in(s)",
        "已恢复启用 %lld 个插件。": "Re-enabled %lld plug-in(s).",
        "还有 %lld 个需要管理员授权。": "%lld still need administrator authorization.",
        "恢复完成": "Restore Complete",
        "没有恢复": "Nothing Restored",
        "删除失败": "Delete Failed",
        "删除这条禁用记录需要管理员权限。": "Deleting this disabled record requires administrator permission.",
        "删除禁用记录失败：%@": "Failed to delete disabled record: %@",
        "%@：需要管理员权限": "%@: administrator permission required",
        "已删除记录": "Records Deleted",
        "已删除 %lld 条禁用记录。": "Deleted %lld disabled record(s).",
        "已恢复 %lld 个插件。重启 Final Cut Pro 后生效。": "Restored %lld plug-in(s). Restart Final Cut Pro to apply.",
        "没有需要恢复的内容。": "Nothing needs restoring.",
        "撤销没有改动任何文件。": "Undo did not change any files.",
        "撤销完成": "Undo Complete",
        "恢复 %lld 个备份": "Restored %lld backup(s)",
        "已将「%@」恢复到原始位置。": "Restored “%@” to its original location.",
        "已成功恢复 %lld 个插件。": "Successfully restored %lld plug-in(s).",
        "没有恢复任何插件。": "No plug-ins were restored.",
        "以下 %lld 个系统级插件需要管理员密码，未恢复。复制命令到「终端」执行，执行完回到本应用点「刷新」。":
            "%lld system-level plug-in(s) need an admin password and were not restored. Copy the commands into Terminal, then come back and click Refresh.",
        "已删除": "Deleted",
        "备份「%@」已移入废纸篓。": "Backup “%@” was moved to the Trash.",
        "删除备份需要管理员权限。": "Deleting the backup requires administrator permission.",
        "删除备份失败：%@": "Failed to delete backup: %@",
        "已删除备份": "Backups Deleted",
        "已删除 %lld 个备份，可在废纸篓找回。": "Deleted %lld backup(s); they can be recovered from the Trash.",
        "删除 %lld 个备份": "Deleted %lld backup(s)",
        "全部备份已清空。": "All backups deleted.",
        "清空失败：%@": "Failed to clear: %@",
        "清空备份": "Clear Backups",
        "备份并删除 %lld 个插件": "Backed up and deleted %lld plug-in(s)",
        "删除 %lld 个插件": "Deleted %lld plug-in(s)",

        // 改名
        "重命名「%@」": "Rename “%@”",
        "会修改真实的文件夹名，Final Cut Pro 菜单里显示的名字也会跟着变。":
            "This renames the real folder, so the name shown in the Final Cut Pro menu changes too.",
        "新名字": "New name",
        "同目录下不能有同名插件，不会覆盖任何文件。":
            "A same-name plug-in in the same folder is not allowed; nothing is overwritten.",
        "名字不能为空。": "The name cannot be empty.",
        "名字里不能有「/」。": "The name cannot contain “/”.",
        "名字里不能有「:」。": "The name cannot contain “:”.",
        "这个名字不合法。": "That name is not valid.",
        "名字太长，最多 255 个字符。": "The name is too long (255 characters max).",
        "和原来的名字一样，不需要改。": "It is the same as the current name.",
        "同目录下已经有叫「%@」的插件，不能覆盖。": "A plug-in named “%@” already exists in this folder; it will not be overwritten.",
        "改名失败：%@": "Rename failed: %@",
        "系统级插件在 /Library 下，需要管理员权限才能改文件夹名":
            "System-level plug-ins live under /Library and need administrator permission to rename.",
        "已改名": "Renamed",
        "已改名为「%@」。": "Renamed to “%@”.",
        "已同步更新 %lld 条备份记录的原始路径，旧备份仍能正常恢复。":
            "Updated the original path of %lld backup record(s); old backups can still be restored.",
        "没有受影响的旧备份。": "No affected backups.",
        "重启 Final Cut Pro 后，菜单里显示的也是新名字。": "After restarting Final Cut Pro, the menu shows the new name.",
        "「%@」是系统级插件，不能在这里直接改名。\n\n原因：%@\n\n复制命令到「终端」执行。执行完回到本应用点「刷新」，列表里应该显示「%@」。\n\n注意：系统级改名无法自动记入日志，也不能用「撤销上一步」改回去，需要手动执行反向命令。":
            "“%@” is a system-level plug-in and cannot be renamed here.\n\nReason: %@\n\nCopy the command into Terminal. Then come back and click Refresh; the list should show “%@”.\n\nNote: system-level renames cannot be logged automatically or undone with Undo Last Step; run the reverse command manually.",
        "重命名「%@」→「%@」": "Renamed “%@” → “%@”",

        // 操作类型
        "恢复备份": "Restore Backups",
        "禁用插件": "Disable Plug-ins",
        "启用插件": "Enable Plug-ins",
        "重命名插件": "Rename Plug-in",

        // 冲突选择
        "确认覆盖？现有的同名插件会先移到废纸篓（可在废纸篓还原），原备份不会被动。":
            "Overwrite? Existing same-name plug-ins are moved to the Trash first (recoverable), and the backup itself is untouched.",
        "返回": "Back",
        "确认覆盖": "Confirm Overwrite",
        "跳过冲突的": "Skip Conflicting",
        "覆盖并继续": "Overwrite and Continue",

        // 详情与日志
        "・%@": "・%@",
        "%@ · %@%@": "%@ · %@%@",
        " · 已撤销": " · Undone",

        // 译名表
        "导入译名表…": "Import Name Map…",
        "导入译名表": "Import Name Map",
        "选择 CSV 或 JSON 文件，第一列是插件原名或完整路径，第二列是新名字。":
            "Choose a CSV or JSON file. First column: original plug-in name or full path. Second column: new name.",
        "选择文件…": "Choose File…",
        "预览": "Preview",
        "原名": "Original",
        "新名": "New Name",
        "结果": "Result",
        "可以改名": "Ready",
        "会失败": "Will Fail",
        "需管理员命令": "Admin Command Required",
        "应用改名": "Apply Renames",
        "没有可导入的条目。": "No importable entries.",
        "文件读不了：%@": "Cannot read file: %@",
        "第 %lld 行：%@": "Line %lld: %@",
        "格式不对：%@": "Invalid format: %@",
        "找到 %lld 条，%lld 条可改名，%lld 条会失败，%lld 条需要管理员命令。":
            "Found %lld entries: %lld ready, %lld will fail, %lld need an admin command.",
        "系统级插件不能在这里直接改名，下面是可复制的命令：":
            "System-level plug-ins cannot be renamed here. Copy the commands below:",
        "已应用 %lld 条改名。": "Applied %lld rename(s).",
        "改名结果": "Rename Results",
        "打开": "Open",
        "文件是空的。": "The file is empty.",
        "文件编码不支持，请另存为 UTF-8 后再导入。": "Unsupported file encoding. Save it as UTF-8 and try again.",
        "JSON 格式不对：%@": "Invalid JSON: %@",
        "JSON 格式不对。支持 {\"原路径或原名\": \"新名字\"} 或 [{\"path\":\"…\",\"name\":\"…\"}]。":
            "Invalid JSON. Use {\"original path or name\": \"new name\"} or [{\"path\":\"…\",\"name\":\"…\"}].",
        "第 %lld 条：缺少原名或路径。": "Entry %lld: missing original name or path.",
        "第 %lld 条：新名字为空。": "Entry %lld: new name is empty.",
        "第 %lld 行：只有一列，需要「原名,新名字」两列。":
            "Line %lld: only one column. Two columns are required: original,new name.",
        "第 %lld 行：超过两列。新名字里如果有逗号，请用英文双引号包起来。":
            "Line %lld: more than two columns. If the new name contains a comma, wrap it in double quotes.",
        "第 %lld 行：原名为空。": "Line %lld: original name is empty.",
        "第 %lld 行：新名字为空。": "Line %lld: new name is empty.",
        "找不到这个插件。": "No matching plug-in found.",
        "在「%@」分类里找不到这个插件。": "No matching plug-in found in “%@”.",
        "匹配到 %lld 个同名插件，请改用完整路径。":
            "Matches %lld plug-ins with the same name. Use the full path instead.",
        "同一个插件在译名表里出现了多次。": "This plug-in appears more than once in the name map.",
        "和译名表里另一条会改成同一个名字，不能同时执行。":
            "Another entry would give it the same name; they cannot both run.",

        // 改名台账
        "已生效": "Active",
        "待执行（系统级改名命令）": "Pending (system rename command)",
        "已恢复原名": "Original name restored",
        "待执行（系统级恢复命令）": "Pending (system restore command)",
        "改名台账读取失败（%@）。本应用无法得知任何插件的原名，请不要手动改回，先备份台账文件再排查。":
            "Could not read the rename ledger (%@). The app cannot know any original name. Do not rename manually — back up the ledger file and investigate first.",
        "改名台账写入失败：%@": "Could not write the rename ledger: %@",
        "改名台账缺少原名信息，原名已无从得知，不能自动恢复。":
            "The ledger has no original name for this entry, so the original name is unknown and cannot be restored automatically.",
        "「%@」已经存在，按规矩不覆盖，原名没有恢复。":
            "“%@” already exists. By policy it is not overwritten, so the original name was not restored.",
        "找不到改名后的插件：%@": "Cannot find the renamed plug-in: %@",
        "恢复原名失败：%@": "Restore original name failed: %@",
        "恢复原名": "Restore Original Name",
        "恢复原名…": "Restore Original Name…",
        "恢复本类原名 (%lld)": "Restore This Category (%lld)",
        "一键全部恢复原名 (%lld)": "Restore All Original Names (%lld)",
        "这里记录的是本应用改名之前的真实名字。恢复前如果目标位置已有同名插件，会拒绝并且不覆盖。":
            "This records the real name before this app renamed it. If a same-name plug-in already exists at the target, the restore is refused and nothing is overwritten.",
        "没有可恢复原名的改名记录。": "No rename records to restore.",
        "如果插件是在本应用之外改的名，原名已无从得知，本应用不会猜一个名字。":
            "If a plug-in was renamed outside this app, its original name is unknown — this app will not guess one.",
        "复制下面的命令到「终端」执行，执行完回到本应用点「复核」：":
            "Copy the command below into Terminal, then come back and click Recheck:",
        "已按磁盘实际情况刷新台账状态。": "Ledger status refreshed from what is actually on disk.",
        "已改回原名「%@」。重启 Final Cut Pro 后生效。":
            "Restored the original name “%@”. Restart Final Cut Pro to apply.",
        "系统级插件恢复原名需要管理员密码，本应用不会自己提权。":
            "Restoring a system-level original name needs an admin password; this app never elevates itself.",
        "恢复 %lld 个插件的原名": "Restored the original name of %lld plug-in(s)",
        "已恢复 %lld 个原名。": "Restored %lld original name(s).",
        "%lld 个系统级插件需要管理员命令，见下方。": "%lld system-level plug-in(s) need an admin command — see below.",
        "%lld 个没有恢复，原因见下方。": "%lld were not restored — see below.",
        "恢复原名「%@」": "Restore original name “%@”",
        "更多操作": "More",
        "语言": "Language",
        "导入失败": "Import Failed",
        "重命名 %lld 个插件": "Renamed %lld plug-in(s)",
        "导入": "Import",
        "可改名": "Ready",

        // 数据层里的用户可见提示
        "无法启动授权对话框：%@": "Could not open the authorization dialog: %@",
        "已取消管理员授权，插件仍在原位置，没有改动。":
            "Administrator authorization was cancelled. Plug-ins are still in place and nothing changed.",
        "管理员命令执行失败": "The administrator command failed",
        "插件路径不存在：%@": "Plug-in path does not exist: %@",
        "写入备份信息失败：%@": "Could not write backup metadata: %@",
        "备份文件不存在：%@": "Backup file does not exist: %@",
        "备份缺少原始位置信息，无法恢复": "The backup has no original location, so it cannot be restored",
        "当前位置的插件需要管理员密码才能移入废纸篓":
            "The plug-in at this location needs an administrator password to move to the Trash",
        "无法移走已存在的插件：%@": "Could not move the existing plug-in away: %@",
        "已恢复，但旧备份未能删除：%@": "Restored, but the old backup could not be deleted: %@",
        "未知错误": "Unknown error",
        "写入禁用信息失败：%@": "Could not write disabled metadata: %@",
        "系统级插件需要管理员授权，才能把原文件移出系统目录":
            "System-level plug-ins need administrator authorization before the originals can be moved out of the system folder",
        "禁用目录和原位置都找不到这个插件：%@":
            "The plug-in was found neither in the disabled folder nor at its original location: %@",
        "清掉重复的禁用记录需要管理员权限":
            "Removing the duplicate disabled record requires administrator permission",
        "清掉重复记录失败：%@": "Could not remove the duplicate record: %@",
        "原插件本来就在原位，已把多余的副本移到废纸篓（可还原）":
            "The plug-in was already in place, so the redundant copy was moved to the Trash (restorable)",
        "清掉多余的禁用记录需要管理员权限":
            "Removing the redundant disabled record requires administrator permission",
        "清掉多余记录失败：%@": "Could not remove the redundant record: %@",
        "其中 %@ 个是「没真正停用」的记录：原插件一直在用，启用时会把多余的副本移到废纸篓（可还原），原插件不动。":
            "%@ of them never actually stopped: the original plug-in is still in use. Enabling will move the redundant copies to the Trash (restorable) and leave the originals untouched.",
        "启用不会删除正在使用的插件。": "Enabling never deletes a plug-in that is in use.",
        "禁用记录缺少原始位置信息，无法启用":
            "The disabled record has no original location, so it cannot be enabled",
        "系统级插件需要管理员授权才能放回系统目录":
            "System-level plug-ins need administrator authorization to be put back into the system folder",
        "已启用，但禁用记录里残留文件未能删除：%@":
            "Enabled, but leftover files in the disabled record could not be deleted: %@",
        "%@：原始位置已有同名插件，未覆盖": "%@: a same-name plug-in already exists at the original location (not overwritten)",
        "%@：原名位置已经有同名插件，未覆盖": "%@: a same-name plug-in already exists at the original-name location (not overwritten)",
        "没有待执行的插件。": "No pending plug-ins.",
        "没有需要管理员权限恢复的插件。": "No plug-ins require administrator permission to restore.",
        "撤销改名失败：%@": "Undo rename failed: %@",

        // 批量进度
        "正在停用 %lld 个插件": "Disabling %lld plug-in(s)",
        "正在启用 %lld 个插件": "Enabling %lld plug-in(s)",
        "正在恢复 %lld 个备份": "Restoring %lld backup(s)",
        "停止": "Stop",
        "正在停止…": "Stopping…",
        "已完成 %@ / %@": "%@ of %@ done",

        // 表格与侧边栏
        "来源": "Source",
        "状态": "Status",
        "用户": "User",
        "正常": "Active",
        "待执行": "Pending",
        "可恢复 %@ 个": "%@ restorable",
        "已真正停用 %@ 个": "%@ truly disabled",
        "真正停用 %@ 个 · 待执行 %@ 个": "%@ disabled · %@ pending",
        "真正停用 %@ 个 · 未生效 %@ 个": "%@ disabled · %@ not effective",
        "共 %@ 个 · 停用 %@ 个": "%@ total · %@ paused",
        "共 %@ 个": "%@ total",
        "失败 %@ 项": "%@ failed",
        "%@ 条明细": "%@ detail(s)",
        "展开查看每一条原因": "Show every reason",
        "已停止，剩下的没有再处理。": "Stopped; the rest were not processed."
    ]
}

// MARK: - 取文案

/// 取当前语言下的文案；英文缺条目时回退到中文原文，界面不会变空白。
func T(_ key: String) -> String {
    Localization.shared.localized(key)
}

/// 带占位符的版本。代码里统一用 %@ / %lld / %d，参数按顺序替换，
/// 这样中英文占位符写法不一致也能对上（内部会先把占位符归一化）。
func T(_ template: String, _ args: Any...) -> String {
    var result = Localization.shared.localized(template)
    guard !args.isEmpty else { return result }
    for arg in args {
        let candidates = ["%lld", "%d", "%@"].compactMap { result.range(of: $0) }
        guard let range = candidates.min(by: { $0.lowerBound < $1.lowerBound }) else { break }
        result.replaceSubrange(range, with: String(describing: arg))
    }
    return result
}
