import Foundation

/// Fetches HTML content from remote URLs with redirect detection.
public enum HTMLFetcher {

    private class RedirectDetector: NSObject, URLSessionTaskDelegate {
        var hasRedirected = false
        var redirectStatusCode: Int?
        var redirectLocation: String?

        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            // Apple Music signals storefront mismatch with a 302 to the regional homepage
            // (e.g. /us/album/... → https://music.apple.com/cn). Cancel the redirect so
            // callers can rewrite the album URL to the detected storefront and retry.
            if response.statusCode == 302 {
                hasRedirected = true
                redirectStatusCode = response.statusCode
                redirectLocation =
                    response.value(forHTTPHeaderField: "Location")
                    ?? request.url?.absoluteString
                completionHandler(nil)
            } else {
                completionHandler(request)
            }
        }
    }

    /// Fetches HTML content from a given URL.
    /// - Parameter url: The URL to fetch HTML content from.
    /// - Returns: The HTML content as a string.
    /// - Throws: `AmbienceError` if the network request fails or the response is invalid.
    public static func fetchHTMLContent(from url: URL) async throws -> String {
        AmbienceLog.debug(
            "Fetching Apple Music page HTML",
            metadata: ["url": url.absoluteString]
        )

        let redirectDetector = RedirectDetector()
        let session = URLSession(configuration: .default, delegate: redirectDetector, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(from: url)
        } catch {
            AmbienceLog.error(
                "HTML fetch network failure",
                metadata: [
                    "url": url.absoluteString,
                    "error": error.localizedDescription,
                ]
            )
            throw AmbienceError.networkError
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            AmbienceLog.error(
                "HTML fetch returned non-HTTP response",
                metadata: ["url": url.absoluteString]
            )
            throw AmbienceError.networkError
        }

        if redirectDetector.hasRedirected {
            let location = redirectDetector.redirectLocation
            let detectedStorefront = storefrontCode(fromRedirectLocation: location)
            AmbienceLog.warning(
                "HTML fetch redirected to homepage (storefront mismatch)",
                metadata: [
                    "url": url.absoluteString,
                    "status": String(redirectDetector.redirectStatusCode ?? 302),
                    "location": location ?? "unknown",
                    "detected_storefront": detectedStorefront ?? "unknown",
                ]
            )
            throw AmbienceError.redirectedToHomepage(detectedStorefront: detectedStorefront)
        }

        guard (200 ... 299).contains(httpResponse.statusCode) else {
            AmbienceLog.error(
                "HTML fetch HTTP error",
                metadata: [
                    "url": url.absoluteString,
                    "status": String(httpResponse.statusCode),
                ]
            )
            throw AmbienceError.networkError
        }

        guard let htmlString = String(data: data, encoding: .utf8), !htmlString.isEmpty else {
            AmbienceLog.error(
                "HTML fetch produced empty or non-UTF8 body",
                metadata: [
                    "url": url.absoluteString,
                    "bytes": String(data.count),
                ]
            )
            throw AmbienceError.invalidHTMLContent
        }

        AmbienceLog.debug(
            "HTML fetch succeeded",
            metadata: [
                "url": url.absoluteString,
                "status": String(httpResponse.statusCode),
                "bytes": String(data.count),
            ]
        )
        return htmlString
    }

    /// Parses a storefront code from an Apple Music redirect location.
    ///
    /// Examples:
    /// - `https://music.apple.com/cn` → `"cn"`
    /// - `https://music.apple.com/jp/` → `"jp"`
    /// - `https://music.apple.com/tw/browse` → `"tw"`
    public static func storefrontCode(fromRedirectLocation location: String?) -> String? {
        guard let location, !location.isEmpty else { return nil }

        guard let url = URL(string: location) else {
            // Fallback for bare paths like "/cn"
            let trimmed = location.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let first = trimmed.split(separator: "/").first.map(String.init)
            return isPlausibleStorefront(first) ? first : nil
        }

        let segments = url.pathComponents.filter { $0 != "/" }
        guard let first = segments.first, isPlausibleStorefront(first) else {
            return nil
        }
        return first.lowercased()
    }

    private static func isPlausibleStorefront(_ value: String?) -> Bool {
        guard let value else { return false }
        // Apple Music storefront codes are short alphabetic tokens (us, cn, jp, tw, ...).
        guard (2 ... 5).contains(value.count) else { return false }
        return value.unicodeScalars.allSatisfy { CharacterSet.letters.contains($0) }
    }
}
