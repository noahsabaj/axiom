//! The network, for a program given it (wants::NET, or +net): TCP
//! connections by host and port, through TLS if asked, and ports listened
//! on, as the kernel's sockets (socket.asm) have them.
//!
//! A socket has 64 KiB each way in the kernel, which the kernel moves to
//! and from TCP. Nothing here waits unless it says so: `send` takes what
//! fits (Error::FULL if nothing does), `recv` gives what came
//! (Error::EMPTY if nothing has); `wait_send` and `wait_recv` wait for that
//! to change. Error::PEER once the other side has finished and all of it
//! is read (recv), or nothing more can be sent; Error::NET once it failed,
//! `status` saying why. A connection is made at once and goes on in the
//! kernel (the lookup, the connection, TLS's handshake): `wait_send` waits
//! until it is open, or never will be.
//!
//! A host is a name, an IPv4 address or an IPv6 one; a capability may
//! reach only some hosts, or one port (Net::sub).

use core::net::{IpAddr, Ipv6Addr};

use crate::ring::{self, State};
use crate::rt;
use crate::sys::*;
use crate::time::Instant;

/// A handle to the network: all of it, or what a narrower one reaches.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub struct Net {
    h: Handle,
}

/// How a connection goes.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Tls {
    /// Plain TCP.
    No,
    /// TLS, the server's certificate checked.
    Checked,
    /// TLS, not checked.
    Insecure,
}

/// `host` as a field in the io block's first SK_HOST_MAX bytes.
fn host_in(r: &mut State, host: &str) -> Result<Handle> {
    if host.is_empty() || host.len() >= SK_HOST_MAX || host.as_bytes().contains(&0) {
        return Err(Error::ARG);
    }
    let (p, io) = r.io(SK_HOST_MAX)?;
    unsafe {
        core::ptr::write_bytes(p, 0, SK_HOST_MAX);
        core::ptr::copy_nonoverlapping(host.as_ptr(), p, host.len());
    }
    Ok(io)
}

impl Net {
    /// The program's own (SB_NET).
    pub fn get() -> Result<Net> {
        match rt::net_handle() {
            0 => Err(Error::ABSENT),
            h => Ok(Net { h }),
        }
    }

    /// One given by handle (another program's gift).
    pub const fn from_handle(h: Handle) -> Net {
        Net { h }
    }

    pub fn handle(self) -> Handle {
        self.h
    }

    fn host_op(self, host: &str, port: u16, flags: u64) -> Result<Socket> {
        let mut r = ring::lock();
        let io = host_in(&mut r, host)?;
        let mut e = Entry::new(RO_NET_CONNECT, self.h);
        e.handle2 = io;
        e.a1 = port as u64;
        e.a2 = flags;
        r.call(&e).map(|v| Socket { h: v.0 as Handle })
    }

    /// A connection to `host`, being made (wait_send until it is open).
    pub fn connect(self, host: &str, port: u16, tls: Tls) -> Result<Socket> {
        let flags = match tls {
            Tls::No => 0,
            Tls::Checked => NETF_TLS,
            Tls::Insecure => NETF_TLS | NETF_INSECURE,
        };
        self.host_op(host, port, flags)
    }

    /// `host` looked up, and no more: the socket ends once its address is
    /// known (wait_recv), for `addrs` to say (its `peer`).
    pub fn lookup(self, host: &str) -> Result<Socket> {
        self.host_op(host, 0, NETF_LOOKUP)
    }

    /// A port listened on; 0 for one of ours that is free. Whether it
    /// could be, it says once it has tried (wait_send, then status); then
    /// `accept` takes each connection, wait_recv waiting for the next.
    pub fn listen(self, port: u16) -> Result<Socket> {
        let mut e = Entry::new(RO_NET_LISTEN, self.h);
        e.a0 = port as u64;
        ring::call(&e).map(|v| Socket { h: v.0 as Handle })
    }

    /// A narrower one: hosts matching `pattern` ("api.example.com",
    /// "*.example.com", "" for any), one port (0: any), with only `rights`
    /// (RT_NET_*, RT_DUP, RT_GIVE...).
    pub fn sub(self, pattern: &str, port: u16, rights: u32) -> Result<Net> {
        const NT_PATTERN_MAX: usize = 64;
        if pattern.len() >= NT_PATTERN_MAX || pattern.as_bytes().contains(&0) {
            return Err(Error::ARG);
        }
        let mut r = ring::lock();
        let (p, io) = r.io(NT_PATTERN_MAX)?;
        unsafe {
            core::ptr::write_bytes(p, 0, NT_PATTERN_MAX);
            core::ptr::copy_nonoverlapping(pattern.as_ptr(), p, pattern.len());
        }
        let mut e = Entry::new(RO_NET_SUB, self.h);
        e.handle2 = io;
        e.a1 = port as u64;
        e.a2 = rights as u64;
        r.call(&e).map(|v| Net { h: v.0 as Handle })
    }
}

