import Foundation

/// Errors that can occur during ambience artwork operations.
public enum AmbienceError: Error, Equatable {
    case invalidURL
    case invalidHTMLContent
    case noAmbienceArtworkFound
    case networkError
    /// Apple Music responded with a storefront homepage redirect (typically HTTP 302).
    /// - Parameter detectedStorefront: Storefront code parsed from the redirect location
    ///   (e.g. `"cn"` from `https://music.apple.com/cn`), when available.
    case redirectedToHomepage(detectedStorefront: String? = nil)
}

extension AmbienceError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "The Apple Music link is invalid."
        case .invalidHTMLContent:
            return "Failed to parse Apple Music page content."
        case .noAmbienceArtworkFound:
            return "No animated artwork is available for this item."
        case .networkError:
            return "Network request failed while loading Apple Music data."
        case .redirectedToHomepage(let storefront):
            if let storefront {
                return "Storefront mismatch detected (redirected toward \(storefront))."
            }
            return "Storefront mismatch detected and redirect to homepage occurred."
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .noAmbienceArtworkFound:
            return "Try another album or playlist that has animated artwork."
        case .redirectedToHomepage:
            return "Try a link from your current storefront, or retry so Ambience can rewrite the storefront automatically."
        default:
            return nil
        }
    }
}
