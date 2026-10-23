import AppKit
import SwiftUI

/// A short notice next to the pointer when a read press does not start a read
/// (same text as last time, nothing captured, a press that stopped instead of
/// switching). The menu-bar status says the same thing, but nobody watches the
/// menu bar while pressing the shortcut, and with sounds muted the fail chime is
/// silent too, so without this a refused press looks like nothing happened.
///
/// The panel never becomes key or active and ignores the mouse: focus has to
/// stay in the user's app, or the next press would copy from Yap.
@MainActor
enum Notice {
    /// Readable so `--capturetest` can check it shows without taking focus.
    private(set) static var panel: NSPanel?
    private static var shown = 0

    static func show(_ title: String, seconds: Double = 3) {
        // VoiceOver hears it even if the panel is never looked at.
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: title,
                                        .priority: NSAccessibilityPriorityLevel.high.rawValue])

        let view = NoticeView(title: title)
        // Measured here, then fixed: with sizingOptions off (we size and place the
        // panel ourselves, see the HUD's note) the host's fittingSize reads 0x0.
        let size = NSHostingController(rootView: view).sizeThatFits(in: CGSize(width: 2000, height: 2000))
        let host = NSHostingView(rootView: view)
        host.sizingOptions = []
        host.frame = NSRect(origin: .zero, size: size)
        let p = panel ?? makePanel()
        panel = p
        p.contentView = host

        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        // Below and to the right of the pointer, where the eyes already are.
        let want = NSRect(x: mouse.x + 14, y: mouse.y - size.height - 18, width: size.width, height: size.height)
        let origin = HUDPlacement.onScreen(want, screens: screen.map { [$0.visibleFrame] } ?? [])
        p.setFrame(NSRect(origin: origin, size: size), display: true)
        p.alphaValue = 1
        p.orderFrontRegardless()

        shown += 1
        let mine = shown
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            guard mine == shown else { return }   // a newer notice owns the panel
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.25
                p.animator().alphaValue = 0
            }, completionHandler: {
                Task { @MainActor in if mine == shown { p.orderOut(nil) } }
            })
        }
    }

    private static func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: .zero, styleMask: [.nonactivatingPanel, .borderless],
                        backing: .buffered, defer: false)
        p.level = .statusBar
        p.isFloatingPanel = true
        p.hidesOnDeactivate = false
        p.ignoresMouseEvents = true
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        return p
    }
}

/// One line, the reason only: the notice is up for a few seconds, read at a
/// glance, so anything longer is not read (Lino, 2026-10-23).
struct NoticeView: View {
    let title: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.bubble.fill")
                .font(.system(size: 15))
                .foregroundStyle(Brand.violet)
                .accessibilityHidden(true)
            Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(1).fixedSize()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(Color.primary.opacity(0.12)))
    }
}
