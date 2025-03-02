//! Connlib tunnel implementation.
//!
//! This is both the wireguard and ICE implementation that should work in tandem.
//! [Tunnel] is the main entry-point for this crate.
use boringtun::{
    noise::rate_limiter::RateLimiter,
    x25519::{PublicKey, StaticSecret},
};

use connlib_shared::{messages::Key, CallbackErrorFacade, Callbacks, Error};
use ip_network::IpNetwork;
use ip_network_table::IpNetworkTable;
use ip_packet::IpPacket;
use pnet_packet::Packet;

use hickory_resolver::proto::rr::RecordType;
use parking_lot::{Mutex, RwLock};
use peer::{Peer, PeerStats};
use tokio::time::MissedTickBehavior;
use webrtc::{
    api::{
        interceptor_registry::register_default_interceptors, media_engine::MediaEngine,
        setting_engine::SettingEngine, APIBuilder, API,
    },
    interceptor::registry::Registry,
    peer_connection::RTCPeerConnection,
};

use futures::channel::mpsc;
use futures_util::task::AtomicWaker;
use futures_util::{SinkExt, StreamExt};
use itertools::Itertools;
use std::collections::VecDeque;
use std::task::{ready, Context, Poll};
use std::{collections::HashMap, fmt, io, net::IpAddr, sync::Arc, time::Duration};
use std::{collections::HashSet, hash::Hash};
use tokio::time::Interval;
use webrtc::data::data_channel::DataChannel;
use webrtc::ice_transport::ice_candidate::RTCIceCandidateInit;

use connlib_shared::{
    messages::{GatewayId, ResourceDescription},
    Result,
};

use device_channel::{DeviceIo, IfaceConfig};

pub use client::ClientState;
use connlib_shared::error::ConnlibError;
pub use control_protocol::Request;
pub use gateway::GatewayState;
pub use webrtc::peer_connection::sdp::session_description::RTCSessionDescription;

use crate::ip_packet::MutableIpPacket;
use connlib_shared::messages::{ClientId, SecretKey};
use index::IndexLfsr;

mod bounded_queue;
mod client;
mod control_protocol;
mod device_channel;
mod dns;
mod gateway;
mod index;
mod ip_packet;
mod peer;
mod peer_handler;
mod resource_table;

const MAX_UDP_SIZE: usize = (1 << 16) - 1;
const DNS_QUERIES_QUEUE_SIZE: usize = 100;

/// For how long we will attempt to gather ICE candidates before aborting.
///
/// Chosen arbitrarily.
/// Very likely, the actual WebRTC connection will timeout before this.
/// This timeout is just here to eventually clean-up tasks if they are somehow broken.
const ICE_GATHERING_TIMEOUT_SECONDS: u64 = 5 * 60;

/// How many concurrent ICE gathering attempts we are allow.
///
/// Chosen arbitrarily.
const MAX_CONCURRENT_ICE_GATHERING: usize = 100;

// Note: Taken from boringtun
const HANDSHAKE_RATE_LIMIT: u64 = 100;

/// Represent's the tunnel actual peer's config
/// Obtained from connlib_shared's Peer
#[derive(Clone)]
pub struct PeerConfig {
    pub(crate) persistent_keepalive: Option<u16>,
    pub(crate) public_key: PublicKey,
    pub(crate) ips: Vec<IpNetwork>,
    pub(crate) preshared_key: SecretKey,
}

impl From<connlib_shared::messages::Peer> for PeerConfig {
    fn from(value: connlib_shared::messages::Peer) -> Self {
        Self {
            persistent_keepalive: value.persistent_keepalive,
            public_key: value.public_key.0.into(),
            ips: vec![value.ipv4.into(), value.ipv6.into()],
            preshared_key: value.preshared_key,
        }
    }
}
#[derive(Clone)]
struct Device {
    config: Arc<IfaceConfig>,
    io: DeviceIo,
}

