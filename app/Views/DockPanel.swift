import AppKit
import ApplicationServices
import SwiftUI

// MARK: - Icon

/// The Dock icon: one neon ring per account, outermost first.
enum DockRings {
    struct Ring {
        let percent: Int?   // nil when there is no reading
        let dimmed: Bool
    }

    static func neon(_ percent: Int) -> NSColor {
        if percent >= 90 { return NSColor(red: 1.00, green: 0.23, blue: 0.42, alpha: 1) }
        if percent >= 70 { return NSColor(red: 1.00, green: 0.69, blue: 0.13, alpha: 1) }
        return NSColor(red: 0.13, green: 0.94, blue: 0.78, alpha: 1)
    }

    static func render(_ rings: [Ring]) -> NSImage {
        let size: CGFloat = 512
        return NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
            let tile = NSBezierPath(roundedRect: NSRect(x: 40, y: 40, width: 432, height: 432), xRadius: 96, yRadius: 96)
            NSGradient(colors: [NSColor(red: 0.05, green: 0.10, blue: 0.17, alpha: 1),
                                NSColor(red: 0.01, green: 0.02, blue: 0.04, alpha: 1)])?
                .draw(in: tile, relativeCenterPosition: NSPoint(x: 0, y: 0.1))
            NSColor(red: 0.13, green: 0.94, blue: 0.78, alpha: 0.28).setStroke()
            tile.lineWidth = 3
            tile.stroke()

            let center = NSPoint(x: size / 2, y: size / 2)
            let count = max(rings.count, 1)
            let outer: CGFloat = 170
            let stroke = min(30, (outer - 40) / CGFloat(count) * 0.62)
            let step = stroke * 1.55

            // Fine tick ring outside the data rings.
            NSColor(red: 0.13, green: 0.94, blue: 0.78, alpha: 0.35).setStroke()
            for t in 0..<60 {
                let angle = CGFloat(t) * 6 * .pi / 180
                let r0: CGFloat = outer + stroke / 2 + 10, r1 = r0 + (t % 5 == 0 ? 12 : 6)
                let tick = NSBezierPath()
                tick.move(to: NSPoint(x: center.x + r0 * cos(angle), y: center.y + r0 * sin(angle)))
                tick.line(to: NSPoint(x: center.x + r1 * cos(angle), y: center.y + r1 * sin(angle)))
                tick.lineWidth = 2
                tick.stroke()
            }

            for (i, ring) in rings.enumerated() {
                let radius = outer - CGFloat(i) * step
                guard radius > stroke else { break }
                let track = NSBezierPath()
                track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
                track.lineWidth = stroke
                NSColor(red: 0.47, green: 0.63, blue: 0.78, alpha: 0.14).setStroke()
                track.stroke()

                guard let percent = ring.percent else { continue }
                let color = ring.dimmed ? NSColor(white: 0.45, alpha: 1) : neon(percent)
                let fraction = CGFloat(min(max(percent, 1), 100)) / 100
                let arc = NSBezierPath()
                arc.appendArc(withCenter: center, radius: radius, startAngle: 90,
                              endAngle: 90 - 360 * fraction, clockwise: true)
                arc.lineWidth = stroke
                arc.lineCapStyle = .round
                NSGraphicsContext.saveGraphicsState()
                let glow = NSShadow()
                glow.shadowColor = color.withAlphaComponent(0.9)
                glow.shadowBlurRadius = 16
                glow.set()
                color.setStroke()
                arc.stroke()
                NSGraphicsContext.restoreGraphicsState()
            }
            return true
        }
    }
}

// MARK: - Hover panel

/// Shows the stats panel while the pointer is over the app's Dock icon.
///
/// macOS gives apps no hover event for their Dock tile, so the icon's frame
/// is read from the Dock through Accessibility and the pointer is watched
/// globally. Without Accessibility, clicking the icon still opens the panel.
final class DockHoverController {
    private let accounts: AccountsController
    private var panel: NSPanel?
    private var monitor: Any?
    private var iconFrame: NSRect?
    private var iconFrameReadAt = Date.distantPast
    private var hideWork: DispatchWorkItem?

