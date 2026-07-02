// SPDX-License-Identifier: MPL-2.0

use aster_util::printer::VmPrinter;
use ostd::task::Task;

use crate::{
    fs::{
        file::mkmod,
        procfs::template::{ProcFile, ProcFileOps},
        vfs::inode::Inode,
    },
    net::uts_ns::{UtsName, UtsNamespace},
    prelude::*,
};

/// Represents the inode at `/proc/sys/kernel/hostname`.
pub struct HostnameFileOps;

impl HostnameFileOps {
    pub fn new_inode(parent: Weak<dyn Inode>) -> Arc<dyn Inode> {
        ProcFile::new(Self, parent, mkmod!(a+r))
    }
}

impl ProcFileOps for HostnameFileOps {
    fn read_at(&self, offset: usize, writer: &mut VmWriter) -> Result<usize> {
        read_uts_name(offset, writer, UtsName::nodename)
    }
}

/// Represents the inode at `/proc/sys/kernel/domainname`.
pub struct DomainnameFileOps;

impl DomainnameFileOps {
    pub fn new_inode(parent: Weak<dyn Inode>) -> Arc<dyn Inode> {
        ProcFile::new(Self, parent, mkmod!(a+r))
    }
}

impl ProcFileOps for DomainnameFileOps {
    fn read_at(&self, offset: usize, writer: &mut VmWriter) -> Result<usize> {
        read_uts_name(offset, writer, UtsName::domainname)
    }
}

/// Represents the inode at `/proc/sys/kernel/osrelease`.
pub struct OsReleaseFileOps;

impl OsReleaseFileOps {
    pub fn new_inode(parent: Weak<dyn Inode>) -> Arc<dyn Inode> {
        ProcFile::new(Self, parent, mkmod!(a+r))
    }
}

impl ProcFileOps for OsReleaseFileOps {
    fn read_at(&self, offset: usize, writer: &mut VmWriter) -> Result<usize> {
        read_uts_name(offset, writer, UtsName::release)
    }
}

/// Represents the inode at `/proc/sys/kernel/version`.
pub struct VersionFileOps;

impl VersionFileOps {
    pub fn new_inode(parent: Weak<dyn Inode>) -> Arc<dyn Inode> {
        ProcFile::new(Self, parent, mkmod!(a+r))
    }
}

impl ProcFileOps for VersionFileOps {
    fn read_at(&self, offset: usize, writer: &mut VmWriter) -> Result<usize> {
        read_uts_name(offset, writer, UtsName::version)
    }
}

fn read_uts_name(
    offset: usize,
    writer: &mut VmWriter,
    get_value: impl FnOnce(&UtsName) -> &str,
) -> Result<usize> {
    let uts_ns = current_uts_namespace();
    let uts_name = uts_ns.uts_name();

    let mut printer = VmPrinter::new_skip(writer, offset);
    writeln!(printer, "{}", get_value(&uts_name))?;

    Ok(printer.bytes_written())
}

fn current_uts_namespace() -> Arc<UtsNamespace> {
    let Some(current_task) = Task::current() else {
        return UtsNamespace::get_init_singleton().clone();
    };
    let Some(thread_local) = current_task.as_thread_local() else {
        return UtsNamespace::get_init_singleton().clone();
    };
    let ns_proxy = thread_local.borrow_ns_proxy();
    ns_proxy.unwrap().uts_ns().clone()
}
