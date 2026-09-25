import Darwin
import Dispatch
import XPC

// Symbols the Swift overlay does not surface: XPC peer identity, mach service
// listeners, and the PTY/ioctl calls the session manager needs.

@_silgen_name("xpc_connection_get_audit_token")
func ighostvtXPCConnectionGetAuditToken(
    _ connection: xpc_connection_t,
    _ token: UnsafeMutablePointer<audit_token_t>,
)

@_silgen_name("xpc_copy_entitlement_for_token")
func ighostvtXPCCopyEntitlement(
    _ name: UnsafePointer<CChar>,
    _ token: UnsafeMutablePointer<audit_token_t>,
) -> xpc_object_t?

@_silgen_name("xpc_connection_create_mach_service")
func ighostvtCreateMachServiceListener(
    _ name: UnsafePointer<CChar>,
    _ targetQueue: DispatchQueue?,
    _ flags: UInt64,
) -> xpc_connection_t?

@_silgen_name("proc_pidpath")
func ighostvtProcPIDPath(
    _ pid: Int32,
    _ buffer: UnsafeMutableRawPointer,
    _ size: UInt32,
) -> Int32

/// `proc_name` from libproc: the process's short name (its `p_comm`,
/// what `ps -c` prints), used for the foreground-process reports. Returns
/// the name's length, 0 on failure (process gone, or not visible to the
/// caller).
@_silgen_name("proc_name")
func ighostvtProcName(
    _ pid: Int32,
    _ buffer: UnsafeMutableRawPointer,
    _ size: UInt32,
) -> Int32

/// `proc_pidinfo` from libproc, used with `PROC_PIDVNODEPATHINFO` to read a
/// process's current directory as the kernel spells it — the form `chdir`
/// wants, whatever vocabulary the shell itself speaks. Returns the number of
/// bytes filled, 0 on failure. The iOS SDK ships no `proc_info.h`, so the
/// struct's layout is carried as constants (`ProcVnodePathInfo`).
@_silgen_name("proc_pidinfo")
func ighostvtProcPIDInfo(
    _ pid: Int32,
    _ flavor: Int32,
    _ argument: UInt64,
    _ buffer: UnsafeMutableRawPointer?,
    _ size: Int32,
) -> Int32

/// ABI of `struct proc_vnodepathinfo` (`sys/proc_info.h`), fixed across
/// arm64 macOS and iOS: two `vnode_info_path`s — current directory, then
/// root — each a `vnode_info` followed by a `MAXPATHLEN` path. The
/// harness's "inherited working directory" checks read a live session's
/// directory through these offsets against the macOS SDK's real struct,
/// which is the one proof they are right; keep that test.
enum ProcVnodePathInfo {
    static let flavor: Int32 = 9 // PROC_PIDVNODEPATHINFO
    static let size = 2352
    /// `offsetof(struct proc_vnodepathinfo, pvi_cdir.vip_path)`
    static let currentDirectoryPathOffset = 152
    static let pathLength = 1024 // MAXPATHLEN
}

/// `forkpty` handles the child-side dance a terminal needs — `setsid`, the
/// `TIOCSCTTY` controlling-terminal assignment, and wiring the slave to
/// stdin/stdout/stderr — none of which `posix_spawn` can express.
@_silgen_name("forkpty")
func ighostvtForkPTY(
    _ master: UnsafeMutablePointer<Int32>,
    _ name: UnsafeMutablePointer<CChar>?,
    _ termios: UnsafeMutableRawPointer?,
    _ winsize: UnsafeMutablePointer<winsize>?,
) -> pid_t

// `ioctl` is deliberately NOT redeclared here. It is C-variadic
// (`int ioctl(int, unsigned long, ...)`), and on arm64 variadic arguments are
// passed on the stack while named ones are passed in registers — so a
// hand-rolled fixed-arity `@_silgen_name` shim puts the `winsize` pointer in
// a register the callee never reads, and the terminal silently gets a garbage
// window size. Use `Darwin.ioctl`, which the overlay declares correctly.

enum PrivateSystemConstant {
    static let machServiceListener: UInt64 = 1
}
