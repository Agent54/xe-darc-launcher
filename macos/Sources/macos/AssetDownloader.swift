import Foundation
import AppKit

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
        let url: URL
        let unzip: Bool
        let filename: String
    }
    var pending: [AssetInfo] = []
    for (name, info) in sources {
        guard let urlString = info["url"] as? String, !urlString.isEmpty,
              let url = URL(string: urlString) else { continue }
        let shouldUnzip = info["unzip"] as? Bool ?? true
        let filename = url.lastPathComponent
        let marker = dataURL.appendingPathComponent(name)
        let appMarker = dataURL.appendingPathComponent("\(name).app")
        let fileMarker = dataURL.appendingPathComponent(filename)
        if fm.fileExists(atPath: marker.path) || fm.fileExists(atPath: appMarker.path) || fm.fileExists(atPath: fileMarker.path) {
            continue
        }
        pending.append(AssetInfo(name: name, url: url, unzip: shouldUnzip, filename: filename))
    }

    guard !pending.isEmpty else { return }

    // Show progress on main thread (synchronous to ensure it's visible before we start)
    let sem = DispatchSemaphore(value: 0)
    DispatchQueue.main.async {
        showSetupProgress(message: "Setting up Darc in \(dataURL.path)")
        sem.signal()
    }
    sem.wait()

    let cancel = setupCancellation

    let totalAssets = Double(pending.count)
    for (index, asset) in pending.enumerated() {
        if cancel.isCancelled { break }

        DispatchQueue.main.async {
            updateSetupProgress(status: "Downloading \(asset.name)...", progress: (Double(index) / totalAssets) * 100)
        }

        log("launcher", "Downloading \(asset.name) from \(asset.url.absoluteString)")

        let downloadSem = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var downloadedFileURL: URL?
        nonisolated(unsafe) var downloadError: Error?

        let session = URLSession(configuration: .default, delegate: DownloadProgressDelegate { fraction in
            DispatchQueue.main.async {
                let base = (Double(index) / totalAssets) * 100
                let portion = (1.0 / totalAssets) * 100
                updateSetupProgress(progress: base + fraction * portion)
            }
        }, delegateQueue: nil)

        let task = session.downloadTask(with: asset.url) { tempURL, _, error in
            if let error {
                downloadError = error
            } else if let tempURL {
                let ext = asset.unzip ? ".zip" : ("." + asset.url.pathExtension)
                let stableTemp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ext)
                try? FileManager.default.moveItem(at: tempURL, to: stableTemp)
                downloadedFileURL = stableTemp
            }
            downloadSem.signal()
        }
        cancel.activeTask = task
        task.resume()
        downloadSem.wait()
        cancel.activeTask = nil

        if cancel.isCancelled {
            // Clean up partial download in background
            if let f = downloadedFileURL { try? fm.removeItem(at: f) }
            break
        }

        if let error = downloadError {
            log("launcher", "Failed to download \(asset.name): \(error.localizedDescription)")
            continue
        }

        guard let downloadedFile = downloadedFileURL else {
            log("launcher", "No file downloaded for \(asset.name)")
            continue
        }

        if asset.unzip {
            DispatchQueue.main.async {
                updateSetupProgress(status: "Extracting \(asset.name)...")
            }
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            proc.arguments = ["-x", "-k", downloadedFile.path, dataURL.path]
            do {
                try proc.run()
                proc.waitUntilExit()
                if proc.terminationStatus == 0 {
                    log("launcher", "Extracted \(asset.name) to \(dataURL.path)")
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
