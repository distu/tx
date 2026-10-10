import SwiftUI
import TxCore

struct DictationDebugView: View {
    @Environment(AppState.self) private var appState
    @State private var log = DictationDebugLog.shared
    @State private var autoScroll: Bool = true
    @State private var filter: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            statusBar
            Divider()
            logList
        }
        .padding(16)
        .frame(minWidth: 720, minHeight: 560)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Dictation Debug").font(.title3.bold())
                Text("Inspecione cada etapa do pipeline de ditado em tempo real.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("Auto-scroll", isOn: $autoScroll).toggleStyle(.switch).controlSize(.small)

            Button {
                copyLogToClipboard()
            } label: {
                Label("Copiar log", systemImage: "doc.on.doc")
            }
            .controlSize(.small)

            Button {
                reinstallAndRelaunch()
            } label: {
                Label("Reinstalar + Reset TCC", systemImage: "arrow.clockwise.circle")
            }
            .controlSize(.small)

            Button(role: .destructive) {
                log.clear()
            } label: {
                Label("Limpar", systemImage: "trash")
            }
            .controlSize(.small)
        }
    }

    private func copyLogToClipboard() {
        var lines: [String] = []
        for entry in filtered {
            let ts = timeString(entry.timestamp)
            let lvl: String
            switch entry.level {
            case .info: lvl = "INFO"
            case .warn: lvl = "WARN"
            case .error: lvl = "ERR "
            case .success: lvl = "OK  "
            }
            lines.append("\(ts) \(lvl) [\(entry.category)] \(entry.message)")
        }
        let joined: String = lines.joined(separator: "\n")
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(joined, forType: .string)
        log.success("ui", "log copiado (\(filtered.count) entradas)")
    }

    private func reinstallAndRelaunch() {
        // Executa script que reassina com identifier estável, instala em
        // /Applications, faz tccutil reset e relança. Isso reseta TCC e fixa
        // o path pra assinaturas ad-hoc futuras manterem a permissão.
        let script = """
        tccutil reset ListenEvent dev.distuai.tx 2>/dev/null
        tccutil reset Accessibility dev.distuai.tx 2>/dev/null
        tccutil reset Microphone dev.distuai.tx 2>/dev/null
        pkill -x tx 2>/dev/null
        sleep 0.5
        rm -rf /Applications/tx.app
        cp -R "\(Bundle.main.bundlePath)" /Applications/tx.app
        open /Applications/tx.app
        """
        let process = Process()
        process.launchPath = "/bin/sh"
        process.arguments = ["-c", script]
        try? process.run()
        log.info("ui", "reinstalando em /Applications e resetando TCC…")
    }

    private var statusBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 16) {
                chip("Tap instalado", ok: appState.dictationInstalled)
                chip("Input Monitoring", ok: GlobalHotkeyManager.hasInputMonitoringPermission())
                chip("Accessibility", ok: PasteSimulator.hasAccessibilityPermission())
                Text("Whisper sob demanda")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                TextField("Filtrar categoria/texto", text: $filter)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 240)
            }

            HStack(spacing: 8) {
                Image(systemName: "info.circle")
                    .foregroundStyle(.orange)
                Text("Se o Fn não dispara logs, macOS está consumindo. Vá em")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Keyboard Settings") {
                    let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")
                    if let url { NSWorkspace.shared.open(url) }
                }
                .controlSize(.mini)
                Text("e mude \"Press Fn/🌐 key to\" para \"Do Nothing\".")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.orange.opacity(0.08))
            )
        }
        .font(.caption)
    }

    private func chip(_ title: String, ok: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(ok ? .green : .red)
            Text(title)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.primary.opacity(0.06))
        )
    }

    private var filtered: [DictationLogEntry] {
        let q = filter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return log.entries }
        return log.entries.filter {
            $0.category.lowercased().contains(q) || $0.message.lowercased().contains(q)
        }
    }

    private var logList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(filtered) { entry in
                        row(entry).id(entry.id)
                    }
                }
                .padding(.horizontal, 4)
            }
            .background(Color.black.opacity(0.05))
            .onChange(of: log.entries.count) { _, _ in
                if autoScroll, let last = filtered.last {
                    withAnimation(.easeOut(duration: 0.1)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }

    private func row(_ entry: DictationLogEntry) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(timeString(entry.timestamp))
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 82, alignment: .leading)

            Text(entry.category)
                .font(.system(.caption2, design: .monospaced).bold())
                .foregroundStyle(.blue)
                .frame(width: 60, alignment: .leading)

            Text(entry.message)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(color(for: entry.level))
                .textSelection(.enabled)
        }
        .padding(.vertical, 1)
    }

    private func color(for level: DictationLogLevel) -> Color {
        switch level {
        case .info: return .primary
        case .success: return .green
        case .warn: return .orange
        case .error: return .red
        }
    }

    private func timeString(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f.string(from: date)
    }
}
