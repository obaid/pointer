import Foundation
import SwiftUI

/// Persistent log of completed tasks. Lives at:
///   ~/Library/Application Support/Pointer/history.jsonl
///
/// Records are keyed by `ActiveTask.id` — recording the same task twice (e.g.,
/// when a follow-up reply runs another turn on the same conversation) replaces
/// the prior entry instead of duplicating it. Capped at `maxEntries` total,
/// most-recent first.
@MainActor
final class HistoryStore: ObservableObject {
    static let shared = HistoryStore()

    @Published private(set) var entries: [ActiveTask] = []

    private let fileURL: URL
    private let maxEntries = 200

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("Pointer", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.fileURL = dir.appendingPathComponent("history.jsonl")
        load()
    }

    /// Insert or replace `task` at the head of the list, then persist.
    func record(_ task: ActiveTask) {
        if let idx = entries.firstIndex(where: { $0.id == task.id }) {
            entries.remove(at: idx)
        }
        entries.insert(task, at: 0)
        if entries.count > maxEntries {
            entries = Array(entries.prefix(maxEntries))
        }
        persist()
    }

    /// Wipe everything (for the "Clear history" affordance — not yet wired).
    func clear() {
        entries = []
        try? FileManager.default.removeItem(at: fileURL)
    }

    // MARK: - Disk I/O

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let text = String(data: data, encoding: .utf8)
        else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        entries = text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { line in
                try? decoder.decode(ActiveTask.self, from: Data(line.utf8))
            }
    }

    private func persist() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let lines = entries.compactMap { task -> String? in
            guard
                let data = try? encoder.encode(task),
                let s = String(data: data, encoding: .utf8)
            else { return nil }
            return s
        }
        let text = lines.joined(separator: "\n") + "\n"
        try? text.data(using: .utf8)?.write(to: fileURL, options: .atomic)
    }
}
