//! Raw-libc PTY helpers for peer-federation (Phase 2.3B).
//!
//! All functions here are thin wrappers around `forkpty(3)` / `read(2)` /
//! `write(2)` / `ioctl(TIOCSWINSZ)` / `kill(2)`. We keep this module free
//! of tokio so the surface-layer glue can make its own choice about how
//! to run the blocking read loop.

use std::ffi::CString;
use std::fs;
use std::io;
use std::os::unix::io::RawFd;
#[cfg(not(target_os = "linux"))]
use std::sync::{Mutex, MutexGuard};
use std::time::{Duration, Instant};

const EXEC_HANDSHAKE_TIMEOUT_MS: u64 = 1_000;
const STARTUP_GRACE_MS: u64 = 100;
const STARTUP_POLL_MS: u64 = 5;

const CHILD_STAGE_CHDIR: u8 = 1;
const CHILD_STAGE_EXEC: u8 = 2;

// Darwin has no pipe2(2). Serialize only this module's non-atomic
// pipe+fcntl+forkpty window so concurrent PTY spawns cannot inherit each
// other's handshake write fd. The bounded startup state machine remains the
// fail-closed defense for unrelated process spawns outside this lock.
#[cfg(not(target_os = "linux"))]
static FORK_FD_LOCK: Mutex<()> = Mutex::new(());

pub struct PtyChild {
    pub master_fd: RawFd,
    pub pid: libc::pid_t,
}

/// Fork a child that runs `command` with `args` attached to a fresh PTY,
/// optionally chdir'd to `cwd` before exec. The caller owns `master_fd`
/// and must close it when done; the child is reaped by the caller via
/// [`teardown`] or by dropping [`PtySurface`].
/// Spawn a child on a new PTY.
///
/// `env` entries are added to the environment this process runs with,
/// replacing any variable of the same name. A pane started without them
/// inherits whatever launched the daemon — under systemd that is a service
/// environment with no `TERM` at all, which leaves every program in the pane
/// unable to tell what terminal it is talking to.
pub fn spawn(
    command: &str,
    args: &[&str],
    cols: u16,
    rows: u16,
    cwd: Option<&str>,
    env: &[(String, String)],
) -> io::Result<PtyChild> {
    // Allocate all CStrings before forking; in the child we can only
    // call async-signal-safe functions.
    let c_cmd = CString::new(command)
        .map_err(|_| io::Error::new(io::ErrorKind::InvalidInput, "command contains NUL"))?;
    let c_args: Vec<CString> = args
        .iter()
        .map(|a| CString::new(*a))
        .collect::<Result<_, _>>()
        .map_err(|_| io::Error::new(io::ErrorKind::InvalidInput, "arg contains NUL"))?;
    let c_cwd = match cwd {
        Some(path) => {
            validate_cwd(path)?;
            Some(
                CString::new(path)
                    .map_err(|_| io::Error::new(io::ErrorKind::InvalidInput, "cwd contains NUL"))?,
            )
        }
        None => None,
    };

    let mut argv: Vec<*const libc::c_char> = std::iter::once(c_cmd.as_ptr())
        .chain(c_args.iter().map(|s| s.as_ptr()))
        .collect();
    argv.push(std::ptr::null());

    // Built here, before the fork, for the same reason as argv: assembling it
    // in the child would mean allocating, and the child may only call
    // async-signal-safe functions.
    let c_env = build_child_env(env)?;
    let mut envp: Vec<*const libc::c_char> = c_env.iter().map(|s| s.as_ptr()).collect();
    envp.push(std::ptr::null());

    let mut master_fd: RawFd = -1;
    let mut ws = libc::winsize {
        ws_row: rows,
        ws_col: cols,
        ws_xpixel: 0,
        ws_ypixel: 0,
    };

    // The write end is close-on-exec. A small fixed payload reports pre-exec
    // failures. The parent also watches the original pid and a fixed deadline:
    // a foreign process inheriting the write fd can delay EOF, but never spawn.
    #[cfg(not(target_os = "linux"))]
    let mut fork_fd_guard = Some(lock_fork_fd());
    let (exec_read_fd, exec_write_fd) = exec_handshake_pipe()?;

    // Safety: forkpty(3) requires valid out-pointer for master_fd and winsize.
    let pid = unsafe {
        libc::forkpty(
            &mut master_fd,
            std::ptr::null_mut(),
            std::ptr::null_mut(),
            &mut ws,
        )
    };
    let fork_error = (pid < 0).then(io::Error::last_os_error);

    if pid == 0 {
        // Do not unlock a copied pthread mutex in the child. exec/_exit drops
        // the private address space; the parent releases the real lock below.
        #[cfg(not(target_os = "linux"))]
        std::mem::forget(fork_fd_guard.take());

        // Child process: only async-signal-safe work from here on.
        unsafe {
            libc::close(exec_read_fd);
            if let Some(cwd_ptr) = c_cwd.as_ref().map(|c| c.as_ptr()) {
                if libc::chdir(cwd_ptr) != 0 {
                    let errno = current_errno();
                    report_child_failure(exec_write_fd, CHILD_STAGE_CHDIR, errno);
                    libc::_exit(126);
                }
            }
            // `execvp` reads the environment from the global `environ`, so
            // pointing that at the array built above is enough to hand the
            // child its environment. A pointer store rather than `setenv`,
            // which allocates and is not safe to call here.
            set_environ(envp.as_ptr());
            libc::execvp(c_cmd.as_ptr(), argv.as_ptr());
            let errno = current_errno();
            report_child_failure(exec_write_fd, CHILD_STAGE_EXEC, errno);
            libc::_exit(127);
        }
    }

    // The child of every LATER spawn must not inherit this master. forkpty(3)
    // hands it back with no close-on-exec flag, so without this each new pane
    // shell inherits every master opened before it: one surviving orphan then
    // pins dozens of PTYs instead of its own, and the ptmx table fills up long
    // after the surfaces themselves are gone.
    //
    // This MUST run while FORK_FD_LOCK is still held. The lock serializes the
    // fork window, so a concurrent spawn cannot fork between forkpty(3)
    // returning the fd and the flag being set; releasing the lock first would
    // leave exactly that gap, and a pane opened during it inherits the master
    // anyway — which is the whole bug. Best-effort otherwise, matching the
    // ghostty side (ghostty/src/pty.zig:153): a spawn that otherwise succeeded
    // must not fail because the flag could not be set.
    if fork_error.is_none() {
        unsafe {
            let flags = libc::fcntl(master_fd, libc::F_GETFD, 0);
            if flags >= 0 {
                libc::fcntl(master_fd, libc::F_SETFD, flags | libc::FD_CLOEXEC);
            }
        }
    }

    #[cfg(not(target_os = "linux"))]
    drop(fork_fd_guard.take());

    if let Some(error) = fork_error {
        close_fd(exec_read_fd);
        close_fd(exec_write_fd);
        return Err(error);
    }

    close_fd(exec_write_fd);
    if let Err(failure) = await_startup(
        exec_read_fd,
        pid,
        Duration::from_millis(EXEC_HANDSHAKE_TIMEOUT_MS),
        Duration::from_millis(STARTUP_GRACE_MS),
    ) {
        cleanup_failed_spawn(master_fd, pid, failure.child_reaped);
        return Err(failure.error);
    }

    Ok(PtyChild { master_fd, pid })
}

