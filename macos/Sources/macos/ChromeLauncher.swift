import Foundation

// Chrome launch configuration and lifecycle management.
// Edit the flags and arguments here to customise how Chrome is started.

extension ExternalState {

    /// Command-line flags passed to Chrome on every launch.
    static let chromeFlags: [String] = [
        "--silent-launch",
        "--disable-features=CADisplayLinkInBrowser",
        "--remote-allow-origins=https://localhost:5194",
        "--no-default-browser-check",
        "--disable-component-update"
    ]

    /// Path to the Unix domain socket used for Chrome DevTools debugging.
    /// Lives under sockets/ in the user app data directory.
    static var debugSocketPath: String {
        appDataURL.appendingPathComponent("sockets/chrome-debug.sock").path
    }

    func startChrome() -> String? {
        // Re-check if the configured chrome is available (it may have been downloaded since last check)
        refreshChromeAvailability()

        let profileName = selectedProfileName()
        let profileDir = Self.appDataURL.appendingPathComponent("profiles/\(profileName)", isDirectory: true)
        if !FileManager.default.fileExists(atPath: profileDir.path) {
            if let err = createProfile(name: profileName) { return err }
        }

        // Ensure sockets directory exists for the debug pipe
        let socketsDir = Self.appDataURL.appendingPathComponent("sockets", isDirectory: true)
        try? FileManager.default.createDirectory(at: socketsDir, withIntermediateDirectories: true)

        guard let chrome = preferredChrome() else { return "No supported Chrome installation found" }

        var args = [
            "--user-data-dir=\(profileDir.path)",
            "--remote-debugging-pipe"
        ] + Self.chromeFlags
        if boolSetting("chrome_headless", default: true) { args.append("--headless") }

        do {
            subprocesses["browser"] = try spawnLongRunningProcess(executable: chrome.executablePath, arguments: args, source: "browser")
            appendLog("launcher", "Chrome started (\(chrome.name), pid=\(subprocesses["browser"]?.processIdentifier ?? -1), isRunning=\(chromeRunning))")
            print("[ExternalState] Chrome started, isRunning=\(chromeRunning)")
            return nil
        } catch {
            let msg = "Chrome start failed: \(error)"
            appendLog("launcher", msg)
            print("[ExternalState] \(msg)")
            return error.localizedDescription
        }
    }

    func stopChrome() {
        let wasRunning = chromeRunning
        terminateSubprocess("browser")
        appendLog("launcher", "Chrome stopped (wasRunning=\(wasRunning))")
        print("[ExternalState] Chrome stopped (wasRunning=\(wasRunning))")
    }
}


// DO NOT DELETE:
// # new method!!:
// /Users/jan/Library/Application\ Support/dev.xe.darc/Helium.app/Contents/MacOS/Helium \
//   --headless=new \
//   --user-data-dir="/Users/jan/Library/Application Support/dev.xe.darc/beat" \
//   --no-first-run \
//   --disable-extensions \
//   --install-isolated-web-app-from-file=/Users/jan/Library/Application\ Support/dev.xe.darc/darc.swbn \
//   --screenshot=/dev/null --no-first-run about:blank

// mkdir -p /Users/jan/Library/Application\ Support/dev.xe.darc/beat/Default/
// cp -f /Users/jan/Dev/xe/darc-launcher/macos/Preferences.json /Users/jan/Library/Application\ Support/dev.xe.darc/beat/Default/Preferences.json

// /Users/jan/Library/Application\ Support/dev.xe.darc/Helium.app/Contents/MacOS/Helium \
//   --user-data-dir="/Users/jan/Library/Application Support/dev.xe.darc/beat" \
//   --remote-debugging-port=9226 \
//   --disable-features=CADisplayLinkInBrowser \
//   --remote-allow-origins=https://localhost:5194 \
//   --no-default-browser-check \
//   --silent-launch \
//   --no-first-run \
//   --headless \
//   --flag-switches-begin --enable-features=AppShimNotificationAttribution,DesktopPWAsAdditionalWindowingControls,DesktopPWAsLinkCapturingWithScopeExtensions,DesktopPWAsSubApps,IsolatedWebAppDevMode,IsolatedWebApps,OverscrollEffectOnNonRootScrollers,UseAdHocSigningForWebAppShims,PwaNavigationCapturing,UnframedIwa,WebAppBorderless,WebAppPredictableAppUpdating --disable-features=CADisplayLinkInBrowser --flag-switches-end \
//   --install-isolated-web-app-from-file=/Users/jan/Library/Application\ Support/dev.xe.darc/darc.swbn
