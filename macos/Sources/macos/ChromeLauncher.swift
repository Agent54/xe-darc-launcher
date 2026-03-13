import Foundation

// Chrome launch configuration and lifecycle management.
// Edit the flags and arguments here to customise how Chrome is started.

extension ExternalState {

    /// File handles for Chrome DevTools Protocol pipe transport.
    /// Write CDP commands to `cdpWriteHandle`, read responses from `cdpReadHandle`.
    /// These are set when Chrome starts with --remote-debugging-pipe and can be
    /// bridged to a Unix socket for workerd or other consumers.
    private static let _cdpHandles = CDPHandles()

    var cdpWriteHandle: FileHandle? {
        get { Self._cdpHandles.writeHandle }
        set { Self._cdpHandles.writeHandle = newValue }
    }
    var cdpReadHandle: FileHandle? {
        get { Self._cdpHandles.readHandle }
        set { Self._cdpHandles.readHandle = newValue }
    }

    /// Command-line flags passed to Chrome on every launch.
    static let chromeFlags: [String] = [
        "--silent-launch",
        "--remote-allow-origins=https://localhost:5194",
        "--no-default-browser-check",
        "--no-first-run",
        "--flag-switches-begin",
        "--enable-features=AppShimNotificationAttribution,DesktopPWAsAdditionalWindowingControls,DesktopPWAsLinkCapturingWithScopeExtensions,DesktopPWAsSubApps,IsolatedWebAppDevMode,IsolatedWebApps,OverscrollEffectOnNonRootScrollers,UseAdHocSigningForWebAppShims,PwaNavigationCapturing,UnframedIwa,WebAppBorderless,WebAppPredictableAppUpdating",
        "--disable-features=CADisplayLinkInBrowser",
        "--flag-switches-end"
    ]
    // DO NOT DELETE:
    //   --remote-debugging-port=9226 \
    //   --remote-allow-origins=https://localhost:5194 \

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
        if boolSetting("chrome_headless", default: true) { args.append("--headless=new") }

        // Install the IWA bundle if it exists
        let iwaPath = Self.appDataURL.appendingPathComponent("darc.swbn").path
        if FileManager.default.fileExists(atPath: iwaPath) {
            args.append("--install-isolated-web-app-from-file=\(iwaPath)")
        }

        // Create pipe pairs for Chrome DevTools Protocol pipe transport.
        // Chrome reads commands from fd 3 and writes responses to fd 4.
        // We keep the other ends for our launcher / future workerd bridge.
        let toChrome = Pipe()    // we write → Chrome reads on fd 3
        let fromChrome = Pipe()  // Chrome writes on fd 4 → we read

