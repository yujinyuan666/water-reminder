import Foundation
import UserNotifications
import AppKit
import SwiftUI

/// 通知调度管理：按"提醒列表"中的每条规则生成通知触发器。
final class ReminderManager {
    static let shared = ReminderManager()
    private init() {}

    let identifierPrefix = "waterreminder."

    /// 触发容忍窗口：触发点过去这么久之内仍视为「应当已触发」。
    /// 一方面兜住 tick 被推迟的情况（App Nap、系统繁忙、屏幕锁定），
    /// 另一方面用来判断「仅一次」规则的目标时刻是否真的已经过期。
    static let fireGraceWindow: TimeInterval = 300

    /// 请求通知权限；启动时先无条件做一次「清理 + 重排」，授权成功后再排一次
    func requestAuthorization() {
        let center = UNUserNotificationCenter.current()
        center.delegate = NotificationCenterDelegate.shared
        // 只在启动时清一次历史遗留的「已送达」通知：
        // 历史版本的命名规则可能和当前版本不同，按前缀过滤匹配不到，会一直留在通知中心。
        // 但这件事只该在启动时做一次 —— 放进 rescheduleAll 里就会变成
        // 「改任意一条规则 = 抹掉用户还没看的所有提醒」。
        center.removeAllDeliveredNotifications()
        // 启动即清理：历史版本排下的待发通知都在这里被清掉，
        // 不依赖用户是否重新授权（已授权时 requestAuthorization 不一定回到主线程重排）。
        DispatchQueue.main.async { self.rescheduleAll() }
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            if granted {
                DispatchQueue.main.async { self.rescheduleAll() }
            }
        }
    }

    /// 清除旧提醒并重新排程。
    ///
    /// 这里刻意做「全量清理」而不是按 identifier 前缀挑选自己的请求：
    /// UNUserNotificationCenter 是按 App 隔离的，本 App 名下的待发/已发通知全归自己所有，
    /// 全清不会影响其他应用；同时也能清掉历史版本遗留的孤儿请求 ——
    /// 它们的命名规则可能与当前版本不同，按前缀过滤是匹配不到的，会一直弹在右上角。
    func rescheduleAll() {
        let center = UNUserNotificationCenter.current()
        center.removeAllPendingNotificationRequests()
        // 不碰「已送达」通知：那是用户还没看的历史记录。
        // rescheduleAll 会因改任意一条规则、切总开关而频繁触发，
        // 全清会让通知中心里的提醒被无端抹掉。
        // getPending 的回调发生在系统处理完上面的移除之后，借它当一次「屏障」，
        // 保证接下来的 add 一定排在 remove 之后；再回主线程处理后续逻辑，
        // 因为 AppSettings 的 @Published 属性只在主线程读写。
        center.getPendingNotificationRequests { _ in
            DispatchQueue.main.async {
                let now = Date()
                self.stampOnceFireTargets(now: now, cal: .current)
                self.schedule()
            }
        }
    }

    /// 给还没有目标时刻的「仅一次」规则钉死一个触发时刻。
    ///
    /// 不做这一步的话，每次重排都会把"下一次该时刻"重算成明天，「仅一次」就变成了每天都提醒。
    /// 目标时刻过去后**不删除规则**：规则留在列表里显示「已执行」，
    /// 由 AppSettings 在用户改动配置时清掉目标时刻，从而重新启用（见 rules.didSet）。
    private func stampOnceFireTargets(now: Date, cal: Calendar) {
        let s = AppSettings.shared
        for rule in s.rules where rule.type == .fixedTime && rule.fixedRepeat == .once {
            guard s.onceFireTarget(for: rule) == nil else { continue }
            guard let (h, m) = parseHM(rule.time),
                  let next = nextFireDate(weekday: nil, hour: h, minute: m, from: now, cal: cal) else { continue }
            s.stampOnceFireTarget(next, for: rule)
        }
    }

    private func schedule() {
        let s = AppSettings.shared
        // 关掉总开关或清空规则后，旧的截断告警必须一起消失，否则面板上会挂着
        // 一条「你的配置超出上限」的提示，而实际压根没在排程
        guard s.isEnabled, !s.rules.isEmpty else {
            if s.scheduleWarning != nil { s.scheduleWarning = nil }
            return
        }

        // 只有「通知」类规则才需要排系统通知；全屏提示规则一律不注册通知请求
        let notificationRules = s.rules.filter { $0.method == .notification }

        // 1) 汇总所有"重复触发器"（按 weekday+hour+minute 去重）和"一次性触发时间"
        var repeating: Set<RepeatingFire> = []
        /// 「仅一次」的目标时刻，带上规则 ID 用于生成唯一标识符
        var oneTimeDates: [(date: Date, ruleID: UUID)] = []
        let now = Date()
        let cal = Calendar.current

        for rule in notificationRules {
            switch rule.type {
            case .fixedTime:
                guard let (h, m) = parseHM(rule.time) else { break }
                switch rule.fixedRepeat {
                case .once:
                    // 「仅一次」只看被钉死的那个目标时刻，不再重算"下一次该时刻"：
                    // 否则每次重排都会把目标顺延到明天，「仅一次」会变成每天都提醒
                    guard let target = s.onceFireTarget(for: rule), target > now else { break }
                    oneTimeDates.append((target, rule.id))
                case .daily:
                    // 「每天」就是每天：不看 weekdays。
                    // 这两个字段历史上会被一起写入（新建按钮里硬编码了工作日），
                    // 而全屏提示路径不看 fixedRepeat、只看 weekdays ——
                    // 于是界面上写着「每天 10:00」的提醒实际只在周一到周五出现。
                    repeating.insert(RepeatingFire(weekday: nil, hour: h, minute: m))
                case .weekly:
                    for wd in rule.weekdays {
                        repeating.insert(RepeatingFire(weekday: wd, hour: h, minute: m))
                    }
                }
            case .cycleInterval:
                for slot in hourlySlots(start: rule.startTime, end: rule.endTime, interval: rule.intervalMinutes) {
                    if rule.weekdays.isEmpty {
                        repeating.insert(RepeatingFire(weekday: nil, hour: slot.hour, minute: slot.minute))
                    } else {
                        for wd in rule.weekdays {
                            guard let shifted = shiftWeekday(wd, by: slot.dayOffset) else { continue }
                            repeating.insert(RepeatingFire(weekday: shifted, hour: slot.hour, minute: slot.minute))
                        }
                    }
                }
            }
        }

        // 2) 注册（系统对每个 App 的待发通知上限是 64 条，超出必须截断）
        //
        // 截断策略（不能是「Set 迭代到哪算哪」）：
        //  · 「仅一次」规则优先 —— 它的时刻是界面上明示给用户的，丢了就是「界面承诺了却不响」
        //  · 重复触发器按 (hour, minute, weekday) 排序 —— 排序键稳定，同样的配置每次重启
        //    排出来的子集就一样，不会今天有这个时段、明天没那个时段
        //  · 排序把「每天」放在每个时段的第一位（weekday 记 -1），它覆盖面最大，最该保住
        var scheduled = 0
        let maxTriggers = 64
        let center = UNUserNotificationCenter.current()

        for item in oneTimeDates.sorted(by: { $0.date < $1.date }) {
            if scheduled >= maxTriggers { break }
            let comps = cal.dateComponents([.year, .month, .day, .hour, .minute], from: item.date)
            let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
            // 标识符必须带规则 ID：两条「仅一次」规则若目标时刻相同，
            // 只用时间戳会让它们撞成同一个 identifier，后 add 的直接覆盖前 add，只剩一条能送达
            let id = "\(identifierPrefix)once_\(item.ruleID.uuidString)_\(Int(item.date.timeIntervalSince1970))"
            let req = UNNotificationRequest(identifier: id, content: makeContent(), trigger: trigger)
            center.add(req) { _ in }
            scheduled += 1
        }
        let sortedFires = repeating.sorted {
            if $0.hour != $1.hour { return $0.hour < $1.hour }
            if $0.minute != $1.minute { return $0.minute < $1.minute }
            return ($0.weekday ?? -1) < ($1.weekday ?? -1)
        }
        for fire in sortedFires {
            if scheduled >= maxTriggers { break }
            var comps = DateComponents()
            if let wd = fire.weekday { comps.weekday = wd }
            comps.hour = fire.hour
            comps.minute = fire.minute
            let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: true)
            let key = fire.weekday.map { "wd\($0)" } ?? "daily"
            let id = "\(identifierPrefix)r_\(key)_\(String(format: "%02d", fire.hour))\(String(format: "%02d", fire.minute))"
            let req = UNNotificationRequest(identifier: id, content: makeContent(), trigger: trigger)
            center.add(req) { _ in }
            scheduled += 1
        }

        // 3) 把截断结果告诉界面：静默丢提醒是最难被发现的一类问题
        let wanted = repeating.count + oneTimeDates.count
        if wanted > maxTriggers {
            s.scheduleWarning = "系统最多只允许 \(maxTriggers) 条通知，当前配置需要 \(wanted) 条，"
                + "超出部分不会提醒。请减少规则或缩短循环区间。"
        } else {
            s.scheduleWarning = nil
        }
    }

    /// 把一个星期几往后挪 n 天（用于跨午夜区间：23:30 的触发点其实属于前一天的窗口）
    private func shiftWeekday(_ wd: Int, by days: Int) -> Int? {
        guard days != 0 else { return wd }
        // Calendar.weekday：1=周日 … 7=周六，按 7 取模循环
        let shifted = (wd - 1 + days) % 7 + 1
        return (1...7).contains(shifted) ? shifted : nil
    }

    private func makeContent() -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = "喝水时间到 💧"
        content.body = "该喝水啦！记得补充水分，身体更健康～"
        content.sound = .default
        return content
    }

    // MARK: - 时间计算

    /// 重复触发单元（weekday=nil 表示每天）
    private struct RepeatingFire: Hashable {
        let weekday: Int?
        let hour: Int
        let minute: Int
    }

    /// 循环区间的步进结果。`dayOffset` 表示这个时间点属于「起始那天」之后的第几天：
    /// 23:30 起、02:00 止的区间里，00:30 是 dayOffset=1（第二天凌晨）。
    ///
    /// 跨午夜（end <= start）必须支持：睡眠时间是喝水提醒最典型的场景之一，
    /// 而旧实现里 `endMin - startMin` 为负数，直接生成 0 个时间点 —— 规则永远不响，
    /// 界面还只说「暂无计划提醒」，用户完全查不出原因。
    func hourlySlots(start: String, end: String, interval: Int) -> [(hour: Int, minute: Int, dayOffset: Int)] {
        guard let (sh, sm) = parseHM(start), let (eh, em) = parseHM(end), interval > 0 else { return [] }
        // 起止相同 = 每天只在那一刻响一次，不算跨午夜
        let startMin = sh * 60 + sm
        var endMin = eh * 60 + em
        if endMin < startMin { endMin += 24 * 60 }
        var slots: [(hour: Int, minute: Int, dayOffset: Int)] = []
        var cur = startMin
        // 上限兜底：单个区间最多 48 小时，即便 interval=1 也不至于无限循环
        while cur <= endMin && slots.count < 2880 {
            slots.append(((cur / 60) % 24, cur % 60, cur / (24 * 60)))
            cur += interval
        }
        return slots
    }

    func parseHM(_ s: String) -> (Int, Int)? {
        let parts = s.split(separator: ":")
        guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]),
              (0...23).contains(h), (0...59).contains(m) else { return nil }
        return (h, m)
    }

    /// 计算下一次 (weekday?, hour, minute) 触发的真实日期时间
    private func nextFireDate(weekday wd: Int?, hour: Int, minute: Int, from now: Date, cal: Calendar) -> Date? {
        for offset in 0..<14 {
            guard let date = cal.date(byAdding: .day, value: offset, to: now) else { continue }
            if let w = wd, cal.component(.weekday, from: date) != w { continue }
            var dc = cal.dateComponents([.year, .month, .day], from: date)
            dc.hour = hour
            dc.minute = minute
            if let d = cal.date(from: dc), d > now { return d }
        }
        return nil
    }

    /// 计算从现在起最近的一次提醒时间
    func nextReminderDate() -> Date? {
        let s = AppSettings.shared
        guard s.isEnabled, !s.rules.isEmpty else { return nil }
        let cal = Calendar.current
        let now = Date()
        var candidates: [Date] = []

        for rule in s.rules {
            switch rule.type {
            case .fixedTime:
                guard let (h, m) = parseHM(rule.time) else { break }
                switch rule.fixedRepeat {
                case .once:
                    // 「仅一次」只看被钉死的目标时刻：已执行的规则不该再出现在"下次提醒"里
                    if let target = s.onceFireTarget(for: rule), target > now {
                        candidates.append(target)
                    }
                case .daily:
                    // 每天：忽略 weekdays（与 schedule() 保持一致）
                    if let d = nextFireDate(weekday: nil, hour: h, minute: m, from: now, cal: cal) {
                        candidates.append(d)
                    }
                case .weekly:
                    for wd in rule.weekdays {
                        if let d = nextFireDate(weekday: wd, hour: h, minute: m, from: now, cal: cal) {
                            candidates.append(d)
                        }
                    }
                }
            case .cycleInterval:
                for slot in hourlySlots(start: rule.startTime, end: rule.endTime, interval: rule.intervalMinutes) {
                    let wds = rule.weekdays.isEmpty ? [Int](1...7) : Array(rule.weekdays)
                    for wd in wds {
                        guard let shifted = shiftWeekday(wd, by: slot.dayOffset) else { continue }
                        if let d = nextFireDate(weekday: shifted, hour: slot.hour, minute: slot.minute, from: now, cal: cal) {
                            candidates.append(d)
                        }
                    }
                }
            }
        }
        return candidates.min()
    }

    /// 手动发送一条即时提醒：遵循规则里配置的提醒方式。
    /// 只有存在「通知」类规则时才发系统通知；否则直接弹居中窗口，
    /// 避免"所有规则都是全屏提示"时手动触发却冒出一个右上角横幅。
    func sendImmediateReminder() {
        guard AppSettings.hasNotificationRuleInStore else {
            DispatchQueue.main.async { FullScreenAlertManager.shared.showAlertNow() }
            return
        }
        let content = makeContent()
        content.body = "手动提醒：该喝水啦！"
        let id = "\(identifierPrefix)manual_\(Int(Date().timeIntervalSince1970))"
        let req = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req) { _ in }
    }
}