/// Where a socket's state is (RO_NET_STATUS).
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub struct Status {
    /// SKS_*
    pub state: u32,
    /// NETW_*, once it failed
    pub why: u32,
    /// TLS's error, for NETW_TLS
    pub tls_error: u32,
    /// Something to receive, or nothing more ever will be: recv won't say
    /// EMPTY.
    pub can_recv: bool,
    /// Room to send, or never again: send won't say FULL. A listener: it
    /// listens, or failed.
    pub can_send: bool,
}

impl Status {
    pub fn failed(&self) -> bool {
        self.state == SKS_FAILED
    }
}

/// What NETW_* says, in a few words.
pub fn why_text(why: u32) -> &'static str {
    match why {
        NETW_NOSERVER => "no DNS server is known",
        NETW_BADNAME => "not a host name",
        NETW_BUSY => "too many lookups at once",
        NETW_NOHOST => "no such host",
        NETW_NOADDR => "the host has no address we can reach",
        NETW_DNS => "the DNS server could not answer",
        NETW_NOANSWER => "no answer from the DNS server",
        NETW_DOWN => "no network, or no address on it",
        NETW_NOROUTE => "no connection free, or no route",
        NETW_REFUSED => "refused",
        NETW_RESET => "reset",
        NETW_TIMEOUT => "timed out",
        NETW_TLS => "TLS failed",
        NETW_INUSE => "the port is listened on already",
        _ => "failed",
    }
}

/// A socket's addresses and ports (RO_NET_ADDR): 16 bytes each, IPv4 as
/// ::ffff:a.b.c.d (`ip` makes them IpAddrs).
#[derive(Clone, Copy, PartialEq, Eq, Debug, Default)]
pub struct Addrs {
    /// The other side's: the host's, for a lookup; none for a listener.
    pub peer: [u8; 16],
    pub peer_port: u16,
    /// Ours (none until it connects, nor for a listener).
    pub local: [u8; 16],
    /// Ours: a listener's own, once it listens.
    pub port: u16,
}

/// An address as the kernel keeps it -> an IpAddr: IPv4 if it is one.
pub fn ip(a: [u8; 16]) -> IpAddr {
    let v6 = Ipv6Addr::from(a);
    match v6.to_ipv4_mapped() {
        Some(v4) => IpAddr::V4(v4),
        None => IpAddr::V6(v6),
    }
}

/// And back.
pub fn kernel_addr(ip: IpAddr) -> [u8; 16] {
    match ip {
        IpAddr::V4(v4) => v4.to_ipv6_mapped().octets(),
        IpAddr::V6(v6) => v6.octets(),
    }
}

/// The unspecified address, as the kernel keeps it.
pub const NONE: [u8; 16] = [0; 16];

/// A connection, a lookup, or a port listened on. Closed when dropped
/// (what was sent still goes out first).
#[derive(Debug)]
pub struct Socket {
    h: Handle,
}

impl Socket {
    pub const fn from_handle(h: Handle) -> Socket {
        Socket { h }
    }

    pub fn handle(&self) -> Handle {
        self.h
    }

    /// Its handle, no longer closed when this goes.
    pub fn into_handle(self) -> Handle {
        let h = self.h;
        core::mem::forget(self);
        h
    }

    /// As much of `buf` as there is room for -> how much; FULL if none.
    pub fn send(&self, buf: &[u8]) -> Result<usize> {
        if buf.is_empty() {
            return Ok(0);
        }
        let n = buf.len().min(SK_BUF);
        let mut r = ring::lock();
        let io = r.io_with(&buf[..n])?;
        let mut e = Entry::new(RO_SEND, self.h);
        e.handle2 = io;
        e.a1 = n as u64;
        r.call(&e).map(|v| v.0 as usize)
    }

    /// What came, as much as fits in `buf` -> how much; EMPTY if nothing
    /// has, PEER at the end.
    pub fn recv(&self, buf: &mut [u8]) -> Result<usize> {
        if buf.is_empty() {
            return Ok(0);
        }
        let n = buf.len().min(SK_BUF);
        let mut r = ring::lock();
        let (p, io) = r.io(n)?;
        let mut e = Entry::new(RO_RECV, self.h);
        e.handle2 = io;
        e.a1 = n as u64;
        let got = (r.call(&e)?.0 as usize).min(n);
        unsafe { core::ptr::copy_nonoverlapping(p, buf.as_mut_ptr(), got) };
        Ok(got)
    }

