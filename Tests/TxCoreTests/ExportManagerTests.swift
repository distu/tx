import Testing
import Foundation
@testable import TxCore

@Suite("ExportManager")
struct ExportManagerTests {
    @Test("Markdown contém frontmatter e rótulos de speaker")
    func markdownFormat() async {
        let manager = ExportManager()
        let project = Project(name: "Produto X", color: "#00FF00")
        let session = Session(
            projectId: project.id,
            title: "Daily 10/04",
            processName: "Google Chrome",
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            endedAt: Date(timeIntervalSince1970: 1_700_001_800),
            durationSeconds: 1800,
            status: .done,
            meetingURL: URL(string: "https://meet.google.com/abc"),
            transcriptModel: "openai_whisper-medium"
        )
        let segments: [TranscriptSegment] = [
            TranscriptSegment(
                sessionId: session.id,
                speaker: .you,
                channel: .mic,
                text: "Olá pessoal, vamos começar.",
                startMs: 0,
                endMs: 3000,
                confidence: -0.1
            ),
            TranscriptSegment(
                sessionId: session.id,
                speaker: .others,
                channel: .app,
                text: "Bom dia!",
                startMs: 3500,
                endMs: 5000,
                confidence: -0.15
            ),
        ]

        let md = await manager.exportMarkdown(session: session, project: project, segments: segments)

        #expect(md.hasPrefix("---\n"))
        #expect(md.contains("project: Produto X"))
        #expect(md.contains("meeting_url: https://meet.google.com/abc"))
        #expect(md.contains("**Você:**") || md.contains("Você"))
        #expect(md.contains("**Outros:**") || md.contains("Outros"))
        #expect(md.contains("Olá pessoal"))
    }
}
