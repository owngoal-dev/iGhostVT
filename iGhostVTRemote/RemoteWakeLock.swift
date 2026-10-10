import Darwin
import Dispatch
import Foundation

/// Keeps the host from idle sleep while a paired device is using it.
///
/// A host that dozes off halfway through a build someone is watching, or a
/// file on its way over, takes the device's links down with it, and the
/// device can only wait for someone to wake it. So the helper holds a
/// `PreventUserIdleSystemSleep` power assertion — the one a download or a
/// backup holds: the display still sleeps, and the lid, the Apple menu
/// and a battery running out still put the machine to sleep — but only
/// for as long as a device is *using* a terminal: typing into one,
/// opening one, sending a file. Output counts too, but only within
/// `outputGraceSeconds` of the last input — what `sz` or a build started
/// from a keystroke prints — so a device that never sleeps, left on
/// `htop` overnight, does not keep a Mac awake all night. Being connected
/// is not using either: a device's links ping every few seconds. The
/// assertion is let go `holdSeconds` after the last use.
///
/// IOKit is reached by name because the iOS SDK has no `IOPMLib.h`; the
/// same calls are what `powerd` honours there for a root daemon.
final class RemoteWakeLock: @unchecked Sendable {
    static let shared = RemoteWakeLock()

    /// How long after the last use the host may sleep again.
    static let holdSeconds: TimeInterval = 5 * 60
    /// How long output keeps counting after the last input.
    static let outputGraceSeconds: TimeInterval = 30 * 60

    private typealias Create = @convention(c) (CFString, UInt32, CFString, UnsafeMutablePointer<UInt32>) -> Int32
    private typealias Release = @convention(c) (UInt32) -> Int32
    private static let levelOn: UInt32 = 255 // kIOPMAssertionLevelOn

    private let create: Create?
    private let release: Release?
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "wiki.qaq.ighostvt.remote.wake", qos: .utility)
    private var assertion: UInt32?
    private var lastUse = Date.distantPast
    private var lastInput = Date.distantPast
    private var isWatching = false
    /// The last refusal, so a refused assertion is asked for again only
    /// after a while, not on every output event.
    private var refusedAt = Date.distantPast

    private init() {
        let iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY)
        create = dlsym(iokit, "IOPMAssertionCreateWithName").map { unsafeBitCast($0, to: Create.self) }
        release = dlsym(iokit, "IOPMAssertionRelease").map { unsafeBitCast($0, to: Release.self) }
    }

    /// Input from a device: typing, a terminal opened or picked up, a file.
    func noteInput() {
        note(isInput: true)
    }

    /// Output toward a device. Called per output event, so this is a
    /// timestamp and nothing more once the assertion is held.
    func noteOutput() {
        note(isInput: false)
    }

    private func note(isInput: Bool) {
        let shouldTake = lock.withLock { () -> Bool in
            let now = Date()
            if isInput {
                lastInput = now
            } else if now.timeIntervalSince(lastInput) > Self.outputGraceSeconds {
                return false
            }
            lastUse = now
            guard assertion == nil, !isWatching, now.timeIntervalSince(refusedAt) > Self.holdSeconds else { return false }
            isWatching = true
            return true
        }
        if shouldTake {
            queue.async { self.take() }
        }
    }

    var isHeld: Bool {
        lock.withLock { assertion != nil }
    }

    private func take() {
        guard let create else {
            RemoteLog.log("wake lock: IOKit has no power assertions here")
            lock.withLock {
                isWatching = false
                refusedAt = .distantFuture
            }
            return
        }
        var identifier: UInt32 = 0
        let status = create(
            "PreventUserIdleSystemSleep" as CFString,
            Self.levelOn,
            "iGhostVT: a paired device is using a terminal" as CFString,
            &identifier,
        )
        guard status == 0 else {
            RemoteLog.log("wake lock: the power assertion was refused (\(status))")
            lock.withLock {
                isWatching = false
                refusedAt = Date()
            }
            return
        }
        lock.withLock { assertion = identifier }
        RemoteLog.log("wake lock: held while a device uses this host")
        scheduleCheck(after: Self.holdSeconds)
    }

    private func scheduleCheck(after delay: TimeInterval) {
        queue.asyncAfter(deadline: .now() + delay) { [self] in
            let idle = lock.withLock { Date().timeIntervalSince(lastUse) }
            guard idle >= Self.holdSeconds else {
                return scheduleCheck(after: Self.holdSeconds - idle + 1)
            }
            let held = lock.withLock { () -> UInt32? in
                defer {
                    assertion = nil
                    isWatching = false
                }
                return assertion
            }
            if let held {
                _ = release?(held)
                RemoteLog.log("wake lock: let go, nothing used for \(Int(idle)) s")
            }
        }
    }
}
