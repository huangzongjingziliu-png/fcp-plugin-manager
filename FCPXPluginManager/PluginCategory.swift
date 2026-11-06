import Foundation

// MARK: - 分类

/// 插件分类。放在数据层，ViewModel 和 UI 共用，不依赖 SwiftUI。
enum PluginCategory: String, CaseIterable, Identifiable {
    case all = "全部"
    case effects = "效果"
    case generators = "发生器"
    case transitions = "转场"
    case titles = "标题"

    var id: String { rawValue }
    /// 界面显示用；rawValue 仍作为数据里的固定键，不跟着语言变
    var displayName: String { T(rawValue) }
}

// MARK: - 侧边栏

enum SidebarItem: String, CaseIterable, Identifiable {
    case all = "全部"
    case effects = "效果"
    case generators = "发生器"
    case transitions = "转场"
    case titles = "标题"
    case backups = "已备份"
    case disabled = "已禁用"

    var id: String { rawValue }

    /// 界面显示用，rawValue 保持稳定
    var displayName: String { T(rawValue) }

    /// 插件分类视图对应的筛选条件；「已备份」「已禁用」不是分类
    var categoryFilter: PluginCategory? {
        switch self {
        case .all: return .all
        case .effects: return .effects
        case .generators: return .generators
        case .transitions: return .transitions
        case .titles: return .titles
        case .backups, .disabled: return nil
        }
    }

    var isBackup: Bool { self == .backups }
    var isDisabled: Bool { self == .disabled }
}
