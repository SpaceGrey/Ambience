import Foundation

/// Exports ambient video to MP4 by downloading raw HLS segments and concatenating.
///
/// Neither `AVAssetExportSession` nor `AVAssetReader` can access Apple's ambient
/// video assets (remote HLS is `isReadable=false`; local `.movpkg` from
/// `AVAssetDownloadURLSession` is also `isReadable=false`).
///
/// This exporter bypasses AVFoundation entirely: it parses the m3u8 manifest,
/// picks the best quality variant, downloads the fMP4 init segment + media segments
/// via plain HTTP, and concatenates them into a valid ISO BMFF (.mp4) file.
/// No re-encoding, lossless, very fast.
public enum AmbienceExporter {

    // MARK: - Types

    public enum ExportError: LocalizedError {
        case invalidManifest
        case noVariants
        case noSegments
        case downloadFailed(URL, Error)

        public var errorDescription: String? {
            switch self {
            case .invalidManifest:     return "Failed to parse the HLS manifest."
            case .noVariants:          return "No video variants found in the manifest."
            case .noSegments:          return "No media segments found in the variant playlist."
            case .downloadFailed(let url, let err):
                return "Failed to download \(url.lastPathComponent): \(err.localizedDescription)"
            }
        }
    }

    /// User-facing quality tier.
    public enum QualityTier: String, CaseIterable, Sendable {
        case low      = "Low"
        case standard = "Standard"
        case high     = "High"
        case original = "Original"

        public var label: String { rawValue }

        public var systemImage: String {
            switch self {
            case .low:      return "arrow.down.circle"
            case .standard: return "play.circle"
            case .high:     return "sparkles"
            case .original: return "star.circle"
            }
        }

        public var subtitle: String {
            switch self {
            case .low:      return "Smallest file size"
            case .standard: return "Good quality"
            case .high:     return "Great quality"
            case .original: return "Best available"
            }
        }
    }

    /// A single HLS variant stream parsed from the master playlist.
    public struct Variant: Identifiable, Sendable {
        public let id = UUID()
        public let url: URL
        public let bandwidth: Double
        public let codec: String?
        public let resolution: String?
        public var tier: QualityTier = .standard

        public var displayName: String { tier.label }
        public var subtitle: String { tier.subtitle }

        var pixelCount: Int {
            guard let resolution else { return 0 }
            let parts = resolution.split(separator: "x")
            guard parts.count == 2,
                  let w = Int(parts[0]),
                  let h = Int(parts[1]) else { return 0 }
            return w * h
        }
    }

    struct SegmentList {
        let initSegmentURL: URL?
        let mediaSegmentURLs: [URL]
    }

    // MARK: - Public API

    /// Fetches the master m3u8 and returns up to 4 quality tiers (low / standard / high / original).
    public static func availableVariants(hlsURL: URL) async throws -> [Variant] {
        let content = try await fetchString(from: hlsURL)
        let all = parseMasterPlaylist(content, baseURL: hlsURL)
        guard !all.isEmpty else { throw ExportError.noVariants }

        let sorted = all.sorted { $0.bandwidth < $1.bandwidth }

        // Pick 4 representatives spread across the range
        var picked: [Variant] = []
        let tiers: [QualityTier] = [.low, .standard, .high, .original]

        for (i, tier) in tiers.enumerated() {
            let fraction = Double(i) / Double(max(tiers.count - 1, 1))
            let index = min(Int(fraction * Double(sorted.count - 1) + 0.5), sorted.count - 1)
            var variant = sorted[index]

            guard !picked.contains(where: { $0.url == variant.url }) else { continue }
            variant.tier = tier
            picked.append(variant)
        }

        return picked.reversed()
    }

