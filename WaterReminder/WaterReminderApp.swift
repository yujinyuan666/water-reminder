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

@main
struct WaterReminderApp: App {
    @StateObject private var settings = AppSettings.shared

    init() {
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
