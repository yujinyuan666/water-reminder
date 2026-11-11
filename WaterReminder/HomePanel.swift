import SwiftUI
import AppKit

/// 「主页」面板：第二次启动 App 时把它弹出来。
///
/// 为什么不用把 `MenuBarExtra` 的面板顶出来：实测做不到 ——
/// `NSSceneStatusItem` 的 `button.action` 为 nil，`performClick(nil)` 只改状态不展开，
/// 合成 `CGEvent` 点击状态栏位置也无效（本机 macOS 27.2 实测）。AGENTS.md 里也记着
/// 「MenuBarExtra(.window) 的面板必须真实点击状态栏才求值」。所以这里用独立
/// `NSPanel` 承载**同一个 `MenuView`**，视觉与交互和点状态栏一致。
///
/// 为什么在 `App.init` 里做单实例判断：`open` 一个已经在跑的 App 时 LaunchServices
/// 根本不会起第二个进程，会直接走 `applicationShouldHandleReopen`。两条路径都要覆盖。
final class HomePanelController: NSObject, NSWindowDelegate {
    static let shared = HomePanelController()

    private var panel: HomePanel?
    private var hostingView: NSHostingView<AnyView>?
    /// 面板显示时刻，用于挡住「刚 orderFront 就被判成 resignKey」的竞态
    private var shownAt: Date = .distantPast

    private override init() { super.init() }

    var isVisible: Bool { panel?.isVisible ?? false }

    /// 打开主页。已经打开着就把它前置到最前面（而不是关掉）。
    func show() {
        if let existing = panel {
            NSApp.activate(ignoringOtherApps: true)
            existing.makeKeyAndOrderFront(nil)
            return
        }

        let root = MenuView()
            .environmentObject(AppSettings.shared)
            .onExitCommand { [weak self] in self?.close() }
        let hosting = NSHostingView(rootView: AnyView(root))
        let initialSize = NSSize(width: 340, height: 420)
        hosting.frame = NSRect(origin: .zero, size: initialSize)
        hosting.autoresizingMask = [.width, .height]

        let panel = HomePanel(
            contentRect: NSRect(origin: .zero, size: initialSize),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.title = "喝水提醒"
        // MenuView 自己不带背景 —— 在 MenuBarExtra 里那层毛玻璃是系统给的。
        // 换到独立 NSPanel 之后没有人铺背景，窗口又必须是圆角面板而不是
        // 一块矩形，所以这里补一个 .popover 材质的 NSVisualEffectView 当底，
        // 视觉上才和点状态栏出来的面板一致。没有它的话面板是透明的，
        // 背后的文字会直接透上来。
        panel.contentView = Self.makeBackdrop(size: initialSize, hosting: hosting)
        // 压在菜单栏之上，否则弹出时会被菜单栏挡住顶部；但不用 .screenSaver(1000)，
        // 那会盖住系统密码框与权限弹窗
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.delegate = self
        panel.onResignKey = { [weak self] in
            guard let self else { return }
            // 刚显示时系统可能先给一次 resignKey（激活切换过程中的抖动），
            // 直接关掉会导致「面板闪一下就没了」
            guard Date().timeIntervalSince(self.shownAt) > 0.35 else { return }
            self.close()
        }

        // 顶边锚在状态栏图标下沿；取不到图标就退回屏幕右上角
        let anchor = Self.statusItemRect()
        panel.setFrameTopLeftPoint(NSPoint(x: anchor.maxX - initialSize.width, y: anchor.minY - 6))

        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)

        self.panel = panel
        self.hostingView = hosting
        self.shownAt = Date()
    }

    func close() {
        guard let panel else { return }
        panel.orderOut(nil)
        panel.close()
        self.panel = nil
        self.hostingView = nil
    }

    func toggle() {
        if isVisible { close() } else { show() }
    }

    // MARK: - 背景

    /// 毛玻璃底 + 圆角裁剪，把 `hosting` 铺在上面。
    ///
    /// 两个要点，都是踩过的：
    /// 1. `NSVisualEffectView` **直接**当 `contentView`。套一层带 `masksToBounds`
    ///    的父容器会让 `behindWindow` 合成被祖先裁剪掉，毛玻璃整块不出现。
    /// 2. 再给它的图层垫一层近乎不透明的底色当保险。毛玻璃是系统私有 backdrop
    ///    图层画的，一旦某台机器/某个外观下合成不出来，面板就会像用户截图那样
    ///    整片透明、背后文字全透上来。垫了底色最坏也只是「没有模糊」，而不是「看不见」。
    private static func makeBackdrop(size: NSSize, hosting: NSHostingView<AnyView>) -> NSView {
        let effect = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        effect.autoresizingMask = [.width, .height]
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 10
        effect.layer?.masksToBounds = true
        // 保险底色：正常情况被 backdrop 覆盖看不见，合成失败时兜住可读性
        effect.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.92).cgColor
        // 一圈极淡描边，和点状态栏出来的面板观感一致，也让面板边界在浅色背景上能看清
        effect.layer?.borderWidth = 0.5
        effect.layer?.borderColor = NSColor.separatorColor.cgColor

        hosting.frame = NSRect(origin: .zero, size: size)
        effect.addSubview(hosting)
        return effect
    }

    // MARK: - NSWindowDelegate

    func windowDidResignKey(_ notification: Notification) {
        guard Date().timeIntervalSince(shownAt) > 0.35 else { return }
        close()
    }

    // MARK: - 定位

    /// 状态栏图标的屏幕矩形。
    ///
    /// `NSStatusBarWindow` 会为每个历史状态项各留一个窗口（实测 7 个，只有 1 个宽度正常），
    /// 所以要挑 `frame.width > 1` 的那个。
    private static func statusItemRect() -> NSRect {
        for window in NSApp.windows where window.className.contains("StatusBar") {
            guard let item = window.value(forKey: "statusItem") as? NSStatusItem,
                  let buttonWindow = item.button?.window,
                  buttonWindow.frame.width > 1 else { continue }
            return buttonWindow.frame
        }
        if let screen = NSScreen.main {
            let visible = screen.visibleFrame
            return NSRect(x: visible.maxX - 40, y: visible.maxY, width: 28, height: 0)
        }
        return .zero
    }
}

/// 主页面板。
///
/// - `canBecomeKey = true`：不成为 key window 的话输入框收不到键盘。
/// - `canBecomeMain = false`：它是辅助面板，不该影响「哪个窗口是主窗口」的判断。
/// - 重写 `resignKey` 而不是只靠 delegate：`borderless` 窗口的 delegate 回调在某些
///   路径下不触发，两条都挂上更稳。
final class HomePanel: NSPanel {
    var onResignKey: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func resignKey() {
        super.resignKey()
        onResignKey?()
    }
}
