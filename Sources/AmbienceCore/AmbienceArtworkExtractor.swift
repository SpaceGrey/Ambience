import Foundation
import Kanna

/// Extracts ambience artwork HLS URLs from Apple Music HTML content.
public enum AmbienceArtworkExtractor {
    /// Extracts the ambience artwork URL from the given HTML content.
    /// - Parameter htmlContent: The HTML content to extract the URL from.
    /// - Returns: The URL of the ambience artwork HLS stream.
    /// - Throws: `AmbienceError` if the ambience artwork URL cannot be found or is invalid.
    public static func extractAmbienceArtworkURL(from htmlContent: String) throws -> URL {
        let keyword = "amp-ambient-video"
        let ampAmbientVideoTagStart = "<" + keyword
        let ampAmbientVideoTagEnd = "</" + keyword + ">"

        guard let startRange = htmlContent.range(of: ampAmbientVideoTagStart),
              let endRange = htmlContent.range(of: ampAmbientVideoTagEnd)
        else {
            AmbienceLog.info(
                "No amp-ambient-video tag in Apple Music HTML",
                metadata: [
                    "html_bytes": String(htmlContent.utf8.count),
                    "contains_ambient": String(htmlContent.contains("ambient")),
                ]
            )
            throw AmbienceError.noAmbienceArtworkFound
        }

        let content = htmlContent[startRange.lowerBound ..< endRange.upperBound]
        let html = String(content)

        let doc = try HTML(html: html, encoding: .utf8)

        guard let source = doc.xpath("//" + keyword).first?["src"],
              !source.isEmpty,
              let url = URL(string: source)
        else {
            AmbienceLog.warning(
                "amp-ambient-video tag present but src missing or invalid",
                metadata: ["tag_bytes": String(html.utf8.count)]
            )
            throw AmbienceError.noAmbienceArtworkFound
        }

        AmbienceLog.info(
            "Extracted ambience HLS URL",
            metadata: ["hls_url": url.absoluteString]
        )
        return url
    }
}
