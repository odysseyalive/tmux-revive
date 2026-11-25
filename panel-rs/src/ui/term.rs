//! The terminal, as scripts/panel.sh sets it up for the live panel (`:5340-5361`): stderr to
//! panel.err, the alternate screen with the cursor hidden, `stty -echo -icanon` (ISIG and ICRNL
//! left on: Ctrl-C is SIGINT, Enter is \n), the settings it found put back on the way out
//! (restore_term), and the signals it traps (INT and TERM end it, WINCH repaints it) through a
//! self-pipe the UI loop polls.

use crate::compat::Bytes;
use std::os::fd::RawFd;
use std::sync::atomic::{AtomicI32, Ordering};
use std::time::Duration;

/// The terminal went away under a read: the panel ends
pub static GONE: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);

/// The write end of the signals' self-pipe (-1 before it is made)
static SIG_W: AtomicI32 = AtomicI32::new(-1);

extern "C" fn on_signal(sig: libc::c_int) {
    let fd = SIG_W.load(Ordering::Relaxed);
    if fd >= 0 {
        let b: u8 = match sig {
            libc::SIGWINCH => b'W',
            libc::SIGINT => b'I', // exit 0, but not while bash has the terminal (its own trap)
            _ => b'X',            // TERM, HUP: exit 0, always
        };
        unsafe {
            libc::write(fd, &b as *const u8 as *const libc::c_void, 1);
        }
    }
}

/// A pipe, both ends close-on-exec and non-blocking -> (read, write)
pub fn pipe() -> (RawFd, RawFd) {
    let mut p = [0 as libc::c_int; 2];
    unsafe {
        if libc::pipe(p.as_mut_ptr()) != 0 {
            panic!("pipe");
        }
        for fd in p {
            libc::fcntl(fd, libc::F_SETFD, libc::FD_CLOEXEC);
            let fl = libc::fcntl(fd, libc::F_GETFL);
            libc::fcntl(fd, libc::F_SETFL, fl | libc::O_NONBLOCK);
        }
    }
    (p[0], p[1])
}

/// The signals' self-pipe: INT, TERM and HUP (bash: `trap 'exit 0' INT TERM`, and HUP ends it
/// too) and WINCH. -> its read end
pub fn signals() -> RawFd {
    let (r, w) = pipe();
    SIG_W.store(w, Ordering::Relaxed);
    for s in [libc::SIGINT, libc::SIGTERM, libc::SIGHUP, libc::SIGWINCH] {
        unsafe {
            let mut sa: libc::sigaction = std::mem::zeroed();
            sa.sa_sigaction = on_signal as *const () as usize;
            sa.sa_flags = libc::SA_RESTART;
            libc::sigemptyset(&mut sa.sa_mask);
            libc::sigaction(s, &sa, std::ptr::null_mut());
        }
    }
    r
}

/// What a pipe holds now, read without waiting
pub fn drain(fd: RawFd) -> Bytes {
    let mut v = Vec::new();
    let mut b = [0u8; 64];
    loop {
        let n = unsafe { libc::read(fd, b.as_mut_ptr() as *mut libc::c_void, b.len()) };
        if n <= 0 {
            break;
        }
        v.extend_from_slice(&b[..n as usize]);
    }
    v
}

/// One byte on the pipe, never waiting (a full pipe already wakes the reader)
pub fn poke(fd: RawFd) {
    let b = [1u8];
    unsafe {
        libc::write(fd, b.as_ptr() as *const libc::c_void, 1);
    }
}

/// Write it all to the terminal (fd 1), as printf does: a full or interrupted write goes on
pub fn out(b: &[u8]) {
    let mut s = b;
    while !s.is_empty() {
        let n = unsafe { libc::write(1, s.as_ptr() as *const libc::c_void, s.len()) };
        if n < 0 {
            let e = std::io::Error::last_os_error();
            if e.kind() == std::io::ErrorKind::Interrupted || e.kind() == std::io::ErrorKind::WouldBlock {
                continue;
            }
            return;
        }
        s = &s[n as usize..];
    }
}

/// tput cols, tput lines: the terminal's size, else None (bash falls back to its defaults)
pub fn size() -> Option<(i64, i64)> {
    let mut ws: libc::winsize = unsafe { std::mem::zeroed() };
    for fd in [1, 0, 2] {
        if unsafe { libc::ioctl(fd, libc::TIOCGWINSZ, &mut ws) } == 0 && ws.ws_col > 0 && ws.ws_row > 0 {
            return Some((ws.ws_col as i64, ws.ws_row as i64));
        }
    }
    None
}

/// `[[ -t 0 && -t 1 ]]`
pub fn is_tty() -> bool {
    unsafe { libc::isatty(0) == 1 && libc::isatty(1) == 1 }
}

/// STTY_SAVED: the terminal's settings when the panel started, put back by restore_term
pub struct Saved(Option<libc::termios>);

