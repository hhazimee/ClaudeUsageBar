import SwiftUI
import AppKit
import WebKit
import Carbon
import Security
import ServiceManagement
import UserNotifications

// Secondary text: system gray in dark; darker in light, where the vibrant
// ~50% gray over the white popover backing reads as washed out.
extension Color {
    static let secondaryText = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? .secondaryLabelColor
            : NSColor(white: 0.24, alpha: 1.0) // opaque: vibrancy washes out alpha grays
    })
}

// Deterministic usage bar: the native linear ProgressView ignores .tint() in
// light (aqua) and vibrant rendering and falls back to accent blue.
struct UsageBar: View {
    let value: Double
    let color: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.12))
                Capsule()
                    .fill(color)
                    .frame(width: max(0, min(1, value)) * geo.size.width)
            }
        }
        .frame(height: 6)
    }
}

// Main entry point
class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    var statusItem: NSStatusItem!
    var popover: NSPopover!
    var accounts: AccountsController!
    var statusManager: StatusManager!
    var updateManager: UpdateManager!
    var eventMonitor: Any?
    var hotKeyRef: EventHotKeyRef?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Ask once; macOS remembers the answer per bundle id.
        UNUserNotificationCenter.current().delegate = self
        Notifier.requestAuthorization()

        // Create status bar item with variable length for compact display
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            // Placeholder until the accounts controller renders the real badges.
            button.image = createSparkIcon(color: .secondaryLabelColor)
            button.action = #selector(handleClick)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.target = self

            // Force the button to be visible
            button.appearsDisabled = false
            button.isEnabled = true
        }

        // Initialize managers
        accounts = AccountsController()
        accounts.delegate = self
        accounts.refreshStatusBar()
        statusManager = StatusManager()
        updateManager = UpdateManager()

        // Create popover
        popover = NSPopover()
        // Initial guess; SwiftUI's intrinsic size (capped at 600) will drive the actual size.
        popover.contentSize = NSSize(width: 360, height: 320)

        NotificationCenter.default.addObserver(
            forName: .usagePopoverHeightChanged,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self = self,
                  let height = note.userInfo?["height"] as? CGFloat else { return }
            let newSize = NSSize(width: 360, height: height)
            guard abs(self.popover.contentSize.height - height) > 1 else { return }
            self.popover.contentSize = newSize
        }
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: UsageView(
            accounts: accounts,
            statusManager: statusManager,
            updateManager: updateManager
        ))

        // Appearance preference: "system" (default) tracks the macOS light/dark
        // setting; "dark"/"light" force one (dark was hard-forced in v1.3.2 and
        // users complained about losing light mode). Applied after the popover
        // exists so both NSApp and the popover get styled.
        applyAppearancePreference()

        // Re-apply when macOS flips light/dark, so a forced mode that matches
        // the system switches back to the native (inherited) rendering.
        DistributedNotificationCenter.default.addObserver(
            forName: NSNotification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil, queue: .main
        ) { [weak self] _ in
            // The defaults key can lag the notification; re-resolve a tick later.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                self?.applyAppearancePreference()
            }
        }

        // Fetch initial data
        accounts.fetchAll()
        statusManager.fetch()
        updateManager.fetch()

        // Usage + Anthropic status are time-sensitive — poll every 5 min.
        Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { _ in
            self.accounts.fetchAll()
            self.statusManager.fetch()
        }

        // Countdowns move once a minute; no point redrawing faster.
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            self.accounts.tick()
        }

        // App updates are infrequent (new release at most weekly) — poll every 3 hours.
        Timer.scheduledTimer(withTimeInterval: 3 * 3600, repeats: true) { _ in
            self.updateManager.fetch()
        }

        // Set up Cmd+U keyboard shortcut
        setupKeyboardShortcut()
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // An accessory app is still "active" to macOS, which suppresses banners
        // by default. Ask for them explicitly.
        completionHandler([.banner, .sound])
    }

    func applyAppearancePreference() {
        let mode = UserDefaults.standard.string(forKey: "appearance_mode") ?? "system"
        let systemIsDark = UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
        let isDark: Bool
        switch mode {
        case "dark":  isDark = true
        case "light": isDark = false
        default:      isDark = systemIsDark
        }
        // Always set an explicit, resolved appearance ("System" resolves to the
        // current macOS setting) so every mode uses the same rendering path:
        // inherited "vibrant" rendering drops ProgressView tints (bars turn
        // accent-blue) and shades colors slightly differently, which made
        // System and Dark look different. Set on the popover too — it doesn't
        // reliably restyle from NSApp.appearance alone once created.
        let appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
        NSApp.appearance = appearance
        popover?.appearance = appearance
    }

    func setupKeyboardShortcut() {
        // Check Accessibility permissions
        checkAccessibilityPermissions()

        // Only register if user has the shortcut enabled
        if accounts.shortcutEnabled {
            registerGlobalHotKey()
        }
    }

    func setShortcutEnabled(_ enabled: Bool) {
        if enabled {
            registerGlobalHotKey()
        } else {
            unregisterGlobalHotKey()
        }
    }

    func checkAccessibilityPermissions() {
        // Check if app has Accessibility permissions
        let trusted = AXIsProcessTrusted()

        if !trusted {
            NSLog("⚠️ Accessibility permissions not granted")
            // Show alert to guide user
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                let alert = NSAlert()
                alert.messageText = "Accessibility Permission Required"
                alert.informativeText = "ClaudeUsageBar needs Accessibility permission to use the Cmd+U keyboard shortcut.\n\nPlease enable it in:\nSystem Settings → Privacy & Security → Accessibility"
                alert.alertStyle = .informational
                alert.addButton(withTitle: "Open System Settings")
                alert.addButton(withTitle: "Skip for Now")

                let response = alert.runModal()
                if response == .alertFirstButtonReturn {
                    // Open System Settings
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                }
            }
        } else {
            NSLog("✅ Accessibility permissions granted")
        }
    }

    func registerGlobalHotKey() {
        // Guard against double registration
        if hotKeyRef != nil { return }

        var hotKeyID = EventHotKeyID()
        // Use simple numeric ID instead of FourCharCode
        hotKeyID.signature = 0x436C5542 // 'ClUB' as hex
        hotKeyID.id = 1

        // Cmd+U key code
        let keyCode: UInt32 = 32 // 'U' key
        let modifiers: UInt32 = UInt32(cmdKey)

        // Create event spec for hotkey
        var eventType = EventTypeSpec()
        eventType.eventClass = OSType(kEventClassKeyboard)
        eventType.eventKind = OSType(kEventHotKeyPressed)

        // Install event handler
        var handler: EventHandlerRef?
        let callback: EventHandlerUPP = { (nextHandler, event, userData) -> OSStatus in
            // Get the AppDelegate instance
            let appDelegate = Unmanaged<AppDelegate>.fromOpaque(userData!).takeUnretainedValue()

            // Toggle popover
            DispatchQueue.main.async {
                appDelegate.togglePopover()
            }

            return noErr
        }

        // Install the handler
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), callback, 1, &eventType, selfPtr, &handler)

        // Register the hotkey
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)

        if status == noErr {
            NSLog("✅ Registered Cmd+U hotkey successfully")
        } else {
            NSLog("❌ Failed to register hotkey, status: \(status)")
        }
    }

    func unregisterGlobalHotKey() {
        if let hotKey = hotKeyRef {
            UnregisterEventHotKey(hotKey)
            hotKeyRef = nil
            NSLog("🗑️ Unregistered Cmd+U hotkey")
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        unregisterGlobalHotKey()
    }

    @objc func quitApp() {
        NSApplication.shared.terminate(nil)
    }

    @objc func togglePopover() {
        if popover.isShown {
            closePopover()
        } else {
            openPopover()
        }
    }

    @objc func handleClick() {
        guard let event = NSApp.currentEvent else { return }

        if event.type == .rightMouseUp {
            // Right click - show menu
            let menu = NSMenu()
            let toggleItem = NSMenuItem(title: "Toggle Usage (⌘U)", action: #selector(togglePopover), keyEquivalent: "u")
            toggleItem.keyEquivalentModifierMask = .command
            menu.addItem(toggleItem)
            menu.addItem(NSMenuItem.separator())
            menu.addItem(NSMenuItem(title: "Quit ClaudeUsageBar", action: #selector(quitApp), keyEquivalent: "q"))
            statusItem.menu = menu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
        } else {
            // Left click - toggle popover
            togglePopover()
        }
    }

    func openPopover() {
        if let button = statusItem.button {
            // Force UI refresh by updating percentages
            DispatchQueue.main.async {
                self.accounts.managers.forEach { $0.updatePercentages() }
            }

            // An LSUIElement app is never "active", so its popover window never
            // becomes key and the cookie field cannot be typed into or pasted
            // into. Activate first, then make the popover window key.
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKeyAndOrderFront(nil)

            // Add event monitor to detect clicks outside the popover
            eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                if self?.popover.isShown == true {
                    self?.closePopover()
                }
            }
        }
    }

    func closePopover() {
        popover.performClose(nil)

        // Remove event monitor
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }

    /// Colour for a usage percentage. This is the severity channel: it is the
    /// only thing in the menu bar that changes colour with usage, so a colour
    /// shift always means "usage", never "which account".
    static func severityColor(for percentage: Int) -> NSColor {
        if percentage < 70 {
            return NSColor(red: 0.13, green: 0.68, blue: 0.33, alpha: 1.0) // green
        } else if percentage < 90 {
            return NSColor(red: 0.90, green: 0.55, blue: 0.0, alpha: 1.0)  // amber, legible on light
        } else {
            return NSColor(red: 0.94, green: 0.21, blue: 0.17, alpha: 1.0) // red
        }
    }

    /// Draws every account into the menu bar as "<emoji> <percent>", with the
    /// percentage carrying the severity colour. Identity is the emoji, so the
    /// two signals never collide.
    func renderStatusBar(for managers: [UsageManager]) {
        guard let button = statusItem.button else { return }
        let showCountdown = accounts?.showCountdown ?? false

        let title = NSMutableAttributedString()
        let font = NSFont.systemFont(ofSize: 12, weight: .medium)

        if managers.isEmpty {
            button.image = createSparkIcon(color: .secondaryLabelColor)
            button.attributedTitle = NSAttributedString(string: "")
            return
        }

        for (index, manager) in managers.enumerated() {
            if index > 0 {
                title.append(NSAttributedString(string: "  "))
            }

            title.append(NSAttributedString(
                string: manager.account.emoji + " ",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 11),
                    .foregroundColor: manager.needsReauth
                        ? NSColor.labelColor.withAlphaComponent(0.4)
                        : NSColor.labelColor
                ]
            ))

            let hasData = manager.hasFetchedData
            let binding = manager.bindingLimit
            // "W" only when the weekly cap is the binding one, so the usual
            // case stays as short as it was with a single limit.
            let marker = binding.kind == .weekly ? "W" : ""
            title.append(NSAttributedString(
                string: hasData ? "\(marker)\(binding.percent)%" : "--",
                attributes: [
                    .font: font,
                    .foregroundColor: hasData
                        ? AppDelegate.severityColor(for: binding.percent)
                        : NSColor.secondaryLabelColor
                ]
            ))

            // Time until the binding limit frees up, when enabled.
            if showCountdown, hasData,
               let resetsAt = manager.bindingResetsAt,
               let remaining = formatCountdown(to: resetsAt) {
                title.append(NSAttributedString(
                    string: " \u{00B7} \(remaining)",
                    attributes: [
                        .font: NSFont.systemFont(ofSize: 11),
                        .foregroundColor: NSColor.secondaryLabelColor
                    ]
                ))
            }
        }

        // The per-account emoji replaces the single global spark.
        button.image = nil
        button.title = ""
        button.attributedTitle = title
    }

    func createSparkIcon(color: NSColor) -> NSImage {
        let size = NSSize(width: 16, height: 16)
        let image = NSImage(size: size)

        image.lockFocus()

        // SVG path: M8 1L9 6L13 3L10 7L15 8L10 9L13 13L9 10L8 15L7 10L3 13L6 9L1 8L6 7L3 3L7 6L8 1Z
        let path = NSBezierPath()
        path.move(to: NSPoint(x: 8, y: 1))
        path.line(to: NSPoint(x: 9, y: 6))
        path.line(to: NSPoint(x: 13, y: 3))
        path.line(to: NSPoint(x: 10, y: 7))
        path.line(to: NSPoint(x: 15, y: 8))
        path.line(to: NSPoint(x: 10, y: 9))
        path.line(to: NSPoint(x: 13, y: 13))
        path.line(to: NSPoint(x: 9, y: 10))
        path.line(to: NSPoint(x: 8, y: 15))
        path.line(to: NSPoint(x: 7, y: 10))
        path.line(to: NSPoint(x: 3, y: 13))
        path.line(to: NSPoint(x: 6, y: 9))
        path.line(to: NSPoint(x: 1, y: 8))
        path.line(to: NSPoint(x: 6, y: 7))
        path.line(to: NSPoint(x: 3, y: 3))
        path.line(to: NSPoint(x: 7, y: 6))
        path.close()

        color.setFill()
        path.fill()

        image.unlockFocus()
        image.isTemplate = false

        return image
    }
}

// NSColor extension for hex conversion
extension NSColor {
    /// Parses "#RRGGBB". Returns nil rather than guessing on bad input.
    convenience init?(hex: String) {
        var value = hex.trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("#") { value.removeFirst() }
        guard value.count == 6, let rgb = UInt32(value, radix: 16) else { return nil }
        self.init(
            srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255.0,
            green: CGFloat((rgb >> 8) & 0xFF) / 255.0,
            blue: CGFloat(rgb & 0xFF) / 255.0,
            alpha: 1.0
        )
    }

    var hexString: String {
        guard let rgbColor = self.usingColorSpace(.deviceRGB) else {
            return "#000000"
        }
        let r = Int(rgbColor.redComponent * 255)
        let g = Int(rgbColor.greenComponent * 255)
        let b = Int(rgbColor.blueComponent * 255)
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}

// Main entry point
@main
struct Main {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

// MARK: - Notifications

/// Delivers notifications through UserNotifications.
///
/// The app previously used NSUserNotification, which macOS 11 deprecated and
/// macOS 13+ ignores: `deliver` accepts the call and drops it, with no error,
/// so every usage alert failed silently.
enum Notifier {
    private(set) static var authorizationStatus: UNAuthorizationStatus = .notDetermined