/// 确保通知在前台时也能弹出，但只放行「通知」类规则产生的提醒。
/// 全屏提示规则不该产生任何右上角横幅 —— 这里是兜底闸门：
/// 无论系统里有没有残留的待发请求，只要当前配置里没有通知类规则，就一律不外显。
final class NotificationCenterDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationCenterDelegate()

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // 以 UserDefaults 里的真实配置为准（didSet 是先写 defaults、再排程）。
        // 带上 .list：不加的话前台收到的提醒不会进入通知中心，
        // 用户错过横幅就再也找不回来了。
        completionHandler(AppSettings.hasNotificationRuleInStore ? [.banner, .sound, .list] : [])
    }
}

// MARK: - 居中弹窗提示

/// 可接受键盘/鼠标事件的面板
class AlertPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// 全屏提醒管理器：定时检查 `.fullScreen` 规则，到点用一个铺满整屏的暗色遮罩 + 居中卡片提醒。
/// 遮罩会拦截鼠标点击（避免误触到后面的应用），需点「我知道了」或按 Esc 才关闭。
/// 需应用保持运行，应用退出后弹窗提示不生效。
final class FullScreenAlertManager {
    static let shared = FullScreenAlertManager()
    private init() {}

    private var timer: Timer?
    private var alertWindow: AlertPanel?
    /// 已触发记录 "ruleID-触发时刻时间戳"，防止同一个触发点重复弹窗
    private var firedKeys: Set<String> = []
    private var lastCheckDay: Date = .distantPast
    private var snoozeWorkItem: DispatchWorkItem?
    /// 阻止 App Nap 的活动令牌：持有期间系统不会把本 App 降频
    private var activityToken: NSObjectProtocol?
    /// 弹窗弹出前的前台 App，关闭弹窗后把焦点还给它
    private var focusReturnTarget: NSRunningApplication?

