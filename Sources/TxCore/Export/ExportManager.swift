import Foundation

public enum ExportFormat: String, CaseIterable, Sendable {
    case markdown
    case json
    case audioFiles
}

public actor ExportManager {
    public init() {}

    public func exportMarkdown(
        session: Session,
        project: Project?,
        segments: [TranscriptSegment]
    ) -> String {
        var md = "---\n"
        if let project {
            md += "project: \(project.name)\n"
        }
        md += "date: \(Self.dateFormatter.string(from: session.startedAt))\n"
        if let duration = session.durationSeconds {
            md += "duration: \(Self.formatDuration(duration))\n"
        }
        if let url = session.meetingURL {
            md += "meeting_url: \(url.absoluteString)\n"
        }
        if let model = session.transcriptModel {
            md += "model: \(model)\n"
        }
        md += "title: \(session.title)\n"
        md += "---\n\n"
        md += "# \(session.title)\n\n"
        md += "**\(Self.dateTimeFormatter.string(from: session.startedAt))**"
        if let duration = session.durationSeconds {
            md += " — \(Self.formatDuration(duration))"
        }
        md += "\n\n---\n\n"

        for segment in segments {
            let ts = Self.formatTimestamp(ms: segment.startMs)
            let speaker = segment.speaker == .you ? "**Você:**" : "**Outros:**"
            md += "[\(ts)] \(speaker) \(segment.text)\n\n"
        }

        return md
    }

    public func exportJSON(
        session: Session,
        project: Project?,
        segments: [TranscriptSegment]
    ) throws -> Data {
        struct Payload: Codable {
            let session: Session
            let project: Project?
            let segments: [TranscriptSegment]
        }
        let payload = Payload(session: session, project: project, segments: segments)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(payload)
    }

    public func exportAll(
        session: Session,
        project: Project?,
        segments: [TranscriptSegment],
        to directory: URL,
        format: ExportFormat
    ) async throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let base = directory.appendingPathComponent(Self.sanitizedFilename(session.title))

        switch format {
        case .markdown:
            let url = base.appendingPathExtension("md")
            let md = exportMarkdown(session: session, project: project, segments: segments)
            try md.write(to: url, atomically: true, encoding: .utf8)
            return url
        case .json:
            let url = base.appendingPathExtension("json")
            let data = try exportJSON(session: session, project: project, segments: segments)
            try data.write(to: url)
            return url
        case .audioFiles:
            if let playback = session.playbackAudioPath, FileManager.default.fileExists(atPath: playback.path) {
                let dst = base.appendingPathExtension("m4a")
                try? FileManager.default.removeItem(at: dst)
                try FileManager.default.copyItem(at: playback, to: dst)
                return dst
            }
            throw TxError.fileSystem("Sessão sem arquivo de playback")
        }
    }

    // MARK: - Helpers

    nonisolated public static func formatTimestamp(ms: Int) -> String {
        let totalSeconds = ms / 1000
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
    }

    nonisolated public static func formatDuration(_ seconds: Double) -> String {
        let total = Int(seconds)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let s = total % 60
        if hours > 0 {
            return "\(hours)h \(minutes)m \(s)s"
        }
        return "\(minutes)m \(s)s"
    }

    nonisolated public static func sanitizedFilename(_ name: String) -> String {
        let invalid: Set<Character> = ["/", ":", "\\", "?", "*", "\"", "<", ">", "|"]
        return String(name.map { invalid.contains($0) ? "-" : $0 })
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static let dateTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()
}