    static func requestAuthorization(completion: (() -> Void)? = nil) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            // An ad-hoc signed app cannot show the permission prompt and reports
            // an error here, yet notifications still deliver once the app is
            // registered in Notification Center. So this is informational: the
            // real test is whether `add` succeeds.
            if let error = error {
                NSLog("🔔 Authorization prompt unavailable (\(error.localizedDescription)); delivery may still work")
            } else {
                NSLog("🔔 Notification authorization granted: \(granted)")
            }
            refreshStatus(completion: completion)
        }
    }

    static func refreshStatus(completion: (() -> Void)? = nil) {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            DispatchQueue.main.async {
                authorizationStatus = settings.authorizationStatus
                NSLog("🔔 Notification authorization status: \(settings.authorizationStatus.rawValue)")
                completion?()
            }
        }
    }

    static func send(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        // A nil trigger delivers immediately.
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                NSLog("❌ Notification failed: \(error.localizedDescription)")
            } else {
                NSLog("📬 Notification delivered: \(title) - \(body)")
            }
        }
    }
}

// MARK: - Accounts

/// One Claude login the app monitors.
///
/// Identity is carried by the emoji (a shape) and severity by colour, so the
/// two never compete for the same pixels in the menu bar. The account's own
/// colour is used in the popup, where there is room for it to mean something.
struct Account: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String
    var emoji: String
    var colorHex: String

    // MARK: Credentials
    //
    // Nothing secret lives here. Tokens and the session cookie are in the
    // account's keychain item, addressed by `id`. The fields below are only
    // what the UI needs to draw the account without opening the keychain.
    // Both are non-optional with a default, so accounts saved before these
    // existed need the custom decoder below: the synthesized one throws
    // keyNotFound for a missing non-optional key rather than using the default.

    /// True once the account has signed in. Kept here so a row can be drawn
    /// without a keychain read on every SwiftUI update.
    var hasOAuth: Bool = false

    /// Same, for whether a session cookie is stored.
    var hasCookie: Bool = false

    /// Email the account's grant resolved to, shown on its row.
    var accountEmail: String? = nil

    // Legacy fields. Decoded so accounts saved before the keychain move can be
    // migrated, then blanked. Nothing reads them after `migrateSecretsToKeychain`.
    var cookie: String = ""
    var oauthToken: String? = nil
    var keychainService: String? = nil
    var keychainAccount: String? = nil

    init(
        id: UUID = UUID(),
        name: String,
        emoji: String,
        colorHex: String,
        hasOAuth: Bool = false,
        hasCookie: Bool = false,
        accountEmail: String? = nil,
        cookie: String = "",
        oauthToken: String? = nil,
        keychainService: String? = nil,
        keychainAccount: String? = nil
    ) {
        self.id = id
        self.name = name
        self.emoji = emoji
        self.colorHex = colorHex
        self.hasOAuth = hasOAuth
        self.hasCookie = hasCookie
        self.accountEmail = accountEmail
        self.cookie = cookie
        self.oauthToken = oauthToken
        self.keychainService = keychainService
        self.keychainAccount = keychainAccount
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, emoji, colorHex, hasOAuth, hasCookie, accountEmail
        case cookie, oauthToken, keychainService, keychainAccount
    }

    // Every key but `name`/`emoji`/`colorHex` may be absent: an account saved
    // by an older build lacks `hasOAuth`/`hasCookie`, and one saved by this
    // build lacks whichever legacy fields it never had.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decode(String.self, forKey: .name)
        emoji = try container.decode(String.self, forKey: .emoji)
        colorHex = try container.decode(String.self, forKey: .colorHex)
        hasOAuth = try container.decodeIfPresent(Bool.self, forKey: .hasOAuth) ?? false
        hasCookie = try container.decodeIfPresent(Bool.self, forKey: .hasCookie) ?? false
        accountEmail = try container.decodeIfPresent(String.self, forKey: .accountEmail)
        cookie = try container.decodeIfPresent(String.self, forKey: .cookie) ?? ""
        oauthToken = try container.decodeIfPresent(String.self, forKey: .oauthToken)
        keychainService = try container.decodeIfPresent(String.self, forKey: .keychainService)
        keychainAccount = try container.decodeIfPresent(String.self, forKey: .keychainAccount)
    }

    static let palette: [String] = [
        "#3B82F6", // blue
        "#8B5CF6", // violet
        "#EC4899", // pink
        "#F97316", // orange
        "#14B8A6", // teal
        "#84CC16"  // lime
    ]

    static let emojiChoices: [String] = [
        "\u{1F3E2}", "\u{1F3E0}", "\u{1F4BC}", "\u{1F9EA}", "\u{1F680}", "\u{1F393}",
        "\u{1F419}", "\u{1F98A}", "\u{1F431}", "\u{2B50}", "\u{1F535}", "\u{1F7E3}"
    ]

    /// A fresh account pre-styled so two new accounts never look alike.
    static func makeDefault(index: Int) -> Account {
        Account(
            name: "Account \(index + 1)",
            emoji: emojiChoices[index % emojiChoices.count],
            colorHex: palette[index % palette.count]
        )
    }

    var color: Color { Color(nsColor: nsColor) }

    var nsColor: NSColor {
        NSColor(hex: colorHex) ?? NSColor.controlAccentColor
    }

    /// What the account is called when the user has not named it.
    var displayName: String {
        name.trimmingCharacters(in: .whitespaces).isEmpty ? "Untitled" : name
    }
}

/// Persists the account list, and migrates the single-cookie setup that
/// predates multi-account support.
enum AccountStore {
    private static let key = "claude_accounts"
    private static let legacyCookieKey = "claude_session_cookie"

    /// The upstream app's preferences domain. This fork uses its own bundle id
    /// so it can coexist with an installed ClaudeUsageBar (and so macOS grants
    /// it notification permission of its own), which means the accounts live in
    /// a different domain and have to be carried across once.
    private static let upstreamDomain = "com.claude.usagebar"

    static func load(store: CredentialStore = CredentialStore()) -> [Account] {
        var accounts = loadFromDefaults()
        migrateSecretsToKeychain(&accounts, store: store)
        return accounts
    }

    /// Moves cookies and pasted setup tokens out of the preferences plist and
    /// into each account's keychain item, once.
    ///
    /// Accounts bound to a Claude Code login lose the binding: that token
    /// belongs to the CLI, and refreshing it would rotate the CLI's own
    /// refresh token and sign it out. Those accounts have to sign in again.
    static func migrateSecretsToKeychain(_ accounts: inout [Account], store: CredentialStore) {
        var changed = false

        for index in accounts.indices {
            var account = accounts[index]
            let hadPlaintext = !account.cookie.isEmpty || !(account.oauthToken ?? "").isEmpty
            let hadBinding = account.keychainService != nil
            guard hadPlaintext || hadBinding else { continue }

            var credential = store.load(account.id) ?? StoredCredential()

            if !account.cookie.isEmpty, (credential.cookie ?? "").isEmpty {
                credential.cookie = account.cookie
            }
            // A setup token is long-lived and needs no refresh, so it becomes
            // an OAuth grant with no refresh token and no expiry.
            if let token = account.oauthToken, !token.isEmpty, credential.oauth == nil {
                credential.oauth = OAuthTokens(accessToken: token, email: account.accountEmail)
            }

            do {
                try store.save(credential, for: account.id)
            } catch {
                NSLog("\u{274C} Could not move '\(account.displayName)' credentials to the keychain: \(error)")
                continue
            }

            account.hasOAuth = credential.oauth != nil
            account.hasCookie = !(credential.cookie ?? "").isEmpty
            account.cookie = ""
            account.oauthToken = nil
            account.keychainService = nil
            account.keychainAccount = nil
            accounts[index] = account
            changed = true

            if hadBinding {
                NSLog("\u{1F511} '\(account.displayName)' was bound to a Claude Code login and needs to sign in again")
            }
        }

        if changed { save(accounts) }
    }

    private static func loadFromDefaults() -> [Account] {
        if let data = UserDefaults.standard.data(forKey: key),
           let accounts = try? JSONDecoder().decode([Account].self, from: data),
           !accounts.isEmpty {
            return accounts
        }

        if let migrated = migrateFromUpstream() {
            save(migrated)
            return migrated
        }

        // Nothing to carry over: start with one blank account.
        let first = Account.makeDefault(index: 0)
        save([first])
        return [first]
    }

    /// Pulls accounts (or a single legacy cookie) out of the upstream domain.
    private static func migrateFromUpstream() -> [Account]? {
        // Same-user, non-sandboxed: another app's domain is readable directly.
        guard let upstream = UserDefaults(suiteName: upstreamDomain) else { return nil }

        if let data = upstream.data(forKey: key),
           let accounts = try? JSONDecoder().decode([Account].self, from: data),
           !accounts.isEmpty {
            NSLog("📦 Migrated \(accounts.count) account(s) from \(upstreamDomain)")
            migrateSettings(from: upstream)
            return accounts
        }

        let cookie = upstream.string(forKey: legacyCookieKey) ?? ""
        guard !cookie.isEmpty else { return nil }

        var first = Account.makeDefault(index: 0)
        first.cookie = cookie
        NSLog("📦 Migrated single upstream cookie into '\(first.name)'")
        migrateSettings(from: upstream)
        return [first]
    }

    /// Carries the app-wide preferences across so the fork opens configured.
    private static func migrateSettings(from upstream: UserDefaults) {
        let keys = [
            "usage_notifications_enabled",
            "status_notifications_enabled",
            "shortcut_enabled",
            "show_countdown",
            "appearance_mode",
            "tracked_component_ids"
        ]
        for key in keys where UserDefaults.standard.object(forKey: key) == nil {
            if let value = upstream.object(forKey: key) {
                UserDefaults.standard.set(value, forKey: key)
            }
        }
        UserDefaults.standard.synchronize()
    }

    static func save(_ accounts: [Account]) {
        guard let data = try? JSONEncoder().encode(accounts) else {
            NSLog("\u{274C} Could not encode accounts")
            return
        }
        UserDefaults.standard.set(data, forKey: key)
        UserDefaults.standard.synchronize()
    }
}

/// Owns the account list, the shared refresh timer, the app-wide settings, and
/// the menu bar rendering. UsageManager stays a single-account concern.
class AccountsController: ObservableObject {
    @Published private(set) var managers: [UsageManager] = []

    /// One provider for every account, so refreshes queue behind a single
    /// lock. Two managers refreshing the same grant at once would each rotate
    /// the refresh token and cost the user a sign-in.
    private let credentials = CredentialProvider()

    // App-wide settings. These used to live on UsageManager, which stopped
    // working once there was more than one of it.
    @Published var usageNotificationsEnabled: Bool = true
    @Published var statusNotificationsEnabled: Bool = true
    @Published var openAtLogin: Bool = false
    @Published var shortcutEnabled: Bool = true
    @Published var isAccessibilityEnabled: Bool = false

    /// Show time remaining instead of clock times, and add a countdown to the
    /// menu bar. Off by default: it roughly doubles the menu bar width.
    @Published var showCountdown: Bool = false

    weak var delegate: AppDelegate?

    init() {
        loadSettings()
        checkAccessibilityStatus()
        managers = AccountStore.load().map(makeManager)
    }

    var accounts: [Account] { managers.map(\.account) }

    private func makeManager(_ account: Account) -> UsageManager {
        let manager = UsageManager(account: account, credentials: credentials)
        manager.notificationsEnabled = { [weak self] in self?.usageNotificationsEnabled ?? true }
        manager.onUsageChanged = { [weak self] in self?.refreshStatusBar() }
        manager.onAccountEdited = { [weak self] _ in self?.persist() }
        return manager
    }

    // MARK: - Account list

    func addAccount() {
        let manager = makeManager(Account.makeDefault(index: managers.count))
        managers.append(manager)
        persist()
    }

    func removeAccount(id: UUID) {
        // Keep at least one account so there is always somewhere to paste a cookie.
        guard managers.count > 1, let index = managers.firstIndex(where: { $0.account.id == id }) else { return }
        UserDefaults.standard.removeObject(forKey: "last_notified_threshold_\(id.uuidString)")
        managers.remove(at: index)
        persist()
    }

    func update(_ account: Account) {
        guard let manager = managers.first(where: { $0.account.id == account.id }) else { return }
        manager.account = account
        persist()
    }

    func persist() {
        AccountStore.save(accounts)
        refreshStatusBar()
        objectWillChange.send()
    }

    // MARK: - Refresh

    func fetchAll() {
        managers.forEach { $0.fetchUsage() }
    }

    func refreshStatusBar() {
        delegate?.renderStatusBar(for: managers)
    }

    // MARK: - Settings

    func checkAccessibilityStatus() {
        isAccessibilityEnabled = AXIsProcessTrusted()
    }

    func loadSettings() {
        // Migrate from legacy single notifications_enabled flag (pre-v1.1) to split flags
        let hasUsageKey  = UserDefaults.standard.object(forKey: "usage_notifications_enabled")  != nil
        let hasStatusKey = UserDefaults.standard.object(forKey: "status_notifications_enabled") != nil

        if !hasUsageKey || !hasStatusKey {
            let legacyHasKey = UserDefaults.standard.object(forKey: "notifications_enabled") != nil
            let legacyValue  = legacyHasKey ? UserDefaults.standard.bool(forKey: "notifications_enabled") : true
            if !hasUsageKey {
                usageNotificationsEnabled = legacyValue
                UserDefaults.standard.set(legacyValue, forKey: "usage_notifications_enabled")
            }
            if !hasStatusKey {
                statusNotificationsEnabled = legacyValue
                UserDefaults.standard.set(legacyValue, forKey: "status_notifications_enabled")
            }
        }
        if hasUsageKey {
            usageNotificationsEnabled = UserDefaults.standard.bool(forKey: "usage_notifications_enabled")
        }
        if hasStatusKey {
            statusNotificationsEnabled = UserDefaults.standard.bool(forKey: "status_notifications_enabled")
        }

        // Reflect the real system login-item state, not just a stored bool.
        if #available(macOS 13.0, *) {
            openAtLogin = (SMAppService.mainApp.status == .enabled)
        } else {
            openAtLogin = UserDefaults.standard.bool(forKey: "open_at_login")
        }

        if UserDefaults.standard.object(forKey: "shortcut_enabled") == nil {
            shortcutEnabled = true
        } else {
            shortcutEnabled = UserDefaults.standard.bool(forKey: "shortcut_enabled")
        }

