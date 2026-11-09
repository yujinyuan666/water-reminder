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

// 宽容解码放在扩展里：扩展里的 init 不会顶掉结构体的 memberwise init。
extension ReminderRule {
    /// 宽容解码：任何字段缺失、类型不符、枚举 rawValue 未知，都退回该字段的默认值。
    ///
    /// 为什么必须这么做：Swift 合成的 Decodable 在字段缺失时直接抛错，而
    /// `AppSettings.init` 一旦解码失败就会重置用户全部配置。也就是说，
    /// 只要给 `ReminderRule` 加任何一个非 Optional 字段，所有老用户升级的瞬间
    /// 规则就会被全部清空。加上这个 init 之后，加字段才是安全的。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ReminderRule()
        self.id = c.tolerant(.id) ?? d.id
        self.type = c.tolerant(.type) ?? d.type
        self.method = c.tolerant(.method) ?? d.method
        self.time = c.tolerant(.time) ?? d.time
        self.fixedRepeat = c.tolerant(.fixedRepeat) ?? d.fixedRepeat
        self.startTime = c.tolerant(.startTime) ?? d.startTime
        self.intervalMinutes = c.tolerant(.intervalMinutes) ?? d.intervalMinutes
        self.endTime = c.tolerant(.endTime) ?? d.endTime
        self.weekdays = c.tolerant(.weekdays) ?? d.weekdays
    }
}

private extension KeyedDecodingContainer {
    /// 解码单个字段：字段缺失 / 为 null / 类型不符 / 枚举 rawValue 未知都返回 nil。
    func tolerant<T: Decodable>(_ key: Key) -> T? {
        guard contains(key) else { return nil }
        return (try? decodeIfPresent(T.self, forKey: key)) ?? nil
    }
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

    /// 排程告警：规则所需的通知条数超过系统上限时由 RescheduleAll 写入，界面据此提示用户。
    /// 只放在内存里，不持久化 —— 它是「当前配置的估算结果」，每次重排都会重算。
    @Published var scheduleWarning: String?

    /// 提醒规则列表，序列化为 JSON 存入 UserDefaults
    @Published var rules: [ReminderRule] {
        didSet {
            persistRules()
            // 用户改动了「仅一次」规则的任一配置 => 意图是重新启用它：
            // 清掉钉死的目标时刻，下一次重排就会按最新配置重新算一个未来的触发时刻。
            // 不改配置的话，已执行的规则就一直是「已执行」，不会再打扰用户。
            for updated in rules {
                guard let previous = oldValue.first(where: { $0.id == updated.id }) else { continue }
                if previous != updated { rearmOnceRule(id: updated.id) }
            }
            pruneOnceFireTargets()
            scheduleReschedule()
        }
    }

    /// 「仅一次」规则被钉死的目标触发时刻：规则 ID -> timeIntervalSince1970。
    ///
    /// 为什么需要它：`.once` 的判定依赖"下一次该时刻"，而"下一次"永远存在 ——
    /// 每次重排（改配置、重启 App）都会把它算成明天，「仅一次」于是变成了每天都提醒。
    /// 这里在首次为该规则确定时刻时写死，之后不再漂移。
    /// 时刻过去后规则**保留在列表里**（显示为「已执行」），直到用户改动它的配置才重新启用。
    private var onceFireTargets: [String: Double] = [:]

    /// 防抖：连续编辑时只排程一次
    private var rescheduleWorkItem: DispatchWorkItem?

    private init() {
        self.isEnabled = (defaults.object(forKey: "isEnabled") as? Bool) ?? true
        self.showQuickActions = (defaults.object(forKey: "showQuickActions") as? Bool) ?? false
        self.scheduleWarning = nil
        // 读取「仅一次」的钉死时刻（NSNumber 需要显式转 Double）
        let rawTargets = defaults.dictionary(forKey: "onceFireTargets") ?? [:]
        self.onceFireTargets = rawTargets.compactMapValues { ($0 as? NSNumber)?.doubleValue }

        if let data = defaults.data(forKey: "rules"), let decoded = Self.decodeRules(data) {
            // 尊重用户操作：列表被清空时也恢复为空，不再塞回默认规则
            self.rules = decoded
        } else {
            // 首次启动（或配置损坏）：一条工作日每 60 分钟循环
            self.rules = [Self.defaultRule]
            // 关键：init 里给 @Published 赋值**不会触发 didSet**，默认规则原本从不落盘。
            // 而 `hasNotificationRuleInStore` 是直接读 UserDefaults 的 —— 于是首次安装的用户
            // 明明有通知类规则，前台通知却全被 willPresent 吞掉。这里主动落盘一次。
            persistRules()
        }
    }

