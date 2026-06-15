import Foundation

// relay-supervisor — standalone, NON-kernel process. Maps `user → relay-kernel`
// instance: spawns/reaps one `relayd` per user. This is the ONLY multitenant
// surface, and it's isolation-by-instance (no shared tenant table).
//
// Alpha: spawns a single relayd. Cloud (TODO): a per-user fleet with lifecycle
// (spawn on first connect, reap when idle), each on its own port/socket.

print("relay-supervisor: alpha stub — one relay-kernel per user, isolation-by-instance.")
print("  cloud TODO: per-user fleet + lifecycle. Run `relayd` directly for now.")
