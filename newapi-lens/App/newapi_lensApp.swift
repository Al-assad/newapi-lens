//
//  newapi_lensApp.swift
//  newapi-lens
//
//  Created by Linying Assad on 2026/6/29.
//

import SwiftUI
#if os(macOS)
import AppKit
#endif

#if os(macOS)
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
#endif

@main
struct newapi_lensApp: App {
    #if os(macOS)
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #endif
    @StateObject private var store = LensStore()
    @AppStorage("appearanceMode") private var appearanceModeRawValue = AppAppearanceMode.system.rawValue

    private var appearanceMode: AppAppearanceMode {
        AppAppearanceMode(rawValue: appearanceModeRawValue) ?? .system
    }

    var body: some Scene {
        WindowGroup("NewAPI Lens", id: "main") {
            ContentView()
                .frame(minWidth: 680, minHeight: 820)
                .environmentObject(store)
                .preferredColorScheme(appearanceMode.colorScheme)
                .task {
                    await store.refresh()
                }
        }
        .defaultSize(width: 680, height: 820)
        .windowStyle(.hiddenTitleBar)

        MenuBarExtra("NewAPI Lens", systemImage: "chart.bar.xaxis") {
            MenuBarOverviewView()
                .environmentObject(store)
                .preferredColorScheme(appearanceMode.colorScheme)
        }
        .menuBarExtraStyle(.window)
    }
}