    init(accounts: AccountsController) {
        self.accounts = accounts
    }

    func start() {
        guard monitor == nil else { return }
        // Hover needs Accessibility to find the icon; ask once if it is off.
        if !AXIsProcessTrusted() {
            AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in
            self?.pointerMoved()
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        hide()
    }

    /// A click lands on the icon, so the pointer marks where it is even
    /// without Accessibility.
    func toggle() {
        if panel?.isVisible == true { hide(); return }
        let point = NSEvent.mouseLocation
        show(at: currentIconFrame(force: true) ?? NSRect(x: point.x - 24, y: point.y - 24, width: 48, height: 48))
    }

    private func pointerMoved() {
        let point = NSEvent.mouseLocation
        guard let icon = currentIconFrame() else { return }
        var region = icon.insetBy(dx: -2, dy: -2)
        if let panel, panel.isVisible { region = region.union(panel.frame) }

        if region.contains(point) {
            hideWork?.cancel()
            if panel?.isVisible != true, icon.contains(point) { show(at: icon) }
        } else if panel?.isVisible == true, hideWork == nil {
            let work = DispatchWorkItem { [weak self] in self?.hide() }
            hideWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
        }
    }

    private func show(at icon: NSRect?) {
        hideWork?.cancel()
        hideWork = nil
        let panel = self.panel ?? makePanel()
        self.panel = panel
        let size = panel.contentView?.fittingSize ?? NSSize(width: 300, height: 300)
        panel.setContentSize(size)
        panel.setFrameOrigin(origin(for: size, near: icon))
        panel.orderFrontRegardless()
    }

    private func hide() {
        hideWork?.cancel()
        hideWork = nil
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 300),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: true)
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.assistiveTechHighWindow)))
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.contentView = NSHostingView(rootView: DockStatsView(accounts: accounts))
        return panel
    }

    /// Above a bottom Dock, beside a side Dock, kept on screen. Sits right on
    /// the icon so it covers the Dock's own name label, which apps cannot change.
    private func origin(for size: NSSize, near icon: NSRect?) -> NSPoint {
        let screen = icon.flatMap { f in NSScreen.screens.first { $0.frame.intersects(f) } } ?? NSScreen.main
        let bounds = screen?.visibleFrame ?? .zero
        guard let icon else {
            return NSPoint(x: bounds.midX - size.width / 2, y: bounds.minY + 12)
        }
        let full = screen?.frame ?? bounds
        var origin: NSPoint
        if icon.minX - full.minX < 160 {
            origin = NSPoint(x: icon.maxX + 4, y: icon.midY - size.height / 2)
        } else if full.maxX - icon.maxX < 160 {
            origin = NSPoint(x: icon.minX - size.width - 4, y: icon.midY - size.height / 2)
        } else {
            origin = NSPoint(x: icon.midX - size.width / 2, y: icon.maxY + 4)
        }
        origin.x = min(max(origin.x, bounds.minX + 8), bounds.maxX - size.width - 8)
        origin.y = min(max(origin.y, bounds.minY + 8), bounds.maxY - size.height - 8)
        return origin
    }

    // MARK: Dock icon frame

    private func currentIconFrame(force: Bool = false) -> NSRect? {
        if force || Date().timeIntervalSince(iconFrameReadAt) > 2 {
            iconFrame = Self.readIconFrame()
            iconFrameReadAt = Date()
        }
        return iconFrame
    }

    private static func readIconFrame() -> NSRect? {
        guard AXIsProcessTrusted(),
              let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else { return nil }
        let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Claude Usage Multi"
        let app = AXUIElementCreateApplication(dock.processIdentifier)
        for list in children(of: app) where string(list, kAXRoleAttribute) == kAXListRole {
            for item in children(of: list) where string(item, kAXTitleAttribute) == name {
                guard let position = value(item, kAXPositionAttribute, CGPoint.zero, .cgPoint),
                      let size = value(item, kAXSizeAttribute, CGSize.zero, .cgSize) else { return nil }
                // Accessibility uses a top-left origin on the primary screen.
                let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
                return NSRect(x: position.x, y: primaryHeight - position.y - size.height,
                              width: size.width, height: size.height)
            }
        }
        return nil
    }

    private static func children(of element: AXUIElement) -> [AXUIElement] {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &ref) == .success else { return [] }
        return ref as? [AXUIElement] ?? []
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success else { return nil }
        return ref as? String
    }

    private static func value<T>(_ element: AXUIElement, _ attribute: String, _ initial: T, _ type: AXValueType) -> T? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success,
              let ref, CFGetTypeID(ref) == AXValueGetTypeID() else { return nil }
        var result = initial
        return AXValueGetValue(ref as! AXValue, type, &result) ? result : nil
    }
}

