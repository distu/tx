import Foundation

/// Conserta texto colado de terminais que aplicam hard-wrap (~60 chars),
/// como o Claude Code CLI. Junta linhas dentro de parágrafos preservando:
/// - Linhas em branco (separadores de parágrafo)
/// - Blocos de código delimitados por ```
/// - Listas (linhas iniciadas por `- `, `* `, `1.`, etc.)
enum TextReflow {

    static func fix(_ raw: String) -> String {
        let normalized = raw.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalized.components(separatedBy: "\n")

        var output: [String] = []
        var paragraph: [String] = []
        var inFence = false

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            let merged = paragraph
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            if !merged.isEmpty { output.append(merged) }
            paragraph.removeAll(keepingCapacity: true)
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Cerca de bloco de código: preserva tudo dentro literal.
            if trimmed.hasPrefix("```") {
                flushParagraph()
                output.append(trimmed)
                inFence.toggle()
                continue
            }
            if inFence {
                output.append(line)
                continue
            }

            // Linha em branco encerra parágrafo.
            if trimmed.isEmpty {
                flushParagraph()
                output.append("")
                continue
            }

            // Bullets/numerações começam parágrafo novo.
            if isListMarker(trimmed) {
                flushParagraph()
                paragraph.append(trimmed)
                continue
            }

            paragraph.append(line)
        }
        flushParagraph()

        // Colapsa múltiplas linhas em branco em uma só.
        var compact: [String] = []
        var prevEmpty = false
        for ln in output {
            let isEmpty = ln.isEmpty
            if isEmpty && prevEmpty { continue }
            compact.append(ln)
            prevEmpty = isEmpty
        }
        while compact.first?.isEmpty == true { compact.removeFirst() }
        while compact.last?.isEmpty == true { compact.removeLast() }

        return compact.joined(separator: "\n")
    }

    private static func isListMarker(_ trimmed: String) -> Bool {
        if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("• ") {
            return true
        }
        // "1. ", "12) "
        var idx = trimmed.startIndex
        var sawDigit = false
        while idx < trimmed.endIndex, trimmed[idx].isNumber {
            sawDigit = true
            idx = trimmed.index(after: idx)
        }
        guard sawDigit, idx < trimmed.endIndex else { return false }
        let next = trimmed[idx]
        guard next == "." || next == ")" else { return false }
        let after = trimmed.index(after: idx)
        return after < trimmed.endIndex && trimmed[after] == " "
    }
}
