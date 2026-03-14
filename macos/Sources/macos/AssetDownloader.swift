import Foundation
import AppKit
import Darwin

/// Download and install assets defined in sources.json on first run.
/// Shows a progress window while downloading. Assets with `"unzip": true` are extracted via ditto;
/// others are saved directly to the app data directory.
func downloadSourceAssetsIfNeeded(dataURL: URL, log: @escaping (String, String) -> Void) {
    let fm = FileManager.default

    guard let sourcesURL = Bundle.main.resourceURL?.appendingPathComponent("sources.json"),
          let sourcesData = try? Data(contentsOf: sourcesURL),
          let sources = try? JSONSerialization.jsonObject(with: sourcesData) as? [String: [String: Any]] else {
        log("launcher", "No sources.json found in bundle, skipping asset download")
        return
    }

    struct AssetInfo {
        let name: String
        let label: String
        let url: URL
        let unzip: Bool
        let filename: String
    }
    var pending: [AssetInfo] = []
    for (name, info) in sources {
        guard let urlString = info["url"] as? String, !urlString.isEmpty,
              let url = URL(string: urlString) else { continue }
        let shouldUnzip = info["unzip"] as? Bool ?? true
        let label = info["label"] as? String ?? name
        let filename = url.lastPathComponent
        // Check if already downloaded/extracted
        let fileMarker = dataURL.appendingPathComponent(filename)
        if fm.fileExists(atPath: fileMarker.path) { continue }
        // For helium, check if Helium.app exists
        if name == "helium" && fm.fileExists(atPath: dataURL.appendingPathComponent("Helium.app").path) { continue }
        pending.append(AssetInfo(name: name, label: label, url: url, unzip: shouldUnzip, filename: filename))
    }

    guard !pending.isEmpty else { return }

    // Show progress on main thread (synchronous to ensure it's visible before we start)
    let sem = DispatchSemaphore(value: 0)
    DispatchQueue.main.async {
        showSetupProgress(message: dataURL.path)
        sem.signal()
    }
    sem.wait()

    let cancel = setupCancellation

    let totalAssets = Double(pending.count)
    for (index, asset) in pending.enumerated() {
        if cancel.isCancelled { break }

        var downloadedFile: URL?

        retryLoop: while true {
            if cancel.isCancelled { break }

            DispatchQueue.main.async {
                updateSetupProgress(status: "Downloading \(asset.label)...", progress: (Double(index) / totalAssets) * 100)
            }

            log("launcher", "Downloading \(asset.name) from \(asset.url.absoluteString)")

            let downloadSem = DispatchSemaphore(value: 0)
            nonisolated(unsafe) var downloadedFileURL: URL?
            nonisolated(unsafe) var downloadError: Error?

            let delegate = DownloadProgressDelegate(onProgress: { fraction in
                DispatchQueue.main.async {
                    let base = (Double(index) / totalAssets) * 100
                    let portion = (1.0 / totalAssets) * 100
                    updateSetupProgress(progress: base + fraction * portion)
                }
            }, completion: { fileURL, error in
                if let error {
                    downloadError = error
                } else if let fileURL {
                    downloadedFileURL = fileURL
                }
                downloadSem.signal()
            })
            let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)

            let task = session.downloadTask(with: asset.url)
            cancel.activeTask = task
            task.resume()
            downloadSem.wait()
            cancel.activeTask = nil

            if cancel.isCancelled {
                if let f = downloadedFileURL { try? fm.removeItem(at: f) }
                break
            }

            if let error = downloadError {
                log("launcher", "Failed to download \(asset.name): \(error.localizedDescription)")
                let action = showSetupError(message: "Failed to download \(asset.label): \(error.localizedDescription)")
                switch action {
                case .retry: continue retryLoop
                case .cancel:
                    cancel.cancel()
                    break retryLoop
                }
            }

            if let f = downloadedFileURL {
                downloadedFile = f
                break retryLoop
            } else {
                log("launcher", "No file downloaded for \(asset.name)")
                let action = showSetupError(message: "Download failed for \(asset.label) — no data received.")
                switch action {
                case .retry: continue retryLoop
                case .cancel:
                    cancel.cancel()
                    break retryLoop
                }
            }
        }

        if cancel.isCancelled { break }
        guard let downloadedFile else { continue }

        if asset.unzip {
            DispatchQueue.main.async {
                updateSetupProgress(status: "Extracting \(asset.label)...")
            }
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            proc.arguments = ["-x", "-k", downloadedFile.path, dataURL.path]
            do {
                try proc.run()
                proc.waitUntilExit()
                if proc.terminationStatus == 0 {
                    log("launcher", "Extracted \(asset.name) to \(dataURL.path)")
                    // Remove quarantine xattr on Helium.app
                    let heliumApp = dataURL.appendingPathComponent("Helium.app")
                    if fm.fileExists(atPath: heliumApp.path) {
                        removeQuarantineRecursively(at: heliumApp)
                    }
                } else {
                    log("launcher", "ditto failed for \(asset.name) with exit code \(proc.terminationStatus)")
                }
            } catch {
                log("launcher", "Failed to extract \(asset.name): \(error.localizedDescription)")
            }
            try? fm.removeItem(at: downloadedFile)
        } else {
            let destFile = dataURL.appendingPathComponent(asset.filename)
            do {
                try fm.moveItem(at: downloadedFile, to: destFile)
                log("launcher", "Saved \(asset.name) to \(destFile.path)")
            } catch {
                log("launcher", "Failed to move \(asset.name): \(error.localizedDescription)")
            }
        }
    }

    DispatchQueue.main.async {
        closeSetupProgress()
    }
}

/// Remove com.apple.quarantine xattr recursively using the C removexattr API.
private func removeQuarantineRecursively(at url: URL) {
    let fm = FileManager.default
    let quarantine = "com.apple.quarantine"

    func strip(_ path: String) {
        removexattr(path, quarantine, XATTR_NOFOLLOW)
    }

    strip(url.path)
    guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: nil) else { return }
    for case let fileURL as URL in enumerator {
        strip(fileURL.path)
    }
}
