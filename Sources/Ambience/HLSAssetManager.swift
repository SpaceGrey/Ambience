import Foundation
import AVFoundation
import os

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
    private let targetBitrate:Double = AmbienceService.targetBitrate
    private let cacheDirectory: URL
    private let metadataURL: URL
    private var assetMetadata: [String: AssetMetadata] = [:]
    
    // Modern logging
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "HLSAssetManager")

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
    }

    /// Returns the local URL for a given remote URL if it's already cached.
    private func localAssetURL(for remoteURL: URL) -> URL? {
        let filename = safeFilename(for: remoteURL)
        if assetMetadata[filename] != nil {
            let localURL = cacheDirectory.appendingPathComponent(filename)
            if FileManager.default.fileExists(atPath: localURL.path) {
                return localURL
            }
        }
        return nil
    }

    /// Downloads an HLS asset from a remote URL and stores it in the cache.
    /// If the asset is already being downloaded, it awaits the result of the existing download.
    func getAsset(from remoteURL: URL) async throws -> URL {
        // If already cached, return the local URL immediately.
        if let localURL = localAssetURL(for: remoteURL) {
            Self.logger.info("Cache hit for URL: \(remoteURL.absoluteString)")
            return localURL
        }
        
        let htmlContent = try await HTMLFetcher.fetchHTMLContent(from: remoteURL)
        let hlsURL = try AmbienceArtworkExtractor.extractAmbienceArtworkURL(from: htmlContent)

        print("[Ambience HLS] Extracted m3u8 URL: \(hlsURL.absoluteString)")
        if let manifest = try? String(contentsOf: hlsURL, encoding: .utf8) {
            print("[Ambience HLS] ── m3u8 manifest ──────────────────────")
            manifest.components(separatedBy: "\n").forEach { print("[Ambience HLS] \($0)") }
            print("[Ambience HLS] ────────────────────────────────────────")
        }

        // If a download for this URL is already in progress, await its result.
        if let existingTask = activeDownloadTasks[hlsURL] {
            Self.logger.info("Download already in progress for URL: \(remoteURL.absoluteString). Awaiting result.")
            return try await existingTask.value
        }

        let downloadTask = Task {
            defer {
                // Clean up after the task is complete
                    self.activeDownloadTasks.removeValue(forKey: hlsURL)
                    self.sourceLookUpTable.removeValue(forKey: hlsURL)
                    self.isDownloading = false
                
            }
            Self.logger.info("Cache miss for URL: \(hlsURL.absoluteString). Starting new download.")
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
                    continuation.resume(throwing: NSError(domain: "HLSAssetManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to load variants: \(error.localizedDescription)"]))
                    return
                }
                
                guard !variants.isEmpty else {
                    continuation.resume(throwing: NSError(domain: "HLSAssetManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "No video variants found."]))
                    return
                }

                print("[Ambience HLS] Found \(variants.count) variant(s), targetBitrate=\(self.targetBitrate)")
                for (i, v) in variants.enumerated() {
                    let bitrate = v.averageBitRate.map { String(format: "%.0f bps", $0) } ?? "unknown"
                    let size: String
                    if let w = v.videoAttributes?.presentationSize.width,
                       let h = v.videoAttributes?.presentationSize.height {
                        size = "\(Int(w))×\(Int(h))"
                    } else {
                        size = "unknown"
                    }
                    print("[Ambience HLS]   [\(i)] \(bitrate)  \(size)")
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
                        res = "\(Int(w))×\(Int(h))"
                    } else {
                        res = "unknown"
                    }
                    print("[Ambience HLS] Selected variant: \(String(format: "%.0f", best.averageBitRate ?? 0)) bps  \(res)")
                }

                var options: [String: Any]? = nil
                if let variant = bestVariant {
                    options = [AVAssetDownloadTaskMinimumRequiredMediaBitrateKey: variant.averageBitRate ?? 0]
                }
                
                guard let task = self.downloadSession.makeAssetDownloadTask(asset: asset,
                                                                            assetTitle: remoteURL.lastPathComponent,
                                                                            assetArtworkData: nil,
                                                                            options: options) else {
                    continuation.resume(throwing: NSError(domain: "HLSAssetManager", code: -2, userInfo: [NSLocalizedDescriptionKey: "Failed to create download task."]))
                    return
                }
                
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
        guard let continuation = downloadContinuations.removeValue(forKey: assetDownloadTask) else { return }

        let hlsURL = assetDownloadTask.urlAsset.url
        guard let sourceURL = sourceLookUpTable[hlsURL] else {
            continuation.resume(throwing: NSError(domain: "HLSAssetManager", code: -3, userInfo: [NSLocalizedDescriptionKey: "Source URL not found in lookup table for \(hlsURL.absoluteString)"]))
            return
        }
        let filename = safeFilename(for: sourceURL)
        let destinationURL = cacheDirectory.appendingPathComponent(filename)

        do {
            try? FileManager.default.removeItem(at: destinationURL)
            try FileManager.default.moveItem(at: location, to: destinationURL)

            Self.logger.info("Successfully downloaded and cached asset from \(hlsURL.absoluteString) to \(destinationURL.path)")

            let metadata = AssetMetadata(localFilename: filename, creationDate: Date())
            addAssetToMetadata(metadata)

            continuation.resume(returning: destinationURL)
        } catch {
            Self.logger.error("Failed to move downloaded asset for \(hlsURL.absoluteString). Error: \(error.localizedDescription)")
            continuation.resume(throwing: error)
        }
    }

    private func handleDidCompleteWithError(assetDownloadTask: AVAssetDownloadTask, error: Error?) {
        guard let continuation = downloadContinuations.removeValue(forKey: assetDownloadTask) else { return }

        if let error = error {
            Self.logger.error("Download failed for task \(assetDownloadTask.urlAsset.url.absoluteString) with error: \(error.localizedDescription)")
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
                Self.logger.info("Convert the id to album \(id)")
                name = String(id)
                return name+".movpkg"
            }
        }
        if let match = urlString.range(of:"pl\\.([a-zA-Z0-9]+)", options: .regularExpression) {
            //https://music.apple.com/cn/playlist/12-星座歌单-巨蟹月/pl.00ead18e05ad4267b7a7f167923dc79f
            let path = urlString[match]
            if let id = path.split(separator: ".").last {
                Self.logger.info("Convert the id to playlist \(id)")
                name = String(id)
                return name+".movpkg"
            }
        }
        
        //if can not match the album or the playlist,then fallback.
        if urlString.hasPrefix("https://music.apple.com") {
            let trimmed = urlString
                .replacingOccurrences(of: "https://music.apple.com", with: "")
                .replacingOccurrences(of: "/", with: "")
            return trimmed+".movpkg"
        }
        return name+".movpkg"
    }

    func loadMetadata() {
        guard FileManager.default.fileExists(atPath: metadataURL.path),
              let data = try? Data(contentsOf: metadataURL),
              let decodedMetadata = try? JSONDecoder().decode([String: AssetMetadata].self, from: data) else {
            Self.logger.info("No existing metadata found. Starting fresh.")
            self.assetMetadata = [:]
            return
        }
        self.assetMetadata = decodedMetadata
        Self.logger.info("Successfully loaded HLS asset metadata for \(self.assetMetadata.count) items.")
    }

    func saveMetadata() {
        do {
            let data = try JSONEncoder().encode(assetMetadata)
            try data.write(to: metadataURL, options: .atomic)
        } catch {
            Self.logger.error("Failed to save HLS asset metadata: \(error.localizedDescription)")
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
            Self.logger.info("Cache limit reached. Removed old asset: \(asset.localFilename)")
        }
    }
} 
