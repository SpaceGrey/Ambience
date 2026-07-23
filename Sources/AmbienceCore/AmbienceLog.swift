import Foundation

/// Severity levels for Ambience logging.
public enum AmbienceLogLevel: String, Sendable, CaseIterable {
    case debug
    case info
    case warning
    case error
}

/// Host apps implement this to receive Ambience log events.
///
/// Inject an instance via ``AmbienceLog/handler`` at launch, for example:
/// ```swift
/// AmbienceLog.handler = MyAppAmbienceLogHandler()
/// ```
public protocol AmbienceLogHandler: Sendable {
    func log(
        _ level: AmbienceLogLevel,
        _ message: String,
        metadata: [String: String]
    )
}

/// Process-wide Ambience logging entry point.
///
/// When no ``handler`` is set, messages fall back to `print` so the package
/// remains debuggable out of the box (CLI / companion app).
public enum AmbienceLog {
    /// App-provided log sink. Expected to be set once during app launch.
    nonisolated(unsafe) public static var handler: (any AmbienceLogHandler)?

    public static func log(
        _ level: AmbienceLogLevel,
        _ message: String,
        metadata: [String: String] = [:]
    ) {
        if let handler {
            handler.log(level, message, metadata: metadata)
            return
        }

        fallbackPrint(level, message, metadata: metadata)
    }

    public static func debug(
        _ message: String,
        metadata: [String: String] = [:]
    ) {
        log(.debug, message, metadata: metadata)
    }

    public static func info(
        _ message: String,
        metadata: [String: String] = [:]
    ) {
        log(.info, message, metadata: metadata)
    }

    public static func warning(
        _ message: String,
        metadata: [String: String] = [:]
    ) {
        log(.warning, message, metadata: metadata)
    }

    public static func error(
        _ message: String,
        metadata: [String: String] = [:]
    ) {
        log(.error, message, metadata: metadata)
    }

    // MARK: - Private

    private static func fallbackPrint(
        _ level: AmbienceLogLevel,
        _ message: String,
        metadata: [String: String]
    ) {
        let metaSuffix: String
        if metadata.isEmpty {
            metaSuffix = ""
        } else {
            let pairs = metadata
                .sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: " ")
            metaSuffix = " | \(pairs)"
        }
        print("[Ambience][\(level.rawValue.uppercased())] \(message)\(metaSuffix)")
    }
}
