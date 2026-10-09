import SwiftUI
import AppKit

/// 菜单栏弹出的面板：状态 + 提醒列表 + 快捷操作
struct MenuView: View {
    @EnvironmentObject var settings: AppSettings
    /// 开机自启动开关的本地状态：点击后立即刷新 UI，再延迟校准系统真实状态
    @State private var launchAtLoginEnabled: Bool = LaunchAtLogin.isEnabled

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            headerSection
            Divider()
            statusSection
            Divider()
            if settings.showQuickActions {
                quickActions
                Divider()
            }
            rulesListSection
            Divider()
            footerSection
        }
        .padding(16)
        .frame(width: 340)
        // 把高度钉在「内容理想尺寸」上：既防止被窗口的提议高度拉伸，
        // 也让下面 PanelWindowSync 读到的一定是内容的真实高度。
        .fixedSize(horizontal: false, vertical: true)
        // 把内容尺寸同步给宿主窗口 —— MenuBarExtra(.window) 自己不会在内容变高/变矮时重排窗口
        .background(
            GeometryReader { proxy in
                PanelWindowSync(size: proxy.size)
            }
        )
        // 每次打开面板时同步一次系统最新状态（含用户在系统设置里手动改动的情况）
        .onAppear { launchAtLoginEnabled = LaunchAtLogin.isEnabled }
    }

    // MARK: 头部
    private var headerSection: some View {
        HStack(spacing: 10) {
            Image(systemName: "drop.fill")
                .font(.title2)
                .foregroundColor(.blue)
            VStack(alignment: .leading, spacing: 2) {
                Text("喝水提醒").font(.headline)
                Text(settings.isEnabled ? "已开启" : "已关闭")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            Toggle("", isOn: $settings.isEnabled)
                .labelsHidden()
                .tint(.blue)
        }
    }

    // MARK: 状态
    private var statusSection: some View {
        // 用 TimelineView 包裹：每 30 秒（以及面板每次出现时）重新计算“下次提醒”，
        // 避免 MenuBarExtra 复用视图缓存导致显示停留在旧日期（如昨天）。
        TimelineView(PeriodicTimelineSchedule(from: .now, by: 30)) { _ in
            VStack(alignment: .leading, spacing: 4) {
                Text("下次提醒").font(.caption).foregroundColor(.secondary)
                if let next = settings.nextReminderDate() {
                    HStack(alignment: .firstTextBaseline) {
                        Text(next, format: .dateTime.month().day().hour().minute())
                            .font(.subheadline.bold())
                        Spacer()
                        Text(next, style: .relative)
                            .font(.caption)
                            .foregroundColor(.blue)
                    }
                } else {
                    Text("暂无计划提醒").font(.subheadline).foregroundColor(.secondary)
                }
            }
        }
    }

    // MARK: 快捷操作
    private var quickActions: some View {
        HStack {
            Button {
                ReminderManager.shared.sendImmediateReminder()
            } label: {
                Label("立即提醒", systemImage: "bell.badge.fill")
            }
            .buttonStyle(.borderedProminent)
            .tint(.blue)

            Button {
                FullScreenAlertManager.shared.showAlertNow()
            } label: {
                Label("测试弹窗", systemImage: "rectangle.center.inset.filled")
            }
            .buttonStyle(.bordered)
            Spacer()
        }
    }

    // MARK: 提醒列表
    private var rulesListSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("提醒列表").font(.caption).foregroundColor(.secondary)
                Spacer()
                Text("\(settings.rules.count) 条").font(.caption2).foregroundColor(.secondary)
            }

            ForEach(settings.rules) { rule in
                RuleCardView(ruleID: rule.id)
            }

            HStack(spacing: 8) {
                Button {
                    settings.rules.append(
                        ReminderRule(type: .fixedTime, time: "10:00", fixedRepeat: .daily, weekdays: [2, 3, 4, 5, 6])
                    )
                } label: {
                    Label("固定时间", systemImage: "clock")
                        .font(.caption)
                }
                .buttonStyle(.bordered)

                Button {
                    settings.rules.append(
                        ReminderRule(type: .cycleInterval, startTime: "09:00", intervalMinutes: 60, endTime: "18:00", weekdays: [2, 3, 4, 5, 6])
                    )
                } label: {
                    Label("循环间隔", systemImage: "arrow.2.circlepath")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
            }
        }
    }

    // MARK: 底部
    private var footerSection: some View {
        VStack(spacing: 12) {
            Toggle(isOn: Binding(
                get: { launchAtLoginEnabled },
                set: { newValue in
                    // 1) 立即更新 UI，开关即时响应
                    launchAtLoginEnabled = newValue
                    // 2) 注册/注销系统登录项（SMAppService 异步生效）
                    let ok = LaunchAtLogin.setEnabled(newValue)
                    // 3) 延迟校准真实状态（register/unregister 需一点时间生效，失败则回滚显示）
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                        let real = LaunchAtLogin.isEnabled
                        if ok, real != newValue {
                            // 系统尚未生效，稍后再查一次
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                launchAtLoginEnabled = LaunchAtLogin.isEnabled
                            }
                        } else {
                            launchAtLoginEnabled = real
                        }
                    }
                }
            )) {
                Label("开机自启动", systemImage: "power.dotted")
            }
            .tint(.blue)

            HStack {
                Spacer()
                Button("退出") {
                    NSApplication.shared.terminate(nil)
                }
            }
        }
    }
}

