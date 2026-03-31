import ArgumentParser
import Foundation
import AmbienceCore

// MARK: - Spinner

final class Spinner: @unchecked Sendable {
    private static let frames = ["⠋","⠙","⠹","⠸","⠼","⠴","⠦","⠧","⠇","⠏"]
    private var frameIndex = 0
    private var message: String
    private var running = false
    private var task: Task<Void, Never>?

    init(_ message: String) {
        self.message = message
    }

    func start() {
        running = true
        task = Task { [weak self] in
            while let self, self.running {
                let frame = Self.frames[self.frameIndex % Self.frames.count]
                print("\r\u{1B}[2K  \(frame) \(self.message)", terminator: "")
                fflush(stdout)
                self.frameIndex += 1
                try? await Task.sleep(nanoseconds: 80_000_000)
            }
        }
    }

    func update(_ newMessage: String) {
        message = newMessage
    }

    func stop(symbol: String = "✓", finalMessage: String) {
        running = false
        task?.cancel()
        task = nil
        print("\r\u{1B}[2K  \(symbol) \(finalMessage)")
        fflush(stdout)
    }
}

// MARK: - Main Command

@main
struct AmbienceCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ambience-cli",
        abstract: "Download and export Apple Music ambient videos.",
        discussion: """
            Quick start:
              ambience-cli                              Interactive guided mode
              ambience-cli <apple-music-url>            Export best quality to Desktop
              ambience-cli <url> -q high -o ~/out.mp4   Custom quality and path
            """,
        subcommands: [Resolve.self, Variants.self]
    )

    @Argument(help: "Apple Music URL. If omitted, enters interactive mode.")
    var url: String?

    @Option(name: .shortAndLong, help: "Quality: low, standard, high, original.")
    var quality: String?

    @Option(name: .shortAndLong, help: "Output file path.")
    var output: String?

    func run() async throws {
        if let url {
            try await directExport(urlString: url, quality: quality, output: output)
        } else {
            try await interactiveMode()
        }
    }
}

// MARK: - Direct Export Mode

private func directExport(urlString: String, quality: String?, output: String?) async throws {
    let spinner = Spinner("Resolving HLS stream...")
    spinner.start()

    let hlsURL: URL
    do {
        hlsURL = try await resolveToHLS(urlString)
        spinner.stop(finalMessage: "Stream resolved.")
    } catch {
        spinner.stop(symbol: "✗", finalMessage: "Failed: \(error.localizedDescription)")
        throw ExitCode.failure
    }

    let variantSpinner = Spinner("Fetching variants...")
    variantSpinner.start()

    let variants: [AmbienceExporter.Variant]
    do {
        variants = try await AmbienceExporter.availableVariants(hlsURL: hlsURL)
        guard !variants.isEmpty else {
            variantSpinner.stop(symbol: "✗", finalMessage: "No variants found.")
            throw ExitCode.failure
        }
        variantSpinner.stop(finalMessage: "Found \(variants.count) quality tier(s).")
    } catch {
        variantSpinner.stop(symbol: "✗", finalMessage: "Failed: \(error.localizedDescription)")
        throw ExitCode.failure
    }

    let tier: AmbienceExporter.QualityTier
    if let quality {
        guard let parsed = AmbienceExporter.QualityTier(rawValue: quality.capitalized) else {
            let valid = AmbienceExporter.QualityTier.allCases.map { $0.rawValue.lowercased() }.joined(separator: ", ")
            print("  ✗ Unknown quality '\(quality)'. Valid: \(valid)")
            throw ExitCode.failure
        }
        tier = parsed
    } else {
        tier = .original
    }

    let variant = variants.first { $0.tier == tier } ?? variants.first!

    let outputURL: URL
    if let output {
        let path = (output as NSString).expandingTildeInPath
        outputURL = URL(fileURLWithPath: path)
    } else {
        outputURL = defaultOutputURL(for: urlString)
    }

    try await performExport(variant: variant, to: outputURL)
}

// MARK: - Interactive Mode

