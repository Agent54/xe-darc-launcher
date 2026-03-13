import AppKit
import os

/// Thread-safe cancellation flag for the setup process.
final class CancellationToken: @unchecked Sendable {
    private let lock = os.OSAllocatedUnfairLock(initialState: false)
    var isCancelled: Bool {
        get { lock.withLock { $0 } }
        set { lock.withLock { $0 = newValue } }
    }
    func cancel() { isCancelled = true }
}

/// @MainActor UI wrapper for the setup progress window.
@MainActor
final class SetupProgressUI: @unchecked Sendable {
    private var window: NSWindow?
    private var progressBar: NSProgressIndicator?
    private var titleLabel: NSTextField?
    private var statusLabel: NSTextField?
    let cancellation = CancellationToken()

    func show(message: String) {
        let pathWidth = max(450, (message as NSString).size(withAttributes: [.font: NSFont.boldSystemFont(ofSize: 13)]).width + 60)
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: pathWidth, height: 160),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        w.title = "Darc Setup"
        w.center()
        w.isReleasedWhenClosed = false

        let container = NSView(frame: w.contentView!.bounds)
        container.autoresizingMask = [.width, .height]

        let innerWidth = pathWidth - 40

        let title = NSTextField(labelWithString: message)
        title.frame = NSRect(x: 20, y: 115, width: innerWidth, height: 25)
        title.font = .boldSystemFont(ofSize: 13)
        container.addSubview(title)
        titleLabel = title

        let status = NSTextField(labelWithString: "")
        status.frame = NSRect(x: 20, y: 90, width: innerWidth, height: 20)
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        container.addSubview(status)
        statusLabel = status

        let bar = NSProgressIndicator(frame: NSRect(x: 20, y: 60, width: innerWidth, height: 20))
        bar.style = .bar
        bar.minValue = 0
        bar.maxValue = 100
        bar.doubleValue = 0
        bar.isIndeterminate = false
        container.addSubview(bar)
        progressBar = bar

        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancelClicked))
        cancelButton.frame = NSRect(x: pathWidth - 100, y: 15, width: 80, height: 30)
        cancelButton.bezelStyle = .rounded
        container.addSubview(cancelButton)

        w.contentView = container
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = w
    }

    @objc private func cancelClicked() {
        cancellation.cancel()
        statusLabel?.stringValue = "Cancelling..."
    }

    func update(status: String? = nil, progress: Double? = nil) {
        if let status { statusLabel?.stringValue = status }
        if let progress { progressBar?.doubleValue = progress }
    }

    func close() {
        window?.close()
        window = nil
    }
}

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
