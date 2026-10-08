import Foundation
import Observation
import os

@MainActor
@Observable
final class ActivityLog {
    enum Level: String {
        case info
        case success
        case warning
        case error
    }

    struct Entry: Identifiable {
        let id = UUID()
        let date: Date
        let level: Level
        let message: String
    }

    private(set) var entries: [Entry] = []
    @ObservationIgnored private let logger = Logger(subsystem: "com.vivapercuore.StayWhereWindowsAre", category: "activity")
    @ObservationIgnored private let fileURL: URL
    @ObservationIgnored private let fileQueue = DispatchQueue(label: "com.vivapercuore.StayWhereWindowsAre.log")
    @ObservationIgnored private let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()

    init(fileURL: URL = ActivityLog.defaultFileURL) {
        self.fileURL = fileURL
    }

    nonisolated static var defaultFileURL: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("StayWhereWindowsAre.log")
    }

    var logFileURL: URL { fileURL }

    func add(_ message: String, level: Level = .info) {
        let entry = Entry(date: Date(), level: level, message: message)
        entries.append(entry)
        if entries.count > 600 { entries.removeFirst(entries.count - 500) }
        switch level {
        case .error: logger.error("\(message, privacy: .public)")
        case .warning: logger.warning("\(message, privacy: .public)")
        default: logger.info("\(message, privacy: .public)")
        }
        let line = "\(formatter.string(from: entry.date)) [\(level.rawValue)] \(message)\n"
        let url = fileURL
        fileQueue.async {
            let manager = FileManager.default
            try? manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let size = (try? manager.attributesOfItem(atPath: url.path))?[.size] as? Int, size > 2_000_000 {
                let rotated = url.deletingPathExtension().appendingPathExtension("old.log")
                try? manager.removeItem(at: rotated)
                try? manager.moveItem(at: url, to: rotated)
            }
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: url)
            }
        }
    }

    func clear() { entries.removeAll() }
}