/// This process's environment with `overrides` applied, as `KEY=VALUE`
/// strings ready for `environ`.
///
/// Inherited rather than replaced: the daemon's environment is where the
/// child's `PATH`, `HOME` and locale come from, and a pane that lost those
/// would be broken in ways far louder than the missing terminal variables
/// this exists to add.
fn build_child_env(overrides: &[(String, String)]) -> io::Result<Vec<CString>> {
    let mut merged: Vec<(String, String)> = std::env::vars()
        .filter(|(key, _)| !overrides.iter().any(|(name, _)| name == key))
        .collect();
    merged.extend(overrides.iter().cloned());

    merged
        .into_iter()
        .map(|(key, value)| {
            CString::new(format!("{key}={value}")).map_err(|_| {
                io::Error::new(io::ErrorKind::InvalidInput, "env entry contains NUL")
            })
        })
        .collect()
}

/// Point the C library's `environ` at `envp`.
///
/// Safety: called only in the forked child, between fork and exec, where this
/// process is single-threaded and nothing else reads `environ`.
#[cfg(target_os = "macos")]
unsafe fn set_environ(envp: *const *const libc::c_char) {
    extern "C" {
        fn _NSGetEnviron() -> *mut *mut *mut libc::c_char;
    }
    *_NSGetEnviron() = envp as *mut *mut libc::c_char;
}

/// Point the C library's `environ` at `envp`. See the macOS variant.
#[cfg(not(target_os = "macos"))]
unsafe fn set_environ(envp: *const *const libc::c_char) {
    extern "C" {
        static mut environ: *mut *mut libc::c_char;
    }
    environ = envp as *mut *mut libc::c_char;
}