private func interactiveMode() async throws {
    print()
    print("  Ambience — Apple Music Ambient Video Exporter")
    print()

    // Step 1: Get URL
    print("  Paste an Apple Music link: ", terminator: "")
    fflush(stdout)
    guard let input = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines),
          !input.isEmpty else {
        print("  ✗ No URL provided.")
        throw ExitCode.failure
    }

    // Step 2: Resolve
    let spinner = Spinner("Resolving HLS stream...")
    spinner.start()

    let hlsURL: URL
    do {
        hlsURL = try await resolveToHLS(input)
        spinner.stop(finalMessage: "Stream resolved.")
    } catch {
        spinner.stop(symbol: "✗", finalMessage: "Failed: \(error.localizedDescription)")
        throw ExitCode.failure
    }

    // Step 3: Fetch variants
    let variantSpinner = Spinner("Fetching variants...")
    variantSpinner.start()

    let variants: [AmbienceExporter.Variant]
    do {
        variants = try await AmbienceExporter.availableVariants(hlsURL: hlsURL)
        guard !variants.isEmpty else {
            variantSpinner.stop(symbol: "✗", finalMessage: "No variants found.")
            throw ExitCode.failure
        }
        variantSpinner.stop(finalMessage: "Found \(variants.count) quality tier(s).")
    } catch {
        variantSpinner.stop(symbol: "✗", finalMessage: "Failed: \(error.localizedDescription)")
        throw ExitCode.failure
    }

    // Step 4: Choose quality
    print()
    print("  Available qualities:")
    for (i, v) in variants.enumerated() {
        let res = v.resolution ?? "unknown"
        let bw = formatBandwidth(v.bandwidth)
        let marker = i == 0 ? " (default)" : ""
        print("    [\(i + 1)] \(v.tier.label.padding(toLength: 10, withPad: " ", startingAt: 0)) \(res.padding(toLength: 12, withPad: " ", startingAt: 0)) \(bw)\(marker)")
    }
    print()
    print("  Choose quality [1]: ", terminator: "")
    fflush(stdout)

    let choiceStr = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let choiceIndex: Int
    if choiceStr.isEmpty {
        choiceIndex = 0
    } else if let num = Int(choiceStr), num >= 1, num <= variants.count {
        choiceIndex = num - 1
    } else {
        print("  ✗ Invalid choice.")
        throw ExitCode.failure
    }

    let variant = variants[choiceIndex]

    // Step 5: Choose output path
    let defaultOutput = defaultOutputURL(for: input)
    let displayPath = defaultOutput.path.replacingOccurrences(
        of: FileManager.default.homeDirectoryForCurrentUser.path,
        with: "~"
    )
    print("  Save to [\(displayPath)]: ", terminator: "")
    fflush(stdout)

    let pathInput = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let outputURL: URL
    if pathInput.isEmpty {
        outputURL = defaultOutput
    } else {
        let expanded = (pathInput as NSString).expandingTildeInPath
        outputURL = URL(fileURLWithPath: expanded)
    }
    print()

    try await performExport(variant: variant, to: outputURL)
}

// MARK: - Shared Export Logic

private func performExport(variant: AmbienceExporter.Variant, to outputURL: URL) async throws {
    let res = variant.resolution ?? "unknown"
    let bw = formatBandwidth(variant.bandwidth)

    let spinner = Spinner("Downloading \(variant.tier.label) (\(res), \(bw))...")
    spinner.start()

    do {
        let result = try await AmbienceExporter.export(
            variant: variant,
            to: outputURL
        ) { progress in
            let pct = Int(progress * 100)
            spinner.update("Downloading \(variant.tier.label) (\(res), \(bw))... \(pct)%")
        }

        let fileSize = (try? FileManager.default.attributesOfItem(atPath: result.path)[.size] as? Int64) ?? 0
        let sizeStr = ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
        let displayPath = result.path.replacingOccurrences(
            of: FileManager.default.homeDirectoryForCurrentUser.path,
            with: "~"
        )
        spinner.stop(finalMessage: "Saved: \(displayPath) (\(sizeStr))")
    } catch {
        spinner.stop(symbol: "✗", finalMessage: "Export failed: \(error.localizedDescription)")
        throw ExitCode.failure
    }
}

// MARK: - Hidden Subcommands

