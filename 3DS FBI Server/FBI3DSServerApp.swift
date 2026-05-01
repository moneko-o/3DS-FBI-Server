//
//  FBI3DSServerApp.swift
//  3DS FBI Server
//

import SwiftUI

@main
struct FBI3DSServerApp: App {
    @NSApplicationDelegateAdaptor(MacAppDelegate.self) private var appDelegate
    @StateObject private var model = AppViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .onAppear {
                    TransparentChrome.configureWindows()
                    appDelegate.onOpenFiles = { model.addDroppedFileURLs($0) }
                }
                .onOpenURL { url in
                    model.addDroppedFileURLs([url])
                }
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .appInfo) {}
            CommandGroup(replacing: .help) {}
        }
    }
}
