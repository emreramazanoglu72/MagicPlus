//
//  LaunchAtLogin.swift
//  tabmenu
//

import Foundation
import ServiceManagement
import os

enum LaunchAtLogin {
    private static let logger = Logger(subsystem: "com.tabmenu", category: "LaunchAtLogin")

    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            logger.error("Failed to update login item: \(error.localizedDescription, privacy: .public)")
        }
    }
}