extension AmbienceCLI {
    struct Resolve: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Resolve an Apple Music URL to its HLS stream URL.",
            shouldDisplay: false
        )

        @Argument(help: "An Apple Music URL (album, playlist, etc.).")
        var url: String

        func run() async throws {
            guard let pageURL = URL(string: url) else {
                throw ValidationError("Invalid URL: \(url)")
            }

            let html = try await HTMLFetcher.fetchHTMLContent(from: pageURL)
            let hlsURL = try AmbienceArtworkExtractor.extractAmbienceArtworkURL(from: html)
            print(hlsURL.absoluteString)
        }
    }

    struct Variants: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "List available quality variants for an ambient video.",
            shouldDisplay: false
        )

        @Argument(help: "An Apple Music URL or a direct HLS m3u8 URL.")
        var url: String

        func run() async throws {
            let hlsURL = try await resolveToHLS(url)
            let variants = try await AmbienceExporter.availableVariants(hlsURL: hlsURL)

            guard !variants.isEmpty else {
                print("No variants found.")
                return
            }

            for variant in variants {
                let resolution = variant.resolution ?? "unknown"
                let bandwidth = formatBandwidth(variant.bandwidth)
                let codec = variant.codec ?? "unknown"
                print("  \(variant.tier.label.padding(toLength: 10, withPad: " ", startingAt: 0)) \(resolution.padding(toLength: 12, withPad: " ", startingAt: 0)) \(bandwidth.padding(toLength: 12, withPad: " ", startingAt: 0)) \(codec)")
            }
        }
    }
}

// MARK: - Helpers

/// Extracts a slug from an Apple Music URL to use as a filename.
/// e.g. `.../album/whatevers-clever/123` -> `whatevers_clever`
private func slugFromURL(_ urlString: String) -> String? {
    guard let url = URL(string: urlString) else { return nil }
    let path = url.pathComponents

    for keyword in ["album", "playlist"] {
        guard let idx = path.firstIndex(of: keyword), idx + 1 < path.count else { continue }
        let slug = path[idx + 1]
        guard !slug.isEmpty, !slug.hasPrefix("pl."), Int(slug) == nil else { continue }
        return slug.replacingOccurrences(of: "-", with: "_")
    }
    return nil
}

/// Returns a default output URL on the Desktop, with a name derived from the input URL.
private func defaultOutputURL(for urlString: String) -> URL {
    let name = slugFromURL(urlString) ?? "ambience_export"
    let desktop = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
    return desktop.appendingPathComponent(name).appendingPathExtension("mp4")
}

/// Resolves a user-provided URL string to an HLS m3u8 URL.
private func resolveToHLS(_ urlString: String) async throws -> URL {
    guard let url = URL(string: urlString) else {
        throw ValidationError("Invalid URL: \(urlString)")
    }

    if url.pathExtension == "m3u8" || url.absoluteString.contains(".m3u8") {
        return url
    }

    do {
        let html = try await HTMLFetcher.fetchHTMLContent(from: url)
        return try AmbienceArtworkExtractor.extractAmbienceArtworkURL(from: html)
    } catch AmbienceError.redirectedToHomepage {
        guard let corrected = try await detectAndCorrectStorefront(for: url) else {
            throw AmbienceError.redirectedToHomepage
        }
        let html = try await HTMLFetcher.fetchHTMLContent(from: corrected)
        return try AmbienceArtworkExtractor.extractAmbienceArtworkURL(from: html)
    }
}

private func detectAndCorrectStorefront(for url: URL) async throws -> URL? {
    final class StorefrontRedirectCapture: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        var redirectLocation: String?

        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            if response.statusCode == 302, let location = response.value(forHTTPHeaderField: "Location") {
                redirectLocation = location
            }
            completionHandler(nil)
        }
    }

    let capture = StorefrontRedirectCapture()
    let session = URLSession(configuration: .default, delegate: capture, delegateQueue: nil)
    defer { session.finishTasksAndInvalidate() }

    _ = try? await session.data(from: url)

    guard let location = capture.redirectLocation else { return nil }

    let storefront = location
        .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        .components(separatedBy: "/")
        .last ?? location.trimmingCharacters(in: CharacterSet(charactersIn: "/"))

    guard !storefront.isEmpty, storefront.count <= 5 else { return nil }

    var pathComponents = url.pathComponents
    guard pathComponents.count >= 2 else { return nil }

    pathComponents[1] = storefront

    guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
    components.path = pathComponents.joined(separator: "/")
        .replacingOccurrences(of: "//", with: "/")

    return components.url
}

private func formatBandwidth(_ bps: Double) -> String {
    if bps >= 1_000_000 {
        return String(format: "%.1f Mbps", bps / 1_000_000)
    } else if bps >= 1_000 {
        return String(format: "%.0f kbps", bps / 1_000)
    }
    return String(format: "%.0f bps", bps)
}
