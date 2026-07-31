import Foundation
import UserNotifications
import AppKit
import SwiftUI

/// 通知调度管理：按"提醒列表"中的每条规则生成通知触发器。
final class ReminderManager {
    static let shared = ReminderManager()
    private init() {}

    let identifierPrefix = "waterreminder."

    /// 请求通知权限，授权后立即排程
    func requestAuthorization() {
        let center = UNUserNotificationCenter.current()
        center.delegate = NotificationCenterDelegate.shared
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            if granted {
                DispatchQueue.main.async { self.rescheduleAll() }
            }
        }
    }

    /// 清除旧提醒并重新排程
    func rescheduleAll() {
        let center = UNUserNotificationCenter.current()
        center.getPendingNotificationRequests { requests in
            let mine = requests.filter { $0.identifier.hasPrefix(self.identifierPrefix) }
            center.removePendingNotificationRequests(withIdentifiers: mine.map { $0.identifier })
            self.schedule()
        }
    }

    private func schedule() {
        let s = AppSettings.shared
        guard s.isEnabled, !s.rules.isEmpty else { return }

        // 1) 汇总所有"重复触发器"（按 weekday+hour+minute 去重）和"一次性触发时间"
        var repeating: Set<RepeatingFire> = []
        var oneTimeDates: [Date] = []
        let now = Date()
        let cal = Calendar.current

        for rule in s.rules where rule.method == .notification {
            switch rule.type {
            case .fixedTime:
                guard let (h, m) = parseHM(rule.time) else { break }
                switch rule.fixedRepeat {
                case .once:
                    // 仅一次：下一次该时刻出现时提醒
                    if let d = nextFireDate(weekday: nil, hour: h, minute: m, from: now, cal: cal) {
                        oneTimeDates.append(d)
                    }
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
                case .once, .daily:
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

    /// 手动发送一条即时提醒
    func sendImmediateReminder() {
        let content = makeContent()
        content.body = "手动提醒：该喝水啦！"
        let id = "\(identifierPrefix)manual_\(Int(Date().timeIntervalSince1970))"
        let req = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req) { _ in }
    }
}

/// 确保通知在前台时也能弹出
final class NotificationCenterDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationCenterDelegate()

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}

// MARK: - 居中弹窗提示

/// 可接受键盘/鼠标事件的面板
class AlertPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// 居中弹窗管理器：定时检查 `.fullScreen` 规则，到点在屏幕正中心弹出提醒窗口。
/// 窗口为固定尺寸、不覆盖全屏，图片/内容始终居中显示。
/// 需应用保持运行，应用退出后弹窗提示不生效。
final class FullScreenAlertManager {
    static let shared = FullScreenAlertManager()
    private init() {}

    /// 弹窗初始尺寸（pt），可在此调整；窗口可被用户缩放
    private let alertSize = NSSize(width: 420, height: 360)

    private var timer: Timer?
    private var alertWindow: AlertPanel?
    /// 已触发记录 "ruleID-hour-minute"，防止同一分钟重复弹窗
    private var firedKeys: Set<String> = []
    private var lastCheckDay: Int = 0
    private var snoozeWorkItem: DispatchWorkItem?

    func start() {
        guard timer == nil else { return }
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
    }

    // MARK: 定时检查
    private func checkAndFire() {
        let cal = Calendar.current
        let now = Date()
        let comp = cal.dateComponents([.weekday, .hour, .minute, .day], from: now)
        guard let weekday = comp.weekday,
              let hour = comp.hour,
              let minute = comp.minute,
              let day = comp.day else { return }

        // 新的一天：清空已触发记录
        if day != lastCheckDay {
            firedKeys.removeAll()
            lastCheckDay = day
        }

        // 已有弹窗显示中，不再叠加
        guard alertWindow == nil else { return }
        guard AppSettings.shared.isEnabled else { return }

        for rule in AppSettings.shared.rules where rule.method == .fullScreen {
            let key = "\(rule.id.uuidString)-\(hour)-\(minute)"
            if firedKeys.contains(key) { continue }

            if shouldFire(rule: rule, weekday: weekday, hour: hour, minute: minute) {
                firedKeys.insert(key)
                showAlert()
                break
            }
        }
    }

    private func shouldFire(rule: ReminderRule, weekday: Int, hour: Int, minute: Int) -> Bool {
        switch rule.type {
        case .fixedTime:
            let weekdayOK = rule.weekdays.isEmpty || rule.weekdays.contains(weekday)
            // .once 不限周几（在下一次该时刻出现时提醒）
            guard weekdayOK || rule.fixedRepeat == .once else { return false }
            guard let (h, m) = ReminderManager.shared.parseHM(rule.time) else { return false }
            return hour == h && minute == m
        case .cycleInterval:
            let weekdayOK = rule.weekdays.isEmpty || rule.weekdays.contains(weekday)
            guard weekdayOK else { return false }
            guard let (sh, sm) = ReminderManager.shared.parseHM(rule.startTime),
                  let (eh, em) = ReminderManager.shared.parseHM(rule.endTime) else { return false }
            let startTotal = sh * 60 + sm
            let endTotal = eh * 60 + em
            let nowTotal = hour * 60 + minute
            guard nowTotal >= startTotal, nowTotal <= endTotal, rule.intervalMinutes > 0 else { return false }
            return (nowTotal - startTotal) % rule.intervalMinutes == 0
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

        // 1) 屏幕正中心定位：无论分辨率如何，窗口水平、垂直居中
        let x = screen.frame.midX - alertSize.width / 2
        let y = screen.frame.midY - alertSize.height / 2
        let contentRect = NSRect(x: x, y: y, width: alertSize.width, height: alertSize.height)

        // 2) 普通居中窗口：带标题栏（含系统关闭按钮）、可拖动、可缩放，非全屏
        let panel = AlertPanel(
            contentRect: contentRect,
            styleMask: [.titled, .closable, .resizable],
            backing: NSWindow.BackingStoreType.buffered,
            defer: false
        )
        panel.title = "💧 喝水提醒"
        panel.level = NSWindow.Level.floating          // 始终置于最前（但不覆盖全屏）
        panel.collectionBehavior = [.canJoinAllSpaces] // 所有 Space 可见（已移除全屏相关 flag）
        panel.backgroundColor = .windowBackgroundColor
        panel.isOpaque = true
        panel.hasShadow = true
        panel.hidesOnDeactivate = false                // 失活时不隐藏
        panel.isMovable = true                         // 允许拖动
        panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: 360, height: 300) // 缩放范围限制
        panel.maxSize = NSSize(width: 620, height: 520)

        // 3) 内容视图：内部为居中布局，窗口缩放/拖动时图片始终居中
        let rootView = FullScreenAlertView(
            onDismiss: { [weak self] in self?.dismissAlert() },
            onSnooze: { [weak self] in self?.snooze() }
        )
        let controller = NSHostingController(rootView: rootView)
        panel.contentViewController = controller

        panel.orderFrontRegardless()
        panel.makeKeyAndOrderFront(nil)
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

/// 居中弹窗内容视图：应用图标图片 + 提醒文字 + 操作按钮。
/// 布局整体居中：窗口缩放或拖动时内容始终保持在窗口中心。
struct FullScreenAlertView: View {
    let onDismiss: () -> Void
    let onSnooze: () -> Void

    var body: some View {
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
        .frame(maxWidth: .infinity, maxHeight: .infinity) // 撑满窗口，内容自动居中
        .padding(24)
        .onExitCommand { onDismiss() } // Esc 键关闭
    }
}