fn validate_cwd(path: &str) -> io::Result<()> {
    let metadata = fs::metadata(path).map_err(|error| match error.kind() {
        io::ErrorKind::NotFound => coded_error(io::ErrorKind::NotFound, "CWD_NOT_FOUND"),
        io::ErrorKind::PermissionDenied => {
            coded_error(io::ErrorKind::PermissionDenied, "CWD_PERMISSION_DENIED")
        }
        _ => error,
    })?;
    if !metadata.is_dir() {
        return Err(coded_error(
            io::ErrorKind::InvalidInput,
            "CWD_NOT_DIRECTORY",
        ));
    }

    let c_path = CString::new(path)
        .map_err(|_| io::Error::new(io::ErrorKind::InvalidInput, "cwd contains NUL"))?;
    // Search permission is required to enter a directory. This also catches
    // inaccessible ancestors before fork; the child repeats chdir for races.
    if unsafe { libc::access(c_path.as_ptr(), libc::X_OK) } != 0 {
        let error = io::Error::last_os_error();
        return Err(match error.raw_os_error() {
            Some(libc::ENOENT) => coded_error(io::ErrorKind::NotFound, "CWD_NOT_FOUND"),
            Some(libc::EACCES) => {
                coded_error(io::ErrorKind::PermissionDenied, "CWD_PERMISSION_DENIED")
            }
            _ => error,
        });
    }
    Ok(())
}

fn coded_error(kind: io::ErrorKind, code: &str) -> io::Error {
    io::Error::new(kind, code)
}

fn exec_handshake_pipe() -> io::Result<(RawFd, RawFd)> {
    let mut fds = [-1; 2];

    #[cfg(target_os = "linux")]
    if unsafe { libc::pipe2(fds.as_mut_ptr(), libc::O_CLOEXEC) } != 0 {
        return Err(io::Error::last_os_error());
    }

    #[cfg(not(target_os = "linux"))]
    if unsafe { libc::pipe(fds.as_mut_ptr()) } != 0 {
        return Err(io::Error::last_os_error());
    }

    #[cfg(not(target_os = "linux"))]
    for fd in fds {
        if unsafe { libc::fcntl(fd, libc::F_SETFD, libc::FD_CLOEXEC) } < 0 {
            let error = io::Error::last_os_error();
            close_fd(fds[0]);
            close_fd(fds[1]);
            return Err(error);
        }
    }
    if let Err(error) = set_nonblocking(fds[0]) {
        close_fd(fds[0]);
        close_fd(fds[1]);
        return Err(error);
    }
    Ok((fds[0], fds[1]))
}

#[cfg(not(target_os = "linux"))]
fn lock_fork_fd() -> MutexGuard<'static, ()> {
    FORK_FD_LOCK
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

unsafe fn report_child_failure(fd: RawFd, stage: u8, errno: i32) {
    let errno_bytes = errno.to_ne_bytes();
    let payload = [
        stage,
        errno_bytes[0],
        errno_bytes[1],
        errno_bytes[2],
        errno_bytes[3],
    ];
    let mut offset = 0;
    while offset < payload.len() {
        let written = libc::write(
            fd,
            payload[offset..].as_ptr().cast(),
            payload.len() - offset,
        );
        if written > 0 {
            offset += written as usize;
        } else if written < 0 && current_errno() == libc::EINTR {
            continue;
        } else {
            break;
        }
    }
}

#[cfg(target_os = "linux")]
unsafe fn current_errno() -> i32 {
    *libc::__errno_location()
}

#[cfg(any(
    target_os = "macos",
    target_os = "ios",
    target_os = "tvos",
    target_os = "watchos",
    target_os = "visionos"
))]
unsafe fn current_errno() -> i32 {
    *libc::__error()
}

#[cfg(not(any(
    target_os = "linux",
    target_os = "macos",
    target_os = "ios",
    target_os = "tvos",
    target_os = "watchos",
    target_os = "visionos"
)))]
unsafe fn current_errno() -> i32 {
    io::Error::last_os_error()
        .raw_os_error()
        .unwrap_or(libc::EIO)
}

fn read_handshake(fd: RawFd, payload: &mut [u8; 5], offset: &mut usize) -> io::Result<bool> {
    if *offset == payload.len() {
        return Ok(false);
    }
    loop {
        let read = unsafe {
            libc::read(
                fd,
                payload[*offset..].as_mut_ptr().cast(),
                payload.len() - *offset,
            )
        };
        if read > 0 {
            *offset += read as usize;
            if *offset == payload.len() {
                return Ok(false);
            }
            continue;
        }
        if read == 0 {
            return Ok(true);
        }
        let error = io::Error::last_os_error();
        match error.kind() {
            io::ErrorKind::Interrupted => continue,
            io::ErrorKind::WouldBlock => return Ok(false),
            _ => return Err(error),
        }
    }
}

