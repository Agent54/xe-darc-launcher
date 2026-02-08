import AppKit

@main
struct MacOSApp {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        
        let delegate = AppDelegate()
        app.delegate = delegate
        
        app.run()
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem?
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
    }
    
    @MainActor private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "app.fill", accessibilityDescription: "Menu")
            button.image?.size = NSSize(width: 18, height: 18)
        }
        
        let menu = NSMenu()
        
        menu.addItem(NSMenuItem(title: "Open", action: #selector(openAction), keyEquivalent: "o"))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "About", action: #selector(aboutAction), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Preferences...", action: #selector(preferencesAction), keyEquivalent: ","))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quitAction), keyEquivalent: "q"))
        
        // Set the target for all menu items
        for item in menu.items {
            item.target = self
        }
        
        statusItem?.menu = menu
    }
    
    @objc func openAction() {
        print("Open clicked")
    }
    
    @MainActor @objc func aboutAction() {
        NSApp.orderFrontStandardAboutPanel(nil)
    }
    
    @objc func preferencesAction() {
        print("Preferences clicked")
    }
    
    @MainActor @objc func quitAction() {
        NSApp.terminate(nil)
    }
}
