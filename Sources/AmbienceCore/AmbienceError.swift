import Foundation

/// Errors that can occur during ambience artwork operations.
public enum AmbienceError: Error {
    case invalidURL
    case invalidHTMLContent
    case noAmbienceArtworkFound
    case networkError
    case redirectedToHomepage
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
        case .redirectedToHomepage:
            return "Storefront mismatch detected and redirect to homepage occurred."
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .noAmbienceArtworkFound:
            return "Try another album or playlist that has animated artwork."
        case .redirectedToHomepage:
            return "Try a link from your current storefront."
        default:
            return nil
        }
    }
}
