//
//  Logging.swift
//  AIAutoImage
//
//  Production-grade actor-isolated logging module for AIAutoImage.
//  Provides safe concurrency, configurable log levels, optional file logging,
//  and integration with AIImageConfig runtime settings.
//

import Foundation

// MARK: - Log Level

/// Severity levels for the AIAutoImage logging system.
///
/// Level comparison:
/// - `.error`   → always log-worthy
/// - `.warning` → recoverable issues
/// - `.info`    → high-level pipeline state
/// - `.debug`   → verbose internal events (disabled in battery-saving mode)
///
/// Used by the `AILog` actor to determine if a message should be emitted.
public enum AILogLevel: Int, Sendable {

    /// Critical failures or unexpected behavior — requires attention.
    case error = 0

    /// Non-fatal issues that may impact functionality.
    case warning = 1

    /// General informational messages about pipeline state.
    case info = 2

    /// Extremely detailed logs for debugging pipeline behavior.
    case debug = 3
}

// MARK: - Actor-Based Logger (Swift-Concurrency Safe)

/// Centralized async-safe logger for all AIAutoImage subsystems.
///
/// Features:
/// - Actor-isolated → fully concurrency-correct under Swift 6
/// - Supports runtime log level filtering
/// - Optional persistent file logging
/// - Integrates with `AIImageConfig` for performance-aware behavior
///
/// The logger does **not** block UI, and safely handles concurrent writes.
///
/// Example:
/// ```swift
/// await AILog.shared.info("Decoding started: \(url)")
/// await AILog.shared.debug("CIImage extent: \(ci.extent)")
/// await AILog.shared.error("Failed to load model: \(model)")
/// ```
public actor AILog {

    /// Shared global instance used throughout the framework.
    public static let shared = AILog()

    // MARK: - State

    /// Minimum log level required for messages to be emitted.
    ///
    /// Default: `.info`
    public var level: AILogLevel = .info

    /// Whether log lines should be appended to disk (`AIAutoImage.log`).
    ///
    /// File path: `<Caches>/AIAutoImage.log`
    public var enableFileLogging: Bool = false

    /// File URL stored in the user cache directory.
    private lazy var logFileURL: URL = {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AIAutoImage.log")
    }()

    private init() {}

    // MARK: - Public Logging API

    /// Logs an error-level message.
    public func error(_ message: String) {
        log(message, level: .error)
    }

    /// Logs a warning-level message.
    public func warning(_ message: String) {
        log(message, level: .warning)
    }

    /// Logs an info-level message.
    public func info(_ message: String) {
        log(message, level: .info)
    }

    /// Logs a debug-level message.
    ///
    /// Debug messages are automatically suppressed when:
    /// - `AIImageConfig.shared.enableDebugLogs == false`
    /// - `AIImageConfig.shared.performanceMode == .batterySaving`
    public func debug(_ message: String) {
        log(message, level: .debug)
    }

    // MARK: - Internal Logging Engine

    /// Central handler for all log messages.
    ///
    /// - Parameters:
    ///   - message: Log line text.
    ///   - level: Severity of the log entry.
    private func log(_ message: String, level: AILogLevel) {
        guard shouldLog(level: level) else { return }

        let line = "[AIAutoImage][\(label(for: level))] \(timestamp()) — \(message)"

        // Console output
        print(line)

        // Optional persistent file logging
        if enableFileLogging {
            appendToFile(line + "\n")
        }
    }

    // MARK: - Log Level Filtering

    /// Determines whether a log message should be emitted.
    ///
    /// Conditions:
    /// - Debug logs disabled in config → skip `.debug`
    /// - Performance mode is battery-saving → skip `.debug`
    /// - Current logger level is higher than requested level → skip
    private func shouldLog(level: AILogLevel) -> Bool {

        // Debug logs globally disabled
        if !AIImageConfig.shared.enableDebugLogs && level == .debug {
            return false
        }

        // In battery-saving mode, debug logs are skipped
        if AIImageConfig.shared.performanceMode == AIPerformanceMode.batterySaving &&
            level == .debug {
            return false
        }

        // Level threshold check
        return level.rawValue <= self.level.rawValue
    }

    // MARK: - Formatting Helpers

    /// Converts log level to an emoji-labeled severity string.
    private func label(for level: AILogLevel) -> String {
        switch level {
        case .error:   return "❌ ERROR"
        case .warning: return "⚠️ WARNING"
        case .info:    return "ℹ️ INFO"
        case .debug:   return "🐞 DEBUG"
        }
    }

    /// Generates a timestamp for log entries (`yyyy-MM-dd HH:mm:ss.SSS`)
    private func timestamp() -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return df.string(from: Date())
    }

    // MARK: - File Logging

    /// Appends text to the log file located in the cache directory.
    ///
    /// Automatically creates the file on first write.
    ///
    /// - Parameter text: A single log line with a trailing newline.
    private func appendToFile(_ text: String) {
        let data = text.data(using: .utf8) ?? Data()

        // Create if missing
        if !FileManager.default.fileExists(atPath: logFileURL.path) {
            _ = try? data.write(to: logFileURL)
            return
        }

        // Append to file
        if let handle = try? FileHandle(forWritingTo: logFileURL) {
            try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
            try? handle.close()
        }
    }

    /// Reads the entire log file from disk and returns its contents.
    ///
    /// - Returns: Log file contents as a UTF-8 string, or nil if missing.
    public func exportLogFile() -> String? {
        guard let data = try? Data(contentsOf: logFileURL) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Deletes the persistent log file from disk.
    public func clearLogFile() {
        try? FileManager.default.removeItem(at: logFileURL)
    }
}
