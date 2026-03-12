import AppKit

@main
struct MacOSApp {
    static func main() {
        // Sandbox disabled during development
        // if !Sandbox.apply() {
        //     print("[FATAL] Sandbox failed to apply - refusing to run unsandboxed")
        //     exit(1)
        // }

        // Set CWD to app data folder
        let appDataPath = ExternalState.appDataFolder
        FileManager.default.changeCurrentDirectoryPath(appDataPath)
        print("[Init] CWD set to \(appDataPath)")

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private let logPanelController = LogPanelController()
    private var stateRefreshTimer: Timer?
    private var specialKeyCheck: Any?

    // Track which services have a pending operation (shows ⏳)
    private var pendingServices: Set<String> = []

    private var darcItem: NSMenuItem?
    private var darcStartItem: NSMenuItem?
    private var darcStopItem: NSMenuItem?
    private var chromeItem: NSMenuItem?
    private var chromeStartItem: NSMenuItem?
    private var chromeStopItem: NSMenuItem?
    private var chromeHeadlessItem: NSMenuItem?
    private var legacyVMItem: NSMenuItem?
    private var legacyVMStartItem: NSMenuItem?
    private var legacyVMStopItem: NSMenuItem?
    private var systemVMItem: NSMenuItem?
    private var systemVMStartItem: NSMenuItem?
    private var systemVMStopItem: NSMenuItem?
    private var appVMItem: NSMenuItem?
    private var appVMStartItem: NSMenuItem?
    private var appVMStopItem: NSMenuItem?
    private var runAtStartupItem: NSMenuItem?
    private var bindCapslockItem: NSMenuItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMainMenu()
        setupStatusItem()
        renderMenuLabels()
        // Do expensive init off main thread
        DispatchQueue.global(qos: .userInitiated).async {
            ExternalState.shared.updateAll()
            _ = ExternalState.shared.launchBrowserStack()
            Task { @MainActor in self.renderMenuLabels() }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // When the app is launched again while already running, bring Darc to foreground or start it
        let state = ExternalState.shared
        if state.darcRunning {
            if let app = state.darcAppRef {
                app.activate()
            }
        } else {
            DispatchQueue.global(qos: .userInitiated).async {
                _ = state.launchBrowserStack()
                Task { @MainActor in self.renderMenuLabels() }
            }
        }
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        stopStateRefreshLoop()
    }

    /// Create a minimal main menu so keyboard shortcuts (Cmd+C, Cmd+A, etc.)
    /// work in panels like the log viewer even though this is an LSUIElement app.
    private func setupMainMenu() {
        let mainMenu = NSMenu()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)
        NSApplication.shared.mainMenu = mainMenu
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem?.button {
            if let resourceURL = Bundle.main.resourceURL,
               let icon = NSImage(contentsOf: resourceURL.appendingPathComponent("app.icns")) {
                icon.size = NSSize(width: 18, height: 18)
                icon.isTemplate = false
                button.image = icon
            } else {
                button.image = NSImage(systemSymbolName: "app.fill", accessibilityDescription: "Menu")
                button.image?.size = NSSize(width: 18, height: 18)
            }
        }

        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        menu.addItem(NSMenuItem(title: "Status: Ready", action: nil, keyEquivalent: ""))
        menu.addItem(.separator())

        buildProfilesSubmenu(parent: menu)
        darcItem = buildDarcSubmenu(parent: menu)
        chromeItem = buildChromeSubmenu(parent: menu)
        legacyVMItem = buildSubmenu(parent: menu, title: "Legacy VM", startSelector: #selector(legacyVMStartAction), stopSelector: #selector(legacyVMStopAction), startRef: &legacyVMStartItem, stopRef: &legacyVMStopItem)
        systemVMItem = buildSubmenu(parent: menu, title: "System VM", startSelector: #selector(systemVMStartAction), stopSelector: #selector(systemVMStopAction), startRef: &systemVMStartItem, stopRef: &systemVMStopItem)
        appVMItem = buildSubmenu(parent: menu, title: "App VM", startSelector: #selector(appVMStartAction), stopSelector: #selector(appVMStopAction), startRef: &appVMStartItem, stopRef: &appVMStopItem)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "System Logs", action: #selector(showLogsAction), keyEquivalent: ""))
        menu.addItem(.separator())

        runAtStartupItem = NSMenuItem(title: "Run at Startup", action: #selector(runAtStartupAction), keyEquivalent: "")
        bindCapslockItem = NSMenuItem(title: "Bind to Capslock", action: #selector(bindCapslockAction), keyEquivalent: "")
        if let runAtStartupItem { menu.addItem(runAtStartupItem) }
        if let bindCapslockItem { menu.addItem(bindCapslockItem) }

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "About", action: #selector(aboutAction), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quitAction), keyEquivalent: "q"))

        setTargets(for: menu)
        statusItem?.menu = menu
    }

    private func buildSubmenu(parent: NSMenu, title: String, startSelector: Selector, stopSelector: Selector, startRef: inout NSMenuItem?, stopRef: inout NSMenuItem?) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        let startItem = NSMenuItem(title: "Start", action: startSelector, keyEquivalent: "")
        let stopItem = NSMenuItem(title: "Stop", action: stopSelector, keyEquivalent: "")
        submenu.addItem(startItem)
        submenu.addItem(stopItem)
        item.submenu = submenu
        parent.addItem(item)
        startRef = startItem
        stopRef = stopItem
        return item
    }

    private var chromeVariantItems: [NSMenuItem] = []
    private var chromeSubmenu: NSMenu?

    private func buildDarcSubmenu(parent: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: "Darc", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        let startItem = NSMenuItem(title: "Start", action: #selector(darcStartAction), keyEquivalent: "")
        let stopItem = NSMenuItem(title: "Stop", action: #selector(darcStopAction), keyEquivalent: "")
        let saveWindowsItem = NSMenuItem(title: "Save Window Positions", action: #selector(darcSaveWindowPositionsAction), keyEquivalent: "")
        let restoreWindowsItem = NSMenuItem(title: "Restore Window Positions", action: #selector(darcRestoreWindowPositionsAction), keyEquivalent: "")
        submenu.addItem(startItem)
        submenu.addItem(stopItem)
        submenu.addItem(.separator())
        submenu.addItem(saveWindowsItem)
        submenu.addItem(restoreWindowsItem)
        item.submenu = submenu
        parent.addItem(item)
        darcStartItem = startItem
        darcStopItem = stopItem
        return item
    }

    private func buildChromeSubmenu(parent: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: "Chrome Engine", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        let start = NSMenuItem(title: "Start", action: #selector(chromeStartAction), keyEquivalent: "")
        let stop = NSMenuItem(title: "Stop", action: #selector(chromeStopAction), keyEquivalent: "")
        let headless = NSMenuItem(title: "Headless", action: #selector(chromeHeadlessAction), keyEquivalent: "")
        submenu.addItem(start)
        submenu.addItem(stop)
        submenu.addItem(headless)

        // Chrome variants (shown only when Option key is held)
        refreshChromeMenuOptions(in: submenu)

        item.submenu = submenu
        parent.addItem(item)
        chromeStartItem = start
        chromeStopItem = stop
        chromeHeadlessItem = headless
        chromeSubmenu = submenu
        return item
    }

    private var chromeVariantSeparator: NSMenuItem?

    private func refreshChromeMenuOptions(in submenu: NSMenu) {
        // Remove old variant items
        for old in chromeVariantItems { submenu.removeItem(old) }
        chromeVariantItems.removeAll()
        if let sep = chromeVariantSeparator { submenu.removeItem(sep); chromeVariantSeparator = nil }

        let state = ExternalState.shared
        let minVersion = 145
        let showVariants = NSEvent.modifierFlags.contains(.option)

        // Only scan all Chrome variants when Option key is held
        if showVariants {
            state.refreshChromeAvailability(scanAll: true)
        }
        let selected = state.selectedChrome()

        // Only show variant selector when Option key is held
        guard showVariants else { return }

        let sep = NSMenuItem.separator()
        submenu.addItem(sep)
        chromeVariantSeparator = sep

        for chrome in state.installedChromes where chrome.isInstalled && (chrome.version ?? 0) >= minVersion {
            let versionStr = chrome.version.map { " (v\($0))" } ?? ""
            let menuItem = NSMenuItem(title: "\(chrome.name)\(versionStr)", action: #selector(chromeVariantSelected(_:)), keyEquivalent: "")
            menuItem.target = self
            menuItem.representedObject = chrome.variant
            menuItem.state = (chrome.variant == selected?.variant) ? .on : .off
            submenu.addItem(menuItem)
            chromeVariantItems.append(menuItem)
        }

        if chromeVariantItems.isEmpty {
            let none = NSMenuItem(title: "No compatible Chrome found", action: nil, keyEquivalent: "")
            none.isEnabled = false
            submenu.addItem(none)
            chromeVariantItems.append(none)
        }
    }

    // MARK: - Profiles submenu

    private var profilesItem: NSMenuItem?
    private var profilesSubmenu: NSMenu?
    private var profileMenuItems: [NSMenuItem] = []

    private func buildProfilesSubmenu(parent: NSMenu) {
        let profileName = ExternalState.shared.selectedProfileName()
        let item = NSMenuItem(title: "Profile: \(profileName)", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        item.submenu = submenu
        parent.addItem(item)
        profilesItem = item
        profilesSubmenu = submenu
        rebuildProfileItems()
    }

    private func rebuildProfileItems() {
        guard let submenu = profilesSubmenu else { return }
        for old in profileMenuItems { submenu.removeItem(old) }
        profileMenuItems.removeAll()

        let state = ExternalState.shared
        let selected = state.selectedProfileName()
        var profiles = state.chromeProfiles.map(\.name)

        // Always show "default" even if the folder doesn't exist yet
        if !profiles.contains("default") {
            profiles.insert("default", at: 0)
        }

        for name in profiles {
            let menuItem = NSMenuItem(title: name, action: #selector(profileSelected(_:)), keyEquivalent: "")
            menuItem.target = self
            menuItem.representedObject = name
            menuItem.state = (name == selected) ? .on : .off
            submenu.addItem(menuItem)
            profileMenuItems.append(menuItem)
        }

        let sep = NSMenuItem.separator()
        submenu.addItem(sep)
        profileMenuItems.append(sep)

        let newItem = NSMenuItem(title: "New...", action: #selector(newProfileAction), keyEquivalent: "")
        newItem.target = self
        submenu.addItem(newItem)
        profileMenuItems.append(newItem)
    }

    @objc private func profileSelected(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        let state = ExternalState.shared
        let wasRunning = state.chromeRunning
        let darcWasRunning = state.darcRunning

        state.selectProfile(name)

        if wasRunning {
            runServiceAction("chrome") {
                if darcWasRunning { ExternalState.shared.stopDarc() }
                ExternalState.shared.stopChrome()
                _ = ExternalState.shared.startChrome()
                if darcWasRunning { _ = ExternalState.shared.startDarc() }
            }
        } else {
            renderMenuLabels()
        }
    }

    @objc private func newProfileAction() {
        let alert = NSAlert()
        alert.messageText = "New Profile"
        alert.informativeText = "Enter a name for the new profile:"
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")

        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        input.placeholderString = "profile-name"
        alert.accessoryView = input

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }

        let name = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }

        let state = ExternalState.shared
        if let err = state.createProfile(name: name) {
            let errAlert = NSAlert()
            errAlert.messageText = "Error"
            errAlert.informativeText = err
            errAlert.runModal()
            return
        }

        // Select and start with the new profile
        let wasRunning = state.chromeRunning
        let darcWasRunning = state.darcRunning
        state.selectProfile(name)

        if wasRunning {
            runServiceAction("chrome") {
                if darcWasRunning { ExternalState.shared.stopDarc() }
                ExternalState.shared.stopChrome()
                _ = ExternalState.shared.startChrome()
                if darcWasRunning { _ = ExternalState.shared.startDarc() }
            }
        } else {
            _ = state.startChrome()
            renderMenuLabels()
        }
    }

    @objc private func chromeVariantSelected(_ sender: NSMenuItem) {
        guard let variant = sender.representedObject as? String else { return }
        let state = ExternalState.shared
        let wasRunning = state.chromeRunning
        let darcWasRunning = state.darcRunning

        state.selectChromeVariant(variant)

        if wasRunning {
            runServiceAction("chrome") {
                if darcWasRunning { ExternalState.shared.stopDarc() }
                ExternalState.shared.stopChrome()
                _ = ExternalState.shared.startChrome()
                if darcWasRunning { _ = ExternalState.shared.startDarc() }
            }
        } else {
            renderMenuLabels()
        }
    }

    private func setTargets(for menu: NSMenu) {
        for item in menu.items {
            item.target = self
            if let submenu = item.submenu { setTargets(for: submenu) }
        }
    }

    // MARK: - NSMenuDelegate

    func menuWillOpen(_ menu: NSMenu) {
        renderMenuLabels()
        // Refresh state in background, then start polling while menu is open
        DispatchQueue.global(qos: .utility).async { [weak self] in
            ExternalState.shared.refreshRuntimeStateFromSystemTruth()
            Task { @MainActor [weak self] in self?.renderMenuLabels() }
        }
        startStateRefreshLoop()
        // Monitor Option key press/release while menu is open to toggle variant items.
        // NSMenu runs its own event tracking loop so addLocalMonitor won't fire;
        // addGlobalMonitor catches modifier changes during menu tracking.
        specialKeyCheck = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let chromeSubmenu = self.chromeSubmenu else { return }
                self.refreshChromeMenuOptions(in: chromeSubmenu)
            }
        }
    }

    func menuDidClose(_ menu: NSMenu) {
        stopStateRefreshLoop()
        if let specialKeyCheck {
            NSEvent.removeMonitor(specialKeyCheck)
            self.specialKeyCheck = nil
        }
    }

    // MARK: - Render (reads cached state only, no I/O)

    private func serviceTitle(_ name: String, key: String, running: Bool) -> String {
        if pendingServices.contains(key) { return "\(name) ⏳" }
        return running ? "\(name) 🟢" : name
    }

    private func renderMenuLabels() {
        let state = ExternalState.shared

        darcItem?.title = serviceTitle("Darc", key: "darc", running: state.darcRunning)
        chromeItem?.title = serviceTitle("Chrome Engine", key: "chrome", running: state.chromeRunning)

        // Force menu to notice title changes on submenu items
        statusItem?.menu?.update()
        legacyVMItem?.title = serviceTitle("Legacy VM", key: "legacyVM", running: state.legacyVMRunning)
        systemVMItem?.title = serviceTitle("System VM", key: "systemVM", running: state.systemVMRunning)
        appVMItem?.title = serviceTitle("App VM", key: "appVM", running: state.appVMRunning)

        let darcPending = pendingServices.contains("darc")
        let chromePending = pendingServices.contains("chrome")
        let legacyPending = pendingServices.contains("legacyVM")
        let systemPending = pendingServices.contains("systemVM")
        let appPending = pendingServices.contains("appVM")

        darcStartItem?.isEnabled = !state.darcRunning && !darcPending
        darcStopItem?.isEnabled = state.darcRunning && !darcPending
        chromeStartItem?.isEnabled = !state.chromeRunning && !chromePending
        chromeStopItem?.isEnabled = state.chromeRunning && !chromePending
        legacyVMStartItem?.isEnabled = !state.legacyVMRunning && !legacyPending
        legacyVMStopItem?.isEnabled = state.legacyVMRunning && !legacyPending
        systemVMStartItem?.isEnabled = !state.systemVMRunning && !systemPending
        systemVMStopItem?.isEnabled = state.systemVMRunning && !systemPending
        appVMStartItem?.isEnabled = !state.appVMRunning && !appPending
        appVMStopItem?.isEnabled = state.appVMRunning && !appPending

        chromeHeadlessItem?.state = state.boolSetting("chrome_headless", default: true) ? .on : .off
        runAtStartupItem?.state = state.boolSetting("run_at_startup", default: false) ? .on : .off
        bindCapslockItem?.state = state.boolSetting("bind_capslock", default: false) ? .on : .off

        // Rebuild dynamic submenu items (handles late discovery after background updateAll)
        if let chromeSubmenu {
            refreshChromeMenuOptions(in: chromeSubmenu)
        }
        profilesItem?.title = "Profile: \(state.selectedProfileName())"
        rebuildProfileItems()
    }

    private func runServiceAction(_ key: String, action: @escaping @Sendable () -> Void) {
        pendingServices.insert(key)
        renderMenuLabels()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            action()
            Task { @MainActor [weak self] in
                self?.pendingServices.remove(key)
                self?.renderMenuLabels()
            }
        }
    }

    // MARK: - Actions

    @objc private func darcStartAction() {
        runServiceAction("darc") {
            _ = ExternalState.shared.startDarc()
            ExternalState.shared.setBoolSetting("darc_was_running", true)
        }
    }

    @objc private func darcStopAction() {
        runServiceAction("darc") {
            ExternalState.shared.stopDarc()
            ExternalState.shared.setBoolSetting("darc_was_running", false)
        }
    }

    @objc private func darcSaveWindowPositionsAction() {
        DispatchQueue.global(qos: .userInitiated).async {
            ExternalState.shared.saveDarcWindowPositions()
        }
    }

    @objc private func darcRestoreWindowPositionsAction() {
        DispatchQueue.global(qos: .userInitiated).async {
            ExternalState.shared.restoreDarcWindowPositions()
        }
    }

    @objc private func chromeStartAction() {
        runServiceAction("chrome") {
            _ = ExternalState.shared.startChrome()
            ExternalState.shared.setBoolSetting("chrome_was_running", true)
        }
    }

    @objc private func chromeStopAction() {
        runServiceAction("chrome") {
            ExternalState.shared.stopChrome()
            ExternalState.shared.setBoolSetting("chrome_was_running", false)
            ExternalState.shared.setBoolSetting("darc_was_running", false)
        }
    }

    @objc private func chromeHeadlessAction() {
        let current = ExternalState.shared.boolSetting("chrome_headless", default: true)
        let next = !current
        ExternalState.shared.setBoolSetting("chrome_headless", next)

        if ExternalState.shared.chromeRunning {
            runServiceAction("chrome") {
                let darcWasRunning = ExternalState.shared.darcRunning
                if darcWasRunning { ExternalState.shared.stopDarc() }
                ExternalState.shared.stopChrome()
                _ = ExternalState.shared.startChrome()
                if darcWasRunning { _ = ExternalState.shared.startDarc() }
            }
        } else {
            renderMenuLabels()
        }
    }

    @objc private func legacyVMStartAction() {
        runServiceAction("legacyVM") { _ = ExternalState.shared.startLegacyVM() }
    }

    @objc private func legacyVMStopAction() {
        runServiceAction("legacyVM") { _ = ExternalState.shared.stopLegacyVM() }
    }

    @objc private func systemVMStartAction() {
        runServiceAction("systemVM") { _ = ExternalState.shared.startColimaVM(profileName: "system") }
    }

    @objc private func systemVMStopAction() {
        runServiceAction("systemVM") { _ = ExternalState.shared.stopColimaVM(profileName: "system") }
    }

    @objc private func appVMStartAction() {
        runServiceAction("appVM") { _ = ExternalState.shared.startColimaVM(profileName: "apps") }
    }

    @objc private func appVMStopAction() {
        runServiceAction("appVM") { _ = ExternalState.shared.stopColimaVM(profileName: "apps") }
    }

    @objc private func showLogsAction() {
        logPanelController.present()
    }

    @objc private func runAtStartupAction() {
        let current = ExternalState.shared.boolSetting("run_at_startup", default: false)
        ExternalState.shared.setBoolSetting("run_at_startup", !current)
        renderMenuLabels()
    }

    @objc private func bindCapslockAction() {
        let current = ExternalState.shared.boolSetting("bind_capslock", default: false)
        ExternalState.shared.setBoolSetting("bind_capslock", !current)
        renderMenuLabels()
    }

    @objc private func aboutAction() { NSApp.orderFrontStandardAboutPanel(nil) }
    @objc private func quitAction() {
        // Save running state before stopping so it can be restored on next launch
        let state = ExternalState.shared
        state.setBoolSetting("darc_was_running", state.darcRunning)
        state.setBoolSetting("chrome_was_running", state.chromeRunning)
        state.stopChrome()  // stopChrome calls stopDarc internally
        NSApp.terminate(nil)
    }

    // MARK: - Background state refresh

    private func startStateRefreshLoop() {
        guard stateRefreshTimer == nil else { return }
        stateRefreshTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            // Re-render from cached/computed state + refresh colima in background
            Task { @MainActor [weak self] in self?.renderMenuLabels() }
            DispatchQueue.global(qos: .utility).async { [weak self] in
                ExternalState.shared.refreshRuntimeStateFromSystemTruth()
                Task { @MainActor [weak self] in self?.renderMenuLabels() }
            }
        }
    }

    private func stopStateRefreshLoop() {
        stateRefreshTimer?.invalidate()
        stateRefreshTimer = nil
    }
}
