use crate::device_channel::Packet;
use crate::Device;
use connlib_shared::{messages::Interface, CallbackErrorFacade, Callbacks, Result};
use ip_network::IpNetwork;
use std::task::{Context, Poll};

#[derive(Clone)]
pub(crate) struct DeviceIo;

pub(crate) struct IfaceConfig;

impl DeviceIo {
    pub fn poll_read(&self, _: &mut [u8], _: &mut Context<'_>) -> Poll<std::io::Result<usize>> {
        todo!()
    }

    pub fn write(&self, _: Packet<'_>) -> std::io::Result<usize> {
        todo!()
    }
}

impl IfaceConfig {
    pub(crate) fn mtu(&self) -> usize {
        todo!()
    }

    pub(crate) async fn refresh_mtu(&self) -> Result<usize> {
        todo!()
    }

    pub(crate) async fn add_route(
        &self,
        _: IpNetwork,
        _: &CallbackErrorFacade<impl Callbacks>,
    ) -> Result<Option<Device>> {
        todo!()
    }
}

pub(crate) async fn create_iface(
    _: &Interface,
    _: &CallbackErrorFacade<impl Callbacks>,
) -> Result<Device> {
    todo!()
}