struct StartupFailure {
    error: io::Error,
    child_reaped: bool,
}

fn startup_failure(error: io::Error, child_reaped: bool) -> StartupFailure {
    StartupFailure {
        error,
        child_reaped,
    }
}

fn await_startup(
    fd: RawFd,
    pid: libc::pid_t,
    handshake_timeout: Duration,
    startup_grace: Duration,
) -> Result<(), StartupFailure> {
    let mut payload = [0u8; 5];
    let mut offset = 0;
    let mut eof = false;
    let handshake_deadline = Instant::now() + handshake_timeout;
    let mut startup_deadline = None;

    loop {
        if !eof {
            match read_handshake(fd, &mut payload, &mut offset) {
                Ok(true) => {
                    eof = true;
                    startup_deadline = Some(Instant::now() + startup_grace);
                }
                Ok(false) => {}
                Err(error) => {
                    close_fd(fd);
                    return Err(startup_failure(error, false));
                }
            }
        }
        if offset == payload.len() {
            close_fd(fd);
            let errno = i32::from_ne_bytes(payload[1..5].try_into().unwrap());
            return Err(startup_failure(
                child_launch_error(payload[0], errno),
                false,
            ));
        }

        let mut status = 0;
        let wait_result = unsafe { libc::waitpid(pid, &mut status, libc::WNOHANG) };
        if wait_result == pid {
            // The original child cannot produce more bytes. Drain once more so
            // a failure payload wins over its generic exit status even when a
            // foreign process still holds another write fd open.
            if !eof {
                let _ = read_handshake(fd, &mut payload, &mut offset);
            }
            close_fd(fd);
            if offset == payload.len() {
                let errno = i32::from_ne_bytes(payload[1..5].try_into().unwrap());
                return Err(startup_failure(child_launch_error(payload[0], errno), true));
            }
            if offset != 0 {
                return Err(startup_failure(
                    coded_error(io::ErrorKind::InvalidData, "EXEC_HANDSHAKE_TRUNCATED"),
                    true,
                ));
            }
            return Err(startup_failure(command_exited_error(status), true));
        }
        if wait_result < 0 {
            let error = io::Error::last_os_error();
            if error.kind() == io::ErrorKind::Interrupted {
                continue;
            }
            close_fd(fd);
            let reaped_elsewhere = error.raw_os_error() == Some(libc::ECHILD);
            return Err(startup_failure(error, reaped_elsewhere));
        }

        let now = Instant::now();
        let deadline = startup_deadline.unwrap_or(handshake_deadline);
        if now >= deadline {
            close_fd(fd);
            return if eof {
                Ok(())
            } else {
                Err(startup_failure(
                    coded_error(io::ErrorKind::TimedOut, "EXEC_HANDSHAKE_TIMEOUT"),
                    false,
                ))
            };
        }

        let remaining = deadline.saturating_duration_since(now);
        let poll_for = remaining.min(Duration::from_millis(STARTUP_POLL_MS));
        if eof {
            std::thread::sleep(poll_for);
            continue;
        }

        let mut poll_fd = libc::pollfd {
            fd,
            events: libc::POLLIN | libc::POLLHUP,
            revents: 0,
        };
        let timeout_ms = poll_for.as_millis().max(1).min(i32::MAX as u128) as i32;
        let poll_result = unsafe { libc::poll(&mut poll_fd, 1, timeout_ms) };
        if poll_result < 0 {
            let error = io::Error::last_os_error();
            if error.kind() == io::ErrorKind::Interrupted {
                continue;
            }
            close_fd(fd);
            return Err(startup_failure(error, false));
        }
    }
}

fn child_launch_error(stage: u8, errno: i32) -> io::Error {
    match (stage, errno) {
        (CHILD_STAGE_CHDIR, libc::ENOENT) => coded_error(io::ErrorKind::NotFound, "CWD_NOT_FOUND"),
        (CHILD_STAGE_CHDIR, libc::ENOTDIR) => {
            coded_error(io::ErrorKind::InvalidInput, "CWD_NOT_DIRECTORY")
        }
        (CHILD_STAGE_CHDIR, libc::EACCES) => {
            coded_error(io::ErrorKind::PermissionDenied, "CWD_PERMISSION_DENIED")
        }
        (CHILD_STAGE_EXEC, libc::ENOENT) | (CHILD_STAGE_EXEC, libc::ENOTDIR) => {
            coded_error(io::ErrorKind::NotFound, "COMMAND_NOT_FOUND")
        }
        (CHILD_STAGE_EXEC, libc::EACCES) => {
            coded_error(io::ErrorKind::PermissionDenied, "COMMAND_PERMISSION_DENIED")
        }
        (CHILD_STAGE_CHDIR, _) => {
            io::Error::new(io::ErrorKind::Other, format!("CWD_ERROR({errno})"))
        }
        (CHILD_STAGE_EXEC, _) => {
            io::Error::new(io::ErrorKind::Other, format!("COMMAND_EXEC_ERROR({errno})"))
        }
        _ => coded_error(io::ErrorKind::InvalidData, "EXEC_HANDSHAKE_INVALID_STAGE"),
    }
}

