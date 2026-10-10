import Foundation
import OSLog

public enum TxLogger {
    public static let subsystem = "dev.distuai.tx"

    public static let audio = Logger(subsystem: subsystem, category: "audio")
    public static let process = Logger(subsystem: subsystem, category: "process")
    public static let meet = Logger(subsystem: subsystem, category: "meet")
    public static let chrome = Logger(subsystem: subsystem, category: "chrome")
    public static let transcription = Logger(subsystem: subsystem, category: "transcription")
    public static let database = Logger(subsystem: subsystem, category: "database")
    public static let ui = Logger(subsystem: subsystem, category: "ui")
    public static let app = Logger(subsystem: subsystem, category: "app")
    public static let intelligence = Logger(subsystem: subsystem, category: "intelligence")
}
