import Foundation
import AppKit
import CoreGraphics

/// Observa eventos globais da tecla Fn e ESC via CGEventTap.
///
/// Máquina de estados interna:
/// - `.flagsChanged` com bit `function` ligando = Fn pressionada.
/// - `.flagsChanged` com bit `function` desligando = Fn solta.
/// - Hold: Fn pressionada por mais de `holdThresholdMs` -> emite `.holdStarted`,
///   ao soltar emite `.holdEnded`.
/// - Double-tap: dois pares down/up consecutivos em < `doubleTapWindowMs`,
///   cada um com duração < `holdThresholdMs` -> emite `.doubleTap`.
/// - ESC (keyCode 53): emite `.escapePressed` somente quando `isRecording == true`.
///
/// Requer permissão "Input Monitoring" (TCC). Se negada, `install()` lança
/// `TxError.permissionDenied("Input Monitoring")`.
public final class GlobalHotkeyManager: @unchecked Sendable {

    // MARK: - Configurable thresholds

    public struct Config: Sendable {
        public var holdThresholdMs: Int
        public var doubleTapWindowMs: Int

        public init(holdThresholdMs: Int = 200, doubleTapWindowMs: Int = 300) {
            self.holdThresholdMs = holdThresholdMs
            self.doubleTapWindowMs = doubleTapWindowMs
        }
    }

    // MARK: - Public surface

    public let stream: AsyncStream<HotkeyEvent>
    public private(set) var isInstalled: Bool = false
    public var isRecording: Bool = false {
        didSet { lock.lock(); _isRecording = isRecording; lock.unlock() }
    }

    // MARK: - Private state (guarded by lock; CGEventTap callback runs off-main)

    private var continuation: AsyncStream<HotkeyEvent>.Continuation?
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    private let lock = NSLock()
    private var _config: Config
    private var _isRecording: Bool = false

    // Máquina de estados Fn
    private var fnDownTimestamp: TimeInterval?
    private var lastShortTapTimestamp: TimeInterval?
    private var holdStartedEmitted: Bool = false
    private var holdWorkItem: DispatchWorkItem?

    private static let kVK_Escape: Int64 = 53
    private static let kVK_Function: Int64 = 63
    private static let kVK_Globe: Int64 = 179

    // MARK: - Lifecycle

    public init(config: Config = Config()) {
        self._config = config
        var cont: AsyncStream<HotkeyEvent>.Continuation!
        self.stream = AsyncStream { continuation in
            cont = continuation
        }
        self.continuation = cont
    }

    deinit {
        uninstall()
        continuation?.finish()
    }

    public func updateConfig(_ config: Config) {
        lock.lock(); _config = config; lock.unlock()
    }

    // MARK: - Permission

    public static func hasInputMonitoringPermission() -> Bool {
        // CGPreflightListenEventAccess é disponível em macOS 10.15+ e retorna
        // o estado corrente sem disparar o prompt TCC.
        return CGPreflightListenEventAccess()
    }

    @discardableResult
    public static func requestInputMonitoringPermission() -> Bool {
        // Dispara o prompt TCC (uma vez por app). Em sessões subsequentes
        // retorna o estado persistido.
        return CGRequestListenEventAccess()
    }

    // MARK: - Install / uninstall

    public func install() throws {
        guard !isInstalled else { return }
        guard Self.hasInputMonitoringPermission() else {
            DictDbg.error("hotkey", "Input Monitoring não concedido")
            throw TxError.permissionDenied("Input Monitoring")
        }

        let mask: CGEventMask =
            (1 << CGEventType.flagsChanged.rawValue) |
            (1 << CGEventType.keyDown.rawValue)

        let unmanaged = Unmanaged.passUnretained(self)
        let opaque = unmanaged.toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: GlobalHotkeyManager.callback,
            userInfo: opaque
        ) else {
            DictDbg.error("hotkey", "CGEventTap rejeitado pelo sistema")
            throw TxError.permissionDenied("Input Monitoring (CGEventTap rejeitado pelo sistema)")
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        self.eventTap = tap
        self.runLoopSource = source
        self.isInstalled = true
        DictDbg.success("hotkey", "CGEventTap instalado — pronto para detectar Fn e ESC")
    }