fn command_exited_error(status: i32) -> io::Error {
    if libc::WIFEXITED(status) {
        return io::Error::new(
            io::ErrorKind::Other,
            format!("COMMAND_EXITED({})", libc::WEXITSTATUS(status)),
        );
    }
    if libc::WIFSIGNALED(status) {
        return io::Error::new(
            io::ErrorKind::Other,
            format!("COMMAND_SIGNALED({})", libc::WTERMSIG(status)),
        );
    }
    coded_error(io::ErrorKind::Other, "COMMAND_EXITED(unknown)")
}

fn cleanup_failed_spawn(master_fd: RawFd, pid: libc::pid_t, child_reaped: bool) {
    close_fd(master_fd);
    if child_reaped {
        return;
    }

    loop {
        let mut status = 0;
        let result = unsafe { libc::waitpid(pid, &mut status, libc::WNOHANG) };
        if result == pid
            || (result < 0 && io::Error::last_os_error().raw_os_error() == Some(libc::ECHILD))
        {
            return;
        }
        if result == 0 {
            break;
        }
        if io::Error::last_os_error().kind() != io::ErrorKind::Interrupted {
            return;
        }
    }

    unsafe {
        libc::kill(pid, libc::SIGKILL);
    }
    loop {
        let mut status = 0;
        let result = unsafe { libc::waitpid(pid, &mut status, 0) };
        if result == pid {
            return;
        }
        if result < 0 && io::Error::last_os_error().kind() == io::ErrorKind::Interrupted {
            continue;
        }
        return;
    }
}