        do {
            // spawnLongRunningProcessWithPipes closes the child-side handles after spawn
            let _ = try spawnLongRunningProcessWithPipes(
                executable: chrome.executablePath,
                arguments: args,
                source: "browser",
                extraFDs: [
                    3: toChrome.fileHandleForReading,
                    4: fromChrome.fileHandleForWriting
                ]
            )

            // Store the pipe handles for later CDP communication (e.g. workerd bridge)
            cdpWriteHandle = toChrome.fileHandleForWriting
            cdpReadHandle = fromChrome.fileHandleForReading

            appendLog("launcher", "Chrome started with debug pipe (\(chrome.name), pid=\(_browserPid), isRunning=\(chromeRunning))")
            print("[ExternalState] Chrome started, isRunning=\(chromeRunning)")

            // Check if app shim needs provisioning (in parallel)
            let shimDir = Self.appDataURL.appendingPathComponent("shims/\(profileName)", isDirectory: true)
            let shimApp = shimDir.appendingPathComponent("Darc.app")
            if !FileManager.default.fileExists(atPath: shimApp.path) {
                provisionAppShim(profileName: profileName, profileDir: profileDir, shimApp: shimApp, chrome: chrome)
            }

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

    /// Provision the app shim in the background.
    /// Chrome creates the shim at ~/Applications/Chromium Apps.localized/Darc.app
    /// on first IWA install. We wait for it, move it to our shims dir, restart Chrome
    /// with a fresh Preferences.json.
    private func provisionAppShim(profileName: String, profileDir: URL, shimApp: URL, chrome: InstalledChrome) {
        DispatchQueue.global().async { [weak self] in
            guard let self else { return }
            let fm = FileManager.default
            let systemShimPath = NSHomeDirectory() + "/Applications/Chromium Apps.localized/Darc.app"
            let shimCodeSignature = systemShimPath + "/Contents/_CodeSignature"

            self.appendLog("launcher", "Waiting for app shim at \(systemShimPath)...")

            // Poll for the shim to appear with a valid code signature (max ~20s)
            var found = false
            for _ in 0..<40 {
                if fm.fileExists(atPath: shimCodeSignature) {
                    found = true
                    break
                }
                Thread.sleep(forTimeInterval: 0.5)
                // If Chrome died, abort
                if !self.chromeRunning { break }
            }

            guard found else {
                self.appendLog("launcher", "App shim was not created within timeout")
                return
            }

            self.appendLog("launcher", "App shim found, moving to \(shimApp.path)")

            // Create shims directory
            try? fm.createDirectory(at: shimApp.deletingLastPathComponent(), withIntermediateDirectories: true)

            // Verify the shim's CrAppModeUserDataDir matches our profile dir before moving
            let systemShimPlist = URL(fileURLWithPath: systemShimPath).appendingPathComponent("Contents/Info.plist")
            if let plistData = try? Data(contentsOf: systemShimPlist),
               let plist = try? PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any],
               let shimUserDataDir = plist["CrAppModeUserDataDir"] as? String {
                if !shimUserDataDir.hasPrefix(profileDir.path) {
                    self.appendLog("launcher", "App shim CrAppModeUserDataDir mismatch: \(shimUserDataDir) does not start with \(profileDir.path), skipping")
                    return
                }
            }

            // Move shim to our managed location
            do {
                try fm.moveItem(atPath: systemShimPath, toPath: shimApp.path)
            } catch {
                self.appendLog("launcher", "Failed to move app shim: \(error.localizedDescription)")
                return
            }

            // Close any Finder windows showing the Helium/Chromium Apps folder
            // Uses System Events (Accessibility permission) instead of Finder Automation permission
            Thread.sleep(forTimeInterval: 2.0)
            let closeScript = """
            tell application "System Events"
                tell process "Finder"
                    set windowList to every window
                    repeat with w in windowList
                        set n to name of w
                        if n contains "Helium" or n contains "Chromium" then
                            click button 1 of w
                        end if
                    end repeat
                end tell
            end tell
            """
            let osascript = Process()
            osascript.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            osascript.arguments = ["-e", closeScript]
            osascript.standardOutput = FileHandle.nullDevice
            osascript.standardError = FileHandle.nullDevice
            try? osascript.run()
            osascript.waitUntilExit()

            // Stop Chrome
            self.appendLog("launcher", "Stopping Chrome for Preferences.json refresh...")
            self.stopChrome()

            // Wait a moment for Chrome to fully exit
            Thread.sleep(forTimeInterval: 1.0)

            // Copy Preferences.json over the profile's Default/Preferences
            let defaultDir = profileDir.appendingPathComponent("Default", isDirectory: true)
            try? fm.createDirectory(at: defaultDir, withIntermediateDirectories: true)
            let destPrefs = defaultDir.appendingPathComponent("Preferences")
            if let bundlePrefs = Bundle.main.resourceURL?.appendingPathComponent("Preferences.json"),
               fm.fileExists(atPath: bundlePrefs.path) {
                try? fm.removeItem(at: destPrefs)
                do {
                    try fm.copyItem(at: bundlePrefs, to: destPrefs)
                    self.appendLog("launcher", "Copied Preferences.json to \(destPrefs.path)")
                } catch {
                    self.appendLog("launcher", "Failed to copy Preferences.json: \(error.localizedDescription)")
                }
            }

            // Restart Chrome
            self.appendLog("launcher", "Restarting Chrome and Darc after shim provisioning...")
            let err = self.startDarc()
            if let err {
                self.appendLog("launcher", "Darc relaunch failed: \(err)")
            }
        }
    }