    public func uninstall() {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        eventTap = nil
        runLoopSource = nil
        isInstalled = false
    }

    // MARK: - CGEventTap callback (off-main)

    private static let callback: CGEventTapCallBack = { _, type, event, userInfo in
        guard let userInfo else { return Unmanaged.passUnretained(event) }
        let me = Unmanaged<GlobalHotkeyManager>.fromOpaque(userInfo).takeUnretainedValue()
        me.handle(type: type, event: event)
        return Unmanaged.passUnretained(event)
    }

    private func handle(type: CGEventType, event: CGEvent) {
        // CGEventTap pode ser desabilitado pelo sistema após timeout; reabilitar.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
                TxLogger.app.warning("GlobalHotkeyManager: tap reabilitado após \(type == .tapDisabledByTimeout ? "timeout" : "user input")")
            }
            return
        }

        switch type {
        case .flagsChanged:
            handleFlagsChanged(event: event)
        case .keyDown:
            handleKeyDown(event: event)
        default:
            break
        }
    }

    private func handleFlagsChanged(event: CGEvent) {
        let flags = event.flags
        let fnIsDown = flags.contains(.maskSecondaryFn)
        let now = CFAbsoluteTimeGetCurrent()

        lock.lock()
        let cfg = _config
        let wasDown = fnDownTimestamp != nil
        lock.unlock()

        // Debug: sempre loga .flagsChanged pra ajudar a diagnosticar
        // qual bit o teclado dispara.
        DictDbg.info("hotkey",
            "flagsChanged raw=0x\(String(flags.rawValue, radix: 16)) fnBit=\(fnIsDown) wasDown=\(wasDown)")

        if fnIsDown && !wasDown {
            DictDbg.info("hotkey", "Fn DOWN")
            fnPressed(at: now, config: cfg)
        } else if !fnIsDown && wasDown {
            DictDbg.info("hotkey", "Fn UP")
            fnReleased(at: now, config: cfg)
        }
    }

    private func fnPressed(at timestamp: TimeInterval, config: Config) {
        lock.lock()
        fnDownTimestamp = timestamp
        holdStartedEmitted = false
        lock.unlock()

        // Agenda verificação de hold
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.checkHoldFired(at: timestamp)
        }
        lock.lock()
        holdWorkItem?.cancel()
        holdWorkItem = workItem
        lock.unlock()
        DispatchQueue.global(qos: .userInitiated).asyncAfter(
            deadline: .now() + .milliseconds(config.holdThresholdMs),
            execute: workItem
        )
    }

    private func checkHoldFired(at pressedAt: TimeInterval) {
        lock.lock()
        // Se ainda está com a Fn pressionada e o timestamp bate, é hold.
        let stillDown = fnDownTimestamp == pressedAt
        if stillDown {
            holdStartedEmitted = true
        }
        lock.unlock()

        if stillDown {
            emit(.holdStarted(timestamp: pressedAt))
        }
    }

    private func fnReleased(at timestamp: TimeInterval, config: Config) {
        lock.lock()
        let pressedAt = fnDownTimestamp
        let emittedHold = holdStartedEmitted
        let lastShort = lastShortTapTimestamp
        holdWorkItem?.cancel()
        fnDownTimestamp = nil
        holdStartedEmitted = false
        lock.unlock()

        guard let pressedAt else { return }
        let durationMs = Int((timestamp - pressedAt) * 1000)

        if emittedHold {
            emit(.holdEnded(timestamp: timestamp))
            lock.lock(); lastShortTapTimestamp = nil; lock.unlock()
            return
        }

        // Tap curto. Verificar double-tap.
        if durationMs <= config.holdThresholdMs {
            if let lastShort, Int((timestamp - lastShort) * 1000) <= config.doubleTapWindowMs {
                emit(.doubleTap(timestamp: timestamp))
                lock.lock(); lastShortTapTimestamp = nil; lock.unlock()
            } else {
                lock.lock(); lastShortTapTimestamp = timestamp; lock.unlock()
            }
        } else {
            // Duração > threshold mas hold não foi emitido (edge case — DispatchQueue atrasado).
            // Emitir par hold/holdEnded retroativamente para não perder o ciclo.
            emit(.holdStarted(timestamp: pressedAt))
            emit(.holdEnded(timestamp: timestamp))
            lock.lock(); lastShortTapTimestamp = nil; lock.unlock()
        }
    }

    private func handleKeyDown(event: CGEvent) {
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)

        // Log de TODA keyDown para diagnosticar qual código o Fn/Globe reporta
        // em teclados diferentes.
        DictDbg.info("hotkey", "keyDown keyCode=\(keyCode)")

        // ESC durante gravação -> cancelar
        if keyCode == Self.kVK_Escape {
            lock.lock()
            let recording = _isRecording
            lock.unlock()
            if recording { emit(.escapePressed) }
            return
        }

        // Fallback: alguns teclados (externos, Bluetooth) reportam Fn/Globe
        // como keyDown separado em vez de flagsChanged. Aceitar ambos.
        if keyCode == Self.kVK_Function || keyCode == Self.kVK_Globe {
            let now = CFAbsoluteTimeGetCurrent()
            lock.lock()
            let cfg = _config
            let wasDown = fnDownTimestamp != nil
            lock.unlock()
            if !wasDown {
                DictDbg.info("hotkey", "Fn/Globe via keyDown (keyCode \(keyCode))")
                fnPressed(at: now, config: cfg)
            }
        }
    }

    private func emit(_ event: HotkeyEvent) {
        DictDbg.success("hotkey", "emit -> \(event)")
        continuation?.yield(event)
    }
}