        showCountdown = UserDefaults.standard.bool(forKey: "show_countdown")
    }

    /// Re-renders the menu bar and any open popup so countdowns advance.
    func tick() {
        guard showCountdown else { return }
        objectWillChange.send()
        refreshStatusBar()
    }

    func saveSettings() {
        UserDefaults.standard.set(usageNotificationsEnabled,  forKey: "usage_notifications_enabled")
        UserDefaults.standard.set(statusNotificationsEnabled, forKey: "status_notifications_enabled")
        UserDefaults.standard.set(openAtLogin, forKey: "open_at_login")
        UserDefaults.standard.set(shortcutEnabled, forKey: "shortcut_enabled")
        UserDefaults.standard.set(showCountdown, forKey: "show_countdown")
        UserDefaults.standard.synchronize()
    }

    // Actually register/unregister the app as a macOS login item.
    func applyLoginItem(_ enabled: Bool) {
        guard #available(macOS 13.0, *) else { return }
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                }
            }
            NSLog("🔑 Login item \(enabled ? "registered" : "unregistered")")
        } catch {
            NSLog("❌ Login item error: \(error.localizedDescription)")
        }
    }

    func sendTestNotification() {
        Notifier.send(
            title: "Claude Usage Alert",
            body: "Test notification - You've reached 75% of your 5-hour session limit"
        )
    }
}

class UsageManager: ObservableObject {
    @Published var sessionUsage: Int = 0
    @Published var sessionLimit: Int = 100
    @Published var weeklyUsage: Int = 0
    @Published var weeklyLimit: Int = 100
    @Published var weeklySonnetUsage: Int = 0
    @Published var weeklySonnetLimit: Int = 100
    @Published var weeklyFableUsage: Int = 0
    @Published var weeklyFableLimit: Int = 100
    // Extra usage spend (from /overage_spend_limit). Shown only when there's spend.
    @Published var extraSpentMinor: Int = 0
    @Published var extraLimitMinor: Int = 0
    @Published var extraResetsAt: Date?
    @Published var freeCreditsMinor: Int = 0   // remaining free/promo credits (/prepaid/credits)
    @Published var creditCurrency: String = "USD"
    @Published var hasCreditUsage: Bool = false
    @Published var sessionResetsAt: Date?
    @Published var weeklyResetsAt: Date?
    @Published var weeklySonnetResetsAt: Date?
    @Published var weeklyFableResetsAt: Date?
    @Published var lastUpdated: Date = Date()
    @Published var isLoading: Bool = false
    @Published var errorMessage: String?
    @Published var hasWeeklySonnet: Bool = false
    @Published var hasWeeklyFable: Bool = false
    @Published var hasFetchedData: Bool = false

    /// The account this manager tracks. One manager per account.
    @Published var account: Account

    /// Called after every usage update so the controller can redraw the menu
    /// bar. The manager no longer owns the status item itself.
    var onUsageChanged: (() -> Void)?

    /// Called when the account's own fields change, so the controller can
    /// persist the list.
    var onAccountEdited: ((Account) -> Void)?

    /// Whether usage notifications are on. Owned globally by AccountsController,
    /// read here so one toggle governs every account.
    var notificationsEnabled: () -> Bool = { true }

    private var lastNotifiedThreshold: Int = 0

    /// Notification state is per account, otherwise two accounts overwrite each
    /// other's "already warned at 75%" bookkeeping.
    private var thresholdKey: String { "last_notified_threshold_\(account.id.uuidString)" }

    /// The one door to this account's credential. Shared with every other
    /// manager so refreshes are serialised across accounts.
    private let credentials: CredentialProvider
    private let oauthClient = OAuthClient()
    private var pendingRequest: AuthorizationRequest?

    init(account: Account, credentials: CredentialProvider) {
        self.account = account
        self.credentials = credentials
        self.lastNotifiedThreshold = UserDefaults.standard.integer(forKey: thresholdKey)
    }

    // MARK: - Authentication

    /// Set when the account's grant is gone and only a new sign-in fixes it.
    @Published var needsReauth: Bool = false

    /// Set when OAuth failed but a stored cookie is keeping numbers flowing.
    @Published var usingCookieFallback: Bool = false

    /// One notification per failure, not one per refresh cycle.
    private var reauthNotified = false

    var authSourceLabel: String {
        if needsReauth { return "Sign in again" }
        if usingCookieFallback { return "Session cookie (sign-in expired)" }
        if account.hasOAuth { return account.accountEmail ?? "Signed in" }
        return account.hasCookie ? "Session cookie" : "Not configured"
    }

    var hasCredential: Bool { account.hasOAuth || account.hasCookie }

    private func reportReauthNeeded() {
        guard !reauthNotified else { return }
        reauthNotified = true
        Notifier.send(title: "\(account.displayName) needs a new sign-in",
                      body: usingCookieFallback
                          ? "Using its session cookie for now."
                          : "Usage will not update until you sign in.")
    }

    // MARK: - Sign-in

    /// Opens the browser at the authorize page. The page prints `code#state`
    /// for the user to paste back, which is the only redirect this client
    /// accepts.
    func beginPasteSignIn() {
        let request = OAuthClient.authorizationRequest(redirectURI: OAuthEndpoints.pasteRedirect)
        pendingRequest = request
        NSWorkspace.shared.open(request.url)
    }

    /// Redeems the pasted code. Returns nil on success, or a message to show.
    func completeSignIn(paste: String, completion: @escaping (String?) -> Void) {
        guard let request = pendingRequest else {
            completion("Start a sign-in first.")
            return
        }
        guard let callback = CallbackParser.parse(paste) else {
            completion("That does not look like a sign-in code.")
            return
        }
        guard request.accepts(callback) else {
            completion("That code is from a different sign-in. Try again.")
            return
        }
        exchange(callback.code, request: request, completion: completion)
    }