// MARK: - 单条规则卡片

struct RuleCardView: View {
    @EnvironmentObject var settings: AppSettings
    let ruleID: UUID
    @State private var expanded = false

    /// 规则在数组中的实时索引；规则已被删除时为 -1（哨兵值，避免数组越界崩溃）
    private var index: Int {
        settings.rules.firstIndex(where: { $0.id == ruleID }) ?? -1
    }

    /// 当前规则；已被删除时返回临时默认值，仅用于最后一帧渲染（随后视图随 ForEach 一起消失）
    private var rule: ReminderRule {
        guard index >= 0, settings.rules.indices.contains(index) else { return ReminderRule() }
        return settings.rules[index]
    }

    /// 索引是否有效（规则仍存在于列表中）
    private var isAlive: Bool {
        index >= 0 && settings.rules.indices.contains(index)
    }

    private let weekdayOrder: [(Int, String)] = [
        (2, "一"), (3, "二"), (4, "三"), (5, "四"), (6, "五"), (7, "六"), (1, "日")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            headerRow
            if expanded { editor }
        }
        .padding(8)
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.2), lineWidth: 1)
        )
    }

    private var headerRow: some View {
        // 用 TimelineView 包裹：MenuBarExtra 会复用视图，「已执行」状态随时间变化，
        // 需要定期重算，否则面板重新打开时可能还停留在旧状态。
        TimelineView(PeriodicTimelineSchedule(from: .now, by: 30)) { context in
            let fired = settings.isOnceRuleFired(rule, now: context.date)
            HStack(spacing: 8) {
                Image(systemName: rule.type.icon)
                    .foregroundColor(fired ? .secondary : .blue)
                    .frame(width: 18)
                Image(systemName: rule.method.icon)
                    .font(.caption2)
                    .foregroundColor(rule.method == .fullScreen ? .purple : .orange)
                    .opacity(fired ? 0.35 : 1)
                Text(summary)
                    .font(.subheadline)
                    .foregroundColor(fired ? .secondary : .primary)
                if fired { firedBadge }
                Spacer()
                Button {
                    expanded.toggle()
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .buttonStyle(.plain)

                Button {
                    delete()
                } label: {
                    Image(systemName: "trash")
                        .font(.caption)
                        .foregroundColor(.red)
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// 「仅一次」规则执行完成后的标记
    private var firedBadge: some View {
        HStack(spacing: 3) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 9))
            Text("已执行").font(.system(size: 10, weight: .medium))
        }
        .foregroundColor(.secondary)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Color.secondary.opacity(0.14))
        .cornerRadius(5)
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 10) {
            if settings.isOnceRuleFired(rule) {
                Text("这条提醒已执行。改动下面任一设置即可重新启用，按新设置重新计算一次触发时刻。")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // 类型切换
            Picker("类型", selection: binding(\.type)) {
                ForEach(RuleType.allCases) { t in Text(t.rawValue).tag(t) }
            }
            .pickerStyle(.segmented)

            // 提醒方式
            Picker("方式", selection: binding(\.method)) {
                ForEach(ReminderMethod.allCases) { m in Text(m.rawValue).tag(m) }
            }
            .pickerStyle(.segmented)

            if rule.method == .fullScreen {
                Text("⚠️ 全屏提示需保持应用运行")
                    .font(.caption2)
                    .foregroundColor(.orange)
            }

            switch rule.type {
            case .fixedTime:
                timeField("时间", binding(\.time))
                Picker("重复", selection: binding(\.fixedRepeat)) {
                    ForEach(FixedRepeat.allCases) { r in Text(r.rawValue).tag(r) }
                }
                .pickerStyle(.segmented)
                if rule.fixedRepeat == .weekly {
                    weekdayPicker(weekdayBinding())
                }
            case .cycleInterval:
                HStack {
                    timeField("开始", binding(\.startTime))
                    timeField("结束", binding(\.endTime))
                }
                Stepper("间隔：\(rule.intervalMinutes) 分钟", value: binding(\.intervalMinutes), in: 15...240, step: 15)
                weekdayPicker(weekdayBinding())
            }
        }
        .padding(.top, 2)
    }

    // MARK: 摘要
    private var summary: String {
        let wdText = weekdaySummary(rule.weekdays)
        switch rule.type {
        case .fixedTime:
            switch rule.fixedRepeat {
            case .once: return "\(rule.time) 仅一次"
            case .daily: return "每天 \(rule.time)"
            case .weekly: return "\(wdText) \(rule.time)"
            }
        case .cycleInterval:
            let wd = rule.weekdays.isEmpty ? "每天" : wdText
            return "\(wd) \(rule.startTime)起 每\(rule.intervalMinutes)分"
        }
    }

    private func weekdaySummary(_ wds: Set<Int>) -> String {
        return weekdayOrder.compactMap { (wd, name) in
            wds.contains(wd) ? name : nil
        }.joined()
    }

    // MARK: 工作日选择器
    private func weekdayPicker(_ binding: Binding<Set<Int>>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("周几").font(.caption2).foregroundColor(.secondary)
            HStack(spacing: 4) {
                ForEach(weekdayOrder, id: \.0) { wd, name in
                    let selected = binding.wrappedValue.contains(wd)
                    Button {
                        var copy = binding.wrappedValue
                        if copy.contains(wd) { copy.remove(wd) } else { copy.insert(wd) }
                        binding.wrappedValue = copy
                    } label: {
                        Text(name)
                            .font(.caption.weight(.medium))
                            .frame(width: 30, height: 26)
                            .background(selected ? Color.blue.opacity(0.15) : Color.clear)
                            .foregroundColor(selected ? .blue : .primary)
                            .cornerRadius(6)
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(selected ? Color.blue : Color.secondary.opacity(0.25), lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: 绑定与删除
    private func binding<T>(_ keyPath: WritableKeyPath<ReminderRule, T>) -> Binding<T> {
        Binding(
            get: {
                guard self.isAlive else { return ReminderRule()[keyPath: keyPath] }
                return self.settings.rules[self.index][keyPath: keyPath]
            },
            set: { newValue in
                guard self.isAlive else { return }
                self.settings.rules[self.index][keyPath: keyPath] = newValue
            }
        )
    }

    private func weekdayBinding() -> Binding<Set<Int>> {
        Binding(
            get: {
                guard self.isAlive else { return [] }
                return self.settings.rules[self.index].weekdays
            },
            set: { newValue in
                guard self.isAlive else { return }
                self.settings.rules[self.index].weekdays = newValue
            }
        )
    }

    private func delete() {
        if let i = settings.rules.firstIndex(where: { $0.id == ruleID }) {
            settings.rules.remove(at: i)
        }
    }

    private func timeField(_ label: String, _ b: Binding<String>) -> some View {
        HStack {
            Text(label).font(.caption)
            TextField("HH:mm", text: b)
                .textFieldStyle(.roundedBorder)
                .frame(width: 70)
        }
    }
}

// MARK: - 面板尺寸同步

/// 把 SwiftUI 内容的尺寸同步给 `MenuBarExtra` 的宿主窗口。
///
/// 为什么需要它（SwiftUI 的已知缺陷，截至 macOS 26 beta 仍无官方 API 可解）：
/// `.menuBarExtraStyle(.window)` 的宿主窗口**只在首次展示时测量一次**内容理想尺寸，
/// 之后内容高度变化时窗口不会重排 —— 删除一条规则后下方残留一大块空白、
/// 收起编辑区后同样留白、新增规则后底部被裁。
///
/// 这里在面板内部挂一个不可见的 NSView，借 `viewDidMoveToWindow` 拿到宿主窗口
/// （公开 API，MenuBarExtraAccess 内部也是这么做的），再把 SwiftUI 报上来的尺寸写过去。
/// 只负责「同步」这一件事，不参与任何布局计算。
private struct PanelWindowSync: NSViewRepresentable {
    let size: CGSize

    func makeNSView(context: Context) -> PanelWindowSyncView {
        PanelWindowSyncView()
    }

    func updateNSView(_ nsView: PanelWindowSyncView, context: Context) {
        nsView.targetSize = size
        nsView.syncIfNeeded()
    }
}

final class PanelWindowSyncView: NSView {
    /// SwiftUI 报上来的目标内容尺寸
    var targetSize: CGSize = .zero
    /// 已投递一次同步但还没执行：避免同一轮布局里重复投递
    private var pendingSync = false
    /// 面板重新展开时的再校准监听（见 viewDidMoveToWindow）
    private var keyToken: NSObjectProtocol?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // 面板每次重新展示都要校准一次（SwiftUI 可能已把窗口重置成旧尺寸）
        syncIfNeeded()

        // SwiftUI 在每次重新展开面板时可能把窗口重置成另一个尺寸（论坛实测：
        // 「第一次打开高度对，第二次起变成另一个值」），而此刻视图没有换窗口、
        // 布局也可能没变化 —— viewDidMoveToWindow 和 updateNSView 都不会触发。
        // 所以补一层「变回 key window 就再校一次」的监听兜住这条路径。
        if let token = keyToken { NotificationCenter.default.removeObserver(token); keyToken = nil }
        if let window = window {
            keyToken = NotificationCenter.default.addObserver(
                forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main
            ) { [weak self] _ in self?.syncIfNeeded() }
        }
    }

    deinit {
        if let token = keyToken { NotificationCenter.default.removeObserver(token) }
    }

    func syncIfNeeded() {
        guard targetSize.width > 0, targetSize.height > 0, !pendingSync else { return }
        pendingSync = true
        // 放到下一轮 runloop：回调时 SwiftUI 这轮布局已结束，读到的窗口尺寸才是最终值
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pendingSync = false
            guard let window = self.window else { return }
            let target = NSSize(width: self.targetSize.width, height: self.targetSize.height)
            guard target.height > 0 else { return }

            // 尺寸一致就什么都不做：既是幂等保护，也切断了
            // 「改窗口 → 触发重新布局 → 再改窗口」这条潜在死循环
            let current = window.contentRect(forFrameRect: window.frame).size
            guard abs(current.width - target.width) > 0.5
                    || abs(current.height - target.height) > 0.5 else { return }

            // SwiftUI 会给面板窗口设 contentMin/MaxSize 来禁止用户拖拽改尺寸，
            // 不放宽的话窗口尺寸会被它卡住。面板 styleMask 里没有 .resizable，
            // 用户本来就拖不动，所以这里直接改成目标尺寸是安全的。
            window.contentMinSize = target
            window.contentMaxSize = target

            // 顶边锚定：面板是从菜单栏往下展开的，而 setContentSize 保持左下角不动，
            // 高度一变顶边就会跟着上下跑（缩小时与菜单栏之间裂开一条缝）。
            // 这里记下原左上角，改完尺寸再钉回去。
            let topLeft = NSPoint(x: window.frame.minX, y: window.frame.maxY)
            window.setContentSize(target)
            window.setFrameTopLeftPoint(topLeft)
        }
    }
}