    /// 容忍窗口，与 ReminderManager 共用同一个常量
    private var graceWindow: TimeInterval { ReminderManager.fireGraceWindow }

    func start() {
        guard timer == nil else { return }
        // 菜单栏 App 长时间无交互会被 App Nap 降频，Timer 一停摆就会漏掉提醒。
        //
        // 这里必须用 `.userInitiatedAllowingIdleSystemSleep` 而不是 `.userInitiated`：
        // NSActivityUserInitiated 的定义里包含 NSActivityIdleSystemSleepDisabled，
        // 而本 App 是常驻的、这个令牌永不归还（stop() 全仓无调用点），
        // 用 `.userInitiated` 会让整台机器在 App 运行期间无法进入空闲睡眠。
        // 实测 `pmset -g assertions` 可复现：前者留下 PreventUserIdleSystemSleep，后者不留。
        activityToken = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep],
            reason: "等待喝水提醒触发"
        )
        checkAndFire()
        let t = Timer(timeInterval: 15, repeats: true) { [weak self] _ in
            self?.checkAndFire()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if let token = activityToken {
            ProcessInfo.processInfo.endActivity(token)
            activityToken = nil
        }
    }

    // MARK: 定时检查
    private func checkAndFire() {
        let cal = Calendar.current
        let now = Date()

        // 新的一天：清空已触发记录。
        // 用「当天零点」比较而不是日号：日号在跨月同日（10/8 → 11/8）时相等，
        // 会把昨天甚至上个月的记录留下来。
        let today = cal.startOfDay(for: now)
        if today != lastCheckDay {
            firedKeys.removeAll()
            lastCheckDay = today
        }

        // 已有弹窗显示中，不再叠加
        guard alertWindow == nil else { return }
        guard AppSettings.shared.isEnabled else { return }

        for rule in AppSettings.shared.rules where rule.method == .fullScreen {
            guard let fireAt = latestFireDate(rule: rule, at: now, cal: cal) else { continue }
            // 超出容忍窗口的旧触发点直接忽略：
            // 免得 App 长时间没运行（或刚从睡眠唤醒）时一次性补弹一堆历史提醒
            guard now.timeIntervalSince(fireAt) <= graceWindow else { continue }
            let key = "\(rule.id.uuidString)-\(Int(fireAt.timeIntervalSince1970))"
            guard !firedKeys.contains(key) else { continue }
            // 先弹窗、成功了才记账：取不到屏幕时 showAlert 会失败返回，
            // 若提前 insert，这次提醒就永久丢了（下一次 tick 会被 firedKeys 挡住）
            guard showAlert() else { continue }
            firedKeys.insert(key)
            // 「仅一次」弹过之后规则仍留在列表里（列表上显示「已执行」），不再重复触发：
            // 上面的 firedKeys 挡住当天重复，graceWindow 挡住次日及以后；
            // 用户改动这条规则的配置时会重新钉一个目标时刻，从而重新启用。
            break
        }
    }

    /// 规则「此刻应当触发」的那个时刻，没有则返回 nil。
    ///
    /// 判定方式不再是「当前分钟是否正好等于目标分钟」，而是「不晚于 now 的最近一个触发点」——
    /// 调用方再判断它是否落在容忍窗口内。这样即使 15 秒的轮询被推迟到跨过了目标分钟，
    /// 下一次 tick 依然能把这次提醒补上；同时容忍窗口也挡住了"唤醒后补弹一堆历史提醒"。
    private func latestFireDate(rule: ReminderRule, at now: Date, cal: Calendar) -> Date? {
        switch rule.type {
        case .fixedTime:
            if rule.fixedRepeat == .once {
                // 「仅一次」只针对被钉死的那个目标时刻，与周几无关
                guard let target = AppSettings.shared.onceFireTarget(for: rule) else { return nil }
                return now >= target ? target : nil
            }
            let weekdayOK: Bool
            switch rule.fixedRepeat {
            case .daily:
                // 「每天」就是每天，不看 weekdays（与 schedule() 一致）；
                // 否则界面上写着「每天 10:00」的全屏提醒实际只在工作日出现
                weekdayOK = true
            case .weekly:
                // 「指定周几」但一个都没选 => 没有可触发的日子，与通知路径（排 0 条）一致
                weekdayOK = rule.weekdays.contains(cal.component(.weekday, from: now))
            case .once:
                weekdayOK = true
            }
            guard weekdayOK else { return nil }
            guard let (h, m) = ReminderManager.shared.parseHM(rule.time),
                  let fireAt = cal.date(bySettingHour: h, minute: m, second: 0, of: now) else { return nil }
            return now >= fireAt ? fireAt : nil

        case .cycleInterval:
            guard rule.intervalMinutes > 0 else { return nil }
            let slots = ReminderManager.shared.hourlySlots(
                start: rule.startTime, end: rule.endTime, interval: rule.intervalMinutes
            )
            guard !slots.isEmpty else { return nil }

            // 空的 weekdays 表示「每天」，与通知路径里 weekday: nil 的语义保持一致
            let weekdays = rule.weekdays.isEmpty ? Set(1...7) : rule.weekdays
            let todayStart = cal.startOfDay(for: now)

            // 跨午夜区间里，凌晨的触发点属于**前一天**开启的那个窗口，
            // 所以候选基准日要往前多看一天，否则周二 01:00 的提醒永远算不出来。
            var latest: Date?
            for dayBack in 0...1 {
                guard let baseDay = cal.date(byAdding: .day, value: -dayBack, to: todayStart) else { continue }
                guard weekdays.contains(cal.component(.weekday, from: baseDay)) else { continue }
                for slot in slots {
                    guard let wallClock = cal.date(bySettingHour: slot.hour, minute: slot.minute, second: 0, of: baseDay),
                          let fireAt = cal.date(byAdding: .day, value: slot.dayOffset, to: wallClock) else { continue }
                    guard fireAt <= now else { continue }
                    if latest == nil || fireAt > latest! { latest = fireAt }
                }
            }
            return latest
        }
    }

    // MARK: 弹窗
    func showAlertNow() {
        showAlert()
    }

    /// 显示全屏遮罩弹窗；返回是否真的显示出来了。
    ///
    /// 返回 Bool 是必要的：调用方（`checkAndFire`）靠它决定要不要把这次触发记为「已触发」。
    /// 取不到屏幕时这里只 return，若调用方提前记账，这次提醒就永久丢了。
    @discardableResult
    private func showAlert() -> Bool {
        // 重入保护：每次 showAlert 都会 new 一个面板并覆盖 alertWindow，
        // 旧面板的引用一旦被覆盖就再也关不掉了（AppKit 会把它留在屏幕上），
        // 只剩强退才能清理。已经有一个在显示时，直接不叠。
        guard alertWindow == nil else { return true }

        // 取消正在进行的贪睡
        snoozeWorkItem?.cancel()
        snoozeWorkItem = nil

        // 记下此刻的前台 App：必须在任何 orderFront / activate 之前取，
        // 之后才能原样还回去（取晚一步就会记成「我们自己」）
        focusReturnTarget = NSWorkspace.shared.frontmostApplication

        // 选屏幕：优先「鼠标所在屏」，其次「前台 App 所在屏」，最后才是主屏。
        // 只用 NSScreen.main 的话，用户在外接屏上工作时，遮罩会跑到另一块屏幕上去。
        guard let screen = targetScreen() else { return false }
        let frame = screen.frame

        // 1) 铺满当前屏幕的无边框窗口：暗色遮罩由 SwiftUI 层绘制，窗口本身保持透明
        let panel = AlertPanel(
            contentRect: frame,
            styleMask: [.borderless],
            backing: NSWindow.BackingStoreType.buffered,
            defer: false
        )
        panel.title = "💧 喝水提醒"
        // 用「比状态栏高一级」而不是 .floating：floating(3) 低于 mainMenu(24) 与 statusBar(25)，
        // 遮罩压不住菜单栏，系统横幅也会叠在遮罩之上。
        // 不取 .screenSaver(1000)：那会连系统密码框/权限弹窗一起盖住。
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary] // 所有 Space 可见
        panel.backgroundColor = .clear                   // 透明背景：遮罩交给 SwiftUI
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false                  // 失活时不隐藏
        panel.isMovable = false                          // 全屏尺寸，不允许拖动
        panel.isReleasedWhenClosed = false

        // 2) 内容视图：整屏 ZStack（暗色遮罩 + 居中卡片）
        //
        // 这里刻意**不**用 contentViewController：Apple 文档写明「赋值 contentViewController
        // 会让窗口按内容的理想尺寸重新布局」（causes the window to resize based on the current
        // size of the contentViewController），而本窗口 contentRect 的原点正是屏幕左下角 (0,0)，
        // 窗口一被缩就整块贴到左下角去了；macOS 15 起更极端，赋完值窗口 frame 直接归零。
        // 改用 NSHostingView 直接当 contentView，尺寸完全由我们控制。
        let rootView = FullScreenAlertView(
            onDismiss: { [weak self] in self?.dismissAlert() },
            onSnooze: { [weak self] in self?.snooze() }
        )
        let hosting = NSHostingView(rootView: rootView)
        hosting.frame = NSRect(origin: .zero, size: frame.size)
        hosting.autoresizingMask = [.width, .height]     // 窗口尺寸变化时跟着铺满
        panel.contentView = hosting
        panel.setFrame(frame, display: false)            // 再兜一次：确保窗口就是整屏

        // 3) 淡入显示。先激活 App，保证 Esc / 回车能被这个 key window 收到
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            panel.animator().alphaValue = 1
        }
        alertWindow = panel

        // 提示音
        NSSound.beep()
        return true
    }

    /// 弹窗该出现在哪块屏幕
    private func targetScreen() -> NSScreen? {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return nil }

        // 鼠标所在屏：用户眼睛和手此刻就在那里
        let mouse = NSEvent.mouseLocation
        if let hit = screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) { return hit }

        // 前台 App 的主窗口所在屏
        if let app = NSWorkspace.shared.frontmostApplication,
           let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] {
            let pid = app.processIdentifier
            for info in list where (info[kCGWindowOwnerPID as String] as? Int32) == pid {
                if let boundsDict = info[kCGWindowBounds as String] as? [String: Any],
                   let rect = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                   let hit = screens.first(where: { $0.frame.intersects(rect) }) {
                    return hit
                }
            }
        }

        return NSScreen.main ?? screens.first
    }

    private func dismissAlert() {
        closeAlertWindow()
        giveFocusBack()
    }

    private func snooze() {
        closeAlertWindow()
        giveFocusBack()
        snoozeWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            // 5 分钟里用户可能已经关掉总开关、或者删掉了所有全屏规则
            guard AppSettings.shared.isEnabled,
                  AppSettings.shared.rules.contains(where: { $0.method == .fullScreen }) else { return }
            self.showAlert()
        }
        snoozeWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 300, execute: work)  // 5 分钟后
    }

    private func closeAlertWindow() {
        alertWindow?.orderOut(nil)
        alertWindow?.close()
        alertWindow = nil
    }

    /// 把焦点还给弹窗弹出前的前台 App。
    /// 不还的话，用户点「我知道了」之后键盘输入会落进一个没有窗口的进程，
    /// 表现为「敲键盘没反应」，直到手动点一下别的 App。
    private func giveFocusBack() {
        guard let target = focusReturnTarget else { return }
        focusReturnTarget = nil
        guard target.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        target.activate()
    }
}

