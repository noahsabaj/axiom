//! Certificates (RFC 5280), the part that reads what a server sends (was
//! x509.asm's): a certificate taken apart from DER into the CERT the chain
//! check in x509.asm works on, the dates in it as Unix seconds, and whether
//! it names the host. Checking the chain itself stays in the assembly, on
//! pubkey.asm's signatures and sha256.asm.
//!
//! The DER is read as pubkey.asm's der_tlv reads it: a tag number past 30,
//! an indefinite length or one of more than three bytes is malformed; a
//! long length that could have been short is not.

use crate::json::Answer;
use core::mem::{offset_of, size_of};
use core::ptr;

/// Why a certificate or chain will not do: X5E_* in x509.asm.
pub const X5E_MALFORMED: u32 = 1;
pub const X5E_CRITICAL: u32 = 12;

/// CTF_*: what a certificate says about itself.
pub const CTF_CA: u32 = 1;
pub const CTF_KU: u32 = 2; // keyUsage there
pub const CTF_KU_SIGN: u32 = 4; //  digitalSignature
pub const CTF_KU_CERT: u32 = 8; //  keyCertSign
pub const CTF_EKU: u32 = 16; // extendedKeyUsage there
pub const CTF_EKU_OK: u32 = 32; //  serverAuth or anyExtendedKeyUsage
pub const CTF_SAN: u32 = 64;
pub const CTF_PATHLEN: u32 = 128;

/// KT_*: the kinds of key pubkey.asm checks signatures with.
pub const KT_RSA: u32 = 1;
pub const KT_P256: u32 = 2;
pub const KT_P384: u32 = 3;

/// pubkey.asm's KEY: what it is, and where its bytes are.
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Key {
    pub kind: u32,
    pub len: u32,
    pub e: u64, // RSA: the public exponent
    pub ptr: *const u8,
}

/// x509.asm's CERT: a certificate, read. Its pointers are into the DER.
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Cert {
    pub err: u32, // X5E_*, 0 if it read well
    pub flags: u32,
    pub tbs: *const u8, // what is signed, the whole TLV
    pub tbs_len: u32,
    pub scheme: u32, // its signature's, as pubkey.asm has it; 0 unknown
    pub sig: *const u8,
    pub sig_len: u32,
    pub iss_len: u32,
    pub iss: *const u8, // issuer and subject: Name TLVs
    pub sub: *const u8,
    pub sub_len: u32,
    pub path_len: u32,
    pub san: *const u8, // subjectAltName's GeneralNames, inside
    pub san_len: u32,
    _pad: u32,
    pub not_before: u64, // Unix seconds
    pub not_after: u64,
    pub key: Key, // kind 0 if not one Axiom can use
    _rest: u64,
}

const _: () = {
    assert!(size_of::<Key>() == 24);
    assert!(size_of::<Cert>() == 128);
    assert!(offset_of!(Cert, tbs_len) == 16 && offset_of!(Cert, sig) == 24);
    assert!(offset_of!(Cert, iss) == 40 && offset_of!(Cert, sub_len) == 56);
    assert!(offset_of!(Cert, san) == 64 && offset_of!(Cert, not_before) == 80);
    assert!(offset_of!(Cert, key) == 96);
};

impl Cert {
    pub const ZERO: Cert = Cert {
        err: 0,
        flags: 0,
        tbs: ptr::null(),
        tbs_len: 0,
        scheme: 0,
        sig: ptr::null(),
        sig_len: 0,
        iss_len: 0,
        iss: ptr::null(),
        sub: ptr::null(),
        sub_len: 0,
        path_len: 0,
        san: ptr::null(),
        san_len: 0,
        _pad: 0,
        not_before: 0,
        not_after: 0,
        key: Key { kind: 0, len: 0, e: 0, ptr: ptr::null() },
        _rest: 0,
    };
}

/// DER, read one TLV at a time from what is left.
struct Der<'a> {
    rest: &'a [u8],
}