    /// 首次启动 / 配置不可用时的兜底规则
    static var defaultRule: ReminderRule {
        ReminderRule(
            type: .cycleInterval,
            startTime: "09:00",
            intervalMinutes: 60,
            endTime: "18:00",
            weekdays: [2, 3, 4, 5, 6]
        )
    }

    /// 解码规则列表；失败时先把原始数据备份一份再返回 nil，便于事后追查。
    private static func decodeRules(_ data: Data) -> [ReminderRule]? {
        do {
            return try JSONDecoder().decode([ReminderRule].self, from: data)
        } catch {
            // 只备份一次（不覆盖已有的备份），随后 init 会用默认规则重新落盘，
            // 于是下次启动就是一份干净数据 —— 坏 blob 不会导致「每次启动都重置」。
            let backupKey = "rulesCorruptedBackup"
            if UserDefaults.standard.data(forKey: backupKey) == nil {
                UserDefaults.standard.set(data, forKey: backupKey)
            }
            print("读取提醒规则失败，已备份原始数据到 \(backupKey): \(error.localizedDescription)")
            return nil
        }
    }

    /// 把当前 rules 写入 UserDefaults（不触发重排）。
    private func persistRules() {
        guard let data = try? JSONEncoder().encode(rules) else { return }
        defaults.set(data, forKey: "rules")
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

    // MARK: - 「仅一次」规则的目标时刻

    /// 取「仅一次」规则已钉死的目标触发时刻
    func onceFireTarget(for rule: ReminderRule) -> Date? {
        guard let t = onceFireTargets[rule.id.uuidString] else { return nil }
        return Date(timeIntervalSince1970: t)
    }

    /// 「仅一次」规则是否已执行：目标时刻已到（或已过）。
    /// 状态不额外持久化 —— 直接由钉死的目标时刻推导，目标一过即为「已执行」。
    func isOnceRuleFired(_ rule: ReminderRule, now: Date = Date()) -> Bool {
        guard rule.type == .fixedTime, rule.fixedRepeat == .once else { return false }
        guard let target = onceFireTarget(for: rule) else { return false }
        return now >= target
    }

    /// 钉死「仅一次」规则的目标触发时刻（只在首次确定时写入，之后不再漂移）
    func stampOnceFireTarget(_ date: Date, for rule: ReminderRule) {
        onceFireTargets[rule.id.uuidString] = date.timeIntervalSince1970
        saveOnceFireTargets()
    }

    /// 重新启用一条「仅一次」规则：清掉钉死时刻，下次重排会按最新配置重新计算。
    /// 用户改动已执行规则的配置时调用（见 rules.didSet）。
    func rearmOnceRule(id: UUID) {
        guard onceFireTargets.removeValue(forKey: id.uuidString) != nil else { return }
        saveOnceFireTargets()
    }

    private func saveOnceFireTargets() {
        defaults.set(onceFireTargets, forKey: "onceFireTargets")
    }

    /// 清掉已被删除规则的钉死时刻，避免 UserDefaults 里留下孤儿记录
    private func pruneOnceFireTargets() {
        let alive = Set(rules.map { $0.id.uuidString })
        let pruned = onceFireTargets.filter { alive.contains($0.key) }
        guard pruned.count != onceFireTargets.count else { return }
        onceFireTargets = pruned
        saveOnceFireTargets()
    }

    /// 直接从 UserDefaults 判断当前是否存在「通知」类规则。
    /// 供通知中心的 delegate 在非主线程调用 —— 这里刻意不触碰 @Published 属性，避免跨线程访问。
    /// 注意：didSet 里是「先写 defaults、再排程」，所以排程完成时读到的一定是最新配置。
    static var hasNotificationRuleInStore: Bool {
        let enabled = (UserDefaults.standard.object(forKey: "isEnabled") as? Bool) ?? true
        guard enabled else { return false }
        // 键缺失时按「即将落盘的默认规则」判断，而不是一律 false：
        // 默认规则是通知类的，这里若返回 false，首次安装的用户前台横幅会被
        // willPresent 静默吞掉（AppSettings.init 现在会主动落盘，这里是双保险）
        guard let data = UserDefaults.standard.data(forKey: "rules") else {
            return defaultRule.method == .notification
        }
        guard let decoded = try? JSONDecoder().decode([ReminderRule].self, from: data) else {
            return false
        }
        return decoded.contains { $0.method == .notification }
    }
}
