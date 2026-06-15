import Foundation
import RelayKernel

// Headless relay-kernel daemon. One instance = one user (the supervisor spawns
// one per user). Config from env (RELAY_LISTEN_ADDR, RELAY_INGRESS_RULE,
// FANTASTIC_GROUP_TOKEN, …). The Mac app embeds RelayEngine directly instead.

func log(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

let config = RelayConfig.fromEnv()
let engine = RelayEngine(config: config)

Task {
    do {
        let port = try await engine.start()
        log(
            "relayd: relay-kernel up — listen \(config.listenHost):\(port), ingress=\(config.ingressRule)"
        )
    } catch {
        log("relayd: failed to start: \(error)")
        exit(1)
    }
}

// Block the main thread running the dispatch main queue; the kernel, eviction
// loop, and NIO surface run on their own threads/tasks.
dispatchMain()
