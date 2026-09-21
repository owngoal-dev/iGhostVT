import UIKit

/// Ends the app the way pressing Home and swiping it away would look.
///
/// `exit` from a foreground app is what a crash looks like: the screen is
/// there and then it is not. Every exit the app chooses for itself (the Quit
/// button of the update notice first of all) leaves for the home screen,
/// waits for that animation and only then exits.
enum QuietExit {
    /// How long SpringBoard takes to put the app away.
    private static let animation: TimeInterval = 1

    /// `cleanup` runs after the app has left the screen, right before `exit`:
    /// what `applicationWillTerminate` would have done, since `exit` never
    /// calls it.
    @MainActor
    static func run(cleanup: @escaping @MainActor () -> Void = {}) {
        let application = UIApplication.shared
        // The background task keeps the process running until the exit below;
        // without it iOS may freeze the app first and the old copy lingers.
        let task = application.beginBackgroundTask()
        // UIApplication answers `suspend` and declares it nowhere public;
        // NSXPCConnection lends the selector its name.
        application.perform(#selector(NSXPCConnection.suspend))
        DispatchQueue.main.asyncAfter(deadline: .now() + animation) {
            cleanup()
            application.endBackgroundTask(task)
            exit(EXIT_SUCCESS)
        }
    }
}
