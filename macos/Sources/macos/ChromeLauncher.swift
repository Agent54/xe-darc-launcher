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
        "--disable-features=CADisplayLinkInBrowser",
        "--remote-allow-origins=https://localhost:5194",
        "--no-default-browser-check"
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

        // Create pipe pairs for Chrome DevTools Protocol pipe transport.
        // Chrome reads commands from fd 3 and writes responses to fd 4.
        // We keep the other ends for our launcher / future workerd bridge.
        let toChrome = Pipe()    // we write → Chrome reads on fd 3
        let fromChrome = Pipe()  // Chrome writes on fd 4 → we read

        do {
            let process = try spawnLongRunningProcessWithPipes(
                executable: chrome.executablePath,
                arguments: args,
                source: "browser",
                extraFDs: [
                    3: toChrome.fileHandleForReading,
                    4: fromChrome.fileHandleForWriting
                ]
            )
            subprocesses["browser"] = process

            // Store the pipe handles for later CDP communication (e.g. workerd bridge)
            cdpWriteHandle = toChrome.fileHandleForWriting
            cdpReadHandle = fromChrome.fileHandleForReading

            // Close the child-side ends in our process
            toChrome.fileHandleForReading.closeFile()
            fromChrome.fileHandleForWriting.closeFile()

            appendLog("launcher", "Chrome started with debug pipe (\(chrome.name), pid=\(process.processIdentifier), isRunning=\(chromeRunning))")
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
    /// Spawn a process with extra file descriptors mapped into the child using posix_spawn.
    /// Returns a Process-like pid. The log output pipe is set up for the `source` label.
    func spawnLongRunningProcessWithPipes(executable: String, arguments: [String], source: String, extraFDs: [Int32: FileHandle]) throws -> Process {
        // Clear close-on-exec flag on the file descriptors we want to pass through
        for (_, handle) in extraFDs {
            let fd = handle.fileDescriptor
            let flags = fcntl(fd, F_GETFD)
            if flags != -1 {
                fcntl(fd, F_SETFD, flags & ~FD_CLOEXEC)
            }
        }

        // Build a shell command that does dup2 for each extra fd then exec's the target
        var dup2s = ""
        for (targetFD, handle) in extraFDs.sorted(by: { $0.key < $1.key }) {
            let srcFD = handle.fileDescriptor
            if srcFD != targetFD {
                dup2s += "exec \(targetFD)<>/dev/fd/\(srcFD) ; "
            }
        }
        let cmd = dup2s + "exec " + ([executable] + arguments).map { $0.shellEscaped }.joined(separator: " ")

        return try spawnLongRunningProcess(executable: "/bin/bash", arguments: ["-c", cmd], source: source)
    }
}

/// Thread-safe storage for CDP pipe handles.
private class CDPHandles: @unchecked Sendable {
    var writeHandle: FileHandle?
    var readHandle: FileHandle?
}

private extension String {
    var shellEscaped: String {
        "'" + replacingOccurrences(of: "'", with: "'\\''") + "'"
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
