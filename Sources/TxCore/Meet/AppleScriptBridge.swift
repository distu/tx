import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// Ponte para executar AppleScript com timeout.
/// Usado para obter URL/título da aba ativa do Chrome.
public enum AppleScriptBridge {

    public struct TabInfo: Sendable, Hashable {
        public let title: String
        public let url: URL?
    }

    public struct MeetTabInfo: Sendable, Hashable {
        public let title: String
        public let url: URL

        public var isTeams: Bool { AppleScriptBridge.isTeamsURL(url) }

        public var roomCode: String {
            url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
    }

    /// Enumera as abas Meet de uma única instância do navegador. O chamador
    /// precisa conferir o PID da instância antes de associar o resultado ao áudio.
    /// Nil significa falha ou permissão negada; [] significa nenhuma sala aberta.
    public static func meetTabs(browserBundleId: String) async -> [MeetTabInfo]? {
        guard ["company.thebrowser.Browser", "com.google.Chrome", "com.apple.Safari"]
            .contains(browserBundleId) else { return nil }
        let tabTitle = browserBundleId == "com.apple.Safari" ? "name of t" : "title of t"
        let script = """
        with timeout of 6 seconds
            set rows to {}
            tell application id "\(browserBundleId)"
                if not running then return rows
                repeat with w in windows
                    repeat with t in tabs of w
                        try
                            set u to URL of t
                            if u starts with "https://meet.google.com/" or u starts with "https://teams.microsoft.com/" or u starts with "https://teams.cloud.microsoft/" then
                                set end of rows to {\(tabTitle) as text, u as text}
                            end if
                        end try
                    end repeat
                end repeat
            end tell
            return rows
        end timeout
        """
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                #if canImport(AppKit)
                var error: NSDictionary?
                let result = NSAppleScript(source: script)?.executeAndReturnError(&error)
                guard error == nil, let result else {
                    TxLogger.meet.debug("AppleScript Meet enumeration unavailable")
                    continuation.resume(returning: nil)
                    return
                }
                var tabs: [MeetTabInfo] = []
                for index in 0..<result.numberOfItems {
                    guard let row = result.atIndex(index + 1),
                          let title = row.atIndex(1)?.stringValue,
                          let rawURL = row.atIndex(2)?.stringValue,
                          let url = URL(string: rawURL),
                          isRoomURL(url) || isTeamsURL(url) else { continue }
                    tabs.append(MeetTabInfo(title: title, url: url))
                }
                continuation.resume(returning: tabs.sorted {
                    $0.url.absoluteString < $1.url.absoluteString
                })
                #else
                continuation.resume(returning: nil)
                #endif
            }
        }
    }

    public static func isRoomURL(_ url: URL) -> Bool {
        guard url.scheme == "https", url.host == "meet.google.com" else { return false }
        let parts = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).split(separator: "-")
        guard parts.count == 3, parts[0].count == 3, parts[1].count == 4, parts[2].count == 3 else {
            return false
        }
        return parts.allSatisfy { $0.allSatisfy { $0.isASCII && $0.isLetter && $0.isLowercase } }
    }

    public static func isTeamsURL(_ url: URL) -> Bool {
        url.scheme == "https" &&
            ["teams.microsoft.com", "teams.cloud.microsoft"].contains(url.host?.lowercased() ?? "")
    }

    /// Consulta apenas o estado do botão local da chamada. Arc e Chrome
    /// executam JavaScript em uma aba em segundo plano sem extensão, sem mudar
    /// foco e sem enviar conteúdo da página ao tx.
    public static func microphoneMuted(
        browserBundleId: String,
        meetingURL: URL?
    ) async -> Bool? {
        guard ["company.thebrowser.Browser", "com.google.Chrome"].contains(browserBundleId) else {
            return nil
        }
        let targetRoom = meetingURL.flatMap { isRoomURL($0) ? $0.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) : nil }
        let matchClause: String
        if let targetRoom {
            let base = "https://meet.google.com/\(targetRoom)"
            matchClause = "(u is \"\(base)\" or u starts with \"\(base)?\")"
        } else {
            matchClause = "u starts with \"https://meet.google.com/\" or u starts with \"https://teams.microsoft.com/\" or u starts with \"https://teams.cloud.microsoft/\""
        }
        // As palavras retornadas são códigos fixos; nenhum texto da chamada
        // ou dos participantes atravessa a ponte AppleScript.
        let javascript = """
        (() => { const norm = x => (x || '').toLowerCase().replaceAll(String.fromCharCode(160), ' ').trim();
          const labels = Array.from(document.querySelectorAll('button,[role=button]')).map(b => norm(b.getAttribute('aria-label') || b.getAttribute('title') || '')).filter(Boolean);
          const leave = labels.some(x => x === 'sair' || x.startsWith('sair da chamada') || x.startsWith('sair da reunião') || x.startsWith('leave call') || x.startsWith('leave meeting') || x.startsWith('hang up'));
          const muted = labels.filter(x => x.startsWith('desativar mudo do microfone') || x.startsWith('ativar microfone') || x.startsWith('ligar microfone') || x.startsWith('turn on microphone') || x.startsWith('unmute microphone') || x === 'ativar som');
          const live = labels.filter(x => x.startsWith('ativar mudo do microfone') || x.startsWith('desativar microfone') || x.startsWith('desligar microfone') || x.startsWith('turn off microphone') || x.startsWith('mute microphone') || x === 'desativar som');
          return !leave || muted.length + live.length !== 1 ? 'none' : muted.length === 1 ? 'muted' : 'live'; })()
        """
        let script = """
        with timeout of 5 seconds
            set rows to {}
            tell application id "\(browserBundleId)"
                if not running then return rows
                repeat with w in windows
                    repeat with t in tabs of w
                        try
                            set u to URL of t
                            if \(matchClause) then
                                set end of rows to execute t javascript "\(javascript.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\"", with: "\\\""))"
                            end if
                        end try
                    end repeat
                end repeat
            end tell
            return rows
        end timeout
        """
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                var error: NSDictionary?
                let result = NSAppleScript(source: script)?.executeAndReturnError(&error)
                guard error == nil, let result else {
                    continuation.resume(returning: nil)
                    return
                }
                guard result.numberOfItems > 0 else {
                    continuation.resume(returning: nil)
                    return
                }
                let states = (1...result.numberOfItems).compactMap { index -> String? in
                    result.atIndex(index)?.stringValue?.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                }.filter { $0 == "muted" || $0 == "live" }
                continuation.resume(returning: states.count == 1 ? states[0] == "muted" : nil)
            }
        }
    }

    /// Lê a aba ativa mais relevante do Chrome.
    /// Prioridade: Meet > YouTube > qualquer aba com título não vazio.
    /// Retorna nil em caso de falha ou timeout.
    public static func chromeActiveTab(timeoutMs: Int = 800) async -> TabInfo? {
        let script = """
        with timeout of 2 seconds
            tell application id "com.google.Chrome"
                if not running then return ""
                if (count of windows) = 0 then return ""
                set bestTitle to ""
                set bestUrl to ""
                repeat with w in windows
                    try
                        set t to title of active tab of w
                        set u to URL of active tab of w
                        if t is not "" and u does not start with "about:" and u does not start with "devtools:" and u does not start with "chrome:" then
                            if u contains "meet.google.com" or u contains "youtube.com" or u contains "teams.microsoft.com" then
                                return t & "|" & u
                            end if
                            if bestTitle is "" then
                                set bestTitle to t
                                set bestUrl to u
                            end if
                        end if
                    end try
                end repeat
                if bestTitle is not "" then
                    return bestTitle & "|" & bestUrl
                end if
                return ""
            end tell
        end timeout
        """

        return await runAppleScript(script, timeoutMs: timeoutMs)
            .flatMap(parseTabInfo)
    }

    private static func parseTabInfo(_ raw: String) -> TabInfo? {
        guard !raw.isEmpty else { return nil }
        let parts = raw.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let title = String(parts[0])
        let url = URL(string: String(parts[1]))
        return TabInfo(title: title, url: url)
    }

    private static func runAppleScript(_ script: String, timeoutMs: Int) async -> String? {
        await withCheckedContinuation { continuation in
            let workItem = DispatchWorkItem {
                #if canImport(AppKit)
                var error: NSDictionary?
                let apple = NSAppleScript(source: script)
                let result = apple?.executeAndReturnError(&error)
                if let error {
                    TxLogger.meet.debug("AppleScript error: \(String(describing: error), privacy: .public)")
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: result?.stringValue)
                #else
                continuation.resume(returning: nil)
                #endif
            }

            let queue = DispatchQueue.global(qos: .userInitiated)
            queue.async(execute: workItem)

            let deadline = DispatchTime.now() + .milliseconds(timeoutMs)
            DispatchQueue.global().asyncAfter(deadline: deadline) {
                if !workItem.isCancelled {
                    workItem.cancel()
                }
            }
        }
    }
}