impl Device {
    fn poll_read<'b>(
        &mut self,
        buf: &'b mut [u8],
        cx: &mut Context<'_>,
    ) -> Poll<io::Result<Option<MutableIpPacket<'b>>>> {
        let res = ready!(self.io.poll_read(&mut buf[..self.config.mtu()], cx))?;

        if res == 0 {
            return Poll::Ready(Ok(None));
        }

        Poll::Ready(Ok(Some(MutableIpPacket::new(&mut buf[..res]).ok_or_else(
            || {
                io::Error::new(
                    io::ErrorKind::InvalidInput,
                    "received bytes are not an IP packet",
                )
            },
        )?)))
    }
}

/// Tunnel is a wireguard state machine that uses webrtc's ICE channels instead of UDP sockets to communicate between peers.
pub struct Tunnel<CB: Callbacks, TRoleState: RoleState> {
    next_index: Mutex<IndexLfsr>,
    rate_limiter: Arc<RateLimiter>,
    private_key: StaticSecret,
    public_key: PublicKey,
    #[allow(clippy::type_complexity)]
    peers_by_ip: RwLock<IpNetworkTable<ConnectedPeer<TRoleState::Id>>>,
    peer_connections: Mutex<HashMap<TRoleState::Id, Arc<RTCPeerConnection>>>,
    webrtc_api: API,
    callbacks: CallbackErrorFacade<CB>,

    /// State that differs per role, i.e. clients vs gateways.
    role_state: Mutex<TRoleState>,

    stop_peer_command_receiver: Mutex<mpsc::Receiver<TRoleState::Id>>,
    stop_peer_command_sender: mpsc::Sender<TRoleState::Id>,

    rate_limit_reset_interval: Mutex<Interval>,
    peer_refresh_interval: Mutex<Interval>,
    mtu_refresh_interval: Mutex<Interval>,

    peers_to_stop: Mutex<VecDeque<TRoleState::Id>>,

    device: RwLock<Option<Device>>,
    read_buf: Mutex<Box<[u8; MAX_UDP_SIZE]>>,
    write_buf: Mutex<Box<[u8; MAX_UDP_SIZE]>>,
    no_device_waker: AtomicWaker,
}

impl<CB> Tunnel<CB, ClientState>
where
    CB: Callbacks + 'static,
{
    pub async fn next_event(&self) -> Result<Event<GatewayId>> {
        std::future::poll_fn(|cx| loop {
            {
                let mut guard = self.device.write();

                if let Some(device) = guard.as_mut() {
                    match self.poll_device(device, cx) {
                        Poll::Ready(Ok(Some(event))) => return Poll::Ready(Ok(event)),
                        Poll::Ready(Ok(None)) => {
                            tracing::info!("Device stopped");
                            guard.take();
                            continue;
                        }
                        Poll::Ready(Err(e)) => {
                            guard.take(); // Ensure we don't poll a failed device again.
                            return Poll::Ready(Err(e));
                        }
                        Poll::Pending => {}
                    }
                } else {
                    self.no_device_waker.register(cx.waker());
                }
            }

            match self.poll_next_event_common(cx) {
                Poll::Ready(event) => return Poll::Ready(Ok(event)),
                Poll::Pending => {}
            }

            return Poll::Pending;
        })
        .await
    }

    pub(crate) fn poll_device(
        &self,
        device: &mut Device,
        cx: &mut Context<'_>,
    ) -> Poll<Result<Option<Event<GatewayId>>>> {
        loop {
            let mut read_guard = self.read_buf.lock();
            let mut write_guard = self.write_buf.lock();
            let read_buf = read_guard.as_mut_slice();
            let write_buf = write_guard.as_mut_slice();

            let Some(packet) = ready!(device.poll_read(read_buf, cx))? else {
                return Poll::Ready(Ok(None));
            };

            let mut role_state = self.role_state.lock();

            let packet = match role_state.handle_dns(packet) {
                Ok(Some(response)) => {
                    device.io.write(response)?;
                    continue;
                }
                Ok(None) => continue,
                Err(non_dns_packet) => non_dns_packet,
            };

            let dest = packet.destination();

            let peers_by_ip = self.peers_by_ip.read();
            let Some(peer) = peer_by_ip(&peers_by_ip, dest) else {
                role_state.on_connection_intent(dest);
                continue;
            };

            self.encapsulate(write_buf, packet, dest, peer);

            continue;
        }
    }
}

