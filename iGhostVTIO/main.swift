import Darwin
import Dispatch
import Foundation

// A dying shell must not take the session host with it.
signal(SIGPIPE, SIG_IGN)
// SIGCHLD stays at default on purpose. SIG_IGN makes the kernel auto-reap
// children, and a `waitpid` racing that auto-reap can block forever — which
// froze the whole control queue the first time a close's grace-kill path
// waited on a SIGKILLed shell. PTYSession reaps its own children with
// WNOHANG, so nothing here needs the auto-reap.
signal(SIGCHLD, SIG_DFL)

// `ighostvtd` spawns this program with the socket on a fixed descriptor and
// names it on the command line; nothing else runs it.
var socketDescriptor = IOWire.socketDescriptor
var arguments = CommandLine.arguments.dropFirst()
while let argument = arguments.popFirst() {
    if argument == IOWire.socketArgument, let value = arguments.popFirst(), let parsed = Int32(value) {
        socketDescriptor = parsed
    } else {
        fputs("usage: \(IOWire.executableName) \(IOWire.socketArgument) <fd>\n", stderr)
        exit(64)
    }
}

guard fcntl(socketDescriptor, F_GETFD) >= 0 else {
    fputs(
        "\(IOWire.executableName): descriptor \(socketDescriptor) is not open; ighostvtd starts this program\n",
        stderr,
    )
    exit(64)
}

autoreleasepool {
    let host = IOHost(descriptor: socketDescriptor)
    host.start()
    withExtendedLifetime(host) {
        dispatchMain()
    }
}
