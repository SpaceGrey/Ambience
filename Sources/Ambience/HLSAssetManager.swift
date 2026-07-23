import Foundation
import AVFoundation
import AmbienceCore

/// Manages downloading and caching of HLS assets.
/// This class is a singleton that handles the entire lifecycle of HLS video assets,
/// including downloading, storing with a predictable filename, and enforcing a cache limit.
actor HLSAssetManager: NSObject {
    static let shared = HLSAssetManager()

    var isDownloading = false
    var currentError: String?

    // MARK: - Private Properties
    private var downloadSession: AVAssetDownloadURLSession!
    private let cacheLimit = AmbienceService.cacheLimit
    private let targetBitrate: Double = AmbienceService.targetBitrate
    private let cacheDirectory: URL
    private let metadataURL: URL
    private var assetMetadata: [String: AssetMetadata] = [:]

    // To prevent re-downloading the same asset concurrently
    private var activeDownloadTasks: [URL: Task<URL, Error>] = [:]
    
    private var sourceLookUpTable: [URL: URL] = [:]
    
    // Delegate callbacks need a way to resume continuations
    private var downloadContinuations: [AVAssetDownloadTask: CheckedContinuation<URL, Error>] = [:]

    private override init() {
        
        assert(AmbienceService.cacheLimit >= 0, "Can not set a negative cache limit.")
        assert(AmbienceService.targetBitrate >= 0, "Can not set a negative bitrate.")
        
        let fileManager = FileManager.default
        let cacheBaseURL = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first!
        self.cacheDirectory = cacheBaseURL.appendingPathComponent("HLSAssets")
        self.metadataURL = self.cacheDirectory.appendingPathComponent("metadata.json")

        if fileManager.fileExists(atPath: self.metadataURL.path),
           let data = try? Data(contentsOf: self.metadataURL),
           let decoded = try? JSONDecoder().decode([String: AssetMetadata].self, from: data) {
            self.assetMetadata = decoded
        }

        super.init()

        try? fileManager.createDirectory(at: self.cacheDirectory, withIntermediateDirectories: true)
        
        let configuration = URLSessionConfiguration.background(withIdentifier: "com.ambience.hlsAssetManager")
        self.downloadSession = AVAssetDownloadURLSession(configuration: configuration,
                                                       assetDownloadDelegate: self,
                                                       delegateQueue: OperationQueue.main)

        AmbienceLog.info(
            "HLSAssetManager initialized",
            metadata: [
                "cache_directory": self.cacheDirectory.path,
                "cached_assets": String(self.assetMetadata.count),
                "cache_limit": String(self.cacheLimit),
                "target_bitrate": String(format: "%.0f", self.targetBitrate),
            ]
        )
    }

    /// Returns the local URL for a given remote URL if it's already cached.
    private func localAssetURL(for remoteURL: URL) -> URL? {
        let filename = safeFilename(for: remoteURL)
        if assetMetadata[filename] != nil {
            let localURL = cacheDirectory.appendingPathComponent(filename)
            if FileManager.default.fileExists(atPath: localURL.path) {
                return localURL
            }
            AmbienceLog.warning(
                "Cache metadata points to missing file; treating as miss",
                metadata: [
                    "source_url": remoteURL.absoluteString,
                    "filename": filename,
                    "expected_path": localURL.path,
                ]
            )
        }
        return nil
    }

    /// Downloads an HLS asset from a remote URL and stores it in the cache.
    /// If the asset is already being downloaded, it awaits the result of the existing download.
    func getAsset(from remoteURL: URL) async throws -> URL {
        AmbienceLog.debug(
            "getAsset started",
            metadata: ["source_url": remoteURL.absoluteString]
        )

        // If already cached, return the local URL immediately.
        if let localURL = localAssetURL(for: remoteURL) {
            AmbienceLog.info(
                "HLS cache hit",
                metadata: [
                    "source_url": remoteURL.absoluteString,
                    "local_path": localURL.path,
                ]
            )
            return localURL
        }
        
        AmbienceLog.debug(
            "HLS cache miss; fetching page HTML for m3u8 extraction",
            metadata: ["source_url": remoteURL.absoluteString]
        )

        let htmlContent: String
        do {
            htmlContent = try await HTMLFetcher.fetchHTMLContent(from: remoteURL)
        } catch {
            AmbienceLog.error(
                "Failed to fetch page HTML for asset",
                metadata: [
                    "source_url": remoteURL.absoluteString,
                    "error": String(describing: error),
                ]
            )
            throw error
        }

        let hlsURL: URL
        do {
            hlsURL = try AmbienceArtworkExtractor.extractAmbienceArtworkURL(from: htmlContent)
        } catch {
            AmbienceLog.error(
                "Failed to extract HLS URL from page",
                metadata: [
                    "source_url": remoteURL.absoluteString,
                    "error": String(describing: error),
                ]
            )
            throw error
        }

        AmbienceLog.info(
            "Extracted m3u8 URL",
            metadata: [
                "source_url": remoteURL.absoluteString,
                "hls_url": hlsURL.absoluteString,
            ]
        )

        if let manifest = try? String(contentsOf: hlsURL, encoding: .utf8) {
            let lineCount = manifest.components(separatedBy: .newlines).filter { !$0.isEmpty }.count
            AmbienceLog.debug(
                "Loaded m3u8 manifest",
                metadata: [
                    "hls_url": hlsURL.absoluteString,
                    "manifest_bytes": String(manifest.utf8.count),
                    "manifest_lines": String(lineCount),
                    "manifest_preview": String(manifest.prefix(400))
                        .replacingOccurrences(of: "\n", with: "\\n"),
                ]
            )
        } else {
            AmbienceLog.warning(
                "Unable to read m3u8 manifest text before download",
                metadata: ["hls_url": hlsURL.absoluteString]
            )
        }

        // If a download for this URL is already in progress, await its result.
        if let existingTask = activeDownloadTasks[hlsURL] {
            AmbienceLog.info(
                "HLS download already in progress; awaiting existing task",
                metadata: [
                    "source_url": remoteURL.absoluteString,
                    "hls_url": hlsURL.absoluteString,
                ]
            )
            return try await existingTask.value
        }

        let downloadTask = Task {
            defer {
                // Clean up after the task is complete
                self.activeDownloadTasks.removeValue(forKey: hlsURL)
                self.sourceLookUpTable.removeValue(forKey: hlsURL)
                self.isDownloading = false
            }
            AmbienceLog.info(
                "Starting HLS download",
                metadata: [
                    "source_url": remoteURL.absoluteString,
                    "hls_url": hlsURL.absoluteString,
                ]
            )
            return try await performDownload(from: hlsURL)
        }

        // Store the new task
        self.isDownloading = true
        self.activeDownloadTasks[hlsURL] = downloadTask
        self.sourceLookUpTable[hlsURL] = remoteURL

        return try await downloadTask.value
    }
    
    // MARK: - Private Core Logic
    private func performDownload(from remoteURL: URL) async throws -> URL {
        return try await withCheckedThrowingContinuation { continuation in
            Task {
                let asset = AVURLAsset(url: remoteURL)
                
                let variants: [AVAssetVariant]
                do {
                    variants = try await asset.load(.variants)
                } catch {
                    AmbienceLog.error(
                        "Failed to load HLS variants",
                        metadata: [
                            "hls_url": remoteURL.absoluteString,
                            "error": error.localizedDescription,
                        ]
                    )
                    continuation.resume(throwing: NSError(domain: "HLSAssetManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to load variants: \(error.localizedDescription)"]))
                    return
                }
                
                guard !variants.isEmpty else {
                    AmbienceLog.error(
                        "No HLS video variants found",
                        metadata: ["hls_url": remoteURL.absoluteString]
                    )
                    continuation.resume(throwing: NSError(domain: "HLSAssetManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "No video variants found."]))
                    return
                }

                AmbienceLog.debug(
                    "HLS variants loaded",
                    metadata: [
                        "hls_url": remoteURL.absoluteString,
                        "variant_count": String(variants.count),
                        "target_bitrate": String(format: "%.0f", self.targetBitrate),
                    ]
                )
                for (i, v) in variants.enumerated() {
                    let bitrate = v.averageBitRate.map { String(format: "%.0f", $0) } ?? "unknown"
                    let size: String
                    if let w = v.videoAttributes?.presentationSize.width,
                       let h = v.videoAttributes?.presentationSize.height {
                        size = "\(Int(w))x\(Int(h))"
                    } else {
                        size = "unknown"
                    }
                    AmbienceLog.debug(
                        "HLS variant",
                        metadata: [
                            "index": String(i),
                            "bitrate_bps": bitrate,
                            "resolution": size,
                        ]
                    )
                }

                let sortedAscending = variants.sorted { ($0.averageBitRate ?? 0) < ($1.averageBitRate ?? 0) }

                // Pick the lowest-bitrate stream that still meets the threshold.
                // If none qualifies (all are below threshold), fall back to the highest available.
                let bestVariant = sortedAscending.first { ($0.averageBitRate ?? 0) >= self.targetBitrate }
                               ?? sortedAscending.last

                if let best = bestVariant {
                    let res: String
                    if let w = best.videoAttributes?.presentationSize.width,
                       let h = best.videoAttributes?.presentationSize.height {
                        res = "\(Int(w))x\(Int(h))"
                    } else {
                        res = "unknown"
                    }
                    AmbienceLog.info(
                        "Selected HLS variant",
                        metadata: [
                            "hls_url": remoteURL.absoluteString,
                            "bitrate_bps": String(format: "%.0f", best.averageBitRate ?? 0),
                            "resolution": res,
                        ]
                    )
                }

                var options: [String: Any]? = nil
                if let variant = bestVariant {
                    options = [AVAssetDownloadTaskMinimumRequiredMediaBitrateKey: variant.averageBitRate ?? 0]
                }
                
                guard let task = self.downloadSession.makeAssetDownloadTask(asset: asset,
                                                                            assetTitle: remoteURL.lastPathComponent,
                                                                            assetArtworkData: nil,
                                                                            options: options) else {
                    AmbienceLog.error(
                        "Failed to create AVAssetDownloadTask",
                        metadata: ["hls_url": remoteURL.absoluteString]
                    )
                    continuation.resume(throwing: NSError(domain: "HLSAssetManager", code: -2, userInfo: [NSLocalizedDescriptionKey: "Failed to create download task."]))
                    return
                }
                
                AmbienceLog.debug(
                    "AVAssetDownloadTask resumed",
                    metadata: ["hls_url": remoteURL.absoluteString]
                )
                self.downloadContinuations[task] = continuation
                task.resume()
            }
        }
    }
}

// MARK: - AVAssetDownloadDelegate
extension HLSAssetManager: AVAssetDownloadDelegate {
    nonisolated func urlSession(_ session: URLSession, assetDownloadTask: AVAssetDownloadTask, didFinishDownloadingTo location: URL) {
        Task { await self.handleDidFinishDownloading(assetDownloadTask: assetDownloadTask, location: location) }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let assetDownloadTask = task as? AVAssetDownloadTask else { return }
        Task { await self.handleDidCompleteWithError(assetDownloadTask: assetDownloadTask, error: error) }
    }

    private func handleDidFinishDownloading(assetDownloadTask: AVAssetDownloadTask, location: URL) {
        guard let continuation = downloadContinuations.removeValue(forKey: assetDownloadTask) else {
            AmbienceLog.warning(
                "Download finished but no continuation found",
                metadata: [
                    "hls_url": assetDownloadTask.urlAsset.url.absoluteString,
                    "temp_location": location.path,
                ]
            )
            return
        }

        let hlsURL = assetDownloadTask.urlAsset.url
        guard let sourceURL = sourceLookUpTable[hlsURL] else {
            AmbienceLog.error(
                "Source URL missing from lookup table after download",
                metadata: ["hls_url": hlsURL.absoluteString]
            )
            continuation.resume(throwing: NSError(domain: "HLSAssetManager", code: -3, userInfo: [NSLocalizedDescriptionKey: "Source URL not found in lookup table for \(hlsURL.absoluteString)"]))
            return
        }
        let filename = safeFilename(for: sourceURL)
        let destinationURL = cacheDirectory.appendingPathComponent(filename)

        do {
            try? FileManager.default.removeItem(at: destinationURL)
            try FileManager.default.moveItem(at: location, to: destinationURL)

            AmbienceLog.info(
                "HLS asset downloaded and cached",
                metadata: [
                    "source_url": sourceURL.absoluteString,
                    "hls_url": hlsURL.absoluteString,
                    "local_path": destinationURL.path,
                    "filename": filename,
                ]
            )

            let metadata = AssetMetadata(localFilename: filename, creationDate: Date())
            addAssetToMetadata(metadata)

            continuation.resume(returning: destinationURL)
        } catch {
            AmbienceLog.error(
                "Failed to move downloaded HLS asset into cache",
                metadata: [
                    "hls_url": hlsURL.absoluteString,
                    "temp_location": location.path,
                    "destination": destinationURL.path,
                    "error": error.localizedDescription,
                ]
            )
            continuation.resume(throwing: error)
        }
    }

    private func handleDidCompleteWithError(assetDownloadTask: AVAssetDownloadTask, error: Error?) {
        guard let continuation = downloadContinuations.removeValue(forKey: assetDownloadTask) else { return }

        if let error = error {
            AmbienceLog.error(
                "HLS download failed",
                metadata: [
                    "hls_url": assetDownloadTask.urlAsset.url.absoluteString,
                    "error": error.localizedDescription,
                    "error_debug": String(describing: error),
                ]
            )
            continuation.resume(throwing: error)
        }
    }
}


// MARK: - Metadata and Cache Management
private extension HLSAssetManager {
    /// A metadata structure to track cached assets.
    struct AssetMetadata: Codable {
        let localFilename: String
        let creationDate: Date
    }
    /// try to extract the album id or the playlist id as the key to improve cache hit rate.
    func safeFilename(for url: URL) -> String {
        let urlString = url.absoluteString
        var name = urlString
        if let match = urlString.range(of: #"album/[^/]+/(\d+)"#, options: .regularExpression) {
            //https://music.apple.com/cn/album/lover/1468058165?l=en-GB
            let path = urlString[match]
            if let id = path.split(separator: "/").last {
                AmbienceLog.debug(
                    "Cache key from album id",
                    metadata: ["album_id": String(id), "source_url": urlString]
                )
                name = String(id)
                return name+".movpkg"
            }
        }
        if let match = urlString.range(of:"pl\\.([a-zA-Z0-9]+)", options: .regularExpression) {
            //https://music.apple.com/cn/playlist/12-星座歌单-巨蟹月/pl.00ead18e05ad4267b7a7f167923dc79f
            let path = urlString[match]
            if let id = path.split(separator: ".").last {
                AmbienceLog.debug(
                    "Cache key from playlist id",
                    metadata: ["playlist_id": String(id), "source_url": urlString]
                )
                name = String(id)
                return name+".movpkg"
            }
        }
        
        //if can not match the album or the playlist,then fallback.
        if urlString.hasPrefix("https://music.apple.com") {
            let trimmed = urlString
                .replacingOccurrences(of: "https://music.apple.com", with: "")
                .replacingOccurrences(of: "/", with: "")
            AmbienceLog.debug(
                "Cache key fallback for Apple Music URL",
                metadata: ["filename": trimmed + ".movpkg"]
            )
            return trimmed+".movpkg"
        }
        AmbienceLog.debug(
            "Cache key raw fallback",
            metadata: ["filename": name + ".movpkg"]
        )
        return name+".movpkg"
    }

    func loadMetadata() {
        guard FileManager.default.fileExists(atPath: metadataURL.path),
              let data = try? Data(contentsOf: metadataURL),
              let decodedMetadata = try? JSONDecoder().decode([String: AssetMetadata].self, from: data) else {
            AmbienceLog.debug("No existing HLS metadata; starting fresh")
            self.assetMetadata = [:]
            return
        }
        self.assetMetadata = decodedMetadata
        AmbienceLog.info(
            "Loaded HLS asset metadata",
            metadata: ["count": String(self.assetMetadata.count)]
        )
    }

    func saveMetadata() {
        do {
            let data = try JSONEncoder().encode(assetMetadata)
            try data.write(to: metadataURL, options: .atomic)
        } catch {
            AmbienceLog.error(
                "Failed to save HLS asset metadata",
                metadata: ["error": error.localizedDescription]
            )
        }
    }

    func addAssetToMetadata(_ metadata: AssetMetadata) {
        assetMetadata[metadata.localFilename] = metadata
        enforceCacheLimit()
        saveMetadata()
    }

    func enforceCacheLimit() {
        guard assetMetadata.count > cacheLimit else { return }

        // Sort by creation date to find the oldest assets
        let sortedAssets = assetMetadata.values.sorted { $0.creationDate < $1.creationDate }
        
        // Number of assets to remove
        let assetsToRemoveCount = assetMetadata.count - cacheLimit
        let assetsToRemove = sortedAssets.prefix(assetsToRemoveCount)

        for asset in assetsToRemove {
            let localURL = cacheDirectory.appendingPathComponent(asset.localFilename)
            try? FileManager.default.removeItem(at: localURL)
            assetMetadata.removeValue(forKey: asset.localFilename)
            AmbienceLog.info(
                "Evicted old HLS cache asset",
                metadata: ["filename": asset.localFilename]
            )
        }
    }
}