/// 全屏提醒内容视图：铺满整屏的暗色遮罩 + 屏幕正中的卡片。
/// 遮罩本身会吞掉鼠标点击，避免用户误触到后面的应用；关闭只能通过按钮或 Esc。
struct FullScreenAlertView: View {
    let onDismiss: () -> Void
    let onSnooze: () -> Void

    var body: some View {
        ZStack {
            // 铺满整屏的暗色遮罩
            Color.black.opacity(0.45)

            // 居中卡片
            VStack(spacing: 20) {
                // 居中显示应用图标图片（自适应原始比例）
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 110, height: 110)
                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .shadow(color: .black.opacity(0.15), radius: 8, y: 4)

                Text("喝水时间到！")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundColor(.primary)

                Text("该起来喝杯水了，保持水分充足")
                    .font(.system(size: 16))
                    .foregroundColor(.secondary)

                HStack(spacing: 16) {
                    Button(action: onSnooze) {
                        Text("稍后提醒")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundColor(.primary)
                            .frame(width: 130, height: 40)
                            .background(Color.primary.opacity(0.08))
                            .cornerRadius(20)
                    }
                    .buttonStyle(.plain)

                    Button(action: onDismiss) {
                        Text("我知道了")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(width: 130, height: 40)
                            .background(Color.blue)
                            .cornerRadius(20)
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.defaultAction) // 回车键关闭
                }
                .padding(.top, 4)
            }
            .padding(36)
            .background(Color(nsColor: .windowBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .shadow(color: .black.opacity(0.3), radius: 30, y: 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity) // 撑满整屏，卡片自动居中
        .onExitCommand { onDismiss() } // Esc 键关闭
    }
}