impl Saved {
    /// STTY_SAVED=$(stty -g)
    pub fn take() -> Saved {
        let mut t: libc::termios = unsafe { std::mem::zeroed() };
        if unsafe { libc::tcgetattr(0, &mut t) } == 0 {
            Saved(Some(t))
        } else {
            Saved(None)
        }
    }
    /// stty -echo -icanon: only those two flags, as stty clears them
    pub fn raw_ish(&self) {
        if let Some(t) = self.0 {
            let mut r = t;
            r.c_lflag &= !(libc::ECHO | libc::ICANON);
            unsafe {
                libc::tcsetattr(0, libc::TCSADRAIN, &r);
            }
        }
    }
    /// stty "$STTY_SAVED"
    pub fn put_back(&self) {
        if let Some(t) = self.0 {
            unsafe {
                libc::tcsetattr(0, libc::TCSADRAIN, &t);
            }
        }
    }
}

/// edit_box's `stty -icrnl -isig`, on top of what is set now: Enter comes as CR (Ctrl-J as LF)
/// and Ctrl-C as the byte 0x03. -> what to put back (`stty "$otty"`), None with no terminal.
pub fn eb_mode() -> Option<libc::termios> {
    let mut t: libc::termios = unsafe { std::mem::zeroed() };
    if unsafe { libc::tcgetattr(0, &mut t) } != 0 {
        return None;
    }
    let mut r = t;
    r.c_iflag &= !libc::ICRNL;
    r.c_lflag &= !libc::ISIG;
    unsafe { libc::tcsetattr(0, libc::TCSADRAIN, &r) };
    Some(t)
}

/// `stty "$otty"`: the settings eb_mode found, back
pub fn set_mode(t: &libc::termios) {
    unsafe { libc::tcsetattr(0, libc::TCSADRAIN, t) };
}

/// restore_term: the settings put back, the cursor shown, the normal screen again
pub fn restore(saved: &Saved) {
    saved.put_back();
    out(b"\x1b[?25h\x1b[?1049l");
}

/// A panic anywhere (a collector's thread too) ends the panel as an error in bash would: the
/// terminal put back first, the message to stderr (panel.err), exit 1
pub fn on_panic(saved: &Saved) {
    let t = saved.0;
    let def = std::panic::take_hook();
    std::panic::set_hook(Box::new(move |info| {
        if let Some(t) = t {
            unsafe {
                libc::tcsetattr(0, libc::TCSADRAIN, &t);
            }
        }
        out(b"\x1b[?25h\x1b[?1049l");
        def(info);
        std::process::exit(1);
    }));
}

/// The alternate screen, the cursor hidden, the screen cleared (`:5351`)
pub fn enter() {
    out(b"\x1b[?1049h\x1b[?25l\x1b[2J");
}

/// The keys, from fd 0 one byte at a time (as bash's read takes them, so nothing is read ahead
/// that the send worker, answering, would miss: it reads fd 0 itself)
pub struct Stdin;

impl super::keys::Src for Stdin {
    fn byte(&mut self, t: Duration) -> Option<u8> {
        if !wait_readable(0, Some(t)) {
            return None;
        }
        let mut b = 0u8;
        loop {
            let n = unsafe { libc::read(0, &mut b as *mut u8 as *mut libc::c_void, 1) };
            if n == 1 {
                return Some(b);
            }
            if n < 0 && std::io::Error::last_os_error().kind() == std::io::ErrorKind::Interrupted {
                continue;
            }
            // The terminal is gone (EOF, or EIO from a hung-up pty): as bash dies with it
            GONE.store(true, Ordering::Relaxed);
            return None;
        }
    }
}

/// poll one fd for input within T (None: no limit)
pub fn wait_readable(fd: RawFd, t: Option<Duration>) -> bool {
    let mut p = libc::pollfd { fd, events: libc::POLLIN, revents: 0 };
    let ms: libc::c_int = match t {
        None => -1,
        Some(d) => d.as_millis().min(i32::MAX as u128) as libc::c_int,
    };
    loop {
        let r = unsafe { libc::poll(&mut p, 1, ms) };
        if r < 0 && std::io::Error::last_os_error().kind() == std::io::ErrorKind::Interrupted {
            // a signal (WINCH): the caller's loop sees it on the self-pipe; a read that waits
            // goes on waiting the rest of its time, near enough
            continue;
        }
        return r > 0 && p.revents & (libc::POLLIN | libc::POLLHUP | libc::POLLERR) != 0;
    }
}

/// panel.err: stderr to a file of this user's alone in RDIR, emptied once it passes 64 KB
/// (`:5345-5350`), so nothing but the frames reaches the screen
pub fn stderr_to(file: &[u8]) {
    use std::os::unix::fs::OpenOptionsExt;
    let p = crate::collect::sh::os(file);
    if std::fs::metadata(p).map(|m| m.len() > 64 * 1024).unwrap_or(false) {
        let _ = std::fs::remove_file(p);
    }
    let f = std::fs::OpenOptions::new().create(true).append(true).mode(0o600).open(p);
    match f {
        Ok(f) => {
            use std::os::fd::IntoRawFd;
            let fd = f.into_raw_fd();
            unsafe {
                libc::dup2(fd, 2);
                libc::close(fd);
            }
        }
        Err(_) => {
            // exec 2>/dev/null
            if let Ok(f) = std::fs::OpenOptions::new().write(true).open("/dev/null") {
                use std::os::fd::IntoRawFd;
                let fd = f.into_raw_fd();
                unsafe {
                    libc::dup2(fd, 2);
                    libc::close(fd);
                }
            }
        }
    }
}
