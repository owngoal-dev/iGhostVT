import Foundation

/// The engine's lines, printed with the run's own; verbose ones only with
/// REMOTE_LAB_VERBOSE set.
enum AppLog {
    enum Category: String {
        case zmodem
    }

    private static let isVerbose = ProcessInfo.processInfo.environment["REMOTE_LAB_VERBOSE"] != nil

    static func verbose(_ category: Category, _ line: @autoclosure () -> String) {
        if isVerbose {
            say("\(category.rawValue): \(line())")
        }
    }

    static func info(_ category: Category, _ line: @autoclosure () -> String) {
        say("\(category.rawValue): \(line())")
    }

    static func warning(_ category: Category, _ line: @autoclosure () -> String) {
        say("\(category.rawValue) warning: \(line())")
    }

    static func error(_ category: Category, _ line: @autoclosure () -> String) {
        say("\(category.rawValue) error: \(line())")
    }
}
