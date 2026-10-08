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
        // 启动即清理：历史版本排下的待发/已交付通知都在这里被清掉，
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
        center.removeAllDeliveredNotifications()
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
        guard s.isEnabled, !s.rules.isEmpty else { return }

        // 只有「通知」类规则才需要排系统通知；全屏提示规则一律不注册通知请求
        let notificationRules = s.rules.filter { $0.method == .notification }

        // 1) 汇总所有"重复触发器"（按 weekday+hour+minute 去重）和"一次性触发时间"
        var repeating: Set<RepeatingFire> = []
        var oneTimeDates: [Date] = []
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
                    oneTimeDates.append(target)
                case .daily:
                    repeating.insert(RepeatingFire(weekday: nil, hour: h, minute: m))
                case .weekly:
                    for wd in rule.weekdays {
                        repeating.insert(RepeatingFire(weekday: wd, hour: h, minute: m))
                    }
                }
            case .cycleInterval:
                let times = hourlyTimes(start: rule.startTime, end: rule.endTime, interval: rule.intervalMinutes)
                let wds = rule.weekdays.isEmpty ? [Int](1...7) : Array(rule.weekdays)
                for t in times {
                    guard let (h, m) = parseHM(t) else { continue }
                    if rule.weekdays.isEmpty {
                        repeating.insert(RepeatingFire(weekday: nil, hour: h, minute: m))
                    } else {
                        for wd in wds {
                            repeating.insert(RepeatingFire(weekday: wd, hour: h, minute: m))
                        }
                    }
                }
            }
        }

        // 2) 注册（系统上限 64 条，超出截断）
        var scheduled = 0
        let maxTriggers = 64
        let center = UNUserNotificationCenter.current()

        for fire in repeating {
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
        for d in oneTimeDates {
            if scheduled >= maxTriggers { break }
            let comps = cal.dateComponents([.year, .month, .day, .hour, .minute], from: d)
            let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
            let id = "\(identifierPrefix)once_\(Int(d.timeIntervalSince1970))"
            let req = UNNotificationRequest(identifier: id, content: makeContent(), trigger: trigger)
            center.add(req) { _ in }
            scheduled += 1
        }
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

    /// 从 start 到 end，按 interval 分钟步进生成时间点列表
    func hourlyTimes(start: String, end: String, interval: Int) -> [String] {
        guard let (sh, sm) = parseHM(start), let (eh, em) = parseHM(end), interval > 0 else { return [] }
        var times: [String] = []
        var h = sh, m = sm
        while true {
            if h > eh || (h == eh && m > em) { break }
            times.append(String(format: "%02d:%02d", h, m))
            m += interval
            while m >= 60 { m -= 60; h += 1 }
            if h > 23 { break }
        }
        return times
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
                let times = hourlyTimes(start: rule.startTime, end: rule.endTime, interval: rule.intervalMinutes)
                let wds = rule.weekdays.isEmpty ? [Int](1...7) : Array(rule.weekdays)
                for wd in wds {
                    for t in times {
                        guard let (h, m) = parseHM(t) else { continue }
                        if let d = nextFireDate(weekday: wd, hour: h, minute: m, from: now, cal: cal) {
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
        // 以 UserDefaults 里的真实配置为准（didSet 是先写 defaults、再排程）
        completionHandler(AppSettings.hasNotificationRuleInStore ? [.banner, .sound] : [])
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
    private var lastCheckDay: Int = 0
    private var snoozeWorkItem: DispatchWorkItem?
    /// 阻止 App Nap 的活动令牌：持有期间系统不会把本 App 降频
    private var activityToken: NSObjectProtocol?

    /// 容忍窗口，与 ReminderManager 共用同一个常量
    private var graceWindow: TimeInterval { ReminderManager.fireGraceWindow }

    func start() {
        guard timer == nil else { return }
        // 菜单栏 App 长时间无交互会被 App Nap 降频，Timer 一停摆就会漏掉提醒
        activityToken = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated],
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

        // 新的一天：清空已触发记录
        if let day = cal.dateComponents([.day], from: now).day, day != lastCheckDay {
            firedKeys.removeAll()
            lastCheckDay = day
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
            firedKeys.insert(key)
            showAlert()
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
            let weekdayOK = rule.weekdays.isEmpty
                || rule.weekdays.contains(cal.component(.weekday, from: now))
            guard weekdayOK else { return nil }
            guard let (h, m) = ReminderManager.shared.parseHM(rule.time),
                  let fireAt = cal.date(bySettingHour: h, minute: m, second: 0, of: now) else { return nil }
            return now >= fireAt ? fireAt : nil

        case .cycleInterval:
            let weekdayOK = rule.weekdays.isEmpty
                || rule.weekdays.contains(cal.component(.weekday, from: now))
            guard weekdayOK, rule.intervalMinutes > 0 else { return nil }
            guard let (sh, sm) = ReminderManager.shared.parseHM(rule.startTime),
                  let (eh, em) = ReminderManager.shared.parseHM(rule.endTime),
                  let start = cal.date(bySettingHour: sh, minute: sm, second: 0, of: now) else { return nil }
            // 步进全部用「当天第几分钟」做整数运算，避免浮点除法在边界上的误差
            let startMin = sh * 60 + sm
            let endMin = eh * 60 + em
            let nowMin = cal.component(.hour, from: now) * 60 + cal.component(.minute, from: now)
            guard nowMin >= startMin else { return nil }
            let lastIndex = (endMin - startMin) / rule.intervalMinutes
            let index = min((nowMin - startMin) / rule.intervalMinutes, lastIndex)
            guard index >= 0 else { return nil }
            return start.addingTimeInterval(TimeInterval(index * rule.intervalMinutes * 60))
        }
    }

    // MARK: 弹窗
    func showAlertNow() {
        showAlert()
    }

    private func showAlert() {
        // 取消正在进行的贪睡
        snoozeWorkItem?.cancel()
        snoozeWorkItem = nil

        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let frame = screen.frame

        // 1) 铺满当前屏幕的无边框窗口：暗色遮罩由 SwiftUI 层绘制，窗口本身保持透明
        let panel = AlertPanel(
            contentRect: frame,
            styleMask: [.borderless],
            backing: NSWindow.BackingStoreType.buffered,
            defer: false
        )
        panel.title = "💧 喝水提醒"
        panel.level = NSWindow.Level.floating            // 始终置于最前
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary] // 所有 Space 可见
        panel.backgroundColor = .clear                   // 透明背景：遮罩交给 SwiftUI
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false                  // 失活时不隐藏
        panel.isMovable = false                          // 全屏尺寸，不允许拖动
        panel.isReleasedWhenClosed = false

        // 2) 内容视图：整屏 ZStack（暗色遮罩 + 居中卡片）
        let rootView = FullScreenAlertView(
            onDismiss: { [weak self] in self?.dismissAlert() },
            onSnooze: { [weak self] in self?.snooze() }
        )
        let controller = NSHostingController(rootView: rootView)
        panel.contentViewController = controller

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
    }

    private func dismissAlert() {
        alertWindow?.close()
        alertWindow = nil
    }

    private func snooze() {
        alertWindow?.close()
        alertWindow = nil
        snoozeWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.showAlert()
        }
        snoozeWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 300, execute: work)  // 5 分钟后
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
