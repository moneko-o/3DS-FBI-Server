//
//  LiquidGlassChrome.swift
//  3DS FBI Server
//

import AppKit
import SwiftUI

enum LiquidGlassChrome {
    static let corner: CGFloat = 12
}

extension View {
    func liquidGlassRoundedRect() -> some View {
        glassEffect(.clear, in: RoundedRectangle(cornerRadius: LiquidGlassChrome.corner, style: .continuous))
    }

    @ViewBuilder
    func consoleRowGlass(selected: Bool) -> some View {
        if selected { glassEffect(.clear, in: Capsule(style: .continuous)) } else { self }
    }
}

struct WindowBackdropBlurView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .popover
        v.blendingMode = .behindWindow
        v.state = .active
        v.isEmphasized = true
        v.autoresizingMask = [.width, .height]
        return v
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

@MainActor
enum TransparentChrome {
    static func shouldApplyLiquidChrome(to window: NSWindow) -> Bool {
        if window is NSPanel { return false }
        let t = window.title
        if t.localizedCaseInsensitiveContains("about") || t.contains("关于") { return false }
        return true
    }

    static func configureWindows() {
        for w in NSApplication.shared.windows where shouldApplyLiquidChrome(to: w) {
            w.isOpaque = false
            w.backgroundColor = .clear
            w.titlebarAppearsTransparent = true
            if !w.styleMask.contains(.fullSizeContentView) { w.styleMask.insert(.fullSizeContentView) }
        }
    }
}