impl<CB> Tunnel<CB, GatewayState>
where
    CB: Callbacks + 'static,
{
    pub fn poll_next_event(&self, cx: &mut Context<'_>) -> Poll<Result<Event<ClientId>>> {
        let mut read_guard = self.read_buf.lock();
        let mut write_guard = self.write_buf.lock();

        let read_buf = read_guard.as_mut_slice();
        let write_buf = write_guard.as_mut_slice();

        loop {
            {
                let mut device = self.device.write();

                match device.as_mut().map(|d| d.poll_read(read_buf, cx)) {
                    Some(Poll::Ready(Ok(Some(packet)))) => {
                        let dest = packet.destination();

                        let peers_by_ip = self.peers_by_ip.read();
                        let Some(peer) = peer_by_ip(&peers_by_ip, dest) else {
                            continue;
                        };

                        self.encapsulate(write_buf, packet, dest, peer);

                        continue;
                    }
                    Some(Poll::Ready(Ok(None))) => {
                        tracing::info!("Device stopped");
                        drop(device.take());
                    }
                    Some(Poll::Ready(Err(e))) => return Poll::Ready(Err(ConnlibError::Io(e))),
                    Some(Poll::Pending) => {
                        // device not ready for reading, moving on ..
                    }
                    None => {
                        self.no_device_waker.register(cx.waker());
                    }
                }
            }

            match self.poll_next_event_common(cx) {
                Poll::Ready(e) => return Poll::Ready(Ok(e)),
                Poll::Pending => {}
            }

            return Poll::Pending;
        }
    }
}

pub struct ConnectedPeer<TId> {
    inner: Arc<Peer<TId>>,
    channel: Arc<DataChannel>,
}

// TODO: For now we only use these fields with debug
#[allow(dead_code)]
#[derive(Debug, Clone)]
pub struct TunnelStats<TId> {
    public_key: String,
    peers_by_ip: HashMap<IpNetwork, PeerStats<TId>>,
    peer_connections: Vec<TId>,
}

