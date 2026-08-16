//
//  tabmenuApp.swift
//  tabmenu
//
//  Created by Emre Ramazanoğlu on 14.08.2026.
//

import SwiftUI

@main
struct tabmenuApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // Every window tabmenu shows is created by an AppKit controller, so its presentation
        // and lifetime stay explicit. This empty scene exists only because `App` requires one;
        // the Settings menu item is redirected to our own window in `AppDelegate`.
        Settings { EmptyView() }
    }
}
