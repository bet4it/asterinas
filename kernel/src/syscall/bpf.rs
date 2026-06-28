// SPDX-License-Identifier: MPL-2.0

use core::fmt::Display;

use ostd::mm::VmIo;

use super::SyscallReturn;
use crate::{
    events::IoEvents,
    fs::{
        file::{
            AccessMode, FileLike, StatusFlags,
            file_table::{FdFlags, RawFileDesc},
        },
        pseudofs::AnonInodeFs,
        vfs::path::Path,
    },
    prelude::*,
    process::signal::{PollHandle, Pollable},
};

const BPF_PROG_LOAD: u32 = 5;
const BPF_PROG_ATTACH: u32 = 8;
const BPF_PROG_DETACH: u32 = 9;
const BPF_PROG_QUERY: u32 = 16;

const BPF_PROG_TYPE_CGROUP_DEVICE: u32 = 15;
const BPF_CGROUP_DEVICE: u32 = 6;

const PROG_LOAD_PROG_TYPE_OFFSET: usize = 0;
const PROG_ATTACH_ATTACH_BPF_FD_OFFSET: usize = 4;
const PROG_ATTACH_ATTACH_TYPE_OFFSET: usize = 8;
const PROG_ATTACH_MIN_SIZE: u32 = 16;
const PROG_QUERY_ATTACH_TYPE_OFFSET: usize = 4;
const PROG_QUERY_ATTACH_FLAGS_OFFSET: usize = 12;
const PROG_QUERY_PROG_CNT_OFFSET: usize = 24;
const PROG_QUERY_MIN_SIZE: u32 = 28;

pub fn sys_bpf(cmd: u32, attr_addr: Vaddr, size: u32, ctx: &Context) -> Result<SyscallReturn> {
    debug!(
        "cmd = {}, attr_addr = 0x{:x}, size = {}",
        cmd, attr_addr, size
    );

    match cmd {
        BPF_PROG_QUERY => query_cgroup_device_programs(attr_addr, size, ctx),
        BPF_PROG_LOAD => load_cgroup_device_program(attr_addr, size, ctx),
        BPF_PROG_ATTACH => attach_cgroup_device_program(attr_addr, size, ctx),
        BPF_PROG_DETACH => detach_cgroup_device_program(attr_addr, size, ctx),
        _ => return_errno_with_message!(Errno::EINVAL, "unsupported bpf command"),
    }
}

fn query_cgroup_device_programs(
    attr_addr: Vaddr,
    size: u32,
    ctx: &Context,
) -> Result<SyscallReturn> {
    if size < PROG_QUERY_MIN_SIZE {
        return_errno_with_message!(Errno::EINVAL, "invalid BPF_PROG_QUERY attr size");
    }

    let user_space = ctx.user_space();
    let attach_type = user_space.read_val::<u32>(attr_addr + PROG_QUERY_ATTACH_TYPE_OFFSET)?;
    if attach_type != BPF_CGROUP_DEVICE {
        return_errno_with_message!(Errno::EINVAL, "unsupported bpf attach type");
    }

    let no_attached_programs = 0u32;
    user_space.write_val(
        attr_addr + PROG_QUERY_ATTACH_FLAGS_OFFSET,
        &no_attached_programs,
    )?;
    user_space.write_val(
        attr_addr + PROG_QUERY_PROG_CNT_OFFSET,
        &no_attached_programs,
    )?;

    Ok(SyscallReturn::Return(0))
}

fn load_cgroup_device_program(attr_addr: Vaddr, size: u32, ctx: &Context) -> Result<SyscallReturn> {
    if size < size_of::<u32>() as u32 {
        return_errno_with_message!(Errno::EINVAL, "invalid BPF_PROG_LOAD attr size");
    }

    let prog_type = ctx
        .user_space()
        .read_val::<u32>(attr_addr + PROG_LOAD_PROG_TYPE_OFFSET)?;
    if prog_type != BPF_PROG_TYPE_CGROUP_DEVICE {
        return_errno_with_message!(Errno::EINVAL, "unsupported bpf program type");
    }

    let program_file = BpfProgramFile::new();
    let file_table = ctx.thread_local.borrow_file_table();
    let mut file_table_locked = file_table.unwrap().write();
    let fd = file_table_locked.insert(Arc::new(program_file), FdFlags::CLOEXEC);

    Ok(SyscallReturn::Return(fd.into()))
}

