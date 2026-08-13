import SwiftUI

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
        HStack(spacing: 8) {
            Image(systemName: rule.type.icon)
                .foregroundColor(.blue)
                .frame(width: 18)
            Image(systemName: rule.method.icon)
                .font(.caption2)
                .foregroundColor(rule.method == .fullScreen ? .purple : .orange)
            Text(summary).font(.subheadline).foregroundColor(.primary)
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

    private var editor: some View {
        VStack(alignment: .leading, spacing: 10) {
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
