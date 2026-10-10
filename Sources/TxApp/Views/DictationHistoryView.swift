import SwiftUI
import TxCore
import AppKit
import AVFoundation

struct DictationHistoryView: View {
    @Environment(AppState.self) private var appState
    @State private var items: [Dictation] = []
    @State private var search: String = ""
    @State private var stats: DictationStats?
    @State private var retryingId: UUID?
    @State private var retryError: String?
    @State private var player = InlineAudioPlayer()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            if let stats {
                statsRow(stats)
            }

            TextField("Buscar no histórico", text: $search)
                .textFieldStyle(.roundedBorder)
                .onChange(of: search) { _, _ in reload() }

            if let retryError {
                Text("Retry: \(retryError)")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.1)))
            }

            if items.isEmpty {
                ContentUnavailableView(
                    "Sem ditados ainda",
                    systemImage: "waveform",
                    description: Text("Segure Fn e fale para criar seu primeiro ditado.")
                )
                .frame(maxHeight: .infinity)
            } else {
                List(items) { item in
                    row(item)
                }
                .listStyle(.inset)
            }
        }
        .padding(20)
        .onAppear { reload() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Ditados").font(.title2.bold())
            Text("Histórico de transcrições por voz. Tudo offline, pt-BR.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private func statsRow(_ s: DictationStats) -> some View {
        HStack(spacing: 16) {
            statCard("Sessions", value: "\(s.totalCount)", icon: "mic")
            statCard("Total Words", value: "\(s.totalWords)", icon: "text.word.spacing")
            statCard("Speaking Time", value: formatDuration(s.totalDurationMs), icon: "timer")
            statCard("Avg WPM", value: String(format: "%.0f", s.avgWpm), icon: "speedometer")
        }
    }

    private func statCard(_ title: String, value: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: icon).foregroundStyle(.secondary)
                Text(title).font(.caption).foregroundStyle(.secondary)
            }
            Text(value).font(.title3.bold()).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
    }

    private func row(_ d: Dictation) -> some View {
        let isFailed = d.text.hasPrefix("[falhou:")
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(d.text)
                    .font(.body)
                    .lineLimit(3)
                    .foregroundStyle(isFailed ? .orange : .primary)
                Spacer()
                if !isFailed {
                    Button {
                        copyToClipboard(d.text)
                    } label: {
                        Image(systemName: "doc.on.doc").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help("Copiar texto")
                }
                if let audio = d.audioPath, FileManager.default.fileExists(atPath: audio.path) {
                    Button {
                        player.toggle(url: audio)
                    } label: {
                        Image(systemName: player.isPlaying(url: audio) ? "pause.circle.fill" : "play.circle")
                            .foregroundStyle(.blue)
                    }
                    .buttonStyle(.borderless)
                    .help("Ouvir áudio (inline)")

                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([audio])
                    } label: {
                        Image(systemName: "folder").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help("Revelar no Finder")

                    if isFailed {
                        if retryingId == d.id {
                            ProgressView().controlSize(.small)
                        } else {
                            Button {
                                retryTranscription(d)
                            } label: {
                                Image(systemName: "arrow.clockwise.circle").foregroundStyle(.orange)
                            }
                            .buttonStyle(.borderless)
                            .help("Tentar transcrever novamente (com ganho digital)")
                        }
                    }
                }
            }
            HStack(spacing: 12) {
                Text(d.startedAt.formatted(date: .abbreviated, time: .shortened))
                Text("·")
                Text("\(d.wordCount) palavras")
                Text("·")
                Text(formatDuration(d.durationMs))
                if let app = d.targetApp {
                    Text("·")
                    Text(app)
                }
                if d.audioPath != nil {
                    Text("·")
                    Image(systemName: "waveform").font(.caption2)
                }
                Spacer()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    private func retryTranscription(_ d: Dictation) {
        guard let audio = d.audioPath else {
            retryError = "sem audioPath no ditado"
            return
        }
        let exists = FileManager.default.fileExists(atPath: audio.path)
        guard exists else {
            retryError = "arquivo não existe: \(audio.lastPathComponent)"
            return
        }
        retryingId = d.id
        retryError = nil
        TxLogger.transcription.info("retry iniciado: \(audio.lastPathComponent, privacy: .public)")
        dbg("[retry-ui] iniciado audio=\(audio.lastPathComponent)")

        Task {
            defer { Task { @MainActor in retryingId = nil } }
            var modelAcquired = false
            defer { if modelAcquired { Task { await appState.transcriptionEngine.endUse() } } }
            do {
                let samples = try await loadNormalizedSamples(from: audio)
                dbg("[retry-ui] samples=\(samples.count)")
                guard !samples.isEmpty else {
                    await MainActor.run { retryError = "áudio vazio no disco" }
                    return
                }

                try await appState.transcriptionEngine.beginUse()
                modelAcquired = true

                var text = try await appState.transcriptionEngine
                    .transcribe(audioArray: samples, language: "pt")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                dbg("[retry-ui] resultado strict=\"\(text.prefix(60))\"")

                if text.isEmpty {
                    dbg("[retry-ui] tentando modo permissivo")
                    text = try await appState.transcriptionEngine
                        .transcribePermissive(audioArray: samples, language: "pt")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    dbg("[retry-ui] resultado permissivo=\"\(text.prefix(60))\"")
                }

                if text.isEmpty {
                    dbg("[retry-ui] tentando via audioPath direto (WhisperKit decoder)")
                    text = try await appState.transcriptionEngine
                        .transcribe(audioPath: audio.path, language: "pt")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    dbg("[retry-ui] resultado audioPath=\"\(text.prefix(60))\"")
                }

                if text.isEmpty {
                    await MainActor.run { retryError = "Whisper vazio em 3 modos — ouça o .m4a pra confirmar se tem voz" }
                    return
                }

                var updated = d
                updated.text = text
                updated.wordCount = Dictation.computeWordCount(text)
                updated.wpm = Dictation.computeWpm(words: updated.wordCount, durationMs: d.durationMs)
                try appState.dictationStore.update(updated)
                await MainActor.run { reload() }
            } catch {
                TxLogger.transcription.error("retry falhou: \(error.localizedDescription, privacy: .public)")
                dbg("[retry-ui] ERRO: \(error.localizedDescription)")
                await MainActor.run { retryError = error.localizedDescription }
            }
        }
    }

    /// Lê um .m4a do disco, converte para mono 16k e aplica normalização de volume.
    /// Reaproveita o mesmo pipeline do ditado em tempo real.
    private func loadNormalizedSamples(from url: URL) async throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let frameCount = AVAudioFrameCount(file.length)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            return []
        }
        try file.read(into: buffer)
        let result = PCMResampler.toMono16kWithInfo(buffers: [buffer])
        TxLogger.transcription.info("retry: samples=\(result.samples.count) gain=\(result.info.gain, format: .fixed(precision: 2))x peakBefore=\(result.info.peakBefore, format: .fixed(precision: 3)) peakAfter=\(result.info.peakAfter, format: .fixed(precision: 3))")
        return result.samples
    }

    private func reload() {
        do {
            items = try appState.dictationStore.search(query: search, limit: 200)
            stats = try appState.dictationStore.stats()
        } catch {
            TxLogger.database.error("DictationHistoryView.reload: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func copyToClipboard(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    private func formatDuration(_ ms: Int) -> String {
        let totalSec = ms / 1000
        let h = totalSec / 3600
        let m = (totalSec % 3600) / 60
        let s = totalSec % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%02d:%02d", m, s)
    }
}

/// Player inline usando AVAudioPlayer. Toca um áudio por vez; clicar em outro
/// interrompe o anterior. Evita abrir Music.app.
@Observable
@MainActor
final class InlineAudioPlayer {
    private var player: AVAudioPlayer?
    private(set) var currentURL: URL?

    func isPlaying(url: URL) -> Bool {
        guard let current = currentURL, current == url, let p = player else { return false }
        return p.isPlaying
    }

    func toggle(url: URL) {
        if let current = currentURL, current == url, let p = player {
            if p.isPlaying {
                p.stop()
                player = nil
                currentURL = nil
            } else {
                p.play()
            }
            return
        }
        // Troca para outro arquivo
        player?.stop()
        do {
            let p = try AVAudioPlayer(contentsOf: url)
            p.prepareToPlay()
            p.play()
            player = p
            currentURL = url
        } catch {
            TxLogger.app.error("InlineAudioPlayer falhou: \(error.localizedDescription, privacy: .public)")
        }
    }
}
