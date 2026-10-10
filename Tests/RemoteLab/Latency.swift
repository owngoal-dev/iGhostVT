import Foundation
import Network
@preconcurrency import XPC

// remote-lab latency --state DIR --session SID (--direct HOST:PORT | --service NAME)
//                    [--runs N] [--pipeline 0|1] [--compress 0|1]
//
// What a tab waits for when it reattaches: a fresh link, TLS, the hello,
// the attach and its replay — timed one phase at a time, `--runs` times,
// each run detaching before it closes so the next finds the session free.
// `--pipeline 1` sends the attach right behind the hello instead of after
// its answer; `--compress 1` asks the host to compress what it sends.
// `--service NAME` dials the Bonjour service, as the app does when the
// browser sees the host, instead of an address.

private struct LatencyRun {
    var ready: Double
    var hello: Double
    var attach: Double
    var wireBytes: UInt64
    var replayBytes: Int
}

private func milliseconds(since start: DispatchTime) -> Double {
    Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
}

private func latencyRun(_ device: LabDevice, sessionID: UInt64, pipeline: Bool, compress: Bool) -> LatencyRun? {
    let key = RemoteTLS.Key(identity: Data(device.deviceID.utf8), secret: device.deviceKey)
    let target: NWEndpoint
    if let service = options["service"] {
        target = .service(name: service, type: RemoteAccess.serviceType, domain: "local.", interface: nil)
    } else {
        target = endpoint(option("direct"))
    }
    let start = DispatchTime.now()
    let link = LabLink(to: target, hostID: device.hostID, key: key, isRelayed: false)
    link.frames.acceptsCompressedInput = compress
    guard link.open() else {
        say("TLS did not come up")
        return nil
    }
    let ready = milliseconds(since: start)
    guard let exporter = RemoteTLS.exporterSecret(of: link.frames.connection) else { return nil }
    let hello = message(.hello)
    xpc_dictionary_set_string(hello, iGhostVTWireKey.deviceID, device.deviceID)
    xpc_dictionary_set_string(hello, iGhostVTWireKey.deviceName, "Remote Lab")
    xpc_dictionary_set_string(hello, iGhostVTWireKey.appVersion, wireVersion)
    xpc_dictionary_set_uint64(hello, iGhostVTWireKey.received, 0)
    if compress {
        RemoteFrameCompression.offer(in: hello)
    }
    setData(
        RemoteDeviceProof.make(key: device.deviceKey, exporterSecret: exporter, deviceID: device.deviceID),
        iGhostVTWireKey.confirmation,
        in: hello,
    )
    let attach = message(.attachSession)
    xpc_dictionary_set_uint64(attach, iGhostVTWireKey.sessionID, sessionID)
    xpc_dictionary_set_bool(attach, iGhostVTWireKey.takeover, true)

    let helloDone = DispatchSemaphore(value: 0)
    let attachDone = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var helloAt = 0.0
    nonisolated(unsafe) var helloOK = false
    nonisolated(unsafe) var attachAt = 0.0
    nonisolated(unsafe) var replayBytes = 0
    nonisolated(unsafe) var attachOK = false
    link.send(hello) { reply in
        helloAt = milliseconds(since: start)
        helloOK = code(of: reply) == .success
        helloDone.signal()
    }
    let sendAttach = {
        link.send(attach) { reply in
            attachAt = milliseconds(since: start)
            attachOK = code(of: reply) == .success
            replayBytes = data(iGhostVTWireKey.data, in: reply)?.count ?? 0
            attachDone.signal()
        }
    }
    if pipeline {
        sendAttach()
    }
    guard helloDone.wait(timeout: .now() + 20) == .success, helloOK else {
        say("hello refused or unanswered")
        link.close()
        return nil
    }
    if !pipeline {
        sendAttach()
    }
    guard attachDone.wait(timeout: .now() + 20) == .success, attachOK else {
        say("attach refused or unanswered")
        link.close()
        return nil
    }
    let wire = link.queue.sync { link.frames.receivedWireByteCount }
    let detach = message(.detachSession)
    xpc_dictionary_set_uint64(detach, iGhostVTWireKey.sessionID, sessionID)
    _ = link.request(detach, timeout: 10)
    link.close()
    return LatencyRun(ready: ready, hello: helloAt, attach: attachAt, wireBytes: wire, replayBytes: replayBytes)
}

func runLatency() -> Int32 {
    let device = loadDevice()
    guard let sessionID = UInt64(option("session")) else { fail("bad --session") }
    let runs = max(1, Int(options["runs"] ?? "10") ?? 10)
    let pipeline = options["pipeline"] == "1"
    let compress = options["compress"] == "1"
    var results: [LatencyRun] = []
    for index in 0 ..< runs {
        guard let run = latencyRun(device, sessionID: sessionID, pipeline: pipeline, compress: compress) else {
            return 1
        }
        results.append(run)
        say(String(
            format: "run %2d  ready %6.1f  hello %6.1f  attach %6.1f ms  wire %7llu B  replay %7d B",
            index + 1, run.ready, run.hello, run.attach, run.wireBytes, run.replayBytes,
        ))
        usleep(200_000)
    }
    func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }
    print(String(
        format: "SUMMARY pipeline=%d compress=%d runs=%d  ready %.1f  hello %.1f  attach %.1f ms (median)  wire %llu B  replay %d B",
        pipeline ? 1 : 0, compress ? 1 : 0, runs,
        median(results.map(\.ready)), median(results.map(\.hello)), median(results.map(\.attach)),
        results.last?.wireBytes ?? 0, results.last?.replayBytes ?? 0,
    ))
    return 0
}