// MARK: - Testable pure state machine

/// Pedaço puro da máquina de estados. Exposto para testes unitários
/// sem depender de CGEventTap.
public final class HotkeyStateMachine: @unchecked Sendable {
    public private(set) var fnDownTimestamp: TimeInterval?
    public private(set) var lastShortTapTimestamp: TimeInterval?
    public private(set) var holdEmitted: Bool = false

    public var config: GlobalHotkeyManager.Config
    public var isRecording: Bool = false

    public init(config: GlobalHotkeyManager.Config = .init()) {
        self.config = config
    }

    /// Marca Fn pressionada. Não emite nada imediatamente — aguarda timer externo
    /// para detectar hold.
    public func onFnDown(at time: TimeInterval) {
        fnDownTimestamp = time
        holdEmitted = false
    }

    /// Checa se, no momento `now`, estamos num hold persistente. Retorna
    /// `.holdStarted` se sim (apenas na primeira chamada após o threshold).
    public func onHoldCheck(at now: TimeInterval) -> HotkeyEvent? {
        guard let pressed = fnDownTimestamp, !holdEmitted else { return nil }
        let durationMs = Int((now - pressed) * 1000)
        if durationMs >= config.holdThresholdMs {
            holdEmitted = true
            return .holdStarted(timestamp: pressed)
        }
        return nil
    }

    /// Marca Fn solta. Pode emitir `.holdEnded`, `.doubleTap` ou nada.
    public func onFnUp(at time: TimeInterval) -> HotkeyEvent? {
        guard let pressed = fnDownTimestamp else { return nil }
        let durationMs = Int((time - pressed) * 1000)
        let wasHold = holdEmitted

        fnDownTimestamp = nil
        holdEmitted = false

        if wasHold {
            lastShortTapTimestamp = nil
            return .holdEnded(timestamp: time)
        }

        if durationMs <= config.holdThresholdMs {
            if let lastShort = lastShortTapTimestamp,
               Int((time - lastShort) * 1000) <= config.doubleTapWindowMs {
                lastShortTapTimestamp = nil
                return .doubleTap(timestamp: time)
            }
            lastShortTapTimestamp = time
            return nil
        }

        // Edge case: hold timer atrasou mas duração passou do limite.
        lastShortTapTimestamp = nil
        return .holdStarted(timestamp: pressed)
    }

    public func onEscape() -> HotkeyEvent? {
        isRecording ? .escapePressed : nil
    }
}
