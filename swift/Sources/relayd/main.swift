import Foundation
import RelayCore

// Bootstrap: load config from env → run the relay server (blocking). Reads the
// SAME env vars as the Rust `fantastic-router` binary.
do {
    let config = try Config.fromEnv()
    let server = try RelayServer(config: config)
    FileHandle.standardError.write(
        Data("relayd: listening on \(config.listenHost):\(config.listenPort)\n".utf8))
    try server.run()
} catch {
    FileHandle.standardError.write(Data("relayd: \(error)\n".utf8))
    exit(1)
}
