//
//  MacAppDelegate.swift
//  3DS FBI Server
//

import AppKit

@MainActor
final class MacAppDelegate: NSObject, NSApplicationDelegate {
    var onOpenFiles: (([URL]) -> Void)?

    func application(_ sender: NSApplication, open urls: [URL]) {
        onOpenFiles?(urls)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        TransparentChrome.configureWindows()
        NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in
                TransparentChrome.configureWindows()
            }
        }
    }
}