    fn wait(&self, send: bool, until: Option<Instant>) -> Result<()> {
        let mut e = Entry::new(RO_WAIT, self.h);
        e.a0 = send as u64;
        e.deadline = until.map_or(0, |t| t.tsc().max(1));
        ring::call(&e).map(|_| ())
    }

    /// Until there is something to receive (a listener: a connection to
    /// accept; a lookup: its answer), or nothing more ever will be; or
    /// until `until`: TIMEOUT.
    pub fn wait_recv(&self, until: Option<Instant>) -> Result<()> {
        self.wait(false, until)
    }

    /// Until there is room to send (it is open), or there never will be (a
    /// listener: until it listens, or failed); or until `until`: TIMEOUT.
    pub fn wait_send(&self, until: Option<Instant>) -> Result<()> {
        self.wait(true, until)
    }

    pub fn status(&self) -> Result<Status> {
        let v = ring::call(&Entry::new(RO_NET_STATUS, self.h))?.0;
        Ok(Status {
            state: (v & 0xFF) as u32,
            why: ((v >> 8) & 0xFF) as u32,
            tls_error: ((v >> 16) & 0xFF) as u32,
            can_recv: v & NS_RECV != 0,
            can_send: v & NS_SEND != 0,
        })
    }

    /// Its addresses; EMPTY while its host is being looked up.
    pub fn addrs(&self) -> Result<Addrs> {
        let mut r = ring::lock();
        let (p, io) = r.io(NA_SIZE)?;
        let mut e = Entry::new(RO_NET_ADDR, self.h);
        e.handle2 = io;
        r.call(&e)?;
        let mut raw = [0u8; NA_SIZE];
        unsafe { core::ptr::copy_nonoverlapping(p, raw.as_mut_ptr(), NA_SIZE) };
        let mut a = Addrs::default();
        a.peer.copy_from_slice(&raw[NA_PEER..NA_PEER + 16]);
        a.local.copy_from_slice(&raw[NA_LOCAL..NA_LOCAL + 16]);
        let dword = |at: usize| u32::from_le_bytes(raw[at..at + 4].try_into().unwrap());
        a.peer_port = dword(NA_PEER_PORT) as u16;
        a.port = dword(NA_PORT) as u16;
        Ok(a)
    }

    /// A listener's oldest connection; EMPTY if none waits.
    pub fn accept(&self) -> Result<Socket> {
        ring::call(&Entry::new(RO_NET_ACCEPT, self.h)).map(|v| Socket { h: v.0 as Handle })
    }

    /// A FIN, once what was sent has gone: nothing more is sent (plain TCP).
    pub fn shut(&self) -> Result<()> {
        ring::call(&Entry::new(RO_NET_SHUT, self.h)).map(|_| ())
    }

    /// Another handle to the same socket; it is closed once both are.
    pub fn try_clone(&self) -> Result<Socket> {
        let mut e = Entry::new(RO_DUP, self.h);
        e.a0 = (RT_SK_SEND | RT_SK_RECV | RT_DUP | RT_GIVE | RT_INFO) as u64;
        ring::call(&e).map(|v| Socket { h: v.0 as Handle })
    }
}

impl Drop for Socket {
    fn drop(&mut self) {
        ring::close(self.h);
    }
}

/// The address as text, as RO_NET_CONNECT takes a host: a.b.c.d, or IPv6's.
pub fn host_text(ip: IpAddr, out: &mut [u8; 64]) -> &str {
    use core::fmt::Write;
    struct Buf<'a>(&'a mut [u8; 64], usize);
    impl Write for Buf<'_> {
        fn write_str(&mut self, s: &str) -> core::fmt::Result {
            let end = self.1 + s.len();
            if end > self.0.len() {
                return Err(core::fmt::Error);
            }
            self.0[self.1..end].copy_from_slice(s.as_bytes());
            self.1 = end;
            Ok(())
        }
    }
    let mut b = Buf(out, 0);
    let _ = match ip {
        IpAddr::V4(v4) => write!(b, "{}", v4),
        IpAddr::V6(v6) => write!(b, "{}", v6),
    };
    let n = b.1;
    core::str::from_utf8(&out[..n]).unwrap_or("")
}
