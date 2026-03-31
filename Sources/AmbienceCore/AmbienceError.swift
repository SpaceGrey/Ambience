import Foundation

/// Errors that can occur during ambience artwork operations.
public enum AmbienceError: Error {
    case invalidURL
    case invalidHTMLContent
    case noAmbienceArtworkFound
    case networkError
    case redirectedToHomepage
}