fn close_fd(fd: RawFd) {
    unsafe {
        libc::close(fd);
    }
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

pub fn write_all(master_fd: RawFd, bytes: &[u8]) -> io::Result<()> {
    let mut offset = 0;
    while offset < bytes.len() {
        // Safety: libc::write on a valid fd with a valid buffer.
        let n = unsafe {
            libc::write(
                master_fd,
                bytes[offset..].as_ptr() as *const _,
                bytes.len() - offset,
            )
        };
        if n > 0 {
            offset += n as usize;
            continue;
        }
        if n == 0 {
            return Err(io::Error::new(
                io::ErrorKind::WriteZero,
                "PTY write returned 0",
            ));
        }
        let err = io::Error::last_os_error();
        match err.raw_os_error() {
            Some(libc::EINTR) => continue,
            Some(code) if code == libc::EAGAIN || code == libc::EWOULDBLOCK => {
                std::thread::sleep(Duration::from_millis(1));
                continue;
            }
            _ => return Err(err),
        }
    }
    Ok(())
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

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;
    use std::sync::{mpsc, Arc, Barrier};
    use std::thread;

    fn spawn_shell(cwd: Option<&str>, script: &str) -> io::Result<PtyChild> {
        spawn("/bin/sh", &["-c", script], 80, 24, cwd, &[])
    }

    fn expect_spawn_error(result: io::Result<PtyChild>) -> io::Error {
        match result {
            Ok(child) => {
                teardown(child.master_fd, child.pid);
                panic!("spawn unexpectedly succeeded")
            }
            Err(error) => error,
        }
    }

    fn fork_write_holder(read_fd: RawFd, write_fd: RawFd) -> libc::pid_t {
        let pid = unsafe { libc::fork() };
        assert!(pid >= 0);
        if pid == 0 {
            unsafe {
                libc::close(read_fd);
                libc::sleep(2);
                libc::close(write_fd);
                libc::_exit(0);
            }
        }
        pid
    }

    fn terminate_and_reap(pid: libc::pid_t) {
        unsafe {
            libc::kill(pid, libc::SIGKILL);
        }
        loop {
            let mut status = 0;
            let result = unsafe { libc::waitpid(pid, &mut status, 0) };
            if result == pid
                || (result < 0 && io::Error::last_os_error().raw_os_error() == Some(libc::ECHILD))
            {
                return;
            }
            if result < 0 && io::Error::last_os_error().kind() != io::ErrorKind::Interrupted {
                return;
            }
        }
    }

    #[test]
    fn rejects_missing_cwd_before_fork() {
        let temp = tempfile::tempdir().unwrap();
        let missing = temp.path().join("missing");
        let error = expect_spawn_error(spawn_shell(missing.to_str(), "sleep 1"));
        assert_eq!(error.kind(), io::ErrorKind::NotFound);
        assert_eq!(error.to_string(), "CWD_NOT_FOUND");
    }

    #[test]
    fn rejects_file_as_cwd_before_fork() {
        let file = tempfile::NamedTempFile::new().unwrap();
        let error = expect_spawn_error(spawn_shell(file.path().to_str(), "sleep 1"));
        assert_eq!(error.kind(), io::ErrorKind::InvalidInput);
        assert_eq!(error.to_string(), "CWD_NOT_DIRECTORY");
    }

    #[test]
    fn rejects_inaccessible_cwd_before_fork() {
        let temp = tempfile::tempdir().unwrap();
        let original = temp.path().metadata().unwrap().permissions();
        let mut inaccessible = original.clone();
        inaccessible.set_mode(0o600);
        fs::set_permissions(temp.path(), inaccessible).unwrap();

        let access_result = CString::new(temp.path().to_str().unwrap()).unwrap();
        let platform_rejects_access =
            unsafe { libc::access(access_result.as_ptr(), libc::X_OK) } != 0;
        let result = spawn_shell(temp.path().to_str(), "sleep 1");

        fs::set_permissions(temp.path(), original).unwrap();
        if platform_rejects_access {
            let error = expect_spawn_error(result);
            assert_eq!(error.kind(), io::ErrorKind::PermissionDenied);
            assert_eq!(error.to_string(), "CWD_PERMISSION_DENIED");
        } else if let Ok(child) = result {
            // Root can bypass mode bits on some platforms; avoid leaking the
            // child while keeping the test deterministic there.
            teardown(child.master_fd, child.pid);
        }
    }

    #[test]
    fn reports_missing_executable_from_exec_handshake() {
        let error = expect_spawn_error(spawn(
            "/definitely/not/a/term-mesh-command",
            &[],
            80,
            24,
            None,
            &[],
        ));
        assert_eq!(error.kind(), io::ErrorKind::NotFound);
        assert_eq!(error.to_string(), "COMMAND_NOT_FOUND");
    }

    #[test]
    fn reports_exit_during_startup_grace() {
        let error = expect_spawn_error(spawn_shell(None, "exit 42"));
        assert_eq!(error.to_string(), "COMMAND_EXITED(42)");
    }

    #[test]
    fn returns_child_that_survives_startup_grace() {
        let started = Instant::now();
        let child = spawn_shell(None, "sleep 1").unwrap();
        assert!(started.elapsed() < Duration::from_millis(190));
        assert!(!child_has_exited(child.pid));
        teardown(child.master_fd, child.pid);
    }

    #[test]
    fn handshake_pipe_is_close_on_exec_at_creation_boundary() {
        let (read_fd, write_fd) = exec_handshake_pipe().unwrap();
        for fd in [read_fd, write_fd] {
            let flags = unsafe { libc::fcntl(fd, libc::F_GETFD) };
            assert!(flags >= 0);
            assert_ne!(flags & libc::FD_CLOEXEC, 0);
            close_fd(fd);
        }
    }

    /// forkpty(3) returns the master with no close-on-exec flag, so every pane
    /// spawned later used to inherit every master opened before it: one orphan
    /// then pinned dozens of PTYs instead of its own and ptmx ran out.
    ///
    /// Asserts the outcome, not just the flag: the second child reports whether
    /// the FIRST child's master is present in its own post-exec fd table.
    ///
    /// Sequential spawns only, so this canNOT catch the flag being set too late
    /// (after the fork lock is released) — that window needs two spawns in
    /// flight at once. See `concurrent_spawns_do_not_leak_masters_into_children`.
    #[test]
    fn master_fd_is_close_on_exec_so_later_children_cannot_inherit_it() {
        let first = spawn_shell(None, "sleep 1").unwrap();
        let flags = unsafe { libc::fcntl(first.master_fd, libc::F_GETFD) };
        assert!(flags >= 0, "F_GETFD on the master fd failed");
        assert_ne!(
            flags & libc::FD_CLOEXEC,
            0,
            "master fd must be close-on-exec or later pane spawns inherit it"
        );

        // The probe runs after exec, so it sees exactly what was inherited.
        let probe = format!(
            "if [ -e /dev/fd/{fd} ]; then printf INHERITED; else printf CLEAN; fi; sleep 1",
            fd = first.master_fd
        );
        let second = spawn_shell(None, &probe).unwrap();

        let mut report = String::new();
        for _ in 0..50 {
            std::thread::sleep(Duration::from_millis(20));
            let mut buf = [0u8; 128];
            let n = unsafe {
                let fl = libc::fcntl(second.master_fd, libc::F_GETFL, 0);
                libc::fcntl(second.master_fd, libc::F_SETFL, fl | libc::O_NONBLOCK);
                libc::read(
                    second.master_fd,
                    buf.as_mut_ptr() as *mut libc::c_void,
                    buf.len(),
                )
            };
            if n > 0 {
                report.push_str(&String::from_utf8_lossy(&buf[..n as usize]));
            }
            if report.contains("CLEAN") || report.contains("INHERITED") {
                break;
            }
        }

        teardown(first.master_fd, first.pid);
        teardown(second.master_fd, second.pid);

        assert!(
            !report.contains("INHERITED"),
            "second child inherited the first child's master fd — got: {report:?}"
        );
        assert!(
            report.contains("CLEAN"),
            "probe never reported; cannot conclude the fd was not inherited — got: {report:?}"
        );
    }

    #[test]
    fn foreign_write_holder_causes_bounded_timeout_and_child_cleanup() {
        let (read_fd, write_fd) = exec_handshake_pipe().unwrap();
        let foreign_pid = fork_write_holder(read_fd, write_fd);
        let original_pid = unsafe { libc::fork() };
        assert!(original_pid >= 0);
        if original_pid == 0 {
            unsafe {
                libc::close(read_fd);
                libc::close(write_fd);
                libc::sleep(2);
                libc::_exit(0);
            }
        }
        close_fd(write_fd);

        let started = Instant::now();
        let failure = await_startup(
            read_fd,
            original_pid,
            Duration::from_millis(100),
            Duration::from_millis(100),
        )
        .unwrap_err();
        let elapsed = started.elapsed();

        assert_eq!(failure.error.kind(), io::ErrorKind::TimedOut);
        assert_eq!(failure.error.to_string(), "EXEC_HANDSHAKE_TIMEOUT");
        assert!(!failure.child_reaped);
        assert!(elapsed < Duration::from_millis(500));
        assert_eq!(unsafe { libc::fcntl(read_fd, libc::F_GETFD) }, -1);
        assert_eq!(io::Error::last_os_error().raw_os_error(), Some(libc::EBADF));

        let dev_null = CString::new("/dev/null").unwrap();
        let cleanup_fd = unsafe { libc::open(dev_null.as_ptr(), libc::O_RDONLY) };
        assert!(cleanup_fd >= 0);
        cleanup_failed_spawn(cleanup_fd, original_pid, failure.child_reaped);
        assert_eq!(unsafe { libc::fcntl(cleanup_fd, libc::F_GETFD) }, -1);
        assert_eq!(io::Error::last_os_error().raw_os_error(), Some(libc::EBADF));
        let mut status = 0;
        assert_eq!(
            unsafe { libc::waitpid(original_pid, &mut status, libc::WNOHANG) },
            -1
        );
        assert_eq!(
            io::Error::last_os_error().raw_os_error(),
            Some(libc::ECHILD)
        );
        terminate_and_reap(foreign_pid);
    }

    #[test]
    fn failure_payload_wins_while_foreign_process_holds_write_fd() {
        let (read_fd, write_fd) = exec_handshake_pipe().unwrap();
        let foreign_pid = fork_write_holder(read_fd, write_fd);
        let original_pid = unsafe { libc::fork() };
        assert!(original_pid >= 0);
        if original_pid == 0 {
            unsafe {
                libc::close(read_fd);
                report_child_failure(write_fd, CHILD_STAGE_EXEC, libc::ENOENT);
                libc::close(write_fd);
                libc::_exit(127);
            }
        }
        close_fd(write_fd);

        let started = Instant::now();
        let failure = await_startup(
            read_fd,
            original_pid,
            Duration::from_millis(100),
            Duration::from_millis(100),
        )
        .unwrap_err();
        let elapsed = started.elapsed();

        assert_eq!(failure.error.to_string(), "COMMAND_NOT_FOUND");
        assert!(elapsed < Duration::from_millis(500));
        if !failure.child_reaped {
            terminate_and_reap(original_pid);
        }
        terminate_and_reap(foreign_pid);
    }

    #[test]
    fn startup_grace_begins_when_exec_eof_is_observed() {
        let (read_fd, write_fd) = exec_handshake_pipe().unwrap();
        let original_pid = unsafe { libc::fork() };
        assert!(original_pid >= 0);
        if original_pid == 0 {
            unsafe {
                libc::close(read_fd);
                libc::usleep(150_000);
                libc::close(write_fd);
                libc::usleep(50_000);
                libc::_exit(42);
            }
        }
        close_fd(write_fd);

        let failure = await_startup(
            read_fd,
            original_pid,
            Duration::from_millis(500),
            Duration::from_millis(100),
        )
        .unwrap_err();

        assert_eq!(failure.error.to_string(), "COMMAND_EXITED(42)");
        assert!(failure.child_reaped);
    }

    #[test]
    /// A correctly spawned child holds only its own stdio (0/1/2); anything at
    /// fd 3+ was inherited from the parent, whatever opened it.
    ///
    /// Scope, measured rather than assumed: this does NOT detect FD_CLOEXEC
    /// being set after FORK_FD_LOCK is released. That regression was tried here
    /// and this test passed 3/3 — the exposed window is only the few
    /// microseconds between one spawn dropping the lock and setting the flag,
    /// and 8 racing threads never landed a fork inside it. Setting the flag
    /// under the lock removes the window by construction, which is why the code
    /// does that instead of relying on this test to catch it.
    #[test]
    fn concurrent_spawns_do_not_leak_masters_into_children() {
        const SPAWN_COUNT: usize = 8;
        let barrier = Arc::new(Barrier::new(SPAWN_COUNT));
        let (sender, receiver) = mpsc::channel();
        let mut threads = Vec::with_capacity(SPAWN_COUNT);

        // `[` and `for` are shell builtins, so the probe opens no fd of its own.
        let probe = "extra=; for fd in 3 4 5 6 7 8 9 10 11 12; do \
                     if [ -e /dev/fd/$fd ]; then extra=\"$extra $fd\"; fi; done; \
                     printf 'FDS:%s:END' \"$extra\"; sleep 1";

        for _ in 0..SPAWN_COUNT {
            let barrier = barrier.clone();
            let sender = sender.clone();
            threads.push(thread::spawn(move || {
                barrier.wait();
                let report = match spawn_shell(None, probe) {
                    Ok(child) => {
                        let mut out = String::new();
                        for _ in 0..50 {
                            thread::sleep(Duration::from_millis(20));
                            let mut buf = [0u8; 256];
                            let n = unsafe {
                                let fl = libc::fcntl(child.master_fd, libc::F_GETFL, 0);
                                libc::fcntl(child.master_fd, libc::F_SETFL, fl | libc::O_NONBLOCK);
                                libc::read(
                                    child.master_fd,
                                    buf.as_mut_ptr() as *mut libc::c_void,
                                    buf.len(),
                                )
                            };
                            if n > 0 {
                                out.push_str(&String::from_utf8_lossy(&buf[..n as usize]));
                            }
                            if out.contains(":END") {
                                break;
                            }
                        }
                        teardown(child.master_fd, child.pid);
                        Ok(out)
                    }
                    Err(error) => Err(error.to_string()),
                };
                sender.send(report).unwrap();
            }));
        }
        drop(sender);

        let mut reports = Vec::with_capacity(SPAWN_COUNT);
        for _ in 0..SPAWN_COUNT {
            reports.push(receiver.recv_timeout(Duration::from_secs(10)).unwrap());
        }
        for thread in threads {
            thread.join().unwrap();
        }

        for report in &reports {
            let out = report.as_ref().expect("concurrent spawn failed");
            let extra = out
                .split("FDS:")
                .nth(1)
                .and_then(|rest| rest.split(":END").next())
                .unwrap_or_else(|| panic!("probe never reported — got: {out:?}"));
            assert!(
                extra.trim().is_empty(),
                "child inherited fd(s){extra} from a concurrent spawn — \
                 FD_CLOEXEC must be set before FORK_FD_LOCK is released"
            );
        }
    }

    #[test]
    fn concurrent_spawns_do_not_hold_other_exec_handshakes_open() {
        const SPAWN_COUNT: usize = 8;
        let barrier = Arc::new(Barrier::new(SPAWN_COUNT));
        let (sender, receiver) = mpsc::channel();
        let mut threads = Vec::with_capacity(SPAWN_COUNT);

        for _ in 0..SPAWN_COUNT {
            let barrier = barrier.clone();
            let sender = sender.clone();
            threads.push(thread::spawn(move || {
                barrier.wait();
                let result: Result<(), String> = match spawn_shell(None, "sleep 1") {
                    Ok(child) => {
                        teardown(child.master_fd, child.pid);
                        Ok(())
                    }
                    Err(error) => Err(error.to_string()),
                };
                sender.send(result).unwrap();
            }));
        }
        drop(sender);

        for _ in 0..SPAWN_COUNT {
            let result = receiver.recv_timeout(Duration::from_secs(5)).unwrap();
            assert!(result.is_ok(), "concurrent spawn failed: {result:?}");
        }
        for thread in threads {
            thread.join().unwrap();
        }
    }
}