    private func exchange(_ code: String,
                          request: AuthorizationRequest,
                          completion: @escaping (String?) -> Void) {
        oauthClient.exchange(code: code,
                             verifier: request.verifier,
                             redirectURI: request.redirectURI,
                             state: request.state) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .failure(let error):
                DispatchQueue.main.async { completion("Sign-in failed: \(error)") }
            case .success(let response):
                var stored = self.credentials.stored(for: self.account.id) ?? StoredCredential()
                stored.oauth = response.tokens()
                do {
                    try self.credentials.save(stored, for: self.account.id)
                } catch {
                    DispatchQueue.main.async { completion("Could not save the sign-in: \(error)") }
                    return
                }
                DispatchQueue.main.async {
                    self.account.hasOAuth = true
                    self.account.accountEmail = response.accountEmail
                    self.needsReauth = false
                    self.reauthNotified = false
                    self.usingCookieFallback = false
                    self.pendingRequest = nil
                    self.onAccountEdited?(self.account)
                    self.fetchUsage()
                    completion(nil)
                }
            }
        }
    }

    /// Drops the OAuth grant. The cookie, if there is one, stays.
    func signOut() {
        credentials.signOut(account.id)
        account.hasOAuth = false
        account.accountEmail = nil
        needsReauth = false
        reauthNotified = false
        usingCookieFallback = false
        onAccountEdited?(account)
        fetchUsage()
    }

    var sessionPercent: Int {
        guard sessionLimit > 0 else { return 0 }
        return Int((Double(sessionUsage) / Double(sessionLimit)) * 100)
    }

    var weeklyPercent: Int {
        guard weeklyLimit > 0 else { return 0 }
        return Int((Double(weeklyUsage) / Double(weeklyLimit)) * 100)
    }

    enum LimitKind {
        case session
        case weekly

        var label: String {
            switch self {
            case .session: return "Session"
            case .weekly:  return "Weekly"
            }
        }
    }

    /// Point at which a weekly cap is close enough to blocking that it, rather
    /// than the session, is the number worth putting in the menu bar.
    static let weeklyTakeoverPercent = 90

    /// The limit closest to blocking this account, and how far along it is.
    ///
    /// The session is the headline in normal use: it is what the next few
    /// hours are actually rationed by, and a mid-week weekly figure of 22%
    /// tells you nothing about that. Once the weekly cap is near spent it
    /// takes over, because an account with a full week reads a comfortable 2%
    /// right up to the moment it refuses to work.
    var bindingLimit: (kind: LimitKind, percent: Int) {
        let session = sessionPercent
        let weekly = weeklyPercent
        if weekly >= Self.weeklyTakeoverPercent && weekly > session {
            return (.weekly, weekly)
        }
        return (.session, session)
    }

    /// True once the binding limit is spent, so the account cannot be used.
    var isBlocked: Bool {
        hasFetchedData && bindingLimit.percent >= 100
    }

    /// When the binding limit frees up again.
    var bindingResetsAt: Date? {
        bindingLimit.kind == .weekly ? weeklyResetsAt : sessionResetsAt
    }

    /// Saves the pasted cookie. Returns nil on success, or a message explaining
    /// why the paste cannot work so the user finds out now instead of after a
    /// failed fetch.
    @discardableResult
    func saveSessionCookie(_ cookie: String) -> String? {
        NSLog("ClaudeUsage: Saving cookie for '\(account.displayName)', length: \(cookie.count)")

        var stored = credentials.stored(for: account.id) ?? StoredCredential()
        stored.cookie = cookie
        do {
            try credentials.save(stored, for: account.id)
        } catch {
            NSLog("❌ Could not save cookie for '\(account.displayName)': \(error)")
            return "Could not save that cookie to the keychain"
        }

        account.hasCookie = !cookie.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        onAccountEdited?(account)

        let header = Self.cookieHeader(from: cookie)
        guard let key = Self.cookieValue(named: "sessionKey", in: header) else {
            NSLog("⚠️ Cookie saved but has no sessionKey. \(Self.cookieFingerprint(header))")
            return "No sessionKey in that cookie - copy the whole Cookie header, not one line of it"
        }

        // A session key is "sk-ant-sid01-...". Catch the common mistake of
        // copying anthropic-device-id, which is a bare 36-character UUID.
        guard key.hasPrefix("sk-ant-") else {
            NSLog("⚠️ Cookie saved but sessionKey looks wrong. \(Self.cookieFingerprint(header))")
            return key.count == 36
                ? "That is your device ID, not your session key. Copy the sessionKey row (starts sk-ant-)."
                : "That does not look like a session key. It should start with sk-ant-."
        }

        NSLog("ClaudeUsage: Cookie saved successfully")
        return nil
    }

    func clearSessionCookie() {
        NSLog("ClaudeUsage: Clearing cookie for '\(account.displayName)'")

        var stored = credentials.stored(for: account.id) ?? StoredCredential()
        stored.cookie = nil
        do {
            try credentials.save(stored, for: account.id)
        } catch {
            NSLog("❌ Could not clear cookie for '\(account.displayName)': \(error)")
        }

        account.hasCookie = false
        usingCookieFallback = false
        onAccountEdited?(account)

        // Reset all data
        sessionUsage = 0
        weeklyUsage = 0
        weeklySonnetUsage = 0
        weeklyFableUsage = 0
        sessionResetsAt = nil
        weeklyResetsAt = nil
        weeklySonnetResetsAt = nil
        weeklyFableResetsAt = nil
        extraSpentMinor = 0
        extraLimitMinor = 0
        extraResetsAt = nil
        freeCreditsMinor = 0
        hasCreditUsage = false
        hasFetchedData = false
        hasWeeklySonnet = false
        hasWeeklyFable = false
        errorMessage = nil
        lastNotifiedThreshold = 0
        UserDefaults.standard.set(0, forKey: thresholdKey)

        onUsageChanged?()

        NSLog("ClaudeUsage: Cookie cleared, data reset")
    }

    // MARK: - Cookie helpers

    /// The value to send in the `Cookie` header.
    /// Accepts either a full cookie header pasted from DevTools
    /// ("anthropic-device-id=...; sessionKey=sk-ant-...; lastActiveOrg=...")
    /// or just the bare sessionKey value.
    private static func cookieHeader(from raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        // Tolerate a pasted "Cookie: ..." header line.
        if value.lowercased().hasPrefix("cookie:") {
            value = String(value.dropFirst("cookie:".count)).trimmingCharacters(in: .whitespaces)
        }

        // Collapse the line breaks DevTools sometimes adds to long cookie values.
        value = value.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .joined()

        // A bare session key has no "name=value" pairs, so name it.
        if !value.contains("=") {
            return "sessionKey=\(value)"
        }
        return value
    }

    /// Reads a single cookie out of a cookie header.
    private static func cookieValue(named name: String, in header: String) -> String? {
        for part in header.components(separatedBy: ";") {
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("\(name)=") {
                let value = String(trimmed.dropFirst(name.count + 1))
                return value.isEmpty ? nil : value
            }
        }
        return nil
    }

    /// Names of the cookies pasted, plus the shape of the session key.
    /// Logs enough to diagnose a bad paste without logging the credential.
    private static func cookieFingerprint(_ header: String) -> String {
        let names = header.components(separatedBy: ";")
            .compactMap { $0.trimmingCharacters(in: .whitespaces).components(separatedBy: "=").first }
            .filter { !$0.isEmpty }

        var key = "sessionKey missing"
        if let value = cookieValue(named: "sessionKey", in: header) {
            key = "sessionKey \(value.count) chars, starts \(value.prefix(11))"
        }
        return "[cookies: \(names.joined(separator: ", ")) | \(key)]"
    }

    /// Every claude.ai request needs the same browser-shaped headers.
    private func makeRequest(_ url: URL, cookie: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(Self.cookieHeader(from: cookie), forHTTPHeaderField: "Cookie")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("https://claude.ai", forHTTPHeaderField: "Origin")
        request.setValue("https://claude.ai", forHTTPHeaderField: "Referer")
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
        request.setValue("claude.ai", forHTTPHeaderField: "authority")
        return request
    }

    func fetchOrganizationId(cookie: String, completion: @escaping (String?, String?) -> Void) {
        let header = Self.cookieHeader(from: cookie)

        // Fast path: the org ID is usually already in the pasted cookie.
        if let orgId = Self.cookieValue(named: "lastActiveOrg", in: header) {
            NSLog("📋 Found org ID in cookie: \(orgId)")
            completion(orgId, nil)
            return
        }

        // Without a sessionKey any API call can only come back 401.
        guard Self.cookieValue(named: "sessionKey", in: header) != nil else {
            NSLog("❌ Pasted cookie contains no sessionKey")
            completion(nil, "Cookie has no sessionKey - copy the whole Cookie header")
            return
        }

        // /api/organizations is the stable endpoint. Bootstrap is a fallback
        // because its shape has changed before and may change again.
        fetchOrgIdFromOrganizations(cookie: cookie) { orgId, reason in
            if let orgId = orgId {
                completion(orgId, nil)
                return
            }
            NSLog("↩️ /api/organizations failed (\(reason ?? "unknown")), trying bootstrap")
            self.fetchOrgIdFromBootstrap(cookie: cookie) { orgId, bootstrapReason in
                completion(orgId, orgId == nil ? (bootstrapReason ?? reason) : nil)
            }
        }
    }

    private func fetchOrgIdFromOrganizations(cookie: String, completion: @escaping (String?, String?) -> Void) {
        guard let url = URL(string: "https://claude.ai/api/organizations") else {
            completion(nil, "Invalid organizations URL")
            return
        }

        NSLog("📡 Fetching /api/organizations for org ID... \(Self.cookieFingerprint(Self.cookieHeader(from: cookie)))")

        URLSession.shared.dataTask(with: makeRequest(url, cookie: cookie)) { data, response, error in
            if let error = error {
                NSLog("❌ Organizations network error: \(error.localizedDescription)")
                completion(nil, "Network error")
                return
            }

            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            NSLog("📡 Organizations status: \(status)")

            guard status == 200, let data = data else {
                completion(nil, status == 401 || status == 403
                    ? "Cookie rejected (HTTP \(status)) - copy a fresh one"
                    : "Organizations lookup failed (HTTP \(status))")
                return
            }

            guard let orgs = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
                  !orgs.isEmpty else {
                NSLog("❌ Unexpected /api/organizations shape: \(Self.shapeSummary(data))")
                completion(nil, "Could not read org ID from your account")
                return
            }

            // An account can belong to several orgs. Prefer one that can chat,
            // which is the org the usage endpoint reports on.
            let chatOrg = orgs.first { org in
                (org["capabilities"] as? [String])?.contains("chat") == true
            }
            guard let uuid = (chatOrg ?? orgs[0])["uuid"] as? String else {
                NSLog("❌ No uuid in /api/organizations entries")
                completion(nil, "Could not read org ID from your account")
                return
            }

            NSLog("✅ Got org ID from /api/organizations: \(uuid)")
            completion(uuid, nil)
        }.resume()
    }

    private func fetchOrgIdFromBootstrap(cookie: String, completion: @escaping (String?, String?) -> Void) {
        guard let url = URL(string: "https://claude.ai/api/bootstrap") else {
            completion(nil, "Invalid bootstrap URL")
            return
        }

        NSLog("📡 Fetching bootstrap to get org ID...")

        URLSession.shared.dataTask(with: makeRequest(url, cookie: cookie)) { data, response, error in
            if let error = error {
                NSLog("❌ Bootstrap network error: \(error.localizedDescription)")
                completion(nil, "Network error")
                return
            }

            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            NSLog("📡 Bootstrap status: \(status)")

            guard status == 200, let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                completion(nil, status == 401 || status == 403
                    ? "Cookie rejected (HTTP \(status)) - copy a fresh one"
                    : "Bootstrap failed (HTTP \(status))")
                return
            }

            let account = json["account"] as? [String: Any]

            // Shapes bootstrap has used for the active org, newest first.
            var candidates: [String?] = [
                account?["lastActiveOrgId"] as? String,
                account?["last_active_org_uuid"] as? String,
                (json["organization"] as? [String: Any])?["uuid"] as? String,
                (account?["organization"] as? [String: Any])?["uuid"] as? String
            ]

            if let memberships = account?["memberships"] as? [[String: Any]] {
                candidates += memberships.map {
                    ($0["organization"] as? [String: Any])?["uuid"] as? String
                }
            }

            guard let orgId = candidates.compactMap({ $0 }).first else {
                NSLog("❌ Could not parse org ID from bootstrap. Top-level keys: \(json.keys.sorted().joined(separator: ", "))")
                if let account = account {
                    NSLog("❌ account keys: \(account.keys.sorted().joined(separator: ", "))")
                }
                completion(nil, "Could not read org ID from your account")
                return
            }

            NSLog("✅ Got org ID from bootstrap: \(orgId)")
            completion(orgId, nil)
        }.resume()
    }

    /// Describes an unexpected JSON payload without logging its contents.
    private static func shapeSummary(_ data: Data) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) else {
            return "not JSON (\(data.count) bytes)"
        }
        if let dict = object as? [String: Any] {
            return "object with keys: \(dict.keys.sorted().joined(separator: ", "))"
        }
        if let array = object as? [Any] {
            return "array of \(array.count)"
        }
        return "\(type(of: object))"
    }

    func fetchUsage() {
        isLoading = true
        errorMessage = nil

        credentials.credential(for: account.id) { [weak self] outcome in
            guard let self = self else { return }
            switch outcome {
            case .token(let token):
                self.needsReauth = false
                self.reauthNotified = false
                self.usingCookieFallback = false
                self.fetchUsageViaOAuth(token)

            case .cookie(let cookie):
                // OAuth is gone but the cookie still works, so numbers keep
                // updating while the user gets around to signing in again.
                self.needsReauth = self.account.hasOAuth
                self.usingCookieFallback = self.account.hasOAuth
                if self.needsReauth {
                    self.reportReauthNeeded()
                } else {
                    self.reauthNotified = false
                }
                self.fetchUsageViaCookie(cookie)

            case .needsReauth(let reason):
                NSLog("🔑 '\(self.account.displayName)' needs a new sign-in: \(reason)")
                self.isLoading = false
                self.needsReauth = true
                self.usingCookieFallback = false
                self.errorMessage = "Sign in again"
                self.reportReauthNeeded()
                self.updateStatusBar()

            case .unavailable(let reason):
                // Temporary. Leave the badge alone and try again next cycle.
                NSLog("⚠️ '\(self.account.displayName)': \(reason)")
                self.isLoading = false
                self.errorMessage = "Could not reach Anthropic"
                self.updateStatusBar()

            case .notConfigured:
                self.isLoading = false
                self.needsReauth = false
                self.reauthNotified = false
                self.usingCookieFallback = false
                self.errorMessage = "Sign in to see usage"
                self.updateStatusBar()
            }
        }
    }

    // MARK: - OAuth fetch

    /// Base for the OAuth endpoints. These are account-scoped, so unlike the
    /// claude.ai ones they need no organisation ID.
    private static let oauthHost = "https://api.anthropic.com"

    private func makeOAuthRequest(_ path: String, token: String) -> URLRequest? {
        guard let url = URL(string: Self.oauthHost + path) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("ClaudeUsageMulti (macOS menu bar)", forHTTPHeaderField: "User-Agent")
        return request
    }

    private func fetchUsageViaOAuth(_ token: String) {
        guard let request = makeOAuthRequest("/api/oauth/usage", token: token) else {
            DispatchQueue.main.async {
                self.errorMessage = "Invalid usage URL"
                self.isLoading = false
            }
            return
        }

        NSLog("🔍 Fetching usage via OAuth for '\(account.displayName)'")

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }
            DispatchQueue.main.async {
                self.isLoading = false

                if let error = error {
                    NSLog("❌ OAuth usage network error: \(error.localizedDescription)")
                    self.errorMessage = "Network error"
                    self.updateStatusBar()
                    return
                }

                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                NSLog("📡 OAuth usage status: \(status)")

                // The provider handed over a token it considered fresh and
                // the API refused it, so the grant is gone. Drop to the cookie if
                // there is one rather than showing an error for an account
                // that can still be read.
                if status == 401 || status == 403 {
                    self.needsReauth = true
                    if let cookie = self.credentials.storedCookie(for: self.account.id),
                       !cookie.isEmpty {
                        NSLog("↩️ Token rejected (HTTP \(status)), falling back to cookie")
                        self.isLoading = true
                        self.usingCookieFallback = true
                        self.reportReauthNeeded()
                        self.fetchUsageViaCookie(cookie)
                        return
                    }
                    self.usingCookieFallback = false
                    self.errorMessage = "Sign in again"
                    self.reportReauthNeeded()
                    self.updateStatusBar()
                    return
                }

                guard status == 200, let data = data else {
                    self.errorMessage = "HTTP \(status)"
                    self.updateStatusBar()
                    return
                }

                self.parseUsageData(data)
                self.updateStatusBar()
            }
        }.resume()
    }

    // MARK: - Cookie fetch

    private func fetchUsageViaCookie(_ cookie: String) {
        guard !cookie.isEmpty else {
            DispatchQueue.main.async {
                self.errorMessage = "Session cookie not set"
                self.isLoading = false
                self.updateStatusBar()
            }
            return
        }

        // Extract org ID from cookie
        fetchOrganizationId(cookie: cookie) { [weak self] orgId, failureReason in
            guard let self = self, let orgId = orgId else {
                DispatchQueue.main.async {
                    self?.errorMessage = failureReason ?? "Could not get org ID from cookie"
                    self?.isLoading = false
                }
                return
            }

            self.fetchUsageWithOrgId(orgId, cookie: cookie)
            self.fetchExtraUsage(orgId, cookie: cookie)
            self.fetchFreeCredits(orgId, cookie: cookie)
        }
    }

    // Remaining free/promo credits (balance) from /prepaid/credits.
    func fetchFreeCredits(_ orgId: String, cookie: String) {
        guard let url = URL(string: "https://claude.ai/api/organizations/\(orgId)/prepaid/credits") else { return }
        let request = makeRequest(url, cookie: cookie)

        URLSession.shared.dataTask(with: request) { [weak self] data, response, _ in
            DispatchQueue.main.async {
                guard let self = self,
                      let http = response as? HTTPURLResponse, http.statusCode == 200,
                      let data = data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
                // `amount` is the current balance; fall back to summing remaining tranches.
                if let amount = json["amount"] as? Int {
                    self.freeCreditsMinor = amount
                } else {
                    var remaining = 0
                    for key in ["tranches", "promo_tranches"] {
                        if let arr = json[key] as? [[String: Any]] {
                            for t in arr { remaining += (t["remaining_amount_minor_units"] as? Int) ?? 0 }
                        }
                    }
                    self.freeCreditsMinor = remaining
                }
                if let cur = json["currency"] as? String { self.creditCurrency = cur }
                NSLog("🎁 Free credits left: \(self.freeCreditsMinor) \(self.creditCurrency)")
            }
        }.resume()
    }

    // Extra usage spend + monthly limit live on a separate endpoint (not /usage).
    func fetchExtraUsage(_ orgId: String, cookie: String) {
        guard let url = URL(string: "https://claude.ai/api/organizations/\(orgId)/overage_spend_limit") else { return }
        let request = makeRequest(url, cookie: cookie)

        URLSession.shared.dataTask(with: request) { [weak self] data, response, _ in
            DispatchQueue.main.async {
                guard let self = self,
                      let http = response as? HTTPURLResponse, http.statusCode == 200,
                      let data = data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

                let spent = (json["used_credits"] as? Int) ?? 0
                let limit = (json["monthly_credit_limit"] as? Int) ?? 0
                self.extraSpentMinor = spent
                self.extraLimitMinor = limit
                self.creditCurrency = (json["currency"] as? String) ?? "USD"
                if let resetStr = json["disabled_until"] as? String {
                    let f = ISO8601DateFormatter()
                    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                    self.extraResetsAt = f.date(from: resetStr) ?? ISO8601DateFormatter().date(from: resetStr)
                }
                self.hasCreditUsage = spent > 0
                NSLog("💳 Extra usage: \(spent)/\(limit) \(self.creditCurrency)")
            }
        }.resume()
    }

    func fetchUsageWithOrgId(_ orgId: String, cookie: String) {
        let urlString = "https://claude.ai/api/organizations/\(orgId)/usage"

        guard let url = URL(string: urlString) else {
            DispatchQueue.main.async {
                self.errorMessage = "Invalid URL"
                self.isLoading = false
            }
            return
        }

        let request = makeRequest(url, cookie: cookie)

        NSLog("🔍 Fetching from: \(urlString)")

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                self?.isLoading = false

                if let error = error {
                    NSLog("❌ Error: \(error.localizedDescription)")
                    self?.errorMessage = "Network error"
                    self?.updateStatusBar()
                    return
                }

                guard let httpResponse = response as? HTTPURLResponse else {
                    self?.errorMessage = "Invalid response"
                    self?.updateStatusBar()
                    return
                }

                NSLog("📡 Status: \(httpResponse.statusCode)")

                if let data = data, let responseString = String(data: data, encoding: .utf8) {
                    NSLog("📦 Response: \(responseString)")
                }

                if httpResponse.statusCode == 200, let data = data {
                    self?.parseUsageData(data)
                } else {
                    self?.errorMessage = "HTTP \(httpResponse.statusCode)"
                }

                self?.updateStatusBar()
            }
        }.resume()
    }

    func parseUsageData(_ data: Data) {
        do {
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                errorMessage = "Invalid JSON"
                return
            }

            NSLog("📊 Parsing usage data...")

            let iso8601Formatter = ISO8601DateFormatter()
            iso8601Formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

            // Parse the actual claude.ai response format
            if let fiveHour = json["five_hour"] as? [String: Any] {
                if let sessionUtil = fiveHour["utilization"] as? Double {
                    sessionUsage = Int(sessionUtil)
                    sessionLimit = 100
                }
                if let resetsAtString = fiveHour["resets_at"] as? String {
                    NSLog("🕐 Session resets_at string: \(resetsAtString)")
                    if let resetsAt = iso8601Formatter.date(from: resetsAtString) {
                        sessionResetsAt = resetsAt
                        NSLog("✅ Parsed session reset time: \(resetsAt)")
                    } else {
                        NSLog("❌ Failed to parse session reset time")
                    }
                }
            }

            if let sevenDay = json["seven_day"] as? [String: Any] {
                if let weeklyUtil = sevenDay["utilization"] as? Double {
                    weeklyUsage = Int(weeklyUtil)
                    weeklyLimit = 100
                }
                if let resetsAtString = sevenDay["resets_at"] as? String {
                    NSLog("🕐 Weekly resets_at string: \(resetsAtString)")
                    if let resetsAt = iso8601Formatter.date(from: resetsAtString) {
                        weeklyResetsAt = resetsAt
                        NSLog("✅ Parsed weekly reset time: \(resetsAt)")
                    } else {
                        NSLog("❌ Failed to parse weekly reset time")
                    }
                }
            }

            // Check for seven_day_sonnet (Pro plan feature)
            if let sevenDaySonnet = json["seven_day_sonnet"] as? [String: Any] {
                hasWeeklySonnet = true
                if let sonnetUtil = sevenDaySonnet["utilization"] as? Double {
                    weeklySonnetUsage = Int(sonnetUtil)
                    weeklySonnetLimit = 100
                }
                if let resetsAtString = sevenDaySonnet["resets_at"] as? String {
                    NSLog("🕐 Weekly Sonnet resets_at string: \(resetsAtString)")
                    if let resetsAt = iso8601Formatter.date(from: resetsAtString) {
                        weeklySonnetResetsAt = resetsAt
                        NSLog("✅ Parsed weekly Sonnet reset time: \(resetsAt)")
                    } else {
                        NSLog("❌ Failed to parse weekly Sonnet reset time")
                    }
                }
            } else {
                hasWeeklySonnet = false
            }

            // Fable is a new, separately-counted model. It isn't a top-level
            // key like seven_day_sonnet — it lives in the `limits` array as a
            // model-scoped weekly limit (scope.model.display_name == "Fable").
            // The bar is only surfaced in the UI when usage is above 1%.
            hasWeeklyFable = false
            if let limits = json["limits"] as? [[String: Any]] {
                let fableLimit = limits.first { entry in
                    let scope = entry["scope"] as? [String: Any]
                    let model = scope?["model"] as? [String: Any]
                    return (model?["display_name"] as? String) == "Fable"
                }
                if let fable = fableLimit {
                    hasWeeklyFable = true
                    // `percent` may decode as Int or Double depending on payload.
                    if let p = fable["percent"] as? Int {
                        weeklyFableUsage = p
                    } else if let p = fable["percent"] as? Double {
                        weeklyFableUsage = Int(p)
                    }
                    weeklyFableLimit = 100
                    if let resetsAtString = fable["resets_at"] as? String {
                        NSLog("🕐 Weekly Fable resets_at string: \(resetsAtString)")
                        if let resetsAt = iso8601Formatter.date(from: resetsAtString) {
                            weeklyFableResetsAt = resetsAt
                            NSLog("✅ Parsed weekly Fable reset time: \(resetsAt)")
                        } else {
                            NSLog("❌ Failed to parse weekly Fable reset time")
                        }
                    }
                }
            }

            // The OAuth endpoint carries extra usage inline, where the
            // claude.ai one needs a second call to /overage_spend_limit.
            // Absent on the cookie payload, so fetchExtraUsage still runs there.
            if let extra = json["extra_usage"] as? [String: Any] {
                // Amounts are scaled by decimal_places; the UI works in minor
                // units, which is 2 places.
                let places = (extra["decimal_places"] as? Int) ?? 2
                let toMinor: (Any?) -> Int = { value in
                    let amount: Double
                    if let int = value as? Int { amount = Double(int) }
                    else if let double = value as? Double { amount = double }
                    else { return 0 }
                    return Int((amount * pow(10, Double(2 - places))).rounded())
                }

                extraSpentMinor = toMinor(extra["used_credits"])
                extraLimitMinor = toMinor(extra["monthly_limit"])
                if let currency = extra["currency"] as? String { creditCurrency = currency }
                hasCreditUsage = extraSpentMinor > 0
                if extraSpentMinor > 0 || extraLimitMinor > 0 {
                    NSLog("💳 Extra usage: \(extraSpentMinor)/\(extraLimitMinor) \(creditCurrency)")
                }
            }

            // (On the cookie path, prepaid credits are fetched separately from
            // /prepaid/credits. The OAuth endpoint has no equivalent.)

            // Log what we found
            NSLog("✅ Parsed: Session \(sessionUsage)%, Weekly \(weeklyUsage)%\(hasWeeklySonnet ? ", Weekly Sonnet \(weeklySonnetUsage)%" : "")\(hasWeeklyFable ? ", Weekly Fable \(weeklyFableUsage)%" : "")")

            lastUpdated = Date()
            errorMessage = nil
            hasFetchedData = true

            // Update percentage values for progress bars
            updatePercentages()
        } catch {
            NSLog("❌ Parse error: \(error.localizedDescription)")
            errorMessage = "Parse error"
        }
    }

    func updateStatusBar() {
        onUsageChanged?()
        // Warn on the binding limit, not the session: watching only the session
        // means a weekly cap fills up silently and blocks you with no warning.
        checkNotificationThresholds(percentage: bindingLimit.percent)
    }

    func checkNotificationThresholds(percentage: Int) {
        NSLog("🔔 Checking notifications for '\(account.displayName)': percentage=\(percentage)%, enabled=\(notificationsEnabled()), lastNotified=\(lastNotifiedThreshold)%")

        guard notificationsEnabled() else {
            NSLog("⚠️ Usage notifications disabled")
            return
        }

        let thresholds = [25, 50, 75, 90]

        for threshold in thresholds {
            if percentage >= threshold && lastNotifiedThreshold < threshold {
                NSLog("📬 Sending notification for \(threshold)% threshold")
                sendNotification(percentage: percentage, threshold: threshold)
                lastNotifiedThreshold = threshold
                // Persist the threshold
                UserDefaults.standard.set(lastNotifiedThreshold, forKey: thresholdKey)
                UserDefaults.standard.synchronize()
            }
        }

        // Reset if usage drops below current threshold
        if percentage < lastNotifiedThreshold {
            let newThreshold = thresholds.filter { $0 <= percentage }.last ?? 0
            NSLog("🔄 Resetting notification threshold from \(lastNotifiedThreshold)% to \(newThreshold)%")
            lastNotifiedThreshold = newThreshold
            UserDefaults.standard.set(lastNotifiedThreshold, forKey: thresholdKey)
            UserDefaults.standard.synchronize()
        }
    }

    func sendNotification(percentage: Int, threshold: Int) {
        let binding = bindingLimit
        let limitName = binding.kind == .weekly ? "7-day weekly" : "5-hour session"
        Notifier.send(
            title: "\(account.emoji) \(account.displayName)",
            body: "You've reached \(percentage)% of your \(limitName) limit"
        )
    }

    @Published var sessionPercentage: Double = 0.0
    @Published var weeklyPercentage: Double = 0.0
    @Published var weeklySonnetPercentage: Double = 0.0
    @Published var weeklyFablePercentage: Double = 0.0

    func updatePercentages() {
        sessionPercentage = Double(sessionUsage) / Double(sessionLimit)
        weeklyPercentage = Double(weeklyUsage) / Double(weeklyLimit)
        weeklySonnetPercentage = Double(weeklySonnetUsage) / Double(weeklySonnetLimit)
        weeklyFablePercentage = Double(weeklyFableUsage) / Double(weeklyFableLimit)
    }
}