// MARK: - Panel content

struct DockStatsView: View {
    @ObservedObject var accounts: AccountsController

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Claude usage")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                if accounts.showsDailyBudget {
                    Text("Today \(accounts.dailyBudget.spent) of \(Int(accounts.dailyBudget.allowance.rounded()))")
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundColor(.secondary)
                }
            }
            VStack(spacing: 6) {
                ForEach(accounts.managers, id: \.account.id) { manager in
                    DockStatsCard(manager: manager)
                }
            }
        }
        .padding(12)
        .frame(width: 280)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.12)))
        .environment(\.colorScheme, .dark)
    }
}

/// One account: name and its main percent, then one line per limit.
private struct DockStatsCard: View {
    @ObservedObject var manager: UsageManager

    private struct Limit: Identifiable {
        let id: String
        let value: Double
        let resetsAt: Date?
    }

    private var limits: [Limit] {
        var out: [Limit] = []
        if manager.hasSessionLimit { out.append(Limit(id: "5h", value: manager.sessionPercentage, resetsAt: manager.sessionResetsAt)) }
        out.append(Limit(id: "Week", value: manager.weeklyPercentage, resetsAt: manager.weeklyResetsAt))
        if manager.hasWeeklySonnet { out.append(Limit(id: "Sonnet", value: manager.weeklySonnetPercentage, resetsAt: manager.weeklySonnetResetsAt)) }
        return out
    }

    /// Colour only when it needs attention, so the one account in trouble stands out.
    private func emphasis(_ percent: Int) -> Color {
        percent >= 70 ? Color(nsColor: DockRings.neon(percent)) : .primary
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(manager.account.emoji).font(.system(size: 13))
                Text(manager.account.displayName)
                    .font(.system(size: 12, weight: .medium))
                Spacer()
                if manager.needsReauth {
                    Text("Signed out").font(.system(size: 11)).foregroundColor(.secondary)
                } else if manager.hasFetchedData {
                    let percent = manager.bindingLimit.percent
                    Text("\(percent)%")
                        .font(.system(size: 15, weight: .semibold).monospacedDigit())
                        .foregroundColor(emphasis(percent))
                }
            }
            if manager.hasFetchedData && !manager.needsReauth {
                ForEach(limits) { limit in
                    HStack(spacing: 8) {
                        Text(limit.id)
                            .frame(width: 40, alignment: .leading)
                        UsageBar(value: limit.value, color: Color(nsColor: DockRings.neon(Int(limit.value * 100))))
                            .frame(height: 5)
                        Text(limit.resetsAt.flatMap { formatCountdown(to: $0) } ?? "")
                            .frame(width: 50, alignment: .trailing)
                    }
                    .font(.system(size: 10.5).monospacedDigit())
                    .foregroundColor(.secondary)
                }
            }
        }
        .padding(10)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
        .opacity(manager.needsReauth ? 0.55 : 1)
    }
}