impl<CB, TRoleState> Tunnel<CB, TRoleState>
where
    CB: Callbacks + 'static,
    TRoleState: RoleState,
{
    pub fn stats(&self) -> TunnelStats<TRoleState::Id> {
        let peers_by_ip = self
            .peers_by_ip
            .read()
            .iter()
            .map(|(ip, peer)| (ip, peer.inner.stats()))
            .collect();
        let peer_connections = self.peer_connections.lock().keys().cloned().collect();

        TunnelStats {
            public_key: Key::from(self.public_key).to_string(),
            peers_by_ip,
            peer_connections,
        }
    }

    fn poll_next_event_common(&self, cx: &mut Context<'_>) -> Poll<Event<TRoleState::Id>> {
        loop {
            if let Some(conn_id) = self.peers_to_stop.lock().pop_front() {
                let mut peers = self.peers_by_ip.write();

                let Some(peer_to_remove) = peers
                    .iter()
                    .find_map(|(n, p)| (p.inner.conn_id == conn_id).then_some(n))
                else {
                    continue;
                };

                let peer = peers.remove(peer_to_remove).expect("just found it");

                let channel = peer.channel.clone();

                tokio::spawn(async move { channel.close().await });
                if let Some(conn) = self.peer_connections.lock().remove(&conn_id) {
                    tokio::spawn({
                        let callbacks = self.callbacks.clone();
                        async move {
                            if let Err(e) = conn.close().await {
                                tracing::warn!(%conn_id, error = ?e, "Can't close peer");
                                let _ = callbacks.on_error(&e.into());
                            }
                        }
                    });
                }
            }

            if self
                .rate_limit_reset_interval
                .lock()
                .poll_tick(cx)
                .is_ready()
            {
                self.rate_limiter.reset_count();
                continue;
            }

            if self.peer_refresh_interval.lock().poll_tick(cx).is_ready() {
                let peers_by_ip = self.peers_by_ip.read();
                let mut peers_to_stop = self.peers_to_stop.lock();

                for (_, peer) in peers_by_ip.iter().unique_by(|(_, p)| p.inner.conn_id) {
                    let conn_id = peer.inner.conn_id;

                    peer.inner.expire_resources();

                    if peer.inner.is_emptied() {
                        tracing::trace!(%conn_id, "peer_expired");
                        peers_to_stop.push_back(conn_id);

                        continue;
                    }

                    let bytes = match peer.inner.update_timers() {
                        Ok(Some(bytes)) => bytes,
                        Ok(None) => continue,
                        Err(e) => {
                            tracing::error!("Failed to update timers for peer: {e}");
                            let _ = self.callbacks.on_error(&e);

                            if e.is_fatal_connection_error() {
                                peers_to_stop.push_back(conn_id);
                            }

                            continue;
                        }
                    };

                    let callbacks = self.callbacks.clone();
                    let peer_channel = peer.channel.clone();
                    let mut stop_command_sender = self.stop_peer_command_sender.clone();

                    tokio::spawn(async move {
                        if let Err(e) = peer_channel.write(&bytes).await {
                            let err = e.into();
                            tracing::error!("Failed to send packet to peer: {err:?}");
                            let _ = callbacks.on_error(&err);

                            if err.is_fatal_connection_error() {
                                let _ = stop_command_sender.send(conn_id).await;
                            }
                        }
                    });
                }

                continue;
            }

            if self.mtu_refresh_interval.lock().poll_tick(cx).is_ready() {
                let Some(device) = self.device.read().clone() else {
                    tracing::debug!("Device temporarily not available");
                    continue;
                };

                tokio::spawn({
                    let callbacks = self.callbacks.clone();

                    async move {
                        if let Err(e) = device.config.refresh_mtu().await {
                            tracing::error!(error = ?e, "refresh_mtu");
                            let _ = callbacks.on_error(&e);
                        }
                    }
                });
            }

            if let Poll::Ready(event) = self.role_state.lock().poll_next_event(cx) {
                return Poll::Ready(event);
            }

            if let Poll::Ready(Some(conn_id)) =
                self.stop_peer_command_receiver.lock().poll_next_unpin(cx)
            {
                self.peers_to_stop.lock().push_back(conn_id);

                continue;
            }

            return Poll::Pending;
        }
    }

    fn encapsulate(
        &self,
        write_buf: &mut [u8],
        packet: MutableIpPacket,
        dest: IpAddr,
        peer: &ConnectedPeer<TRoleState::Id>,
    ) {
        let peer_id = peer.inner.conn_id;

        match peer.inner.encapsulate(packet, dest, write_buf) {
            Ok(None) => {}
            Ok(Some(b)) => {
                tokio::spawn({
                    let channel = peer.channel.clone();
                    let mut sender = self.stop_peer_command_sender.clone();

                    async move {
                        if let Err(e) = channel.write(&b).await {
                            tracing::error!(resource_address = %dest, err = ?e, "failed to handle packet {e:#}");
                            let _ = sender.send(peer_id).await;
                        }
                    }
                });
            }
            Err(e) => {
                tracing::error!(resource_address = %dest, err = ?e, "failed to handle packet {e:#}");

                if e.is_fatal_connection_error() {
                    self.peers_to_stop.lock().push_back(peer_id);
                }
            }
        };
    }
}

pub(crate) fn peer_by_ip<Id>(
    peers_by_ip: &IpNetworkTable<ConnectedPeer<Id>>,
    ip: IpAddr,
) -> Option<&ConnectedPeer<Id>> {
    peers_by_ip.longest_match(ip).map(|(_, peer)| peer)
}

#[derive(Debug)]
pub struct DnsQuery<'a> {
    pub name: String,
    pub record_type: RecordType,
    // We could be much more efficient with this field,
    // we only need the header to create the response.
    pub query: IpPacket<'a>,
}

impl<'a> DnsQuery<'a> {
    pub(crate) fn into_owned(self) -> DnsQuery<'static> {
        let Self {
            name,
            record_type,
            query,
        } = self;
        let buf = query.packet().to_vec();
        let query =
            IpPacket::owned(buf).expect("We are constructing the ip packet from an ip packet");

        DnsQuery {
            name,
            record_type,
            query,
        }
    }
}

