import AppKit

/// @MainActor UI wrapper for the setup progress window.
@MainActor
final class SetupProgressUI: @unchecked Sendable {
    private var window: NSWindow?
    private var progressBar: NSProgressIndicator?
    private var statusLabel: NSTextField?

    func show(message: String) {
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 450, height: 120),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        w.title = "Darc Setup"
        w.center()
        w.isReleasedWhenClosed = false

        let container = NSView(frame: w.contentView!.bounds)
        container.autoresizingMask = [.width, .height]

        let label = NSTextField(labelWithString: message)
        label.frame = NSRect(x: 20, y: 70, width: 410, height: 30)
        label.font = .systemFont(ofSize: 13)
        label.lineBreakMode = .byTruncatingMiddle
        container.addSubview(label)
        statusLabel = label

        let bar = NSProgressIndicator(frame: NSRect(x: 20, y: 40, width: 410, height: 20))
        bar.style = .bar
        bar.minValue = 0
        bar.maxValue = 100
        bar.doubleValue = 0
        bar.isIndeterminate = false
        container.addSubview(bar)
        progressBar = bar

        w.contentView = container
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = w
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
