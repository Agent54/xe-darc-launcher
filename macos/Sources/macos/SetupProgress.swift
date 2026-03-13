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
    let pathWidth = max(500, (message as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 13, weight: .medium)]).width + 80)
    let panel = NSPanel(
        contentRect: NSRect(x: 0, y: 0, width: pathWidth, height: 150),
        styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
        backing: .buffered,
        defer: false
    )
    panel.titlebarAppearsTransparent = true
    panel.titleVisibility = .hidden
    panel.isMovableByWindowBackground = true
    panel.backgroundColor = .clear
    panel.isOpaque = false
    panel.level = .floating
    panel.center()
    panel.isReleasedWhenClosed = false
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    panel.hidesOnDeactivate = false

    let vfx = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: pathWidth, height: 150))
    vfx.material = .hudWindow
    vfx.blendingMode = .behindWindow
    vfx.state = .active
    vfx.wantsLayer = true
    vfx.layer?.cornerRadius = 12
    vfx.layer?.masksToBounds = true
    vfx.autoresizingMask = [.width, .height]
    panel.contentView = vfx

    let innerWidth = pathWidth - 60

    let title = NSTextField(labelWithString: message)
    title.frame = NSRect(x: 30, y: 105, width: innerWidth, height: 20)
    title.font = .systemFont(ofSize: 13, weight: .medium)
    title.textColor = .white
    vfx.addSubview(title)
    _titleLabel = title

    let status = NSTextField(labelWithString: "Preparing...")
    status.frame = NSRect(x: 30, y: 82, width: innerWidth, height: 18)
    status.font = .systemFont(ofSize: 11)
    status.textColor = NSColor.white.withAlphaComponent(0.6)
    vfx.addSubview(status)
    _statusLabel = status

    let bar = NSProgressIndicator(frame: NSRect(x: 30, y: 55, width: innerWidth, height: 6))
    bar.style = .bar
    bar.minValue = 0
    bar.maxValue = 100
    bar.doubleValue = 0
    bar.isIndeterminate = false
    bar.controlSize = .small
    vfx.addSubview(bar)
    _progressBar = bar

    let cancelButton = NSButton(title: "Cancel", target: nil, action: #selector(SetupCancelHelper.cancelSetup))
    cancelButton.frame = NSRect(x: pathWidth - 100, y: 15, width: 70, height: 28)
    cancelButton.bezelStyle = .recessed
    cancelButton.isBordered = true
    cancelButton.contentTintColor = NSColor.white.withAlphaComponent(0.8)
    cancelButton.refusesFirstResponder = true
    cancelButton.target = SetupCancelHelper.shared
    vfx.addSubview(cancelButton)

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
