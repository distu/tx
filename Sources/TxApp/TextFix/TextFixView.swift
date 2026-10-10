import SwiftUI
import AppKit

struct TextFixView: View {
    @State private var text: String = ""
    @State private var copied: Bool = false
    @FocusState private var editorFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            TextEditor(text: $text)
                .font(.system(.body, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.primary.opacity(0.1), lineWidth: 0.5)
                )
                .focused($editorFocused)
                .frame(minHeight: 280)

            footer
        }
        .padding(16)
        .frame(minWidth: 560, minHeight: 420)
        .onAppear {
            pasteFromClipboardIfEmpty()
            editorFocused = true
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Conserta texto").font(.title3.bold())
            Text("Cola texto bagunçado (ex: copiado do terminal/Claude Code), aplica fix e copia.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button {
                pasteFromClipboard()
            } label: {
                Label("Colar", systemImage: "doc.on.clipboard")
            }
            .keyboardShortcut("v", modifiers: [.command, .shift])

            Button {
                text = ""
                copied = false
            } label: {
                Label("Limpar", systemImage: "trash")
            }

            Spacer()

            Button {
                text = TextReflow.fix(text)
                copied = false
            } label: {
                Label("Fix", systemImage: "wand.and.stars")
            }
            .keyboardShortcut(.return, modifiers: [.command])
            .buttonStyle(.borderedProminent)
            .disabled(text.isEmpty)

            Button {
                copyToClipboard(text)
                copied = true
            } label: {
                Label(copied ? "Copiado!" : "Copiar", systemImage: copied ? "checkmark" : "doc.on.doc")
            }
            .keyboardShortcut("c", modifiers: [.command, .shift])
            .buttonStyle(.bordered)
            .disabled(text.isEmpty)
        }
    }

    private func pasteFromClipboardIfEmpty() {
        guard text.isEmpty else { return }
        pasteFromClipboard()
    }

    private func pasteFromClipboard() {
        if let s = NSPasteboard.general.string(forType: .string) {
            text = s
            copied = false
        }
    }

    private func copyToClipboard(_ s: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(s, forType: .string)
    }
}