// MARK: - Anthropic Service Status

struct StatusIncident: Identifiable, Equatable {
    let id: String
    let name: String
    let status: String           // investigating | identified | monitoring | resolved
    let latestUpdate: String
    let updatedAt: Date?
    let componentIds: [String]
}

struct AffectedComponent: Identifiable, Equatable {
    let id: String
    let name: String
    let status: String           // degraded_performance | partial_outage | major_outage
}

struct StatusComponent: Identifiable, Equatable {
    let id: String
    let name: String
    let status: String           // operational | degraded_performance | ...
}

private let defaultTrackedComponents: [StatusComponent] = [
    StatusComponent(id: "c-claude-ai",      name: "claude.ai",                          status: "operational"),
    StatusComponent(id: "c-claude-console", name: "Claude Console (platform.claude.com)", status: "operational"),
    StatusComponent(id: "c-claude-api",     name: "Claude API (api.anthropic.com)",     status: "operational"),
    StatusComponent(id: "c-claude-code",    name: "Claude Code",                         status: "operational"),
    StatusComponent(id: "c-claude-cowork",  name: "Claude Cowork",                       status: "operational"),
    StatusComponent(id: "c-claude-gov",     name: "Claude for Government",              status: "operational"),
]

private let defaultTrackedComponentIdSet: Set<String> = Set(
    defaultTrackedComponents.map { $0.id }.filter { $0 != "c-claude-gov" }
)

class StatusManager: ObservableObject {
    @Published var indicator: String = "none"        // none | minor | major | critical (raw, global)
    @Published var statusDescription: String = "All systems operational"
    @Published var incidents: [StatusIncident] = []
    @Published var affectedComponents: [AffectedComponent] = []
    @Published var allComponents: [StatusComponent] = defaultTrackedComponents
    @Published var selectedComponentIds: Set<String> = defaultTrackedComponentIdSet
    @Published var lastUpdated: Date?
    @Published var hasFetched: Bool = false

    // Canonical URL (status.anthropic.com 302-redirects here)
    private let endpoint = URL(string: "https://status.claude.com/api/v2/summary.json")!

    init() {
        if let saved = UserDefaults.standard.array(forKey: "tracked_component_ids") as? [String] {
            selectedComponentIds = Set(saved)
        }
        // Clean up legacy debug pref if present
        UserDefaults.standard.removeObject(forKey: "status_preview_mode")
    }

    func toggleComponent(_ id: String) {
        if selectedComponentIds.contains(id) {
            selectedComponentIds.remove(id)
        } else {
            selectedComponentIds.insert(id)
        }
        UserDefaults.standard.set(Array(selectedComponentIds), forKey: "tracked_component_ids")
    }

    func isTracked(_ id: String) -> Bool {
        selectedComponentIds.contains(id)
    }

    // MARK: - Filtered/effective views (respect tracked components)

    var filteredAffectedComponents: [AffectedComponent] {
        affectedComponents.filter { selectedComponentIds.contains($0.id) }
    }

    var filteredIncidents: [StatusIncident] {
        incidents.filter { incident in
            guard !incident.componentIds.isEmpty else { return true }
            return incident.componentIds.contains(where: { selectedComponentIds.contains($0) })
        }
    }

    var effectiveIndicator: String {
        let trackedComponents = allComponents.filter { selectedComponentIds.contains($0.id) }
        let max = trackedComponents.map { severity(for: $0.status) }.max() ?? 0
        switch max {
        case 0:  return "none"
        case 1:  return "minor"
        case 2:  return "major"
        default: return "critical"
        }
    }

    private func severity(for componentStatus: String) -> Int {
        switch componentStatus {
        case "operational":          return 0
        case "under_maintenance":    return 1
        case "degraded_performance": return 1
        case "partial_outage":       return 2
        case "major_outage":         return 3
        default:                     return 0
        }
    }

    func fetch() {
        let request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        URLSession.shared.dataTask(with: request) { [weak self] data, _, _ in
            guard let self = self, let data = data else { return }
            self.parse(data)
        }.resume()
    }

    private func parse(_ data: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let status = json["status"] as? [String: Any],
              let indicator = status["indicator"] as? String,
              let desc = status["description"] as? String else {
            return
        }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoNoFrac = ISO8601DateFormatter()
        isoNoFrac.formatOptions = [.withInternetDateTime]

        var parsedIncidents: [StatusIncident] = []
        if let raw = json["incidents"] as? [[String: Any]] {
            for inc in raw {
                guard let id = inc["id"] as? String,
                      let name = inc["name"] as? String,
                      let st = inc["status"] as? String else { continue }
                if st == "resolved" || st == "postmortem" { continue }
                let updates = inc["incident_updates"] as? [[String: Any]] ?? []
                let latest = (updates.first?["body"] as? String) ?? ""
                let dateStr = (updates.first?["created_at"] as? String) ?? (inc["updated_at"] as? String)
                let updatedAt = dateStr.flatMap { iso.date(from: $0) ?? isoNoFrac.date(from: $0) }
                let compIds = (inc["components"] as? [[String: Any]] ?? [])
                    .compactMap { $0["id"] as? String }
                parsedIncidents.append(StatusIncident(
                    id: id, name: name, status: st, latestUpdate: latest,
                    updatedAt: updatedAt,
                    componentIds: compIds
                ))
            }
        }

        var parsedAffected: [AffectedComponent] = []
        var parsedAll: [StatusComponent] = []
        if let raw = json["components"] as? [[String: Any]] {
            for c in raw {
                guard let id = c["id"] as? String,
                      let name = c["name"] as? String,
                      let st = c["status"] as? String else { continue }
                parsedAll.append(StatusComponent(id: id, name: name, status: st))
                if st != "operational" {
                    parsedAffected.append(AffectedComponent(id: id, name: name, status: st))
                }
            }
        }

        DispatchQueue.main.async {
            let isFirstFetch = !self.hasFetched

            self.indicator = indicator
            self.statusDescription = desc
            self.incidents = parsedIncidents
            self.affectedComponents = parsedAffected
            if !parsedAll.isEmpty {
                self.allComponents = parsedAll
                // First time we see real components: track all except Claude for Government by default
                if UserDefaults.standard.array(forKey: "tracked_component_ids") == nil {
                    let defaultIds = parsedAll
                        .filter { !$0.name.localizedCaseInsensitiveContains("Government") }
                        .map { $0.id }
                    self.selectedComponentIds = Set(defaultIds)
                    UserDefaults.standard.set(Array(self.selectedComponentIds),
                                              forKey: "tracked_component_ids")
                }
            }
            self.lastUpdated = Date()
            self.hasFetched = true

            // Notify on transitions of EFFECTIVE (filtered) indicator
            let effective = self.effectiveIndicator
            let previous = UserDefaults.standard.string(forKey: "last_effective_indicator")
            if !isFirstFetch, let previous = previous, previous != effective {
                self.notifyStatusChange(to: effective, description: desc)
            }
            UserDefaults.standard.set(effective, forKey: "last_effective_indicator")
        }
    }

    private func notifyStatusChange(to indicator: String, description: String) {
        guard UserDefaults.standard.bool(forKey: "status_notifications_enabled") else { return }

        if indicator == "none" {
            Notifier.send(title: "Claude is back online", body: "All systems operational")
        } else {
            Notifier.send(
                title: "Claude status: \(description)",
                body: "Visit status.anthropic.com for details"
            )
        }
        NSLog("📬 Sent status-change notification: \(indicator)")
    }
}

// MARK: - App Updates

struct BannerButton: Equatable {
    let label: String
    let url: URL?         // optional — opens this URL (validated)
    let action: String?   // "dismiss" closes the banner; nil = no extra side effect
    let style: String?    // "primary" | "secondary" | nil
}

struct AvailableUpdate: Equatable {
    let version: String
    let title: String
    let body: String
    let buttons: [BannerButton]
}

// Free-form message channel, decoupled from the app version. Driven by the
// `message` object in latest.json and keyed on `id` (not version), so any
// message can be sent at any time without shipping a new build. Every field is
// author-controlled — including the notification title, which is NOT possible
// on the legacy version-based channel.
struct Announcement: Equatable {
    let id: String
    let heading: String?          // optional small top line on the card (nil = none)
    let title: String
    let body: String
    let buttons: [BannerButton]
    let notify: Bool              // false = show the in-app card only, no OS notification
    let notifTitle: String        // fully custom notification title
    let notifBody: String         // fully custom notification body
}

class UpdateManager: ObservableObject {
    @Published var available: AvailableUpdate?
    @Published var announcement: Announcement?

    // Served directly from the repo via GitHub — free, unlimited, no Vercel meter.
    // Same file as website/latest.json so existing v1.1 users on Vercel see the same JSON.
    private let endpoint = URL(string: "https://raw.githubusercontent.com/Artzainnn/ClaudeUsageBar/main/website/latest.json")!

    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    private static let allowedHostSuffixes = [
        "github.com",
        "claudeusagebar.com"
    ]

