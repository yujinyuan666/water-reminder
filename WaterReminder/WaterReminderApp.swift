import SwiftUI
import ServiceManagement

/// 开机自启动管理（macOS 13+ 原生 SMAppService）
enum LaunchAtLogin {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
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
