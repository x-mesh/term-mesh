use std::ffi::CString;
use std::io::{self, Write};
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::thread;

/// Run a command inside a PTY, forwarding all I/O.
/// Returns (exit_code, child_pid).
/// If `cwd` is Some, the child process changes to that directory before exec.
pub fn run_with_pty(cmd: &str, args: &[&str], cwd: Option<&str>) -> Result<(i32, u32), String> {
    // Open a PTY pair
    let (master_fd, slave_fd) = open_pty().map_err(|e| format!("openpty: {}", e))?;

    // Fork
    let pid = unsafe { libc::fork() };
    if pid < 0 {
        return Err("fork failed".to_string());
    }

    if pid == 0 {
        // ── Child process ──
        drop(master_fd);

        // Create new session
        unsafe { libc::setsid() };

        // Set controlling terminal
        unsafe { libc::ioctl(slave_fd.as_raw_fd(), libc::TIOCSCTTY as _, 0) };

        // Dup slave to stdin/stdout/stderr
        let slave_raw = slave_fd.as_raw_fd();
        unsafe {
            libc::dup2(slave_raw, 0);
            libc::dup2(slave_raw, 1);
            libc::dup2(slave_raw, 2);
        }
        if slave_raw > 2 {
            drop(slave_fd);
        }

        // Change working directory if requested
        if let Some(dir) = cwd {
            let c_dir = CString::new(dir).unwrap();
            if unsafe { libc::chdir(c_dir.as_ptr()) } != 0 {
                eprintln!("term-mesh: failed to chdir to '{}': {}", dir, io::Error::last_os_error());
                unsafe { libc::_exit(126) };
            }
        }

        // Exec the command
        let c_cmd = CString::new(cmd).unwrap();
        let mut c_args: Vec<CString> = vec![c_cmd.clone()];
        for arg in args {
            c_args.push(CString::new(*arg).unwrap());
        }
        let c_argv: Vec<*const libc::c_char> = c_args
            .iter()
            .map(|a| a.as_ptr())
            .chain(std::iter::once(std::ptr::null()))
            .collect();

        // Try execvp (search PATH)
        unsafe { libc::execvp(c_cmd.as_ptr(), c_argv.as_ptr()) };

        // If exec fails
        eprintln!("term-mesh: failed to exec '{}': {}", cmd, io::Error::last_os_error());
        unsafe { libc::_exit(127) };
    }

    // ── Parent process ──
    let child_pid = pid as u32;
    drop(slave_fd);

    // Set terminal to raw mode
    let orig_termios = set_raw_mode(libc::STDIN_FILENO);

    // Copy current terminal size to PTY
    copy_winsize(libc::STDIN_FILENO, master_fd.as_raw_fd());

    // Handle SIGWINCH (terminal resize)
    let master_raw = master_fd.as_raw_fd();
    let running = Arc::new(AtomicBool::new(true));

    // Install SIGWINCH handler
    install_sigwinch_handler(master_raw);

    // Spawn stdin→master forwarding thread
    let stdin_running = running.clone();
    let master_raw_for_stdin = master_fd.as_raw_fd();
    let _stdin_thread = thread::spawn(move || {
        let mut buf = [0u8; 4096];
        while stdin_running.load(Ordering::Relaxed) {
            let n = unsafe { libc::read(libc::STDIN_FILENO, buf.as_mut_ptr() as _, buf.len()) };
            if n <= 0 {
                break;
            }
            let written = unsafe { libc::write(master_raw_for_stdin, buf.as_ptr() as _, n as usize) };
            if written <= 0 {
                break;
            }
        }
    });

    // Main thread: master→stdout forwarding
    let mut stdout = io::stdout();
    let mut buf = [0u8; 8192];
    let exit_code;

    loop {
        let n = unsafe { libc::read(master_fd.as_raw_fd(), buf.as_mut_ptr() as _, buf.len()) };
        if n <= 0 {
            break;
        }
        let chunk = &buf[..n as usize];
        let _ = stdout.write_all(chunk);
        let _ = stdout.flush();
    }

    // Wait for child
    let mut status: libc::c_int = 0;
    unsafe { libc::waitpid(pid, &mut status, 0) };

    if libc::WIFEXITED(status) {
        exit_code = libc::WEXITSTATUS(status);
    } else {
        exit_code = 1;
    }

    // Cleanup
    running.store(false, Ordering::Relaxed);

    // Restore terminal
    if let Some(termios) = orig_termios {
        restore_termios(libc::STDIN_FILENO, &termios);
    }

    Ok((exit_code, child_pid))
}

/// Open a PTY master/slave pair.
fn open_pty() -> Result<(OwnedFd, OwnedFd), io::Error> {
    let mut master: libc::c_int = 0;
    let mut slave: libc::c_int = 0;

    let ret = unsafe {
        libc::openpty(
            &mut master,
            &mut slave,
            std::ptr::null_mut(),
            std::ptr::null_mut(),
            std::ptr::null_mut(),
        )
    };

    if ret != 0 {
        return Err(io::Error::last_os_error());
    }

    Ok(unsafe { (OwnedFd::from_raw_fd(master), OwnedFd::from_raw_fd(slave)) })
}

/// Set stdin to raw mode, returning the original termios for restoration.
fn set_raw_mode(fd: libc::c_int) -> Option<libc::termios> {
    if unsafe { libc::isatty(fd) } != 1 {
        return None;
    }

    let mut orig = unsafe { std::mem::zeroed::<libc::termios>() };
    if unsafe { libc::tcgetattr(fd, &mut orig) } != 0 {
        return None;
    }

    let mut raw = orig;
    unsafe { libc::cfmakeraw(&mut raw) };

    if unsafe { libc::tcsetattr(fd, libc::TCSANOW, &raw) } != 0 {
        return None;
    }

    Some(orig)
}

/// Restore terminal settings.
fn restore_termios(fd: libc::c_int, termios: &libc::termios) {
    unsafe { libc::tcsetattr(fd, libc::TCSANOW, termios) };
}

/// Copy terminal window size from src_fd to dst_fd.
fn copy_winsize(src_fd: libc::c_int, dst_fd: libc::c_int) {
    let mut ws = unsafe { std::mem::zeroed::<libc::winsize>() };
    if unsafe { libc::ioctl(src_fd, libc::TIOCGWINSZ as _, &mut ws) } == 0 {
        unsafe { libc::ioctl(dst_fd, libc::TIOCSWINSZ as _, &ws) };
    }
}

/// Install SIGWINCH handler that copies window size to the PTY master.
fn install_sigwinch_handler(master_fd: libc::c_int) {
    MASTER_FD.store(master_fd, Ordering::Relaxed);

    unsafe {
        let mut sa: libc::sigaction = std::mem::zeroed();
        sa.sa_sigaction = sigwinch_handler as *const () as usize;
        sa.sa_flags = libc::SA_RESTART;
        libc::sigaction(libc::SIGWINCH, &sa, std::ptr::null_mut());
    }
}

static MASTER_FD: std::sync::atomic::AtomicI32 = std::sync::atomic::AtomicI32::new(-1);

extern "C" fn sigwinch_handler(_sig: libc::c_int) {
    let master_fd = MASTER_FD.load(Ordering::Relaxed);
    if master_fd >= 0 {
        copy_winsize(libc::STDIN_FILENO, master_fd);
    }
}