    /// Spawn a process with extra file descriptors mapped into the child using posix_spawn.
    /// Uses posix_spawn_file_actions_adddup2 for reliable fd mapping.
    /// Swift's Process uses POSIX_SPAWN_CLOEXEC_DEFAULT which closes all unmapped fds,
    /// so we must use posix_spawn directly to pass fds 3/4 to the child.
    func spawnLongRunningProcessWithPipes(executable: String, arguments: [String], source: String, extraFDs: [Int32: FileHandle]) throws -> Process {
        var env = ProcessInfo.processInfo.environment
        if env["HOME"] == nil { env["HOME"] = NSHomeDirectory() }
        env["PATH"] = (["/opt/homebrew/bin", "/usr/local/bin", env["PATH"] ?? "/usr/bin:/bin"]).joined(separator: ":")
        env.removeValue(forKey: "__CFBundleIdentifier")

        // Build argv: [executable, args..., NULL]
        let allArgs = [executable] + arguments
        let cArgs = allArgs.map { strdup($0) } + [nil]
        defer { for p in cArgs { if let p { free(p) } } }

        // Build envp: ["KEY=VALUE", ..., NULL]
        let cEnv = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { for p in cEnv { if let p { free(p) } } }

        // Set up stdout/stderr pipe for log capture
        let outputPipe = Pipe()

        // Configure posix_spawn file actions
        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        defer { posix_spawn_file_actions_destroy(&fileActions) }

        // Map stdout and stderr to our output pipe
        let outWriteFD = outputPipe.fileHandleForWriting.fileDescriptor
        posix_spawn_file_actions_adddup2(&fileActions, outWriteFD, STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&fileActions, outWriteFD, STDERR_FILENO)

        // Map extra fds (e.g. 3 for CDP read, 4 for CDP write)
        for (targetFD, handle) in extraFDs {
            posix_spawn_file_actions_adddup2(&fileActions, handle.fileDescriptor, targetFD)
        }

        // Configure spawn attributes — do NOT set POSIX_SPAWN_CLOEXEC_DEFAULT
        var attrs: posix_spawnattr_t?
        posix_spawnattr_init(&attrs)
        defer { posix_spawnattr_destroy(&attrs) }

        var pid: pid_t = 0
        let spawnResult = cArgs.withUnsafeBufferPointer { argsBuf in
            cEnv.withUnsafeBufferPointer { envBuf in
                posix_spawnp(
                    &pid,
                    executable,
                    &fileActions,
                    &attrs,
                    UnsafeMutablePointer(mutating: argsBuf.baseAddress!),
                    UnsafeMutablePointer(mutating: envBuf.baseAddress!)
                )
            }
        }

        guard spawnResult == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(spawnResult), userInfo: [
                NSLocalizedDescriptionKey: "posix_spawnp failed: \(String(cString: strerror(spawnResult)))"
            ])
        }

        // Close parent-side ends of fds that belong to the child
        outputPipe.fileHandleForWriting.closeFile()
        for (_, handle) in extraFDs {
            handle.closeFile()
        }

        // Set up log capture from the output pipe
        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            for line in text.components(separatedBy: .newlines) {
                let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { self?.appendLog(source, t) }
            }
        }

        // Create a Process object to track the pid for subprocess management.
        // We use a lightweight wrapper: monitor the pid with waitpid in background.
        let process = Process()
        // Store the pid for terminateSubprocess to use
        appendLog("launcher", "\(source) spawned via posix_spawn (pid=\(pid))")

        // Monitor child exit in background
        let capturedPid = pid
        DispatchQueue.global().async { [weak self] in
            var status: Int32 = 0
            waitpid(capturedPid, &status, 0)
            outputPipe.fileHandleForReading.readabilityHandler = nil
            let exitCode = (status & 0x7f) == 0 ? Int32((status >> 8) & 0xff) : Int32(-1)
            self?.appendLog(source, "Process exited with code \(exitCode)")
            self?.appendLog("launcher", "\(source) process exited (code=\(exitCode))")
            print("[ExternalState] \(source) process exited (code=\(exitCode))")
        }

        // We can't return a real Process object since we used posix_spawn directly.
        // Store the pid directly for kill management.
        _browserPid = pid
        return process  // Placeholder — terminateSubprocess should use _browserPid
    }
}

/// Thread-safe storage for CDP pipe handles.
private class CDPHandles: @unchecked Sendable {
    var writeHandle: FileHandle?
    var readHandle: FileHandle?
}
