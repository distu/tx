import Foundation
import Darwin
import OSLog

// MARK: - Payload

struct MeetBridgePayload: Decodable {
    var meetId: String?
    var title: String?
    var participants: [String] = []
    var micMuted: Bool?
    /// "ended" = usuário saiu ou reunião encerrou. Nil = payload normal.
    var meetStatus: String?

    enum CodingKeys: String, CodingKey {
        case meetId, title, participants, micMuted, meetStatus
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        meetId = try c.decodeIfPresent(String.self, forKey: .meetId)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        participants = try c.decodeIfPresent([String].self, forKey: .participants) ?? []
        micMuted = try c.decodeIfPresent(Bool.self, forKey: .micMuted)
        meetStatus = try c.decodeIfPresent(String.self, forKey: .meetStatus)
    }
}

// MARK: - MeetBridgeServer

/// HTTP server local em 127.0.0.1:49200 que recebe POSTs da extensão Chrome
/// com dados de participantes e título da reunião.
public final class MeetBridgeServer: @unchecked Sendable {
    private var listenerSource: DispatchSourceRead?
    private let port: UInt16 = 49200
    private let queue = DispatchQueue(label: "tx.meet-bridge", qos: .utility)

    /// Chamado quando a extensão envia dados de reunião.
    /// Parâmetros: (meetId?, title?, participants)
    public var onUpdate: (@Sendable (_ meetId: String?, _ title: String?, _ participants: [String]) -> Void)?

    /// Chamado quando o estado de mute do microfone muda no Meet.
    /// Parâmetro: true = mutado, false = ativo.
    public var onMicMuteChange: (@Sendable (_ muted: Bool, _ meetId: String?) -> Void)?

    /// Chamado quando o usuário sai ou a reunião encerra.
    /// Parâmetro: meetId da reunião que encerrou (pode ser nil se desconhecido).
    public var onMeetEnded: (@Sendable (_ meetId: String?) -> Void)?

    public init() {}

    public func start() {
        guard listenerSource == nil else { return }
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            TxLogger.audio.error("MeetBridgeServer: socket failed: \(errno)")
            return
        }
        var reuse: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout.size(ofValue: reuse)))

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        _ = "127.0.0.1".withCString { inet_pton(AF_INET, $0, &address.sin_addr) }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, Darwin.listen(fd, 16) == 0 else {
            TxLogger.audio.error("MeetBridgeServer: bind/listen failed: \(errno)")
            Darwin.close(fd)
            return
        }
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptConnections(on: fd) }
        source.setCancelHandler { Darwin.close(fd) }
        listenerSource = source
        source.resume()
        TxLogger.audio.info("MeetBridgeServer: listening on 127.0.0.1:49200")
    }

    public func stop() {
        listenerSource?.cancel()
        listenerSource = nil
    }

    // MARK: - Connection handling

    private func acceptConnections(on fd: Int32) {
        while true {
            let client = Darwin.accept(fd, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                return
            }
            DispatchQueue.global(qos: .utility).async { [weak self] in
                self?.handleConnection(client)
                Darwin.close(client)
            }
        }
    }

    private func handleConnection(_ fd: Int32) {
        var noSigPipe: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout.size(ofValue: noSigPipe)))
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
        var accumulated = Data()
        var chunk = [UInt8](repeating: 0, count: 8192)

        while accumulated.count <= 131_072 {
            let received = chunk.withUnsafeMutableBytes { raw in
                Darwin.recv(fd, raw.baseAddress, raw.count, 0)
            }
            if received <= 0 { break }
            accumulated.append(contentsOf: chunk.prefix(received))
            if accumulated.count > 131_072 { break }

            // Preflight CORS (OPTIONS) — responde imediatamente sem body.
            if accumulated.starts(with: Data("OPTIONS".utf8)) {
                sendResponse(fd: fd, status: 200, body: "")
                return
            }
            if let body = extractBody(from: accumulated) {
                processBody(body)
                sendResponse(fd: fd, status: 200, body: #"{"ok":true}"#)
                return
            }
        }
        sendResponse(fd: fd, status: 400, body: #"{"ok":false}"#)
    }

    /// Extrai o corpo JSON de uma requisição HTTP raw.
    private func extractBody(from data: Data) -> Data? {
        guard let raw = String(data: data, encoding: .utf8) else { return nil }

        // Separa headers do body por \r\n\r\n
        guard let range = raw.range(of: "\r\n\r\n") else { return nil }

        let bodyString = String(raw[range.upperBound...])

        // Verifica Content-Length para saber se o body está completo
        let headersPart = String(raw[raw.startIndex..<range.lowerBound])
        let headers = headersPart.components(separatedBy: "\r\n")
        var contentLength = 0
        for header in headers {
            let lower = header.lowercased()
            if lower.hasPrefix("content-length:") {
                let value = header.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)
                contentLength = Int(value) ?? 0
                break
            }
        }

        let bodyData = Data(bodyString.utf8)
        if contentLength > 0 && bodyData.count < contentLength {
            return nil // ainda não recebeu tudo
        }

        return bodyData.isEmpty ? nil : bodyData
    }

    private func processBody(_ body: Data) {
        do {
            let payload = try JSONDecoder().decode(MeetBridgePayload.self, from: body)

            // Evento de reunião encerrada — tem prioridade sobre tudo
            if payload.meetStatus == "ended" {
                TxLogger.audio.info("MeetBridgeServer: meetEnded meetId=\(payload.meetId ?? "nil", privacy: .public)")
                onMeetEnded?(payload.meetId)
                return
            }

            // Evento de mute isolado: só micMuted, sem participantes
            if let muted = payload.micMuted, payload.participants.isEmpty {
                TxLogger.audio.info("MeetBridgeServer: mic muted=\(muted)")
                dbg("[bridge] mic muted=\(muted)")
                onMicMuteChange?(muted, payload.meetId)
                return
            }

            TxLogger.audio.info(
                "MeetBridgeServer: received meetId=\(payload.meetId ?? "nil", privacy: .public) participants=\(payload.participants.count) micMuted=\(payload.micMuted.map(String.init) ?? "nil", privacy: .public)"
            )
            onUpdate?(payload.meetId, payload.title, payload.participants)

            // Aplica estado de mute junto com atualização de participantes, se presente
            if let muted = payload.micMuted {
                dbg("[bridge] mic muted=\(muted) (com participantes)")
                onMicMuteChange?(muted, payload.meetId)
            }
        } catch {
            TxLogger.audio.error("MeetBridgeServer: JSON decode error: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func sendResponse(fd: Int32, status: Int, body: String) {
        let statusText = status == 200 ? "OK" : "Bad Request"
        let response = "HTTP/1.1 \(status) \(statusText)\r\n" +
            "Content-Type: application/json\r\n" +
            "Content-Length: \(body.utf8.count)\r\n" +
            "Access-Control-Allow-Origin: *\r\n" +
            "Access-Control-Allow-Methods: POST, OPTIONS\r\n" +
            "Access-Control-Allow-Headers: Content-Type\r\n" +
            "Connection: close\r\n" +
            "\r\n" +
            body
        let data = Data(response.utf8)
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var sent = 0
            while sent < raw.count {
                let count = Darwin.send(fd, base.advanced(by: sent), raw.count - sent, 0)
                if count <= 0 { break }
                sent += count
            }
        }
    }
}
