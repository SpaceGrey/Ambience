import Foundation

/// Fetches HTML content from remote URLs with redirect detection.
public enum HTMLFetcher {

    private class RedirectDetector: NSObject, URLSessionTaskDelegate {
        var hasRedirected = false

        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            if response.statusCode == 302 {
                hasRedirected = true
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
        let redirectDetector = RedirectDetector()
        let session = URLSession(configuration: .default, delegate: redirectDetector, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        let (data, response) = try await session.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AmbienceError.networkError
        }

        if redirectDetector.hasRedirected {
            throw AmbienceError.redirectedToHomepage
        }

        guard (200 ... 299).contains(httpResponse.statusCode) else {
            throw AmbienceError.networkError
        }

        guard let htmlString = String(data: data, encoding: .utf8), !htmlString.isEmpty else {
            throw AmbienceError.invalidHTMLContent
        }

        return htmlString
    }
}
