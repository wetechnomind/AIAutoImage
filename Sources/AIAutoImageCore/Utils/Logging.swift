//
//  Logging.swift
//  AIAutoImage
//

import Foundation

// MARK: - Log Level

public enum AILogLevel: Int, Sendable {
    case error = 0
    case warning = 1
    case info = 2
    case debug = 3
}

// MARK: - Actor-Based Logger

public actor AILog {

    public static let shared = AILog()

    public var level: AILogLevel = .info
    public var enableFileLogging: Bool = false

    private lazy var logFileURL: URL = {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AIAutoImage.log")
    }()

    private init() {}

    // MARK: Public API (async-safe)

    public func error(_ message: String) async { await log(message, level: .error) }
    public func warning(_ message: String) async { await log(message, level: .warning) }
    public func info(_ message: String) async { await log(message, level: .info) }
    public func debug(_ message: String) async { await log(message, level: .debug) }

    // MARK: Core Logging Engine (async)

    private func log(_ message: String, level: AILogLevel) async {
        guard await shouldLog(level: level) else { return }

        let line = "[AIAutoImage][\(label(for: level))] \(timestamp()) — \(message)"

        print(line)

        if enableFileLogging {
            appendToFile(line + "\n")
        }
    }

    // MARK: Log-Level Rules (MainActor-safe)

    @MainActor
    private func snapshotConfig()
    -> (debugEnabled: Bool, perfMode: AIPerformanceMode) {
        let cfg = AIImageConfig.shared
        return (cfg.enableDebugLogs, cfg.performanceMode)
    }

    private func shouldLog(level: AILogLevel) async -> Bool {

        // must hop to main actor to read config safely
        let (debugEnabled, perfMode) = await snapshotConfig()

        if level == .debug {
            if !debugEnabled { return false }
            if perfMode == .batterySaving { return false }
        }

        return level.rawValue <= self.level.rawValue
    }

    // MARK: Formatting

    private func label(for level: AILogLevel) -> String {
        switch level {
        case .error: return "❌ ERROR"
        case .warning: return "⚠️ WARNING"
        case .info: return "ℹ️ INFO"
        case .debug: return "🐞 DEBUG"
        }
    }

    private func timestamp() -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return df.string(from: Date())
    }

    // MARK: File Logging

    private func appendToFile(_ text: String) {
        let data = text.data(using: .utf8) ?? Data()

        // create new file
        if !FileManager.default.fileExists(atPath: logFileURL.path) {
            _ = try? data.write(to: logFileURL)   // safe ignore
            return
        }

        // append
        if let handle = try? FileHandle(forWritingTo: logFileURL) {
            try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
            try? handle.close()
        }
    }

    public func exportLogFile() -> String? {
        guard let data = try? Data(contentsOf: logFileURL) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func clearLogFile() {
        _ = try? FileManager.default.removeItem(at: logFileURL)
    }
}