    static func isSafeURL(_ url: URL) -> Bool {
        guard url.scheme == "https" else { return false }
        guard let host = url.host?.lowercased() else { return false }
        return allowedHostSuffixes.contains(where: { host == $0 || host.hasSuffix("." + $0) })
    }

    private static func parseButtons(from json: [String: Any]) -> [BannerButton] {
        // Explicit `buttons` array (new schema, supports any combination)
        if let raw = json["buttons"] as? [[String: Any]] {
            return raw.compactMap { dict -> BannerButton? in
                guard let label = dict["label"] as? String, !label.isEmpty else { return nil }
                let urlStr = dict["url"] as? String
                let url = urlStr.flatMap { URL(string: $0) }
                if let url = url, !isSafeURL(url) { return nil }   // reject unsafe URLs
                return BannerButton(
                    label: label,
                    url: url,
                    action: dict["action"] as? String,
                    style: dict["style"] as? String
                )
            }
        }
        // Back-compat: legacy `download_url` builds the default 2-button layout
        if let urlStr = json["download_url"] as? String,
           let url = URL(string: urlStr),
           isSafeURL(url) {
            return [
                BannerButton(label: "Download", url: url, action: nil, style: "primary"),
                BannerButton(label: "Later",    url: nil, action: "dismiss", style: nil)
            ]
        }
        return []
    }

    func fetch() {
        let request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        URLSession.shared.dataTask(with: request) { [weak self] data, _, _ in
            guard let self = self,
                  let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                NSLog("⚠️ Update fetch failed or invalid payload")
                return
            }

            // ---- Legacy version-update channel (for real releases; also what
            //      pre-1.3.1 apps rely on). Optional — absent fields = no update.
            let updatePayload: AvailableUpdate? = {
                guard let version = json["version"] as? String,
                      let title = json["title"] as? String,
                      let body = json["description"] as? String else { return nil }
                return AvailableUpdate(version: version, title: title, body: body,
                                       buttons: Self.parseButtons(from: json))
            }()

            // ---- Free-form message channel (`message` object, keyed on `id`).
            //      Every field author-controlled, including the notification title.
            let announcementPayload: Announcement? = {
                guard let msg = json["message"] as? [String: Any],
                      let id = msg["id"] as? String, !id.isEmpty else { return nil }
                let title = msg["title"] as? String ?? ""
                let body  = msg["body"]  as? String ?? ""
                let notif = msg["notification"] as? [String: Any]
                return Announcement(
                    id: id,
                    heading: msg["heading"] as? String,
                    title: title,
                    body: body,
                    buttons: Self.parseButtons(from: msg),
                    notify: (msg["notify"] as? Bool) ?? true,
                    notifTitle: (notif?["title"] as? String) ?? (title.isEmpty ? "ClaudeUsageBar" : title),
                    notifBody:  (notif?["body"]  as? String) ?? body
                )
            }()

            DispatchQueue.main.async {
                // Version-update channel
                if let update = updatePayload, self.isNewer(remote: update.version, than: self.currentVersion) {
                    if self.available != update {
                        self.available = update
                        NSLog("⬆️ Update available: \(update.version)")
                    }
                    let lastNotified = UserDefaults.standard.string(forKey: "last_notified_update_version")
                    if lastNotified != update.version {
                        Notifier.send(
                            title: "ClaudeUsageBar \(update.version) is available",
                            body: update.title
                        )
                        UserDefaults.standard.set(update.version, forKey: "last_notified_update_version")
                        NSLog("📬 Sent update notification for \(update.version)")
                    }
                } else {
                    self.available = nil
                }

                // Message channel — notify once per `id`. On the very first run
                // that supports messages, seed the current id WITHOUT notifying so
                // updating from an older version doesn't re-ping the live message.
                if let ann = announcementPayload {
                    let dismissed = UserDefaults.standard.string(forKey: "dismissed_message_id")
                    self.announcement = (dismissed == ann.id) ? nil : ann

                    let lastShown = UserDefaults.standard.string(forKey: "last_shown_message_id")
                    if lastShown == nil {
                        UserDefaults.standard.set(ann.id, forKey: "last_shown_message_id")   // seed, no notif
                    } else if lastShown != ann.id {
                        if ann.notify {
                            Notifier.send(title: ann.notifTitle, body: ann.notifBody)
                            NSLog("📬 Sent message notification for id \(ann.id)")
                        }
                        UserDefaults.standard.set(ann.id, forKey: "last_shown_message_id")
                    }
                } else {
                    self.announcement = nil
                }
            }
        }.resume()
    }

    func dismissCurrent() {
        // Announcement takes priority in the UI, so dismiss it first if present.
        if let id = announcement?.id {
            UserDefaults.standard.set(id, forKey: "dismissed_message_id")
            announcement = nil
            return
        }
        if let v = available?.version {
            UserDefaults.standard.set(v, forKey: "dismissed_update_version")
        }
        available = nil
    }

    var isCurrentDismissed: Bool {
        guard let v = available?.version else { return false }
        return UserDefaults.standard.string(forKey: "dismissed_update_version") == v
    }

    private func isNewer(remote: String, than current: String) -> Bool {
        let r = remote.split(separator: ".").map { Int($0) ?? 0 }
        let c = current.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(r.count, c.count) {
            let a = i < r.count ? r[i] : 0
            let b = i < c.count ? c[i] : 0
            if a != b { return a > b }
        }
        return false
    }
}

// Custom NSTextField that properly handles paste
class CustomTextField: NSTextField {
    var onTextChange: ((String) -> Void)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.type == .keyDown {
            if (event.modifierFlags.contains(.command)) {
                switch event.charactersIgnoringModifiers {
                case "v":
                    if let string = NSPasteboard.general.string(forType: .string) {
                        self.stringValue = string
                        onTextChange?(string)
                        NSLog("ClaudeUsage: Pasted text length: \(string.count)")
                        return true
                    }
                case "a":
                    self.currentEditor()?.selectAll(nil)
                    return true
                case "c":
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(self.stringValue, forType: .string)
                    return true
                case "x":
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(self.stringValue, forType: .string)
                    self.stringValue = ""
                    onTextChange?("")
                    return true
                default:
                    break
                }
            }
        }
        return super.performKeyEquivalent(with: event)
    }

    override func textDidChange(_ notification: Notification) {
        super.textDidChange(notification)
        onTextChange?(self.stringValue)
    }
}

// Custom TextView that ensures keyboard commands work
class PasteableNSTextView: NSTextView {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command) {
            switch event.charactersIgnoringModifiers {
            case "v": // Paste
                paste(nil)
                return true
            case "c": // Copy
                copy(nil)
                return true
            case "x": // Cut
                cut(nil)
                return true
            case "a": // Select All
                selectAll(nil)
                return true
            default:
                break
            }
        }
        return super.performKeyEquivalent(with: event)
    }
}

// Multi-line text field with proper paste support
struct PasteableTextField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        let textView = PasteableNSTextView()

        textView.isEditable = true
        textView.isSelectable = true
        textView.font = NSFont.systemFont(ofSize: 11)
        textView.textColor = .labelColor
        textView.backgroundColor = .textBackgroundColor
        textView.drawsBackground = true
        textView.isRichText = false
        textView.delegate = context.coordinator
        textView.textContainerInset = NSSize(width: 4, height: 4)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.usesFindBar = false
        textView.isGrammarCheckingEnabled = false
        textView.allowsUndo = true

        // Enable wrapping
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .bezelBorder

        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? PasteableNSTextView else { return }
        if textView.string != text {
            textView.string = text
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: PasteableTextField

        init(_ parent: PasteableTextField) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
        }
    }
}

extension Notification.Name {
    static let usagePopoverHeightChanged = Notification.Name("usagePopoverHeightChanged")
}

private struct ContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

// Shared by UsageView and AccountUsageSection.
func formatTime(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.timeStyle = .short
    return formatter.string(from: date)
}

func formatResetTime(_ date: Date, includeDate: Bool = false) -> String {
    let formatter = DateFormatter()

    if includeDate {
        // Format: "on 31 Jan 2026 at 7:59 AM"
        formatter.dateFormat = "d MMM yyyy 'at' h:mm a"
        return "on \(formatter.string(from: date))"
    } else {
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return "at \(formatter.string(from: date))"
    }
}

/// Compact time remaining, e.g. "3d 4h", "2h 14m", "47m". Nil once elapsed,
/// so a stale reset time renders as nothing rather than a negative countdown.
func formatCountdown(to date: Date, from now: Date = Date()) -> String? {
    let seconds = Int(date.timeIntervalSince(now))
    guard seconds > 0 else { return nil }

    let days = seconds / 86_400
    let hours = (seconds % 86_400) / 3_600
    let minutes = (seconds % 3_600) / 60

    if days > 0 { return "\(days)d \(hours)h" }
    if hours > 0 { return "\(hours)h \(minutes)m" }
    return "\(minutes)m"
}

/// "in 2h 14m" when counting down, otherwise "at 2:49 PM" / "on 2 Sep ...".
func formatReset(_ date: Date, includeDate: Bool = false, relative: Bool) -> String {
    if relative, let remaining = formatCountdown(to: date) {
        return "in \(remaining)"
    }
    return formatResetTime(date, includeDate: includeDate)
}

/// Severity colour for the popup. Matches the menu bar's meaning of colour.
func colorForPercentage(_ percentage: Double) -> Color {
    if percentage < 0.7 {
        return .green
    } else if percentage < 0.9 {
        return .orange
    } else {
        return .red
    }
}

struct UsageView: View {
    @ObservedObject var accounts: AccountsController
    @ObservedObject var statusManager: StatusManager
    @ObservedObject var updateManager: UpdateManager
    @State private var sessionCookieInput: String = ""
    @State private var hasSavedCookie: Bool = false
    @State private var showingCookieInput: Bool = false
    @State private var showingSettings: Bool = false
    @State private var showingStatusDetails: Bool = false
    @State private var measuredHeight: CGFloat = 250
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("appearance_mode") private var appearanceMode: String = "system"