fn attach_cgroup_device_program(
    attr_addr: Vaddr,
    size: u32,
    ctx: &Context,
) -> Result<SyscallReturn> {
    check_cgroup_device_program_attr(attr_addr, size, ctx)?;
    Ok(SyscallReturn::Return(0))
}

fn detach_cgroup_device_program(
    attr_addr: Vaddr,
    size: u32,
    ctx: &Context,
) -> Result<SyscallReturn> {
    check_cgroup_device_program_attr(attr_addr, size, ctx)?;
    Ok(SyscallReturn::Return(0))
}

fn check_cgroup_device_program_attr(attr_addr: Vaddr, size: u32, ctx: &Context) -> Result<()> {
    if size < PROG_ATTACH_MIN_SIZE {
        return_errno_with_message!(Errno::EINVAL, "invalid BPF_PROG_ATTACH attr size");
    }

    let user_space = ctx.user_space();
    let attach_bpf_fd = user_space.read_val::<u32>(attr_addr + PROG_ATTACH_ATTACH_BPF_FD_OFFSET)?;
    let attach_type = user_space.read_val::<u32>(attr_addr + PROG_ATTACH_ATTACH_TYPE_OFFSET)?;
    if attach_type != BPF_CGROUP_DEVICE {
        return_errno_with_message!(Errno::EINVAL, "unsupported bpf attach type");
    }

    let file_table = ctx.thread_local.borrow_file_table();
    let file_table_locked = file_table.unwrap().read();
    let raw_attach_bpf_fd = RawFileDesc::try_from(attach_bpf_fd)
        .map_err(|_| Error::with_message(Errno::EBADF, "the fd is too large"))?;
    let file = file_table_locked.get_file(raw_attach_bpf_fd.try_into()?)?;
    if file.downcast_ref::<BpfProgramFile>().is_none() {
        return_errno_with_message!(Errno::EINVAL, "the fd is not a bpf program");
    }

    Ok(())
}

struct BpfProgramFile {
    pseudo_path: Path,
}

impl BpfProgramFile {
    fn new() -> Self {
        Self {
            pseudo_path: AnonInodeFs::new_path(|_| "anon_inode:[bpf-prog]".to_string()),
        }
    }
}

impl Pollable for BpfProgramFile {
    fn poll(&self, mask: IoEvents, _poller: Option<&mut PollHandle>) -> IoEvents {
        IoEvents::empty() & mask
    }
}

impl FileLike for BpfProgramFile {
    fn status_flags(&self) -> StatusFlags {
        StatusFlags::empty()
    }

    fn access_mode(&self) -> AccessMode {
        AccessMode::O_RDWR
    }

    fn path(&self) -> &Path {
        &self.pseudo_path
    }

    fn dump_proc_fdinfo(self: Arc<Self>, fd_flags: FdFlags) -> Box<dyn Display> {
        struct FdInfo {
            inner: Arc<BpfProgramFile>,
            fd_flags: FdFlags,
        }

        impl Display for FdInfo {
            fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
                let mut flags = self.inner.status_flags().bits() | self.inner.access_mode() as u32;
                if self.fd_flags.contains(FdFlags::CLOEXEC) {
                    flags |= crate::fs::file::CreationFlags::O_CLOEXEC.bits();
                }

                writeln!(f, "pos:\t{}", 0)?;
                writeln!(f, "flags:\t0{:o}", flags)?;
                writeln!(f, "mnt_id:\t{}", AnonInodeFs::mount_node().id())?;
                writeln!(f, "ino:\t{}", AnonInodeFs::shared_inode().ino())
            }
        }

        Box::new(FdInfo {
            inner: self,
            fd_flags,
        })
    }
}
