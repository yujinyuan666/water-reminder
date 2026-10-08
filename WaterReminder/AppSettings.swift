import Foundation
import Combine

// MARK: - 提醒规则模型

/// 规则类型
enum RuleType: String, Codable, CaseIterable, Identifiable {
    case fixedTime = "固定时间"
    case cycleInterval = "循环间隔"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .fixedTime: return "clock.fill"
        case .cycleInterval: return "arrow.2.circlepath.circle.fill"
        }
    }
}

/// 固定时间规则的重复方式
enum FixedRepeat: String, Codable, CaseIterable, Identifiable {
    case once = "仅一次"
    case daily = "每天"
    case weekly = "指定周几"
    var id: String { rawValue }
}

/// 提醒方式
enum ReminderMethod: String, Codable, CaseIterable, Identifiable {
    case notification = "通知"
    case fullScreen = "全屏提示"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .notification: return "bell.badge"
        case .fullScreen: return "rectangle.on.rectangle.angled"
        }
    }
}

/// 单条提醒规则
struct ReminderRule: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var type: RuleType = .fixedTime
    var method: ReminderMethod = .notification
    // 固定时间用
    var time: String = "09:00"
    var fixedRepeat: FixedRepeat = .daily
    // 循环间隔用
    var startTime: String = "09:00"
    var intervalMinutes: Int = 60
    var endTime: String = "18:00"
    // 两者共用：指定周几（Calendar.weekday 1=周日…7=周六）
    var weekdays: Set<Int> = [2, 3, 4, 5, 6]
}

// MARK: - 全局设置

/// 全局设置模型，持久化到 UserDefaults，改动后自动重新排程提醒。
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private let defaults = UserDefaults.standard

    @Published var isEnabled: Bool {
        didSet {
            defaults.set(isEnabled, forKey: "isEnabled")
            scheduleReschedule()
        }
    }

    /// 是否在菜单中显示“立即提醒”和“测试弹窗”快捷操作
    @Published var showQuickActions: Bool {
        didSet {
            defaults.set(showQuickActions, forKey: "showQuickActions")
        }
    }

    /// 提醒规则列表，序列化为 JSON 存入 UserDefaults
    @Published var rules: [ReminderRule] {
        didSet {
            if let data = try? JSONEncoder().encode(rules) {
                defaults.set(data, forKey: "rules")
            }
            scheduleReschedule()
        }
    }

    /// 防抖：连续编辑时只排程一次
    private var rescheduleWorkItem: DispatchWorkItem?

    private init() {
        self.isEnabled = (defaults.object(forKey: "isEnabled") as? Bool) ?? true
        self.showQuickActions = (defaults.object(forKey: "showQuickActions") as? Bool) ?? false
        if let data = defaults.data(forKey: "rules"),
           let decoded = try? JSONDecoder().decode([ReminderRule].self, from: data) {
            // 尊重用户操作：列表被清空时也恢复为空，不再塞回默认规则
            self.rules = decoded
        } else {
            // 首次启动：默认一条工作日每 60 分钟循环
            self.rules = [
                ReminderRule(
                    type: .cycleInterval,
                    startTime: "09:00",
                    intervalMinutes: 60,
                    endTime: "18:00",
                    weekdays: [2, 3, 4, 5, 6]
                )
            ]
        }
    }

    private func scheduleReschedule() {
        rescheduleWorkItem?.cancel()
        let work = DispatchWorkItem { ReminderManager.shared.rescheduleAll() }
        rescheduleWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    /// 计算下一次提醒时间，用于菜单栏展示
    func nextReminderDate() -> Date? {
        ReminderManager.shared.nextReminderDate()
    }

    /// 直接从 UserDefaults 判断当前是否存在「通知」类规则。
    /// 供通知中心的 delegate 在非主线程调用 —— 这里刻意不触碰 @Published 属性，避免跨线程访问。
    /// 注意：didSet 里是「先写 defaults、再排程」，所以排程完成时读到的一定是最新配置。
    static var hasNotificationRuleInStore: Bool {
        let enabled = (UserDefaults.standard.object(forKey: "isEnabled") as? Bool) ?? true
        guard enabled,
              let data = UserDefaults.standard.data(forKey: "rules"),
              let decoded = try? JSONDecoder().decode([ReminderRule].self, from: data) else {
            return false
        }
        return decoded.contains { $0.method == .notification }
    }
}