    private let maxPopupHeight: CGFloat = 600

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                content
                    .padding()
                    .background(
                        GeometryReader { geo in
                            Color.clear.preference(key: ContentHeightKey.self, value: geo.size.height)
                        }
                    )
            }
            .frame(width: 360, height: min(max(measuredHeight, 100), maxPopupHeight))
            // Dark: light scrim over the native material — between fully native
            // (too transparent) and the v1.3.2 0.62 scrim (read as "too dark").
            // TEST VALUE on ClaudeUsageBar only; CodexUsageBar stays fully native.
            // Light: near-opaque backing, or a dark desktop bleeds through as
            // murky blue-gray when forced.
            .background(
                colorScheme == .dark
                    ? Color(red: 0.07, green: 0.07, blue: 0.08).opacity(0.3)
                    : Color.white.opacity(0.85)
            )
            .onPreferenceChange(ContentHeightKey.self) { value in
                guard value > 0 else { return }
                measuredHeight = value
                // The SwiftUI frame grows, but NSPopover keeps whatever
                // contentSize it was given at launch, so anything past 320pt
                // (the cookie field included) was clipped out of the window.
                NotificationCenter.default.post(
                    name: .usagePopoverHeightChanged,
                    object: nil,
                    userInfo: ["height": min(max(value, 100), maxPopupHeight)]
                )
            }
            .onAppear {
                // Never prefill the field with a truncated cookie: saving that
                // back would store 20 characters plus "..." as the credential.
                sessionCookieInput = ""
                hasSavedCookie = !(UserDefaults.standard.string(forKey: "claude_session_cookie") ?? "").isEmpty
                accounts.managers.forEach { $0.updatePercentages() }
            }
            .onChange(of: showingSettings) { isOpen in
                if isOpen {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        withAnimation(.easeInOut(duration: 0.35)) {
                            proxy.scrollTo("settings-anchor", anchor: .bottom)
                        }
                    }
                }
            }
            .onChange(of: showingCookieInput) { isOpen in
                if isOpen {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        withAnimation(.easeInOut(duration: 0.35)) {
                            proxy.scrollTo("cookie-anchor", anchor: .bottom)
                        }
                    }
                }
            }
        }
    }

    var content: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Claude Usage")
                .font(.headline)
                .padding(.bottom, 4)

            // Free-form message banner (author-controlled). Takes priority over
            // the version-update banner when both are present.
            if let ann = updateManager.announcement {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        if let heading = ann.heading, !heading.isEmpty {
                            Text(heading)
                                .font(.caption)
                                .fontWeight(.semibold)
                        }
                        Spacer()
                        Button(action: { updateManager.dismissCurrent() }) {
                            Image(systemName: "xmark")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundColor(Color.secondaryText)
                        }
                        .buttonStyle(.borderless)
                    }
                    if !ann.title.isEmpty {
                        Text(ann.title)
                            .font(.caption)
                    }
                    if !ann.body.isEmpty {
                        Text(ann.body)
                            .font(.caption2)
                            .foregroundColor(Color.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if !ann.buttons.isEmpty {
                        HStack(spacing: 6) {
                            ForEach(ann.buttons.indices, id: \.self) { i in
                                bannerButton(ann.buttons[i])
                            }
                        }
                    }
                }
                .padding(8)
                .background(Color.accentColor.opacity(0.12))
                .cornerRadius(6)
            }

            // App update banner (version-based). Hidden while a message banner shows.
            if updateManager.announcement == nil,
               let update = updateManager.available, !updateManager.isCurrentDismissed {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Text("⬆️")
                        Text("Version \(update.version) available")
                            .font(.caption)
                            .fontWeight(.semibold)
                        Spacer()
                        Button(action: { updateManager.dismissCurrent() }) {
                            Image(systemName: "xmark")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundColor(Color.secondaryText)
                        }
                        .buttonStyle(.borderless)
                    }
                    Text(update.title)
                        .font(.caption)
                    Text(update.body)
                        .font(.caption2)
                        .foregroundColor(Color.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    if !update.buttons.isEmpty {
                        HStack(spacing: 6) {
                            ForEach(update.buttons.indices, id: \.self) { i in
                                bannerButton(update.buttons[i])
                            }
                        }
                    }
                }
                .padding(8)
                .background(Color.accentColor.opacity(0.12))
                .cornerRadius(6)
            }

            // One section per account, stacked. Both accounts visible at once.
            ForEach(accounts.managers, id: \.account.id) { manager in
                if manager.account.id != accounts.managers.first?.account.id {
                    Divider()
                }
                AccountUsageSection(manager: manager, accounts: accounts)
            }


            if statusManager.hasFetched {
                Divider()
            }

            // Anthropic service status (compact; expandable on issue)
            if statusManager.hasFetched {
                let effective = statusManager.effectiveIndicator
                let filteredIncidents = statusManager.filteredIncidents
                let filteredAffected = statusManager.filteredAffectedComponents
                let hasIssue = effective != "none"
                    && (!filteredIncidents.isEmpty || !filteredAffected.isEmpty)

                VStack(alignment: .leading, spacing: 8) {
                    // Compact header row
                    HStack(alignment: .top, spacing: 6) {
                        Circle()
                            .fill(statusColor(for: effective))
                            .frame(width: 8, height: 8)
                            .padding(.top, 4)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(effective == "none"
                                 ? "All Claude services operational"
                                 : statusManager.statusDescription)
                                .font(.caption)
                                .foregroundColor(Color.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(statusContextLine(for: statusManager))
                                .font(.system(size: 10))
                                .foregroundColor(Color.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        if hasIssue {
                            Button(action: { showingStatusDetails.toggle() }) {
                                HStack(spacing: 2) {
                                    Text(showingStatusDetails ? "Hide" : "Details")
                                    Image(systemName: showingStatusDetails ? "chevron.up" : "chevron.down")
                                        .font(.system(size: 8))
                                }
                                .font(.caption2)
                            }
                            .buttonStyle(.borderless)
                        }
                    }

                    // Expanded panel
                    if hasIssue && showingStatusDetails {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(filteredIncidents) { incident in
                                VStack(alignment: .leading, spacing: 6) {
                                    // Title
                                    Text(incident.name)
                                        .font(.system(size: 12, weight: .semibold))
                                        .fixedSize(horizontal: false, vertical: true)

                                    // Status badge + updated time
                                    HStack(spacing: 8) {
                                        Text(incident.status.uppercased())
                                            .font(.system(size: 9, weight: .bold))
                                            .foregroundColor(.white)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(badgeColor(for: incident.status))
                                            .cornerRadius(3)
                                        if let updated = incident.updatedAt {
                                            Text("Updated \(relativeTime(updated))")
                                                .font(.caption2)
                                                .foregroundColor(Color.secondaryText)
                                        }
                                    }

                                    // Body
                                    if !incident.latestUpdate.isEmpty {
                                        Text(incident.latestUpdate)
                                            .font(.caption)
                                            .foregroundColor(.primary)
                                            .fixedSize(horizontal: false, vertical: true)
                                            .padding(.top, 2)
                                    }
                                }
                            }

                            // Affected components (when no formal incident)
                            if filteredIncidents.isEmpty && !filteredAffected.isEmpty {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Affected services")
                                        .font(.caption2)
                                        .fontWeight(.semibold)
                                        .foregroundColor(Color.secondaryText)
                                    ForEach(filteredAffected) { c in
                                        HStack(spacing: 6) {
                                            Circle()
                                                .fill(Color.orange)
                                                .frame(width: 5, height: 5)
                                            Text(c.name).font(.caption2)
                                            Spacer()
                                            Text(componentLabel(c.status))
                                                .font(.caption2)
                                                .foregroundColor(Color.secondaryText)
                                        }
                                    }
                                }
                            }

                            Divider()

                            HStack {
                                if let lastCheck = statusManager.lastUpdated {
                                    Text("Checked \(relativeTime(lastCheck))")
                                        .font(.caption2)
                                        .foregroundColor(Color.secondaryText)
                                }
                                Spacer()
                                Button(action: {
                                    NSWorkspace.shared.open(URL(string: "https://status.claude.com")!)
                                }) {
                                    Text("Open status page →")
                                        .font(.caption2)
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                        .padding(10)
                        .background(Color.orange.opacity(0.10))
                        .cornerRadius(6)
                    }
                }
            }

            if accounts.managers.contains(where: { $0.hasFetchedData }) {
                Divider()

                HStack {
                    // Every account refreshes on the same timer, so the newest
                    // fetch time describes all of them.
                    let newest = accounts.managers
                        .filter { $0.hasFetchedData }
                        .map(\.lastUpdated)
                        .max()
                    Text("Last updated: \(newest.map(formatTime) ?? "never")")
                        .font(.caption)
                        .foregroundColor(Color.secondaryText)
                    Spacer()
                    Button("Refresh All") {
                        accounts.fetchAll()
                        statusManager.fetch()
                        updateManager.fetch()
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                }
            }


            // Settings Section
            Button(showingSettings ? "Hide Settings" : "Settings") {
                showingSettings.toggle()
            }
            .buttonStyle(.borderless)
            .font(.caption)

            if showingSettings {
                VStack(alignment: .leading, spacing: 12) {
                    AccountsSettingsSection(accounts: accounts)

                    Divider()

                    Toggle(isOn: Binding(
                        get: { accounts.showCountdown },
                        set: { newValue in
                            accounts.showCountdown = newValue
                            accounts.saveSettings()
                            accounts.refreshStatusBar()
                        }
                    )) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Show time remaining")
                                .font(.caption)
                            Text("Counts down to the reset in the menu bar")
                                .font(.caption2)
                                .foregroundColor(Color.secondaryText)
                        }
                    }
                    .toggleStyle(.switch)
                    .controlSize(.mini)

                    Toggle(isOn: Binding(
                        get: { accounts.openAtLogin },
                        set: { newValue in
                            accounts.openAtLogin = newValue
                            accounts.applyLoginItem(newValue)
                            accounts.saveSettings()
                        }
                    )) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Open at Login")
                                .font(.caption)
                            Text("Launch app automatically when you log in")
                                .font(.caption2)
                                .foregroundColor(Color.secondaryText)
                        }
                    }
                    .toggleStyle(.checkbox)

                    VStack(alignment: .leading, spacing: 8) {
                        Toggle(isOn: Binding(
                            get: { accounts.usageNotificationsEnabled },
                            set: { newValue in
                                accounts.usageNotificationsEnabled = newValue
                                accounts.saveSettings()
                            }
                        )) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Enable Usage Notifications")
                                    .font(.caption)
                                Text("Get alerts at 25%, 50%, 75%,\nand 90% session usage")
                                    .font(.caption2)
                                    .foregroundColor(Color.secondaryText)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .toggleStyle(.checkbox)

                        Toggle(isOn: Binding(
                            get: { accounts.statusNotificationsEnabled },
                            set: { newValue in
                                accounts.statusNotificationsEnabled = newValue
                                accounts.saveSettings()
                            }
                        )) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Enable Status Notifications")
                                    .font(.caption)
                                Text("Get alerts when tracked Claude services have an outage")
                                    .font(.caption2)
                                    .foregroundColor(Color.secondaryText)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .toggleStyle(.checkbox)

                        Button("Test Notification") {
                            accounts.sendTestNotification()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: 8) {
                        Toggle(isOn: Binding(
                            get: { accounts.shortcutEnabled },
                            set: { newValue in
                                accounts.shortcutEnabled = newValue
                                accounts.saveSettings()
                                if let appDelegate = NSApplication.shared.delegate as? AppDelegate {
                                    appDelegate.setShortcutEnabled(newValue)
                                }
                            }
                        )) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Keyboard Shortcut (⌘U)")
                                    .font(.caption)
                                Text("Toggle popup from anywhere.\nDisable if it conflicts with other apps.")
                                    .font(.caption2)
                                    .foregroundColor(Color.secondaryText)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .toggleStyle(.switch)

                        if accounts.shortcutEnabled && !accounts.isAccessibilityEnabled {
                            Button("Grant Accessibility Permission") {
                                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)

                            Text("Accessibility permission may be needed\nfor the shortcut to work in all apps")
                                .font(.caption2)
                                .foregroundColor(Color.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Status alerts: services to track")
                            .font(.caption)
                            .fontWeight(.semibold)
                        Text("Only tick the Claude services you use. Status issues with unticked services won't be shown or trigger alerts.")
                            .font(.caption2)
                            .foregroundColor(Color.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                        ForEach(statusManager.allComponents) { component in
                            Toggle(isOn: Binding(
                                get: { statusManager.isTracked(component.id) },
                                set: { _ in statusManager.toggleComponent(component.id) }
                            )) {
                                Text(component.name)
                                    .font(.caption2)
                            }
                            .toggleStyle(.checkbox)
                        }
                    }

                    Divider()

                    // Appearance sits last on purpose: opening Settings auto-scrolls
                    // to the anchor below, so this lands in view.
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Appearance")
                            .font(.caption)
                        Picker("Appearance", selection: $appearanceMode) {
                            Text("System").tag("system")
                            Text("Dark").tag("dark")
                            Text("Light").tag("light")
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .onChange(of: appearanceMode) { _ in
                            (NSApplication.shared.delegate as? AppDelegate)?.applyAppearancePreference()
                        }
                        Text("Match macOS, or keep the classic dark look")
                            .font(.caption2)
                            .foregroundColor(Color.secondaryText)
                    }

                }
                .padding(8)
                .background(Color.secondary.opacity(0.1))
                .cornerRadius(6)

                // Anchor for scroll-to-bottom when Settings opens
                Color.clear
                    .frame(height: 1)
                    .id("settings-anchor")
            }
        }
    }

    func formatNumber(_ number: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: number)) ?? "\(number)"
    }

    func statusColor(for indicator: String) -> Color {
        switch indicator {
        case "none":     return .green
        case "minor":    return .yellow
        case "major":    return .orange
        case "critical": return .red
        default:         return .gray
        }
    }

    func statusLabel(for indicator: String, description: String) -> String {
        if indicator == "none" {
            return "Claude: all systems operational"
        }
        return "Claude: \(description)"
    }

    func relativeTime(_ date: Date) -> String {
        let elapsed = Int(Date().timeIntervalSince(date))
        if elapsed < 60 { return "just now" }
        if elapsed < 3600 {
            let m = elapsed / 60
            return "\(m) min\(m == 1 ? "" : "s") ago"
        }
        if elapsed < 86_400 {
            let h = elapsed / 3600
            return "\(h) hour\(h == 1 ? "" : "s") ago"
        }
        let d = elapsed / 86_400
        return "\(d) day\(d == 1 ? "" : "s") ago"
    }

    func statusContextLine(for sm: StatusManager) -> String {
        let tracked = sm.allComponents.filter { sm.selectedComponentIds.contains($0.id) }
        let trackedNames = tracked.prefix(4).map { shortName($0.name) }.joined(separator: ", ")
        let extra = tracked.count > 4 ? " +\(tracked.count - 4)" : ""
        let trackedSummary = tracked.isEmpty ? "No services tracked" : "Tracks \(trackedNames)\(extra)"

        if sm.effectiveIndicator == "none" {
            if let lastCheck = sm.lastUpdated {
                return "\(trackedSummary) · checked \(relativeTime(lastCheck))"
            }
            return trackedSummary
        }
        let affected = sm.filteredAffectedComponents
        if !affected.isEmpty {
            let names = affected.prefix(3).map { shortName($0.name) }.joined(separator: ", ")
            let more = affected.count > 3 ? " +\(affected.count - 3)" : ""
            return "Affects: \(names)\(more)"
        }
        if let lastCheck = sm.lastUpdated {
            return "Checked \(relativeTime(lastCheck))"
        }
        return ""
    }

    func shortName(_ raw: String) -> String {
        if let paren = raw.range(of: " (") {
            return String(raw[..<paren.lowerBound])
        }
        return raw
    }

    @ViewBuilder
    func bannerButton(_ btn: BannerButton) -> some View {
        let tap = {
            if let url = btn.url {
                NSWorkspace.shared.open(url)
            }
            if btn.action == "dismiss" {
                updateManager.dismissCurrent()
            }
        }
        if btn.style == "primary" {
            Button(btn.label, action: tap)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        } else {
            Button(btn.label, action: tap)
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
    }

    func badgeColor(for status: String) -> Color {
        switch status {
        case "investigating": return Color.red.opacity(0.8)
        case "identified":    return Color.orange
        case "monitoring":    return Color.blue
        case "resolved":      return Color.green
        default:              return Color.gray
        }
    }

    func componentLabel(_ status: String) -> String {
        switch status {
        case "degraded_performance": return "degraded"
        case "partial_outage":       return "partial outage"
        case "major_outage":         return "major outage"
        case "under_maintenance":    return "maintenance"
        default:                     return status
        }
    }

}

/// One account's usage. Rendered once per account, stacked, so both accounts
/// are visible without switching.
///
/// The account's colour appears on the name and the left accent stripe only.
/// Progress bars and percentages keep the severity colours, so colour always
/// answers "how close to the limit", never "which account".
struct AccountUsageSection: View {
    @ObservedObject var manager: UsageManager
    @ObservedObject var accounts: AccountsController

    @State private var sessionCookieInput: String = ""
    @State private var showingCookieInput: Bool = false
    @State private var hasSavedCookie: Bool = false
    @State private var pasteInput: String = ""
    @State private var awaitingPaste: Bool = false
    @State private var showCookie: Bool = false

    private var account: Account { manager.account }

    // MARK: - Sign-in