pub enum Event<TId> {
    SignalIceCandidate {
        conn_id: TId,
        candidate: RTCIceCandidateInit,
    },
    ConnectionIntent {
        resource: ResourceDescription,
        connected_gateway_ids: HashSet<GatewayId>,
        reference: usize,
    },
    DnsQuery(DnsQuery<'static>),
}

impl<CB, TRoleState> Tunnel<CB, TRoleState>
where
    CB: Callbacks + 'static,
    TRoleState: RoleState,
{
    /// Creates a new tunnel.
    ///
    /// # Parameters
    /// - `private_key`: wireguard's private key.
    /// -  `control_signaler`: this is used to send SDP from the tunnel to the control plane.
    #[tracing::instrument(level = "trace", skip(private_key, callbacks))]
    pub async fn new(private_key: StaticSecret, callbacks: CB) -> Result<Self> {
        let public_key = (&private_key).into();
        let rate_limiter = Arc::new(RateLimiter::new(&public_key, HANDSHAKE_RATE_LIMIT));
        let peers_by_ip = RwLock::new(IpNetworkTable::new());
        let next_index = Default::default();
        let peer_connections = Default::default();
        let device = Default::default();

        // ICE
        let mut media_engine = MediaEngine::default();

        // Register default codecs (TODO: We need this?)
        media_engine.register_default_codecs()?;
        let mut registry = Registry::new();
        registry = register_default_interceptors(registry, &mut media_engine)?;
        let mut setting_engine = SettingEngine::default();
        setting_engine.detach_data_channels();
        setting_engine.set_interface_filter(Box::new(|name| !name.contains("tun")));

        let webrtc_api = APIBuilder::new()
            .with_media_engine(media_engine)
            .with_interceptor_registry(registry)
            .with_setting_engine(setting_engine)
            .build();

        let (stop_peer_command_sender, stop_peer_command_receiver) = mpsc::channel(10);

        Ok(Self {
            rate_limiter,
            private_key,
            peer_connections,
            public_key,
            peers_by_ip,
            next_index,
            webrtc_api,
            device,
            read_buf: Mutex::new(Box::new([0u8; MAX_UDP_SIZE])),
            write_buf: Mutex::new(Box::new([0u8; MAX_UDP_SIZE])),
            callbacks: CallbackErrorFacade(callbacks),
            role_state: Default::default(),
            stop_peer_command_receiver: Mutex::new(stop_peer_command_receiver),
            stop_peer_command_sender,
            rate_limit_reset_interval: Mutex::new(rate_limit_reset_interval()),
            peer_refresh_interval: Mutex::new(peer_refresh_interval()),
            mtu_refresh_interval: Mutex::new(mtu_refresh_interval()),
            peers_to_stop: Default::default(),
            no_device_waker: Default::default(),
        })
    }

    fn next_index(&self) -> u32 {
        self.next_index.lock().next()
    }

    pub fn callbacks(&self) -> &CallbackErrorFacade<CB> {
        &self.callbacks
    }
}

/// Constructs the interval for resetting the rate limit count.
///
/// As per documentation on [`RateLimiter::reset_count`], this is configured to run every second.
fn rate_limit_reset_interval() -> Interval {
    let mut interval = tokio::time::interval(Duration::from_secs(1));
    interval.set_missed_tick_behavior(MissedTickBehavior::Delay);

    interval
}

/// Constructs the interval for "refreshing" peers.
///
/// On each tick, we remove expired peers from our map, update wireguard timers and send packets, if any.
fn peer_refresh_interval() -> Interval {
    let mut interval = tokio::time::interval(Duration::from_secs(1));
    interval.set_missed_tick_behavior(MissedTickBehavior::Delay);

    interval
}

/// Constructs the interval for refreshing the MTU of our TUN device.
fn mtu_refresh_interval() -> Interval {
    let mut interval = tokio::time::interval(Duration::from_secs(30));
    interval.set_missed_tick_behavior(MissedTickBehavior::Delay);

    interval
}

/// Dedicated trait for abstracting over the different ICE states.
///
/// By design, this trait does not allow any operations apart from advancing via [`RoleState::poll_next_event`].
/// The state should only be modified when the concrete type is known, e.g. [`ClientState`] or [`GatewayState`].
pub trait RoleState: Default + Send + 'static {
    type Id: fmt::Debug + fmt::Display + Eq + Hash + Copy + Unpin + Send + Sync + 'static;

    fn poll_next_event(&mut self, cx: &mut Context<'_>) -> Poll<Event<Self::Id>>;
}
