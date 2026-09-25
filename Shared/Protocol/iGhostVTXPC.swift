import CiGhostVTXPC
import XPC

/// The XPC type constants, read through C rather than through Swift's XPC
/// overlay.
///
/// Naming one of the SDK's uppercase XPC type macros in Swift links
/// `/usr/lib/swift/libswiftXPC.dylib` as a *required* library — the SDK's .tbd
/// carries no back-deployment metadata, so the deployment target does not make
/// it weak — and iOS 15 does not have that dylib: dyld terminates the process
/// before `main` with "Library not loaded". Through `CiGhostVTXPC` they are the
/// libSystem globals they have always been, the overlay stays weakly linked and
/// unused, and the same binary runs on iOS 15 and on iOS 26.
///
/// No Swift file in this project may spell those macros directly; `make check`
/// fails on one that does.
enum iGhostVTXPC {
    static var typeArray: xpc_type_t {
        ighostvt_xpc_type_array()
    }

    static var typeBool: xpc_type_t {
        ighostvt_xpc_type_bool()
    }

    static var typeConnection: xpc_type_t {
        ighostvt_xpc_type_connection()
    }

    static var typeData: xpc_type_t {
        ighostvt_xpc_type_data()
    }

    static var typeDictionary: xpc_type_t {
        ighostvt_xpc_type_dictionary()
    }

    static var typeError: xpc_type_t {
        ighostvt_xpc_type_error()
    }

    static var typeInt64: xpc_type_t {
        ighostvt_xpc_type_int64()
    }

    static var typeString: xpc_type_t {
        ighostvt_xpc_type_string()
    }

    static var typeUInt64: xpc_type_t {
        ighostvt_xpc_type_uint64()
    }
}
