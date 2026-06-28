// SPDX-License-Identifier: MPL-2.0

//! Minimal POSIX message queue file system.
//!
//! This provides the mountable `mqueue` file-system type expected at
//! `/dev/mqueue`. POSIX message queue syscalls are not implemented yet.

use fs::MqueueFsType;

mod fs;

pub(super) fn init() {
    crate::fs::vfs::registry::register(&MqueueFsType).unwrap();
}
