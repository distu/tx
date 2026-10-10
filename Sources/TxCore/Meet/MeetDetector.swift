import Foundation

public actor MeetDetector {
    public typealias MeetingHandler = @Sendable (DetectedMeeting) -> Void

    private let processDetector: ProcessDetector
    private var pollingTask: Task<Void, Never>?
    private var handler: MeetingHandler?
    private var ignoredProcesses: [pid_t: Date] = [:]
    private let ignoreDuration: TimeInterval = 30 * 60

    public init(processDetector: ProcessDetector = ProcessDetector()) {
        self.processDetector = processDetector
    }

    public func onMeetingDetected(_ handler: @escaping MeetingHandler) {
        self.handler = handler
    }

    public func ignore(pid: pid_t, for duration: TimeInterval? = nil) {
        let until = Date().addingTimeInterval(duration ?? ignoreDuration)
        ignoredProcesses[pid] = until
    }

    public func startWatching(interval: Duration = .seconds(2)) {
        guard pollingTask == nil else { return }
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.scanOnce()
                try? await Task.sleep(for: interval)
            }
        }
    }

    public func stopWatching() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    public func scanOnce() async {
        let processes = await processDetector.listAudioActiveProcesses()
        for process in processes {
            if let ignoreUntil = ignoredProcesses[process.pid], ignoreUntil > .now {
                continue
            } else if ignoredProcesses[process.pid] != nil {
                ignoredProcesses.removeValue(forKey: process.pid)
            }
            if let detected = await detectMeeting(in: process) {
                handler?(detected)
            }
        }
    }

    // MARK: - Detection heuristics

    private func detectMeeting(in process: AudioProcess) async -> DetectedMeeting? {
        let bundle = process.bundleId ?? ""
        let name = process.name.lowercased()

        if bundle == "com.google.Chrome" || name.contains("chrome") {
            return await detectChromeMeeting(process: process)
        }

        if bundle == "com.microsoft.teams2" || bundle == "com.microsoft.teams" || name.contains("teams") {
            let title = AXWindowReader.frontWindowTitle(pid: process.pid) ?? "Microsoft Teams"
            return DetectedMeeting(
                process: process,
                url: nil,
                title: title,
                platform: .teams
            )
        }

        if bundle.contains("us.zoom") || name.contains("zoom") {
            let title = AXWindowReader.frontWindowTitle(pid: process.pid) ?? "Zoom"
            return DetectedMeeting(
                process: process,
                url: nil,
                title: title,
                platform: .zoom
            )
        }

        return nil
    }

    private func detectChromeMeeting(process: AudioProcess) async -> DetectedMeeting? {
        if let tab = await AppleScriptBridge.chromeActiveTab(timeoutMs: 500),
           let url = tab.url {
            if Self.isMeetURL(url) {
                return DetectedMeeting(
                    process: process,
                    url: url,
                    title: tab.title,
                    platform: .googleMeet
                )
            }
            if Self.isTeamsURL(url) {
                return DetectedMeeting(
                    process: process,
                    url: url,
                    title: tab.title,
                    platform: .teams
                )
            }
        }

        // Fallback via AX: título da janela frontal pode conter "Meet"
        if let title = AXWindowReader.frontWindowTitle(pid: process.pid) {
            if title.localizedCaseInsensitiveContains("Google Meet") {
                return DetectedMeeting(
                    process: process,
                    url: nil,
                    title: title,
                    platform: .googleMeet
                )
            }
        }

        return nil
    }

    nonisolated public static func isMeetURL(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host.contains("meet.google.com")
    }

    nonisolated public static func isTeamsURL(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host.contains("teams.microsoft.com") || host.contains("teams.live.com")
    }
}