    /// Exports a specific variant to a local MP4 file.
    public static func export(
        variant: Variant,
        outputName: String = "ambience_export",
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> URL {
        let prefix = "[Ambience Export]"
        print("\(prefix) Exporting variant: \(variant.displayName)")
        return try await downloadVariant(variant, outputName: outputName, onProgress: onProgress, prefix: prefix)
    }

    /// Convenience: fetches the master m3u8, picks the highest-bandwidth variant, and exports.
    public static func export(
        hlsURL: URL,
        outputName: String = "ambience_export",
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> URL {
        let prefix = "[Ambience Export]"
        print("\(prefix) Master m3u8: \(hlsURL.absoluteString)")

        let variants = try await availableVariants(hlsURL: hlsURL)
        guard let best = variants.first else { throw ExportError.noVariants }
        print("\(prefix) Auto-selected: \(best.displayName)")
        return try await downloadVariant(best, outputName: outputName, onProgress: onProgress, prefix: prefix)
    }

    // MARK: - Core Download

    private static func downloadVariant(
        _ variant: Variant,
        outputName: String,
        onProgress: (@Sendable (Double) -> Void)?,
        prefix: String
    ) async throws -> URL {

        let subContent = try await fetchString(from: variant.url)
        let segments = parseSubPlaylist(subContent, baseURL: variant.url)
        let totalSegments = segments.mediaSegmentURLs.count + (segments.initSegmentURL != nil ? 1 : 0)
        print("\(prefix) Init segment: \(segments.initSegmentURL != nil)  Media segments: \(segments.mediaSegmentURLs.count)")
        guard !segments.mediaSegmentURLs.isEmpty else { throw ExportError.noSegments }

        // 4. Prepare output file
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(outputName)
            .appendingPathExtension("mp4")
        try? FileManager.default.removeItem(at: outputURL)
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: outputURL)
        defer { try? handle.close() }

        var downloaded = 0

        // 5. Download init segment (ftyp + moov)
        if let initURL = segments.initSegmentURL {
            let data = try await downloadData(from: initURL)
            handle.write(data)
            downloaded += 1
            await reportProgress(downloaded, of: totalSegments, onProgress: onProgress)
            print("\(prefix) Init segment: \(ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file))")
        }

        // 6. Download media segments (moof + mdat)
        for segURL in segments.mediaSegmentURLs {
            let data = try await downloadData(from: segURL)
            handle.write(data)
            downloaded += 1
            await reportProgress(downloaded, of: totalSegments, onProgress: onProgress)
        }

        let fileSize = (try? FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? Int64) ?? 0
        print("\(prefix) Done: \(outputURL.lastPathComponent) (\(ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)))")

        return outputURL
    }

    // MARK: - M3U8 Parsing

    /// Parses a master playlist to extract variant streams.
    private static func parseMasterPlaylist(_ content: String, baseURL: URL) -> [Variant] {
        var variants: [Variant] = []
        let lines = content.components(separatedBy: .newlines)
        var i = 0

        while i < lines.count {
            let line = lines[i].trimmingCharacters(in: .whitespaces)

            if line.hasPrefix("#EXT-X-STREAM-INF:") {
                let attrs = String(line.dropFirst("#EXT-X-STREAM-INF:".count))
                let bandwidth = extractAttribute("BANDWIDTH", from: attrs).flatMap(Double.init) ?? 0
                let avgBandwidth = extractAttribute("AVERAGE-BANDWIDTH", from: attrs).flatMap(Double.init)
                let resolution = extractAttribute("RESOLUTION", from: attrs)
                let codecs = extractQuotedAttribute("CODECS", from: line)
                let primaryCodec = codecs?.components(separatedBy: ",").first

                i += 1
                while i < lines.count {
                    let urlLine = lines[i].trimmingCharacters(in: .whitespaces)
                    if !urlLine.isEmpty, !urlLine.hasPrefix("#") {
                        if let url = resolveURL(urlLine, against: baseURL) {
                            variants.append(Variant(
                                url: url,
                                bandwidth: avgBandwidth ?? bandwidth,
                                codec: primaryCodec,
                                resolution: resolution
                            ))
                        }
                        break
                    }
                    i += 1
                }
            }
            i += 1
        }

        return variants
    }

    /// Keeps only the highest-bandwidth variant per unique resolution.
    private static func deduplicateByResolution(_ sortedVariants: [Variant]) -> [Variant] {
        var seen = Set<String>()
        return sortedVariants.filter { v in
            let key = v.resolution ?? UUID().uuidString
            guard !seen.contains(key) else { return false }
            seen.insert(key)
            return true
        }
    }

    /// Parses a variant sub-playlist to extract init and media segment URLs.
    private static func parseSubPlaylist(_ content: String, baseURL: URL) -> SegmentList {
        var initURL: URL?
        var mediaURLs: [URL] = []
        let lines = content.components(separatedBy: .newlines)

        for (i, rawLine) in lines.enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespaces)

            // #EXT-X-MAP:URI="init.mp4"
            if line.hasPrefix("#EXT-X-MAP:") {
                if let uri = extractQuotedAttribute("URI", from: line) {
                    initURL = resolveURL(uri, against: baseURL)
                }
            }

            // #EXTINF: followed by segment URL
            if line.hasPrefix("#EXTINF:") {
                var j = i + 1
                while j < lines.count {
                    let segLine = lines[j].trimmingCharacters(in: .whitespaces)
                    if !segLine.isEmpty, !segLine.hasPrefix("#") {
                        if let url = resolveURL(segLine, against: baseURL) {
                            mediaURLs.append(url)
                        }
                        break
                    }
                    j += 1
                }
            }
        }

        return SegmentList(initSegmentURL: initURL, mediaSegmentURLs: mediaURLs)
    }

    // MARK: - Helpers

    private static func extractAttribute(_ name: String, from attrs: String) -> String? {
        // Handles: NAME=VALUE or NAME="VALUE"
        guard let range = attrs.range(of: "\(name)=") else { return nil }
        let rest = attrs[range.upperBound...]
        if rest.hasPrefix("\"") {
            let unquoted = rest.dropFirst()
            guard let end = unquoted.firstIndex(of: "\"") else { return nil }
            return String(unquoted[..<end])
        } else {
            let end = rest.firstIndex(of: ",") ?? rest.endIndex
            return String(rest[..<end])
        }
    }

    private static func extractQuotedAttribute(_ name: String, from line: String) -> String? {
        guard let range = line.range(of: "\(name)=\"") else { return nil }
        let rest = line[range.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        return String(rest[..<end])
    }

    private static func resolveURL(_ urlString: String, against base: URL) -> URL? {
        if urlString.hasPrefix("http://") || urlString.hasPrefix("https://") {
            return URL(string: urlString)
        }
        return URL(string: urlString, relativeTo: base)?.absoluteURL
    }

    private static func fetchString(from url: URL) async throws -> String {
        let (data, _) = try await URLSession.shared.data(from: url)
        guard let string = String(data: data, encoding: .utf8) else {
            throw ExportError.invalidManifest
        }
        return string
    }

    private static func downloadData(from url: URL) async throws -> Data {
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            return data
        } catch {
            throw ExportError.downloadFailed(url, error)
        }
    }

    @MainActor
    private static func reportProgress(_ done: Int, of total: Int, onProgress: (@Sendable (Double) -> Void)?) {
        guard let onProgress, total > 0 else { return }
        onProgress(Double(done) / Double(total))
    }
}
