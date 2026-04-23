//! Raw-libc PTY helpers for peer-federation (Phase 2.3B).
//!
//! All functions here are thin wrappers around `forkpty(3)` / `read(2)` /
//! `write(2)` / `ioctl(TIOCSWINSZ)` / `kill(2)`. We keep this module free
//! of tokio so the surface-layer glue can make its own choice about how
//! to run the blocking read loop.

use std::ffi::CString;
use std::io;
use std::os::unix::io::RawFd;

pub struct PtyChild {
    pub master_fd: RawFd,
    pub pid: libc::pid_t,
}

/// Fork a child that runs `command` with `args` attached to a fresh PTY.
/// The caller owns `master_fd` and must close it when done; the child
/// is reaped by the caller via [`reap`] or by dropping [`PtySurface`].
pub fn spawn(command: &str, args: &[&str], cols: u16, rows: u16) -> io::Result<PtyChild> {
    // Allocate all CStrings before forking; in the child we can only
    // call async-signal-safe functions.
    let c_cmd = CString::new(command)
        .map_err(|_| io::Error::new(io::ErrorKind::InvalidInput, "command contains NUL"))?;
    let c_args: Vec<CString> = args
        .iter()
        .map(|a| CString::new(*a))
        .collect::<Result<_, _>>()
        .map_err(|_| io::Error::new(io::ErrorKind::InvalidInput, "arg contains NUL"))?;

    let mut argv: Vec<*const libc::c_char> = std::iter::once(c_cmd.as_ptr())
        .chain(c_args.iter().map(|s| s.as_ptr()))
        .collect();
    argv.push(std::ptr::null());

    let mut master_fd: RawFd = -1;
    let mut ws = libc::winsize {
        ws_row: rows,
        ws_col: cols,
        ws_xpixel: 0,
        ws_ypixel: 0,
    };

    // Safety: forkpty(3) requires valid out-pointer for master_fd and winsize.
    let pid = unsafe {
        libc::forkpty(
            &mut master_fd,
            std::ptr::null_mut(),
            std::ptr::null_mut(),
            &mut ws,
        )
    };

    if pid < 0 {
        return Err(io::Error::last_os_error());
    }

    if pid == 0 {
        // Child process: only async-signal-safe work from here on.
        // execvp replaces the image; if it returns, it failed.
        unsafe {
            libc::execvp(c_cmd.as_ptr(), argv.as_ptr());
            libc::_exit(127);
        }
    }

    Ok(PtyChild { master_fd, pid })
}

/// Blocking read from the master side. Returns `Ok(0)` on EOF
/// (which happens when the child closes its slave or exits and
/// the kernel drains). Returns `Err` on ioctl / read failures.
/// Set `O_NONBLOCK` on `fd`. Required when the fd is wrapped in
/// `tokio::io::unix::AsyncFd` — blocking syscalls on a registered fd defeat
/// the reactor.
pub fn set_nonblocking(fd: RawFd) -> io::Result<()> {
    // Safety: fcntl is always safe to call with a valid fd and these cmds.
    let flags = unsafe { libc::fcntl(fd, libc::F_GETFL, 0) };
    if flags < 0 {
        return Err(io::Error::last_os_error());
    }
    let rc = unsafe { libc::fcntl(fd, libc::F_SETFL, flags | libc::O_NONBLOCK) };
    if rc < 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(())
}

pub fn write(master_fd: RawFd, bytes: &[u8]) -> io::Result<usize> {
    // Safety: libc::write on a valid fd with a valid buffer.
    let n = unsafe { libc::write(master_fd, bytes.as_ptr() as *const _, bytes.len()) };
    if n < 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(n as usize)
}

pub fn resize(master_fd: RawFd, cols: u16, rows: u16) -> io::Result<()> {
    let ws = libc::winsize {
        ws_row: rows,
        ws_col: cols,
        ws_xpixel: 0,
        ws_ypixel: 0,
    };
    // Safety: ioctl with a correctly-sized winsize.
    let rc = unsafe { libc::ioctl(master_fd, libc::TIOCSWINSZ as _, &ws) };
    if rc != 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(())
}

/// Non-blocking check: has the child exited?
///
/// Returns `true` iff `waitpid(pid, _, WNOHANG)` reports the child has
/// terminated (rc > 0 means it was just reaped; rc < 0 means it was
/// already reaped elsewhere or there's no such pid — both count as
/// "not alive" from our perspective).
///
/// Used to distinguish a genuine PTY EOF/EIO from a transient startup
/// glitch: on macOS the master fd can momentarily report EIO during the
/// brief window between `fork(2)` and `execve(2)` in the child.
pub fn child_has_exited(pid: libc::pid_t) -> bool {
    let mut status = 0i32;
    // Safety: waitpid with WNOHANG is safe on any pid we own; we don't
    // care about the status value, only the return code.
    let rc = unsafe { libc::waitpid(pid, &mut status, libc::WNOHANG) };
    rc != 0
}

/// Best-effort graceful shutdown: SIGHUP the child, close the master fd,
/// and non-blocking reap. Any errors are swallowed; this is cleanup-path
/// code run from Drop.
pub fn teardown(master_fd: RawFd, pid: libc::pid_t) {
    // Safety: sending SIGHUP to a known PID; closing a fd we own; WNOHANG reap.
    unsafe {
        libc::kill(pid, libc::SIGHUP);
        libc::close(master_fd);
        let mut status = 0i32;
        libc::waitpid(pid, &mut status, libc::WNOHANG);
    }
}
