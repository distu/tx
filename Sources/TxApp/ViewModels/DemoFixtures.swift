#if DEBUG
import Foundation
import TxCore

/// Synthetic, isolated data for reproducible public screenshots.
/// Enabled only in a debug build whose bundle ID is dev.distuai.tx.demo.
enum DemoFixtures {
    static func seedIfNeeded(
        projects: ProjectRepository,
        sessions: SessionRepository,
        segments: SegmentRepository
    ) throws {
        guard try sessions.all().isEmpty else { return }

        let project = Project(name: "Sample project", color: "#4A90E2")
        try projects.insert(project)

        let examples: [(String, Double, [String])] = [
            ("Product planning — sample meeting", 754, ["Alex", "Morgan"]),
            ("Design review — sample meeting", 1122, ["Alex", "Taylor"]),
            ("Weekly check-in — sample meeting", 487, ["Morgan", "Taylor"])
        ]
        for (index, example) in examples.enumerated() {
            let start = Date.now.addingTimeInterval(-Double(index + 1) * 3600)
            let session = Session(
                projectId: project.id,
                title: example.0,
                processName: "Demo Browser",
                startedAt: start,
                endedAt: start.addingTimeInterval(example.1),
                durationSeconds: example.1,
                status: .done,
                transcriptModel: "WhisperKit (demo)",
                participants: example.2
            )
            try sessions.insert(session)
            if index == 0 {
                try segments.insertMany([
                    TranscriptSegment(sessionId: session.id, speaker: .others, channel: .app,
                                      text: "Let's review the next release and the open questions.",
                                      startMs: 0, endMs: 4200),
                    TranscriptSegment(sessionId: session.id, speaker: .you, channel: .mic,
                                      text: "I'll summarize the decisions and share the plan.",
                                      startMs: 4600, endMs: 9200),
                    TranscriptSegment(sessionId: session.id, speaker: .others, channel: .app,
                                      text: "Great. We can follow up after the design review.",
                                      startMs: 9800, endMs: 14400)
                ])
            }
        }
    }
}
#endif
