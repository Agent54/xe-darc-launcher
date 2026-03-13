import AppKit
import os

/// Thread-safe cancellation token with active task management.
final class CancellationToken: @unchecked Sendable {
    private struct State {
        var cancelled = false
        var activeTask: URLSessionDownloadTask?
    }
    private let lock = os.OSAllocatedUnfairLock(initialState: State())

    var isCancelled: Bool { lock.withLock { $0.cancelled } }

    var activeTask: URLSessionDownloadTask? {
        get { lock.withLock { $0.activeTask } }
        set { lock.withLock { $0.activeTask = newValue } }
    }

    func cancel() {
        lock.withLock {
            $0.cancelled = true
            $0.activeTask?.cancel()
            $0.activeTask = nil
        }
    }
}

// MARK: - Module-level setup progress UI (all UI calls must happen on main thread)

nonisolated(unsafe) private var _setupWindow: NSPanel?
nonisolated(unsafe) private var _progressBar: NSProgressIndicator?
nonisolated(unsafe) private var _titleLabel: NSTextField?
nonisolated(unsafe) private var _statusLabel: NSTextField?
private let _cancellation = CancellationToken()

/// The shared cancellation token for the current setup. Check `isCancelled` from any thread.
var setupCancellation: CancellationToken { _cancellation }

/// Show the setup progress window. Call from main thread.
@MainActor
func showSetupProgress(message: String) {
    // Size window to fit the path
    let pathFont = NSFont.systemFont(ofSize: 11)
    let pathTextWidth = (message as NSString).size(withAttributes: [.font: pathFont]).width + 100
    let w = max(420, min(pathTextWidth, 700))
    let h: CGFloat = 320
    let panel = NSPanel(
        contentRect: NSRect(x: 0, y: 0, width: w, height: h),
        styleMask: [.titled, .fullSizeContentView],
        backing: .buffered,
        defer: false
    )
    panel.titlebarAppearsTransparent = true
    panel.titleVisibility = .hidden
    panel.isMovableByWindowBackground = true
    panel.backgroundColor = .clear
    panel.isOpaque = false
    panel.level = .normal
    panel.center()
    panel.isReleasedWhenClosed = false
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    panel.hidesOnDeactivate = false

    let vfx = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: w, height: h))
    vfx.material = .hudWindow
    vfx.blendingMode = .behindWindow
    vfx.state = .active
    vfx.wantsLayer = true
    vfx.layer?.cornerRadius = 16
    vfx.layer?.masksToBounds = true
    vfx.autoresizingMask = [.width, .height]
    panel.contentView = vfx

    let pad: CGFloat = 40

    // Large centered app icon
    let iconSize: CGFloat = 80
    let iconView = NSImageView(frame: NSRect(x: (w - iconSize) / 2, y: h - iconSize - 50, width: iconSize, height: iconSize))
    if let resourceURL = Bundle.main.resourceURL,
       let icon = NSImage(contentsOf: resourceURL.appendingPathComponent("app.icns")) {
        iconView.image = icon
    } else {
        iconView.image = NSApp.applicationIconImage
    }
    iconView.imageScaling = .scaleProportionallyUpOrDown
    vfx.addSubview(iconView)

    // "Setting up Darc" title centered below icon
    let title = NSTextField(labelWithString: "Setting up Darc")
    title.frame = NSRect(x: pad, y: h - iconSize - 80, width: w - pad * 2, height: 22)
    title.font = .systemFont(ofSize: 15, weight: .semibold)
    title.textColor = .white
    title.alignment = .center
    vfx.addSubview(title)
    _titleLabel = title

    // Path on its own line
    let pathLabel = NSTextField(labelWithString: message)
    pathLabel.frame = NSRect(x: 20, y: h - iconSize - 103, width: w - 40, height: 16)
    pathLabel.font = .systemFont(ofSize: 11)
    pathLabel.textColor = NSColor.white.withAlphaComponent(0.45)
    pathLabel.alignment = .center
    pathLabel.lineBreakMode = .byTruncatingMiddle
    vfx.addSubview(pathLabel)

    // Status text
    let status = NSTextField(labelWithString: "Preparing...")
    status.frame = NSRect(x: pad, y: h - iconSize - 125, width: w - pad * 2, height: 18)
    status.font = .systemFont(ofSize: 11)
    status.textColor = NSColor.white.withAlphaComponent(0.6)
    status.alignment = .center
    vfx.addSubview(status)
    _statusLabel = status

    // Progress bar
    let bar = NSProgressIndicator(frame: NSRect(x: pad, y: 55, width: w - pad * 2, height: 6))
    bar.style = .bar
    bar.minValue = 0
    bar.maxValue = 100
    bar.doubleValue = 0
    bar.isIndeterminate = false
    bar.controlSize = .small
    vfx.addSubview(bar)
    _progressBar = bar

    // Cancel button centered at bottom
    let cancelButton = NSButton(title: "Cancel", target: SetupCancelHelper.shared, action: #selector(SetupCancelHelper.cancelSetup))
    cancelButton.frame = NSRect(x: (w - 80) / 2, y: 15, width: 80, height: 28)
    cancelButton.bezelStyle = .recessed
    cancelButton.isBordered = true
    cancelButton.contentTintColor = NSColor.white.withAlphaComponent(0.8)
    cancelButton.refusesFirstResponder = true
    vfx.addSubview(cancelButton)

    // Set the app icon for Dock display
    if let resourceURL = Bundle.main.resourceURL,
       let icon = NSImage(contentsOf: resourceURL.appendingPathComponent("app.icns")) {
        NSApp.applicationIconImage = icon
    }
    // Temporarily show Dock icon so user can click to bring window forward
    NSApp.setActivationPolicy(.regular)
    panel.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    _setupWindow = panel
}

/// Update the setup progress status and/or bar. Call from main thread.
@MainActor
func updateSetupProgress(status: String? = nil, progress: Double? = nil) {
    if let status { _statusLabel?.stringValue = status }
    if let progress { _progressBar?.doubleValue = progress }
}

/// Close the setup progress window. Call from main thread.
@MainActor
func closeSetupProgress() {
    _setupWindow?.close()
    _setupWindow = nil
    _progressBar = nil
    _titleLabel = nil
    _statusLabel = nil
    // Restore accessory (no Dock icon) mode
    NSApp.setActivationPolicy(.accessory)
}

// Helper to wire up the cancel button action
@MainActor
private class SetupCancelHelper: NSObject {
    static let shared = SetupCancelHelper()
    @objc func cancelSetup() {
        _cancellation.cancel()
        _statusLabel?.stringValue = "Cancelling..."
        _setupWindow?.close()
        _setupWindow = nil
        NSApp.setActivationPolicy(.accessory)
    }
}

// MARK: - Download progress delegate

/// URLSession delegate that reports download progress via a callback.
class DownloadProgressDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let onProgress: (Double) -> Void

    init(onProgress: @escaping (Double) -> Void) {
        self.onProgress = onProgress
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        onProgress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // Handled by completion handler
    }
}
