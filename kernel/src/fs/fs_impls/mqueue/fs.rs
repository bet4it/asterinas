// SPDX-License-Identifier: MPL-2.0

use crate::{
    fs::{
        ramfs::RamFs,
        vfs::{
            file_system::FileSystem,
            registry::{FsCreationCtx, FsProperties, FsType},
        },
    },
    prelude::*,
};

pub(super) struct MqueueFsType;

impl FsType for MqueueFsType {
    fn name(&self) -> &'static str {
        "mqueue"
    }

    fn properties(&self) -> FsProperties {
        FsProperties::empty()
    }

    fn create(&self, _fs_creation_ctx: &FsCreationCtx) -> Result<Arc<dyn FileSystem>> {
        Ok(RamFs::new_mqueue())
    }

    fn sysnode(&self) -> Option<Arc<dyn aster_systree::SysNode>> {
        None
    }
}
