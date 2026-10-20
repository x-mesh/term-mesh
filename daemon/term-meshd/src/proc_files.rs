use std::path::PathBuf;

/// Paths of the regular files one process holds open.
///
/// Read straight from the kernel rather than through `lsof`: the callers run
/// on every token-broadcast tick, which the pane tracker already moved off
/// per-poll subprocesses. An unreadable process yields an empty list.
pub fn open_file_paths(pid: u32) -> Vec<PathBuf> {
    platform::open_file_paths(pid)
}

#[cfg(target_os = "macos")]
mod platform {
    use std::ffi::CStr;
    use std::path::PathBuf;

    // sys/proc_info.h. `libc` exposes `proc_pidfdinfo` but not this flavor or
    // the struct it fills.
    const PROC_PIDFDVNODEPATHINFO: libc::c_int = 2;

    #[repr(C)]
    struct ProcFileinfo {
        fi_openflags: u32,
        fi_status: u32,
        fi_offset: libc::off_t,
        fi_type: i32,
        fi_guardflags: u32,
    }

    #[repr(C)]
    struct VnodeFdinfoWithPath {
        pfi: ProcFileinfo,
        pvip: libc::vnode_info_path,
    }

    pub fn open_file_paths(pid: u32) -> Vec<PathBuf> {
        let Ok(pid) = libc::c_int::try_from(pid) else {
            return Vec::new();
        };
        let entry_size = std::mem::size_of::<libc::proc_fdinfo>();
        // SAFETY: a null buffer asks only for the byte count the list needs.
        let needed =
            unsafe { libc::proc_pidinfo(pid, libc::PROC_PIDLISTFDS, 0, std::ptr::null_mut(), 0) };
        if needed <= 0 {
            return Vec::new();
        }
        // Headroom for descriptors opened between the two calls.
        let capacity = needed as usize / entry_size + 16;
        let mut fds: Vec<libc::proc_fdinfo> = Vec::with_capacity(capacity);
        // SAFETY: `fds` owns `capacity` entries of writable storage, and the
        // kernel reports how many bytes it initialized.
        let written = unsafe {
            libc::proc_pidinfo(
                pid,
                libc::PROC_PIDLISTFDS,
                0,
                fds.as_mut_ptr().cast(),
                (capacity * entry_size) as libc::c_int,
            )
        };
        if written <= 0 {
            return Vec::new();
        }
        // SAFETY: the kernel initialized `written` bytes of whole entries.
        unsafe { fds.set_len((written as usize / entry_size).min(capacity)) };

        let info_size = std::mem::size_of::<VnodeFdinfoWithPath>();
        fds.iter()
            .filter(|fd| fd.proc_fdtype == libc::PROX_FDTYPE_VNODE as u32)
            .filter_map(|fd| {
                let mut info = std::mem::MaybeUninit::<VnodeFdinfoWithPath>::zeroed();
                // SAFETY: `info` is a writable buffer of exactly the size
                // passed; a short write is rejected before it is read.
                let got = unsafe {
                    libc::proc_pidfdinfo(
                        pid,
                        fd.proc_fd,
                        PROC_PIDFDVNODEPATHINFO,
                        info.as_mut_ptr().cast(),
                        info_size as libc::c_int,
                    )
                };
                if got as usize != info_size {
                    return None;
                }
                // SAFETY: fully written by the call above.
                let info = unsafe { info.assume_init() };
                // SAFETY: `vip_path` is MAXPATHLEN contiguous bytes (libc
                // splits the array only to support old compilers).
                let bytes = unsafe {
                    std::slice::from_raw_parts(
                        info.pvip.vip_path.as_ptr().cast::<u8>(),
                        std::mem::size_of_val(&info.pvip.vip_path),
                    )
                };
                let path = CStr::from_bytes_until_nul(bytes).ok()?.to_str().ok()?;
                (!path.is_empty()).then(|| PathBuf::from(path))
            })
            .collect()
    }
}

#[cfg(target_os = "linux")]
mod platform {
    use std::path::PathBuf;

    pub fn open_file_paths(pid: u32) -> Vec<PathBuf> {
        let Ok(entries) = std::fs::read_dir(format!("/proc/{pid}/fd")) else {
            return Vec::new();
        };
        entries
            .flatten()
            .filter_map(|entry| std::fs::read_link(entry.path()).ok())
            .filter(|path| path.is_absolute())
            .collect()
    }
}

#[cfg(not(any(target_os = "macos", target_os = "linux")))]
mod platform {
    use std::path::PathBuf;

    pub fn open_file_paths(_pid: u32) -> Vec<PathBuf> {
        Vec::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    #[test]
    fn lists_a_file_this_process_holds_open() {
        let mut file = tempfile::NamedTempFile::new().unwrap();
        writeln!(file, "held").unwrap();
        let held = file.path().canonicalize().unwrap();
        let open: Vec<PathBuf> = open_file_paths(std::process::id())
            .into_iter()
            .filter_map(|p| p.canonicalize().ok())
            .collect();
        assert!(open.contains(&held), "{held:?} not in {open:?}");
    }

    #[test]
    fn an_absent_process_has_no_open_files() {
        assert!(open_file_paths(u32::MAX).is_empty());
    }
}