impl<'a> Der<'a> {
    fn new(s: &'a [u8]) -> Der<'a> {
        Der { rest: s }
    }

    fn done(&self) -> bool {
        self.rest.is_empty()
    }

    /// The next byte, the tag of what comes next; there must be one.
    fn peek(&self) -> u8 {
        self.rest[0]
    }

    /// The next TLV -> its tag (the whole first byte) and contents; None
    /// if malformed.
    fn tlv(&mut self) -> Option<(u8, &'a [u8])> {
        self.whole().map(|(tag, inside, _)| (tag, inside))
    }

    /// tlv, and the whole TLV too.
    fn whole(&mut self) -> Option<(u8, &'a [u8], &'a [u8])> {
        let s = self.rest;
        if s.len() < 2 || s[0] & 0x1F == 0x1F {
            return None; // (tag numbers past 30: not in X.509)
        }
        let mut len = usize::from(s[1]);
        let mut at = 2;
        if len & 0x80 != 0 {
            let n = len & 0x7F;
            if n == 0 || n > 3 || n > s.len() - 2 {
                return None; // indefinite, not DER; or too long
            }
            len = s[2..2 + n].iter().fold(0, |l, &b| l << 8 | usize::from(b));
            at += n;
        }
        if len > s.len() - at {
            return None;
        }
        self.rest = &s[at + len..];
        Some((s[0], &s[at..at + len], &s[..at + len]))
    }
}

const OID_RSA: &[u8] = &[0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01]; // rsaEncryption
const OID_EC: &[u8] = &[0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01]; // id-ecPublicKey
const OID_P256: &[u8] = &[0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07]; // prime256v1
const OID_P384: &[u8] = &[0x2B, 0x81, 0x04, 0x00, 0x22]; // secp384r1
const OID_SERVER: &[u8] = &[0x2B, 0x06, 0x01, 0x05, 0x05, 0x07, 0x03, 0x01]; // serverAuth
const OID_ANY: &[u8] = &[0x55, 0x1D, 0x25, 0x00]; // anyExtendedKeyUsage

/// Signature algorithms: the OID, then the scheme, TLS's number.
const ALGORITHMS: &[(&[u8], u32)] = &[
    (&[0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x0B], 0x0401), // sha256WithRSAEncryption
    (&[0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x0C], 0x0501), // sha384WithRSAEncryption
    (&[0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x0D], 0x0601), // sha512WithRSAEncryption
    (&[0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x04, 0x03, 0x02], 0x0403), // ecdsa-with-SHA256
    (&[0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x04, 0x03, 0x03], 0x0503), // ecdsa-with-SHA384
    (&[0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x04, 0x03, 0x04], 0x0603), // ecdsa-with-SHA512
];

/// A certificate from DER, into c: it is cleared first, and keeps what was
/// read before anything went wrong, with the reason in `err` too.
pub fn parse(der: &[u8], c: &mut Cert) -> Result<(), u32> {
    *c = Cert::ZERO;
    let r = read(der, c).map_err(|e| e.unwrap_or(X5E_MALFORMED));
    if let Err(e) = r {
        c.err = e;
    }
    r
}

/// Err(None): malformed; Err(Some(X5E_*)): another reason.
type Read = Result<(), Option<u32>>;

fn read(der: &[u8], c: &mut Cert) -> Read {
    let mut whole = Der::new(der);
    let (tag, cert) = whole.tlv().ok_or(None)?; // Certificate ::= SEQUENCE {
    if tag != 0x30 || !whole.done() {
        return Err(None);
    }
    let mut outer = Der::new(cert);
    let (tag, tbs, tbs_tlv) = outer.whole().ok_or(None)?; //   tbsCertificate
    if tag != 0x30 {
        return Err(None);
    }
    c.tbs = tbs_tlv.as_ptr();
    c.tbs_len = tbs_tlv.len() as u32;
    let mut t = Der::new(tbs);
    if t.done() {
        return Err(None);
    }
    if t.peek() == 0xA0 {
        t.tlv().ok_or(None)?; //   [0] version, any
    }
    if t.tlv().ok_or(None)?.0 != 2 {
        return Err(None); //   serialNumber
    }
    let (tag, alg, alg_tlv) = t.whole().ok_or(None)?; //   signature
    if tag != 0x30 {
        return Err(None);
    }
    c.scheme = scheme(alg);
    let (tag, _, issuer) = t.whole().ok_or(None)?; //   issuer
    if tag != 0x30 {
        return Err(None);
    }
    c.iss = issuer.as_ptr();
    c.iss_len = issuer.len() as u32;
    let (tag, validity) = t.tlv().ok_or(None)?; //   validity
    if tag != 0x30 {
        return Err(None);
    }
    let mut v = Der::new(validity);
    c.not_before = time(&mut v).ok_or(None)?;
    c.not_after = time(&mut v).ok_or(None)?;
    if !v.done() {
        return Err(None);
    }
    let (tag, _, subject) = t.whole().ok_or(None)?; //   subject
    if tag != 0x30 {
        return Err(None);
    }
    c.sub = subject.as_ptr();
    c.sub_len = subject.len() as u32;
    let (tag, spki) = t.tlv().ok_or(None)?; //   subjectPublicKeyInfo
    if tag != 0x30 {
        return Err(None);
    }
    public_key(spki, c).ok_or(None)?;
    while !t.done() {
        let b = t.peek();
        if b & 0xDF == 0x81 || b & 0xDF == 0x82 {
            t.tlv().ok_or(None)?; //   [1], [2] unique IDs
            continue;
        }
        if b != 0xA3 {
            return Err(None);
        }
        let (_, explicit) = t.tlv().ok_or(None)?; //   [3] extensions
        let mut e = Der::new(explicit);
        let (tag, list) = e.tlv().ok_or(None)?;
        if tag != 0x30 || !e.done() {
            return Err(None);
        }
        extensions(list, c)?;
    }
    let (tag, _, again) = outer.whole().ok_or(None)?; //   signatureAlgorithm, as in the TBS
    if tag != 0x30 || again != alg_tlv {
        return Err(None);
    }
    let (tag, sig) = outer.tlv().ok_or(None)?; //   signatureValue }
    if tag != 3 || sig.first() != Some(&0) {
        return Err(None);
    }
    c.sig = sig[1..].as_ptr();
    c.sig_len = sig.len() as u32 - 1;
    if !outer.done() {
        return Err(None);
    }
    Ok(())
}

/// An AlgorithmIdentifier's insides -> the scheme, 0 if not one Axiom
/// checks. Its parameters: none, or NULL.
fn scheme(alg: &[u8]) -> u32 {
    let mut d = Der::new(alg);
    let Some((6, oid)) = d.tlv() else {
        return 0;
    };
    if !matches!(d.rest, [] | [5, 0]) {
        return 0;
    }
    ALGORITHMS.iter().find(|(o, _)| *o == oid).map_or(0, |&(_, s)| s)
}

/// A UTCTime (1950-2049) or GeneralizedTime, to the second, in Z ->
/// Unix seconds; a leap second as 59.
fn time(d: &mut Der) -> Option<u64> {
    let (year, rest) = match d.tlv()? {
        (0x18, v) if v.len() == 15 => (digits(&v[0..])? * 100 + digits(&v[2..])?, &v[4..]),
        (0x17, v) if v.len() == 13 => {
            let y = digits(v)?;
            (if y < 50 { 2000 + y } else { 1900 + y }, &v[2..])
        }
        _ => return None,
    };
    let month = digits(rest).filter(|m| (1..=12).contains(m))?;
    let day = digits(&rest[2..]).filter(|d| (1..=31).contains(d))?;
    let hour = digits(&rest[4..]).filter(|&h| h <= 23)?;
    let minute = digits(&rest[6..]).filter(|&m| m <= 59)?;
    let second = digits(&rest[8..]).filter(|&s| s <= 60)?.min(59);
    if rest[10] != b'Z' {
        return None;
    }
    Some(unix(year, month, day, hour, minute, second))
}

/// Two decimal digits.
fn digits(s: &[u8]) -> Option<u32> {
    let d = |b: u8| b.is_ascii_digit().then(|| u32::from(b - b'0'));
    Some(d(s[0])? * 10 + d(s[1])?)
}

/// A date and time -> Unix seconds (days from civil: H. Hinnant's). Any
/// numbers at all, wrapping as the assembly's 32- and 64-bit arithmetic
/// did.
pub fn unix(year: u32, month: u32, day: u32, hour: u32, minute: u32, second: u32) -> u64 {
    let (mut y, mut m) = (year, month);
    if m <= 2 {
        y = y.wrapping_sub(1); // the year from March
        m = m.wrapping_add(12);
    }
    let m = m.wrapping_sub(3);
    let era = y / 400;
    let yoe = y - era * 400;
    let mut doy = u64::from(m.wrapping_mul(153).wrapping_add(2) / 5)
        .wrapping_add(u64::from(day))
        .wrapping_sub(1);
    doy = doy.wrapping_add(u64::from(yoe * 365) + u64::from(yoe >> 2)).wrapping_sub(u64::from(yoe / 100));
    let days = (u64::from(era) * 146_097).wrapping_add(doy).wrapping_sub(719_468);
    days.wrapping_mul(86_400)
        .wrapping_add(u64::from(hour) * 3600)
        .wrapping_add(u64::from(minute) * 60)
        .wrapping_add(u64::from(second))
}

/// SubjectPublicKeyInfo's insides -> c.key (kind 0 for one Axiom cannot
/// use); None if malformed.
fn public_key(spki: &[u8], c: &mut Cert) -> Option<()> {
    let mut d = Der::new(spki);
    let (tag, alg) = d.tlv()?; // AlgorithmIdentifier
    if tag != 0x30 {
        return None;
    }
    let mut a = Der::new(alg);
    let (tag, oid) = a.tlv()?;
    if tag != 6 {
        return None;
    }
    let mut kind = 0;
    if oid == OID_RSA {
        kind = KT_RSA;
    } else if oid == OID_EC {
        if let (6, curve) = a.tlv()? {
            // the named curve
            if curve == OID_P256 {
                kind = KT_P256;
            } else if curve == OID_P384 {
                kind = KT_P384;
            }
        }
    }
    let (tag, bits) = d.tlv()?; // subjectPublicKey BIT STRING
    if tag != 3 || bits.first() != Some(&0) || !d.done() {
        return None;
    }
    let key = &bits[1..];
    match kind {
        0 => Some(()),
        KT_RSA => rsa_key(key, c),
        _ => {
            // a point: 04, X, Y
            let size = if kind == KT_P256 { 65 } else { 97 };
            if key.len() == size && key[0] == 4 {
                c.key.len = key.len() as u32;
                c.key.ptr = key.as_ptr();
                c.key.kind = kind;
            }
            Some(())
        }
    }
}

/// RSAPublicKey ::= SEQUENCE { n, e } -> c.key: n of 2048 to 4096 bits,
/// near enough, without its leading zeros; e of 8 bytes at most.
fn rsa_key(key: &[u8], c: &mut Cert) -> Option<()> {
    let (tag, seq) = Der::new(key).tlv()?;
    if tag != 0x30 {
        return None;
    }
    let mut s = Der::new(seq);
    let (tag, n) = s.tlv()?;
    if tag != 2 || n.is_empty() {
        return None;
    }
    if n[0] & 0x80 != 0 {
        return Some(()); // negative: unusable
    }
    let n = &n[n.iter().position(|&b| b != 0).unwrap_or(n.len())..];
    if !(256..=512).contains(&n.len()) {
        return Some(());
    }
    c.key.len = n.len() as u32;
    c.key.ptr = n.as_ptr();
    let (tag, e) = s.tlv()?;
    if tag != 2 || e.is_empty() {
        return None;
    }
    if e.len() > 8 || e[0] & 0x80 != 0 {
        return Some(());
    }
    c.key.e = e.iter().fold(0, |e, &b| e << 8 | u64::from(b));
    if !s.done() {
        return None;
    }
    c.key.kind = KT_RSA;
    Some(())
}

/// The Extensions' insides -> what they say, in c. Err(None) if
/// malformed, Err(Some(X5E_CRITICAL)) for a critical one Axiom does not
/// know.
fn extensions(list: &[u8], c: &mut Cert) -> Read {
    let mut d = Der::new(list);
    while !d.done() {
        let (tag, ext) = d.tlv().ok_or(None)?; // Extension ::= SEQUENCE {
        if tag != 0x30 {
            return Err(None);
        }
        let mut e = Der::new(ext);
        let (tag, id) = e.tlv().ok_or(None)?; //   extnID
        if tag != 6 || e.done() {
            return Err(None);
        }
        let mut critical = 0; //   critical BOOLEAN DEFAULT FALSE
        if e.peek() == 1 {
            let (_, b) = e.tlv().ok_or(None)?;
            if b.len() != 1 {
                return Err(None);
            }
            critical = b[0];
        }
        let (tag, value) = e.tlv().ok_or(None)?; //   extnValue OCTET STRING }
        if tag != 4 || !e.done() {
            return Err(None);
        }
        let known = match id {
            [0x55, 0x1D, 15] => key_usage(value, c),
            [0x55, 0x1D, 17] => alt_names(value, c),
            [0x55, 0x1D, 19] => basic(value, c),
            [0x55, 0x1D, 37] => ext_key_usage(value, c),
            // certificatePolicies, policyConstraints, inhibitAnyPolicy: no
            // policies asked for, so nothing they could forbid
            [0x55, 0x1D, 32 | 36 | 54] => Some(()),
            _ if critical != 0 => return Err(Some(X5E_CRITICAL)),
            _ => Some(()),
        };
        known.ok_or(None)?;
    }
    Ok(())
}

fn key_usage(value: &[u8], c: &mut Cert) -> Option<()> {
    let (tag, bits) = Der::new(value).tlv()?; // BIT STRING
    if tag != 3 || bits.is_empty() {
        return None;
    }
    c.flags |= CTF_KU;
    if let Some(&b) = bits.get(1) {
        if b & 0x80 != 0 {
            c.flags |= CTF_KU_SIGN; // digitalSignature (0)
        }
        if b & 0x04 != 0 {
            c.flags |= CTF_KU_CERT; // keyCertSign (5)
        }
    }
    Some(())
}

fn alt_names(value: &[u8], c: &mut Cert) -> Option<()> {
    let (tag, names) = Der::new(value).tlv()?; // GeneralNames ::= SEQUENCE OF GeneralName
    if tag != 0x30 {
        return None;
    }
    c.san = names.as_ptr();
    c.san_len = names.len() as u32;
    c.flags |= CTF_SAN;
    Some(())
}

fn basic(value: &[u8], c: &mut Cert) -> Option<()> {
    let (tag, seq) = Der::new(value).tlv()?; // SEQUENCE { cA BOOLEAN, pathLen INTEGER }
    if tag != 0x30 {
        return None;
    }
    let mut s = Der::new(seq);
    if s.done() {
        return Some(());
    }
    if s.peek() == 1 {
        let (_, b) = s.tlv()?;
        if b.len() != 1 {
            return None;
        }
        if b[0] != 0 {
            c.flags |= CTF_CA;
        }
    }
    if s.done() {
        return Some(());
    }
    let (tag, n) = s.tlv()?;
    if tag != 2 || n.is_empty() || n.len() > 4 || n[0] & 0x80 != 0 {
        return None;
    }
    c.path_len = n.iter().fold(0, |v, &b| v << 8 | u32::from(b));
    c.flags |= CTF_PATHLEN;
    Some(())
}

fn ext_key_usage(value: &[u8], c: &mut Cert) -> Option<()> {
    let (tag, seq) = Der::new(value).tlv()?; // SEQUENCE OF KeyPurposeId
    if tag != 0x30 {
        return None;
    }
    c.flags |= CTF_EKU;
    let mut s = Der::new(seq);
    while !s.done() {
        let (tag, oid) = s.tlv()?;
        if tag != 6 {
            return None;
        }
        if oid == OID_SERVER || oid == OID_ANY {
            c.flags |= CTF_EKU_OK;
        }
    }
    Some(())
}

/// Whether a certificate's subjectAltName names the host: a DNS name, a
/// leading "*." standing for one label, or an IPv4 address; never the
/// common name. "example.com." is example.com.
pub fn names(c: &Cert, host: &[u8]) -> bool {
    let host = host.strip_suffix(b".").unwrap_or(host);
    if host.is_empty() || c.flags & CTF_SAN == 0 {
        return false;
    }
    let san: &[u8] = if c.san_len == 0 {
        &[]
    } else {
        // SAFETY: the SAN that parse found, in the DER it was given, which
        // lasts as long as the CERT does
        unsafe { core::slice::from_raw_parts(c.san, c.san_len as usize) }
    };
    let ip = ipv4(host);
    let mut d = Der::new(san);
    while let Some((tag, name)) = d.tlv() {
        let found = match ip {
            Some(ip) => tag == 0x87 && name == ip, // [7] iPAddress
            None => tag == 0x82 && dns(name, host), // [2] dNSName
        };
        if found {
            return true;
        }
    }
    false
}

/// A dotted IPv4 address: four parts of one to three digits, each 255 at
/// most.
fn ipv4(host: &[u8]) -> Option<[u8; 4]> {
    let mut ip = [0; 4];
    let mut parts = host.split(|&b| b == b'.');
    for byte in &mut ip {
        let part = parts.next()?;
        if part.is_empty() || part.len() > 3 || !part.iter().all(u8::is_ascii_digit) {
            return None;
        }
        *byte = u8::try_from(part.iter().fold(0u32, |v, &b| v * 10 + u32::from(b - b'0'))).ok()?;
    }
    parts.next().is_none().then_some(ip)
}

/// Whether a dNSName names the host, ASCII letters in either case.
fn dns(pattern: &[u8], host: &[u8]) -> bool {
    let (mut p, mut h) = (pattern, host);
    if p.len() >= 4 && p.starts_with(b"*.") {
        if !p[2..].contains(&b'.') {
            return false; // no "*.com"
        }
        match h.iter().position(|&b| b == b'.') {
            Some(first) if first > 0 => {
                h = &h[first..]; // the host's first label, one at least,
                p = &p[1..]; // and the rest against the pattern's
            }
            _ => return false,
        }
    }
    p.eq_ignore_ascii_case(h)
}

/// x509_parse(RSI = DER, ECX = bytes, RDI = CERT): x509.asm. Answer: 0 or
/// X5E_*, and ok 0 if it will not do.
///
/// # Safety
/// `der` points at `bytes` bytes, and `cert` at a CERT.
#[unsafe(no_mangle)]
pub unsafe extern "sysv64" fn rs_x509_parse(cert: &mut Cert, der: *const u8, bytes: u64) -> Answer {
    let der: &[u8] = match bytes as u32 {
        0 => &[],
        // SAFETY: the caller's
        n => unsafe { core::slice::from_raw_parts(der, n as usize) },
    };
    match parse(der, cert) {
        Ok(()) => Answer { value: 0, ok: 1 },
        Err(e) => Answer { value: u64::from(e), ok: 0 },
    }
}

/// x509_unix(EDI, ESI, EDX, ECX, R8D, R9D): x509.asm.
#[unsafe(no_mangle)]
pub extern "sysv64" fn rs_x509_unix(year: u64, month: u64, day: u64, hour: u64, minute: u64, second: u64) -> u64 {
    unix(year as u32, month as u32, day as u32, hour as u32, minute as u32, second as u32)
}

/// x5_name(RBX = CERT, x5_host): x509.asm -> 1 if the certificate names
/// the host, a C string (the first 254 bytes of it looked at: no longer
/// name is one).
///
/// # Safety
/// `cert` is a CERT that parse filled in, its DER still there; `host` is
/// null or a C string.
#[unsafe(no_mangle)]
pub unsafe extern "sysv64" fn rs_x509_name(cert: &Cert, host: *const u8) -> u64 {
    if host.is_null() {
        return 0;
    }
    // SAFETY: a C string: each byte looked at comes before its NUL
    let Some(len) = (0..255).find(|&i| unsafe { *host.add(i) } == 0) else {
        return 0;
    };
    // SAFETY: as above
    let host = unsafe { core::slice::from_raw_parts(host, len) };
    u64::from(names(cert, host))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn dates() {
        assert_eq!(unix(1970, 1, 1, 0, 0, 0), 0);
        assert_eq!(unix(2000, 3, 1, 0, 0, 0), 951_868_800);
        assert_eq!(unix(2024, 2, 29, 23, 59, 59), 1_709_251_199);
        assert_eq!(unix(2038, 1, 19, 3, 14, 8), 1 << 31);
    }

    #[test]
    fn times() {
        let t = |der: &[u8]| time(&mut Der::new(der));
        assert_eq!(t(b"\x17\x0d250101000000Z"), Some(1_735_689_600));
        assert_eq!(t(b"\x17\x0d491231235960Z"), Some(unix(2049, 12, 31, 23, 59, 59)));
        assert_eq!(t(b"\x17\x0d500101000000Z"), Some(unix(1950, 1, 1, 0, 0, 0)));
        assert_eq!(t(b"\x18\x0f20250101000000Z"), Some(1_735_689_600));
        assert_eq!(t(b"\x17\x0d251301000000Z"), None);
        assert_eq!(t(b"\x17\x0d250101000000+"), None);
        assert_eq!(t(b"\x17\x0d2501010000 0Z"), None);
    }

    #[test]
    fn der() {
        let mut d = Der::new(b"\x30\x81\x02ab\x04\x00");
        assert_eq!(d.tlv(), Some((0x30, &b"ab"[..])));
        assert_eq!(d.tlv(), Some((4, &b""[..])));
        assert!(d.done());
        assert_eq!(Der::new(b"\x30\x80").tlv(), None);
        assert_eq!(Der::new(b"\x30\x84\0\0\0\0").tlv(), None);
        assert_eq!(Der::new(b"\x1f\x00").tlv(), None);
        assert_eq!(Der::new(b"\x30\x03ab").tlv(), None);
    }

    #[test]
    fn hosts() {
        assert_eq!(ipv4(b"10.0.2.2"), Some([10, 0, 2, 2]));
        assert_eq!(ipv4(b"010.0.2.255"), Some([10, 0, 2, 255]));
        for bad in [&b"10.0.2"[..], b"10.0.2.256", b"10..2.2", b"10.0.2.2.", b"1000.0.0.1", b"a.b.c.d"] {
            assert_eq!(ipv4(bad), None);
        }
        assert!(dns(b"*.example.com", b"www.Example.com"));
        assert!(!dns(b"*.example.com", b"example.com"));
        assert!(!dns(b"*.example.com", b"a.b.example.com"));
        assert!(!dns(b"*.com", b"example.com"));
        assert!(dns(b"axiom.test", b"AXIOM.test"));
    }

    #[test]
    fn names_in_a_san() {
        let san = b"\x82\x0bexample.com\x87\x04\x0a\x00\x02\x02";
        let mut c = Cert::ZERO;
        c.san = san.as_ptr();
        c.san_len = san.len() as u32;
        assert!(!names(&c, b"example.com"));
        c.flags = CTF_SAN;
        assert!(names(&c, b"example.com."));
        assert!(names(&c, b"10.0.2.2"));
        assert!(!names(&c, b"10.0.2.3"));
        assert!(!names(&c, b"."));
    }
}
