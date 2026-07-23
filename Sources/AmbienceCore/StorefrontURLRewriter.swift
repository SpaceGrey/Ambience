import Foundation

/// Rewrites Apple Music page URLs to a different storefront.
public enum StorefrontURLRewriter {
    /// Returns a copy of `url` with the storefront path segment replaced.
    ///
    /// Apple Music catalog URLs look like:
    /// `https://music.apple.com/{storefront}/album/{slug}/{id}`
    ///
    /// - Parameters:
    ///   - url: Original music.apple.com URL.
    ///   - storefront: Target storefront code (e.g. `"cn"`).
    /// - Returns: Rewritten URL, or `nil` if the URL cannot be rewritten.
    public static func replacingStorefront(in url: URL, with storefront: String) -> URL? {
        let normalized = storefront.lowercased()
        guard (2 ... 5).contains(normalized.count),
              normalized.unicodeScalars.allSatisfy({ CharacterSet.letters.contains($0) })
        else {
            return nil
        }

        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }

        var segments = url.pathComponents.filter { $0 != "/" }
        guard !segments.isEmpty else { return nil }

        // First path segment is the storefront on music.apple.com.
        if segments[0].lowercased() == normalized {
            return url
        }
        segments[0] = normalized
        components.path = "/" + segments.joined(separator: "/")
        return components.url
    }

    /// Extracts the storefront path segment from an Apple Music URL, if present.
    public static func storefront(in url: URL) -> String? {
        let segments = url.pathComponents.filter { $0 != "/" }
        guard let first = segments.first,
              (2 ... 5).contains(first.count),
              first.unicodeScalars.allSatisfy({ CharacterSet.letters.contains($0) })
        else {
            return nil
        }
        return first.lowercased()
    }
}
