//! Rendezvous pairing.
//!
//! Two half-open connections sharing a `(tenant_id, rendezvous)` key get paired
//! into one session. Single-use: the slot is consumed on match. The first
//! arrival parks its whole socket in the slot and keeps a `oneshot::Receiver`
//! exit signal; the SECOND arrival takes the first's socket, owns both, and is
//! the sole driver of `forward::run`. A RAII `SlotGuard` reclaims + closes a
//! parked socket on timeout / drop / panic so nothing leaks.
//!
//! Security: a third party that guesses a rendezvous can at worst occupy/race a
//! slot — the endpoints' E2E handshake fails for an impostor, so this is an
//! availability nuisance, never impersonation. Pairing honesty is not
//! security-critical.

use std::pin::Pin;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;

use dashmap::mapref::entry::Entry;
use dashmap::DashMap;
use futures_util::{Sink, Stream};
use tokio::sync::oneshot;
use tokio_tungstenite::tungstenite::{Error as WsError, Message};

use crate::auth::Claims;
use crate::config::Config;

/// Object-safe halves so the registry + forwarder stay monomorphic and tests
/// can slot in duplex-backed sockets.
pub type FrameStream = Pin<Box<dyn Stream<Item = Result<Message, WsError>> + Send + Sync>>;
pub type FrameSink = Pin<Box<dyn Sink<Message, Error = WsError> + Send + Sync>>;

/// An authenticated, upgraded peer connection, split into its halves.
pub struct PeerSocket {
    pub stream: FrameStream,
    pub sink: FrameSink,
    pub claims: Claims,
}

type RvKey = (String, String); // (tenant_id, rendezvous)

struct Slot {
    socket: PeerSocket,
    wake: oneshot::Sender<()>,
    peer_id: String,
}

struct State {
    slots: DashMap<RvKey, Slot>,
    waiting_total: AtomicUsize,
    waiting_per_tenant: DashMap<String, usize>,
    max_waiting_global: usize,
    max_waiting_per_tenant: usize,
}

impl State {
    fn over_cap(&self, tenant: &str) -> bool {
        if self.waiting_total.load(Ordering::SeqCst) >= self.max_waiting_global {
            return true;
        }
        let n = self.waiting_per_tenant.get(tenant).map(|e| *e).unwrap_or(0);
        n >= self.max_waiting_per_tenant
    }

    fn inc_waiting(&self, tenant: &str) {
        self.waiting_total.fetch_add(1, Ordering::SeqCst);
        *self
            .waiting_per_tenant
            .entry(tenant.to_string())
            .or_insert(0) += 1;
    }

    fn dec_waiting(&self, tenant: &str) {
        self.waiting_total.fetch_sub(1, Ordering::SeqCst);
        if let Some(mut e) = self.waiting_per_tenant.get_mut(tenant) {
            if *e > 0 {
                *e -= 1;
            }
        }
    }
}

/// In-memory pairing registry.
pub struct InMemoryRendezvous {
    state: Arc<State>,
}

/// Outcome of a `join`.
pub enum Join {
    /// Second arrival: drive `forward::run(a, b)`. `a` = first arrival.
    Paired { a: PeerSocket, b: PeerSocket },
    /// First arrival: await the ticket (with a timeout in the caller).
    Waiting(WaitTicket),
    /// Reject the just-arrived socket (caller closes it). Socket returned.
    Rejected {
        socket: PeerSocket,
        reason: &'static str,
    },
}

/// Held by the first arrival while it waits for its pair.
pub struct WaitTicket {
    rx: oneshot::Receiver<()>,
    guard: SlotGuard,
}

impl WaitTicket {
    /// Wait up to `dur` for a pair. Returns `true` if paired (the peer now
    /// drives the session); `false` on timeout/cancel, in which case the
    /// guard's drop reclaims + closes the parked socket.
    pub async fn settle(mut self, dur: std::time::Duration) -> bool {
        match tokio::time::timeout(dur, &mut self.rx).await {
            Ok(Ok(())) => {
                self.guard.disarm();
                true
            }
            _ => false,
        }
    }
}

/// RAII cleanup for a parked (unpaired) slot. Removes the slot iff it's still
/// ours; dropping the reclaimed `Slot` closes the parked TCP connection.
pub struct SlotGuard {
    state: Arc<State>,
    key: RvKey,
    peer_id: String,
    armed: bool,
}

impl SlotGuard {
    fn disarm(&mut self) {
        self.armed = false;
    }
}

impl Drop for SlotGuard {
    fn drop(&mut self) {
        if !self.armed {
            return;
        }
        let peer_id = self.peer_id.clone();
        let removed = self
            .state
            .slots
            .remove_if(&self.key, move |_, s| s.peer_id == peer_id);
        if removed.is_some() {
            self.state.dec_waiting(&self.key.0);
        }
        // `removed` (the Slot, holding the socket) drops here → closes the TCP.
    }
}

fn partner_ok(first_peer: &str, first_partner: &str, second: &Claims) -> bool {
    if !first_partner.is_empty() && first_partner != second.peer_id {
        return false;
    }
    if !second.partner_peer_id.is_empty() && second.partner_peer_id != first_peer {
        return false;
    }
    true
}

impl InMemoryRendezvous {
    pub fn from_config(config: &Config) -> Self {
        Self {
            state: Arc::new(State {
                slots: DashMap::new(),
                waiting_total: AtomicUsize::new(0),
                waiting_per_tenant: DashMap::new(),
                max_waiting_global: config.max_waiting_global,
                max_waiting_per_tenant: config.max_waiting_per_tenant,
            }),
        }
    }

    pub fn join(&self, socket: PeerSocket) -> Join {
        let key: RvKey = (
            socket.claims.tenant_id.clone(),
            socket.claims.rendezvous.clone(),
        );
        match self.state.slots.entry(key.clone()) {
            Entry::Occupied(o) => {
                let first_peer = o.get().peer_id.clone();
                let first_partner = o.get().socket.claims.partner_peer_id.clone();
                if first_peer == socket.claims.peer_id {
                    return Join::Rejected {
                        socket,
                        reason: "self-pair",
                    };
                }
                if !partner_ok(&first_peer, &first_partner, &socket.claims) {
                    return Join::Rejected {
                        socket,
                        reason: "partner-mismatch",
                    };
                }
                let slot = o.remove();
                self.state.dec_waiting(&key.0);
                let _ = slot.wake.send(());
                Join::Paired {
                    a: slot.socket,
                    b: socket,
                }
            }
            Entry::Vacant(v) => {
                if self.state.over_cap(&key.0) {
                    return Join::Rejected {
                        socket,
                        reason: "waiting-cap",
                    };
                }
                let (tx, rx) = oneshot::channel();
                let peer_id = socket.claims.peer_id.clone();
                v.insert(Slot {
                    socket,
                    wake: tx,
                    peer_id: peer_id.clone(),
                });
                self.state.inc_waiting(&key.0);
                let guard = SlotGuard {
                    state: Arc::clone(&self.state),
                    key,
                    peer_id,
                    armed: true,
                };
                Join::Waiting(WaitTicket { rx, guard })
            }
        }
    }
}
