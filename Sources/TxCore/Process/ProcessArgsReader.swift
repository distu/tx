import Foundation
import Darwin
#if canImport(AppKit)
import AppKit
#endif

/// Lê os argumentos de linha de comando de um processo via `sysctl KERN_PROCARGS2`.
/// Usado para extrair `--user-data-dir` de processos Chrome lançados externamente.
public enum ProcessArgsReader {

    /// Encontra o processo principal do mesmo app, mesmo quando ele foi lançado
    /// pelo tx ou por um shell e não é filho direto do launchd.
    public static func captureGroupRoot(for pid: pid_t, bundleId: String?) -> pid_t? {
        #if canImport(AppKit)
        return matchingAncestor(
            for: pid,
            bundleId: bundleId,
            parent: parentPID(for:),
            appBundle: { NSRunningApplication(processIdentifier: $0)?.bundleIdentifier }
        )
        #else
        return nil
        #endif
    }

    /// Separado do acesso ao SO para testar árvores com duas instâncias do
    /// mesmo navegador sob um único processo lançador.
    static func matchingAncestor(
        for pid: pid_t,
        bundleId: String?,
        parent: (pid_t) -> pid_t?,
        appBundle: (pid_t) -> String?
    ) -> pid_t? {
        guard pid > 1, let bundleId, !bundleId.isEmpty else { return nil }
        let selected = bundleId.lowercased()
        var current = pid
        var found: pid_t?
        var visited: Set<pid_t> = []
        while current > 1 && visited.insert(current).inserted {
            if let bundle = appBundle(current)?.lowercased(),
               selected == bundle || selected.hasPrefix(bundle + ".") {
                found = current
            }
            guard let next = parent(current) else { break }
            current = next
        }
        return found
    }

    public static func isDescendant(_ pid: pid_t, of root: pid_t) -> Bool {
        isDescendant(pid, of: root, parent: parentPID(for:))
    }

    static func isDescendant(
        _ pid: pid_t, of root: pid_t, parent: (pid_t) -> pid_t?
    ) -> Bool {
        var current = pid
        var visited: Set<pid_t> = []
        while current > 1 && visited.insert(current).inserted {
            if current == root { return true }
            guard let next = parent(current) else { break }
            current = next
        }
        return false
    }

    private static func parentPID(for pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0,
              size == MemoryLayout<kinfo_proc>.stride else { return nil }
        let parent = info.kp_eproc.e_ppid
        return parent > 1 ? parent : nil
    }

    public static func arguments(for pid: pid_t) -> [String]? {
        var argMax: Int32 = 0
        var size = MemoryLayout<Int32>.size
        var mib = [CTL_KERN, KERN_ARGMAX]
        if sysctl(&mib, 2, &argMax, &size, nil, 0) != 0 {
            return nil
        }

        var bufferSize = Int(argMax)
        let buffer = UnsafeMutablePointer<CChar>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }

        var mib2 = [CTL_KERN, KERN_PROCARGS2, pid]
        if sysctl(&mib2, 3, buffer, &bufferSize, nil, 0) != 0 {
            return nil
        }

        return parseProcArgs(buffer: buffer, size: bufferSize)
    }

    public static func userDataDir(for pid: pid_t) -> String? {
        guard let args = arguments(for: pid) else { return nil }
        for arg in args {
            if arg.hasPrefix("--user-data-dir=") {
                return String(arg.dropFirst("--user-data-dir=".count))
            }
        }
        return nil
    }

    private static func parseProcArgs(buffer: UnsafeMutablePointer<CChar>, size: Int) -> [String]? {
        guard size > MemoryLayout<Int32>.size else { return nil }

        // O buffer começa com argc (Int32) seguido pelo path do executável,
        // depois os argumentos separados por \0.
        var argc: Int32 = 0
        memcpy(&argc, buffer, MemoryLayout<Int32>.size)

        var cursor = MemoryLayout<Int32>.size

        // Pula o path do executável (primeira string).
        while cursor < size && buffer[cursor] != 0 {
            cursor += 1
        }
        // Pula bytes nulos de padding.
        while cursor < size && buffer[cursor] == 0 {
            cursor += 1
        }

        var args: [String] = []
        var current = cursor
        while cursor < size && args.count < Int(argc) {
            if buffer[cursor] == 0 {
                if cursor > current {
                    let length = cursor - current
                    let data = Data(bytes: buffer.advanced(by: current), count: length)
                    if let str = String(data: data, encoding: .utf8) {
                        args.append(str)
                    }
                }
                cursor += 1
                current = cursor
            } else {
                cursor += 1
            }
        }

        return args
    }
}