    /// The only sign-in route: the browser prints a code, the user pastes it
    /// back. Anthropic rejects loopback redirects for this client, so there is
    /// no callback to catch.
    @ViewBuilder
    private var signInSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Sign in")
                    .font(.caption)
                    .fontWeight(.semibold)
                Spacer()
                if account.hasOAuth {
                    Button("Sign out") {
                        awaitingPaste = false
                        pasteInput = ""
                        manager.signOut()
                    }
                    .buttonStyle(.borderless)
                    .font(.caption2)
                }
            }

            if account.hasOAuth, !manager.needsReauth {
                Text(account.accountEmail ?? "Signed in")
                    .font(.caption2)
                    .foregroundColor(Color.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Button(account.hasOAuth && !manager.needsReauth ? "Sign in again" : "Sign in with Claude") {
                manager.beginPasteSignIn()
                awaitingPaste = true
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)

            if awaitingPaste {
                // The one line that earns its place: signing a second account
                // in from a normal window silently re-authorises the first,
                // and nothing on screen would show that.
                Text("For a second account, sign in from a private window.")
                    .font(.caption2)
                    .foregroundColor(Color.secondaryText)

                PasteableTextField(text: $pasteInput, placeholder: "Paste code")
                    .frame(height: 40)
                    .cornerRadius(4)

                Button("Finish sign-in") {
                    manager.completeSignIn(paste: pasteInput) { problem in
                        if problem == nil {
                            pasteInput = ""
                            awaitingPaste = false
                        }
                        manager.errorMessage = problem ?? "Signed in, fetching..."
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
    }

    /// The original cookie route, kept as the fallback when sign-in fails.
    @ViewBuilder
    private var cookieSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Session cookie")
                    .font(.caption)
                    .fontWeight(.semibold)
                Spacer()
                Button(action: {
                    NSWorkspace.shared.open(URL(string: "https://github.com/Artzainnn/ClaudeUsageBar/blob/main/setup-guide.png")!)
                }) {
                    Text("View tutorial →")
                        .font(.caption2)
                        .foregroundColor(.blue)
                }
                .buttonStyle(.borderless)
            }

            VStack(alignment: .leading, spacing: 2) {
                // The Network tab route told people to copy the Cookie
                // header, and they reliably stopped at the first semicolon
                // and got anthropic-device-id instead. The Application tab
                // gives one unambiguous value.
                Text("1. Open claude.ai and sign in")
                Text("2. Press F12 (or Cmd+Option+I)")
                Text("3. Go to Application > Cookies > claude.ai")
                Text("4. Click the row named 'sessionKey'")
                Text("5. Copy its whole Value (starts sk-ant-sid)")
            }
            .font(.caption2)
            .foregroundColor(Color.secondaryText)

            PasteableTextField(
                text: $sessionCookieInput,
                placeholder: hasSavedCookie
                    ? "A cookie is saved. Paste a new one to replace it."
                    : "Paste cookie here..."
            )
            .frame(height: 40)
            .cornerRadius(4)

            HStack(spacing: 8) {
                Button("Save Cookie & Fetch") {
                    NSLog("ClaudeUsage: Save clicked, input length: \(sessionCookieInput.count)")
                    if sessionCookieInput.isEmpty {
                        manager.errorMessage = "Cookie field is empty!"
                    } else {
                        if let problem = manager.saveSessionCookie(sessionCookieInput) {
                            manager.errorMessage = problem
                            return
                        }
                        hasSavedCookie = true
                        sessionCookieInput = ""
                        manager.fetchUsage()
                        manager.errorMessage = "Cookie saved, fetching..."
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                if hasSavedCookie {
                    Button("Clear Cookie") {
                        sessionCookieInput = ""
                        hasSavedCookie = false
                        manager.clearSessionCookie()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
    }

    /// The cookie route is the fallback now, so it sits behind a disclosure
    /// instead of competing with sign-in.
    @ViewBuilder
    private var cookieFallbackSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(showCookie ? "Hide session cookie" : "Use a session cookie instead") {
                showCookie.toggle()
            }
            .buttonStyle(.borderless)
            .font(.caption2)

            if showCookie { cookieSection }
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(account.color)
                .frame(width: 3)

            VStack(alignment: .leading, spacing: 12) {
                header
                blockedBanner
            if let error = manager.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.orange)
                    .padding(.bottom, 8)
            }

            // Only show usage if data has been fetched
            if !manager.hasFetchedData {
                Text("Sign in below to get started.")
                    .font(.subheadline)
                    .foregroundColor(Color.secondaryText)
                    .padding(.vertical, 8)
            }

            // Session Usage
            if manager.hasFetchedData {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Session (5 hour)")
                        .font(.subheadline)
                    Spacer()
                    if let resetTime = manager.sessionResetsAt {
                        Text("Resets \(formatReset(resetTime, relative: accounts.showCountdown))")
                            .font(.caption)
                            .foregroundColor(Color.secondaryText)
                    }
                }

                UsageBar(value: manager.sessionPercentage,
                         color: colorForPercentage(manager.sessionPercentage))

                Text("\(Int(manager.sessionPercentage * 100))% used")
                    .font(.caption)
                    .foregroundColor(Color.secondaryText)
            }

            // Weekly Usage
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Weekly (7 day)")
                        .font(.subheadline)
                    Spacer()
                    if let resetTime = manager.weeklyResetsAt {
                        Text("Resets \(formatReset(resetTime, includeDate: true, relative: accounts.showCountdown))")
                            .font(.caption)
                            .foregroundColor(Color.secondaryText)
                    }
                }

                UsageBar(value: manager.weeklyPercentage,
                         color: colorForPercentage(manager.weeklyPercentage))

                Text("\(Int(manager.weeklyPercentage * 100))% used")
                    .font(.caption)
                    .foregroundColor(Color.secondaryText)
            }

            // Weekly Sonnet Usage (only show if available)
            if manager.hasWeeklySonnet && manager.hasFetchedData {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Weekly Sonnet (7 day)")
                            .font(.subheadline)
                        Spacer()
                        if let resetTime = manager.weeklySonnetResetsAt {
                            Text("Resets \(formatReset(resetTime, includeDate: true, relative: accounts.showCountdown))")
                                .font(.caption)
                                .foregroundColor(Color.secondaryText)
                        }
                    }

                    UsageBar(value: manager.weeklySonnetPercentage,
                             color: colorForPercentage(manager.weeklySonnetPercentage))

                    Text("\(Int(manager.weeklySonnetPercentage * 100))% used")
                        .font(.caption)
                        .foregroundColor(Color.secondaryText)
                }
            }

            // Weekly Fable Usage — only surfaced once usage is above 1%
            // (new model, counted separately; hidden while idle to avoid clutter).
            if manager.hasWeeklyFable && manager.hasFetchedData && manager.weeklyFableUsage >= 1 {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Weekly Fable (7 day)")
                            .font(.subheadline)
                        Spacer()
                        if let resetTime = manager.weeklyFableResetsAt {
                            Text("Resets \(formatReset(resetTime, includeDate: true, relative: accounts.showCountdown))")
                                .font(.caption)
                                .foregroundColor(Color.secondaryText)
                        }
                    }

                    UsageBar(value: manager.weeklyFablePercentage,
                             color: colorForPercentage(manager.weeklyFablePercentage))

                    Text("\(Int(manager.weeklyFablePercentage * 100))% used")
                        .font(.caption)
                        .foregroundColor(Color.secondaryText)
                }
            }

            // Usage credits (pay-as-you-go). Only shown once credits are actually
            // used; links out to manage credits on claude.ai.
            if manager.hasCreditUsage || manager.freeCreditsMinor > 0 {
                let spentMinor = manager.extraSpentMinor
                let limitMinor = manager.extraLimitMinor
                let pct = limitMinor > 0 ? Double(spentMinor) / Double(limitMinor) : 0
                let pctInt = Int((pct * 100).rounded())
                // Show the exact % up to the limit; once over, just say "over limit".
                let pctLabel = pctInt > 100 ? "over limit" : "\(pctInt)%"
                let fmt: (Int) -> String = { minor in
                    let v = Double(minor) / 100.0
                    return manager.creditCurrency == "USD"
                        ? String(format: "$%.2f", v)
                        : String(format: "%@ %.2f", manager.creditCurrency, v)
                }
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Extra usage")
                            .font(.subheadline)
                        Spacer()
                        Button(action: {
                            if let url = URL(string: "https://claude.ai/new#settings/usage") {
                                NSWorkspace.shared.open(url)
                            }
                        }) {
                            Text("Manage →")
                                .font(.caption.weight(.semibold))
                                .foregroundColor(.accentColor)
                        }
                        .buttonStyle(.borderless)
                    }

                    // Reset date, shortened (e.g. "Resets Aug 1") so it fits inline.
                    let shortReset: String? = manager.extraResetsAt.map { d in
                        let f = DateFormatter(); f.dateFormat = "MMM d"
                        return "Resets \(f.string(from: d))"
                    }

                    // Spend vs monthly limit — only when there's actual spend.
                    if manager.hasCreditUsage {
                        if limitMinor > 0 {
                            UsageBar(value: min(pct, 1.0),
                                     color: colorForPercentage(pct))
                        }
                        HStack {
                            Text(limitMinor > 0
                                 ? "\(fmt(spentMinor)) of \(fmt(limitMinor)) · \(pctLabel)"
                                 : "\(fmt(spentMinor)) spent")
                                .font(.caption)
                                .foregroundColor(Color.secondaryText)
                            Spacer()
                            if let r = shortReset {
                                Text(r)
                                    .font(.caption)
                                    .foregroundColor(Color.secondaryText)
                            }
                        }
                    }

                    if manager.freeCreditsMinor > 0 {
                        Text("\(fmt(manager.freeCreditsMinor)) free credits left")
                            .font(.caption2)
                            .foregroundColor(Color.secondaryText)
                            .opacity(0.85)
                    }
                }
            }

            // Discreet reassurance line naming whichever of Fable / extra usage
            // is not being consumed (nothing shown when both are active).
            if manager.hasFetchedData {
                let fableActive = manager.hasWeeklyFable && manager.weeklyFableUsage >= 1
                let extraActive = manager.hasCreditUsage || manager.freeCreditsMinor > 0
                if !fableActive || !extraActive {
                    Text(
                        !fableActive && !extraActive ? "No Fable or extra usage"
                        : !extraActive ? "No extra usage"
                        : "No Fable usage"
                    )
                    .font(.caption2)
                    .foregroundColor(Color.secondaryText)
                    .opacity(0.6)
                }
            }
            }
            // Which credential is actually being used, so a silent fallback
            // from a dead token to a cookie is visible rather than mysterious.
            if manager.hasCredential {
                Text(manager.authSourceLabel)
                    .font(.caption2)
                    .foregroundColor(manager.needsReauth ? .orange : Color.secondaryText)
                    .opacity(manager.needsReauth ? 1 : 0.7)
            }

            Button(showingCookieInput ? "Hide Sign-in" : "Set Sign-in") {
                showingCookieInput.toggle()
            }
            .buttonStyle(.borderless)
            .font(.caption)

            if showingCookieInput {
                VStack(alignment: .leading, spacing: 12) {
                    signInSection
                    Divider()
                    cookieFallbackSection
                }
                .padding(8)
                .background(Color.secondary.opacity(0.1))
                .cornerRadius(6)
                .id("cookie-anchor")
            }
            }
        }
        .onAppear {
            sessionCookieInput = ""
            hasSavedCookie = account.hasCookie
            // An account already leaning on its cookie shows that section open.
            showCookie = manager.usingCookieFallback
        }
        .onChange(of: manager.usingCookieFallback) { isFallingBack in
            if isFallingBack { showCookie = true }
        }
    }

    /// Says plainly that the account is out, and when it comes back. Without
    /// this the only clue is a full bar the eye slides past.
    @ViewBuilder
    private var blockedBanner: some View {
        if manager.isBlocked {
            let binding = manager.bindingLimit
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text("\u{26A0}")
                        .font(.caption)
                    Text("\(binding.kind.label) limit reached")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(.red)
                }
                if let resetsAt = manager.bindingResetsAt {
                    Text("Back \(formatReset(resetsAt, includeDate: binding.kind == .weekly, relative: accounts.showCountdown))")
                        .font(.caption2)
                        .foregroundColor(Color.secondaryText)
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.red.opacity(0.10))
            .cornerRadius(6)
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text(account.emoji)
                .font(.system(size: 13))
                .opacity(manager.needsReauth ? 0.4 : 1)
            Text(account.displayName)
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundColor(account.color)
            Spacer()
            if manager.isLoading {
                Text("updating")
                    .font(.caption2)
                    .foregroundColor(Color.secondaryText)
            } else if manager.hasFetchedData {
                let binding = manager.bindingLimit
                Text("\(binding.kind == .weekly ? "W" : "")\(binding.percent)%")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundColor(colorForPercentage(Double(binding.percent) / 100.0))
            }
        }
    }
}


/// Add, name, style, and remove accounts.
///
/// The emoji is the identity signal in the menu bar, so it is the first thing
/// offered; the colour is what marks the account inside the popup.
struct AccountsSettingsSection: View {
    @ObservedObject var accounts: AccountsController
    @State private var editingId: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Accounts")
                    .font(.caption)
                    .fontWeight(.semibold)
                Spacer()
                Button("Add Account") {
                    accounts.addAccount()
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }

            ForEach(accounts.managers, id: \.account.id) { manager in
                accountRow(manager)
            }
        }
    }

    @ViewBuilder
    private func accountRow(_ manager: UsageManager) -> some View {
        let account = manager.account
        let isEditing = editingId == account.id

        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(account.emoji)
                    .font(.system(size: 13))
                Text(account.displayName)
                    .font(.caption)
                    .foregroundColor(account.color)
                Spacer()
                Button(isEditing ? "Done" : "Edit") {
                    editingId = isEditing ? nil : account.id
                }
                .buttonStyle(.borderless)
                .font(.caption2)

                if accounts.managers.count > 1 {
                    Button("Remove") {
                        if editingId == account.id { editingId = nil }
                        accounts.removeAccount(id: account.id)
                    }
                    .buttonStyle(.borderless)
                    .font(.caption2)
                    .foregroundColor(.red)
                }
            }

            if isEditing {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Text("Name")
                            .font(.caption2)
                            .foregroundColor(Color.secondaryText)
                            .frame(width: 40, alignment: .leading)
                        TextField("Account name", text: Binding(
                            get: { manager.account.name },
                            set: { newValue in
                                var updated = manager.account
                                updated.name = newValue
                                accounts.update(updated)
                            }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .font(.caption)
                    }

                    HStack(alignment: .top, spacing: 6) {
                        Text("Icon")
                            .font(.caption2)
                            .foregroundColor(Color.secondaryText)
                            .frame(width: 40, alignment: .leading)
                        emojiPicker(manager)
                    }

                    HStack(spacing: 6) {
                        Text("Colour")
                            .font(.caption2)
                            .foregroundColor(Color.secondaryText)
                            .frame(width: 40, alignment: .leading)
                        colorPicker(manager)
                    }
                }
                .padding(.leading, 4)
            }
        }
        .padding(8)
        .background(account.color.opacity(0.08))
        .cornerRadius(6)
    }

    private func emojiPicker(_ manager: UsageManager) -> some View {
        // A fixed set keeps the menu bar legible; every one of these renders
        // at a consistent width in the status bar.
        let columns = [GridItem(.adaptive(minimum: 26), spacing: 4)]
        return LazyVGrid(columns: columns, alignment: .leading, spacing: 4) {
            ForEach(Account.emojiChoices, id: \.self) { emoji in
                Button(action: {
                    var updated = manager.account
                    updated.emoji = emoji
                    accounts.update(updated)
                }) {
                    Text(emoji)
                        .font(.system(size: 14))
                        .frame(width: 24, height: 24)
                        .background(
                            manager.account.emoji == emoji
                                ? Color.accentColor.opacity(0.25)
                                : Color.clear
                        )
                        .cornerRadius(4)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func colorPicker(_ manager: UsageManager) -> some View {
        HStack(spacing: 6) {
            ForEach(Account.palette, id: \.self) { hex in
                let isSelected = manager.account.colorHex == hex
                Button(action: {
                    var updated = manager.account
                    updated.colorHex = hex
                    accounts.update(updated)
                }) {
                    Circle()
                        .fill(Color(nsColor: NSColor(hex: hex) ?? .controlAccentColor))
                        .frame(width: 16, height: 16)
                        .overlay(
                            Circle()
                                .strokeBorder(Color.primary.opacity(isSelected ? 0.8 : 0), lineWidth: 2)
                        )
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
    }
}
