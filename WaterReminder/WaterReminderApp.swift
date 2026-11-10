import SwiftUI
import ServiceManagement

/// 开机自启动管理（macOS 13+ 原生 SMAppService）
enum LaunchAtLogin {
    /// 系统登录项的真实状态
    static var status: SMAppService.Status {
        SMAppService.mainApp.status
    }

    /// 开关应显示的「已开启」状态。
    ///
    /// 注意 `.requiresApproval`：用户已经在系统设置里同意了这个登录项，
    /// 但还需要在「系统设置 → 通用 → 登录项」里手动放行。旧实现只认 `.enabled`，
    /// 于是这个状态下 UI 显示「关闭」，而 register() 早已成功 —— 用户再点一次
    /// 会抛 already-registered 被静默吞掉，从界面上永远打不开。
    static var isEnabled: Bool {
        let s = status
        return s == .enabled || s == .requiresApproval
    }

    /// 是否处于「已注册但等待用户在系统设置里放行」的状态，需要提示用户去手动确认
    static var requiresApproval: Bool {
        status == .requiresApproval
    }

    static var errorDescription: String? {
        switch status {
        case .notRegistered, .enabled:
            return nil
        case .requiresApproval:
            return "已在「系统设置 → 通用 → 登录项」中注册，需要你手动允许它开机启动。"
        case .notFound:
            return "系统找不到本应用，请把它放到「应用程序」文件夹后再试。"
        @unknown default:
            return "系统登录项状态未知。"
        }
    }

    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Bool {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return true
        } catch {
            print("设置开机自启动失败: \(error.localizedDescription)")
            return false
        }
    }
}

/// 处理「第二次启动」的两条路径。
///
/// 路径一（LaunchServices 已是单实例）：`open` 一个正在跑的 App 时系统根本不会起
/// 第二个进程，直接调 `applicationShouldHandleReopen` —— 这里把主页打开。
/// 路径二（真的起了第二个进程，例如从终端跑二进制、`open -n`、装了两份 App）：
/// 第二份在 `App.init` 里就被 flock 挡住并退出，退出前发一条分布式通知，
/// 由这里的观察者接到后打开主页。
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        DistributedNotificationCenter.default().addObserver(
            forName: SingleInstanceGuard.showHomeRequest,
            object: nil,
            queue: .main
        ) { _ in
            HomePanelController.shared.show()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        HomePanelController.shared.show()
        // 返回 false 表示「我已经处理了」，不让 AppKit 再按默认逻辑折腾窗口
        return false
    }
}

@main
struct WaterReminderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var settings = AppSettings.shared

    init() {
        // 放在最前面：第二个实例在这里就要退掉，不能先去注册通知、开定时器
        guard SingleInstanceGuard.acquire() else {
            SingleInstanceGuard.requestShowHome()
            // 给分布式通知一点时间送出去，再退出；否则会出现
            // 「点了图标什么都没发生」的观感
            Thread.sleep(forTimeInterval: 0.3)
            exit(0)
        }

        ReminderManager.shared.requestAuthorization()
        FullScreenAlertManager.shared.start()
    }

    var body: some Scene {
        MenuBarExtra {
            MenuView()
                .environmentObject(settings)
        } label: {
            Image(systemName: settings.isEnabled ? "drop.fill" : "drop")
                .foregroundColor(settings.isEnabled ? .blue : .secondary)
        }
        .menuBarExtraStyle(.window)
    }
}
