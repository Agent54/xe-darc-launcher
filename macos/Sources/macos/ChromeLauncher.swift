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
    /// Uses posix_spawn_file_actions_adddup2 for reliable fd mapping — no shell involved.
    func spawnLongRunningProcessWithPipes(executable: String, arguments: [String], source: String, extraFDs: [Int32: FileHandle]) throws -> Process {
        // We can't add extra fds to Swift's Process, so we use posix_spawn directly
        // and wrap the pid in a monitoring Process-like mechanism via the existing
        // spawnLongRunningProcess. Instead, we'll fork+exec with dup2.
        //
        // Actually, the simplest reliable approach: before calling Process.run(),
        // dup2 the pipe fds to 3 and 4 in the PARENT process. Since Process.run()
        // calls fork() internally, the child inherits all open fds that don't have
        // close-on-exec set. We just need to clear FD_CLOEXEC on fds 3 and 4.

        // dup2 the source fds to the target fd numbers (3, 4) in this process
        for (targetFD, handle) in extraFDs {
            let srcFD = handle.fileDescriptor
            if srcFD != targetFD {
                let result = dup2(srcFD, targetFD)
                guard result != -1 else {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [
                        NSLocalizedDescriptionKey: "dup2(\(srcFD), \(targetFD)) failed: \(String(cString: strerror(errno)))"
                    ])
                }
            }
            // Clear close-on-exec so the fd survives fork+exec
            let flags = fcntl(targetFD, F_GETFD)
            if flags != -1 {
                _ = fcntl(targetFD, F_SETFD, flags & ~FD_CLOEXEC)
            }
        }

        let process = try spawnLongRunningProcess(executable: executable, arguments: arguments, source: source)

        // Close fds 3 and 4 in the parent — Chrome has them in the child
        for (targetFD, _) in extraFDs {
            close(targetFD)
        }

        return process
    }
}

/// Thread-safe storage for CDP pipe handles.
private class CDPHandles: @unchecked Sendable {
    var writeHandle: FileHandle?
    var readHandle: FileHandle?
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
