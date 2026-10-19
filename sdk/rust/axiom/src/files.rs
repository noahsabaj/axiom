//! Files on FAT volumes, for a program given them (wants::FILES, or +files).
//!
//! A path is "vol<n>:/a/b" with the files on every volume, or from the folder
//! with a handle to one folder (Files::sub, or what another program gave).
//! A volume is written only after the user said "vol <n> rw" in the shell:
//! until then, writing is Error::READONLY. What is in the boot volume's
//! /Home (Files::home) may always be written: a program's own files go
//! there. A read or a write is 16 MiB at most; a file is read and written
//! whole.

#[cfg(feature = "alloc")]
use alloc::{string::String, vec::Vec};

use crate::ring::{self, State};
use crate::rt;
use crate::sys::*;

const FS_PATH: usize = 256;
#[cfg(feature = "alloc")]
const FV_SIZE: usize = 72;
const FE_NAME: usize = 24;

pub const ATTR_DIR: u32 = 1;
pub const ATTR_READONLY: u32 = 2;
pub const ATTR_HIDDEN: u32 = 4;
pub const ATTR_SYSTEM: u32 = 8;

pub const VOL_WRITABLE: u32 = 1;
pub const VOL_REMOVABLE: u32 = 2;
pub const VOL_BOOT: u32 = 4;

/// A handle to files: on every volume, or in one folder.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub struct Files {
    h: Handle,
}

/// When a thing was last written; year 0 if it never said.
#[derive(Clone, Copy, PartialEq, Eq, Debug, Default)]
pub struct Written {
    pub year: u16,
    pub month: u8,
    pub day: u8,
    pub hour: u8,
    pub min: u8,
    pub sec: u8,
}

#[cfg(feature = "alloc")]
#[derive(Clone, PartialEq, Eq, Debug)]
pub struct DirEntry {
    pub name: String,
    pub attr: u32,
    /// bytes, 0 for a folder
    pub size: u64,
    pub written: Written,
}

#[cfg(feature = "alloc")]
impl DirEntry {
    pub fn is_dir(&self) -> bool {
        self.attr & ATTR_DIR != 0
    }
}

#[cfg(feature = "alloc")]
#[derive(Clone, PartialEq, Eq, Debug)]
pub struct Volume {
    /// its n in "vol<n>:"
    pub index: u32,
    /// VOL_*
    pub flags: u32,
    pub bytes: u64,
    /// of them free
    pub free: u64,
    pub label: String,
}

/// `path` as a field in the io block's first FS_PATH bytes, room after it.
fn path_in(r: &mut State, path: &str, room: usize) -> Result<(*mut u8, Handle)> {
    if path.len() >= FS_PATH || path.as_bytes().contains(&0) {
        return Err(Error::ARG);
    }
    let (p, io) = r.io(FS_PATH + room)?;
    unsafe {
        core::ptr::write_bytes(p, 0, FS_PATH);
        core::ptr::copy_nonoverlapping(path.as_ptr(), p, path.len());
    }
    Ok((p, io))
}

impl Files {
    /// The program's own (SB_FILES).
    pub fn get() -> Result<Files> {
        match rt::files_handle() {
            0 => Err(Error::ABSENT),
            h => Ok(Files { h }),
        }
    }

    /// One given by handle (another program's gift).
    pub const fn from_handle(h: Handle) -> Files {
        Files { h }
    }

    pub fn handle(self) -> Handle {
        self.h
    }

    /// Its handle closed (one made by sub, or given).
    pub fn close(self) {
        ring::close(self.h);
    }

    fn op(self, op: u8, path: &str, a1: u64, a2: u64) -> Result<u64> {
        let mut r = ring::lock();
        let (_, io) = path_in(&mut r, path, 0)?;
        let mut e = Entry::new(op, self.h);
        e.handle2 = io;
        e.a1 = a1;
        e.a2 = a2;
        r.call(&e).map(|v| v.0)
    }

    /// A file, into `buf` -> its size: as much of it as fits is there.
    pub fn read_into(self, path: &str, buf: &mut [u8]) -> Result<usize> {
        let mut r = ring::lock();
        let (p, io) = path_in(&mut r, path, buf.len())?;
        let mut e = Entry::new(RO_FS_READ, self.h);
        e.handle2 = io;
        e.a1 = FS_PATH as u64;
        e.a2 = buf.len() as u64;
        let size = r.call(&e)?.0 as usize;
        let n = size.min(buf.len());
        unsafe { core::ptr::copy_nonoverlapping(p.add(FS_PATH), buf.as_mut_ptr(), n) };
        Ok(size)
    }

    /// A file's size.
    pub fn size(self, path: &str) -> Result<usize> {
        self.read_into(path, &mut [])
    }

    /// A file, whole.
    #[cfg(feature = "alloc")]
    pub fn read(self, path: &str) -> Result<Vec<u8>> {
        loop {
            let size = self.size(path)?;
            let mut v = alloc::vec![0u8; size]; // made outside the ring's lock
            let now = self.read_into(path, &mut v)?;
            if now == size {
                return Ok(v);
            } // it changed between: again
        }
    }

    /// A file made, or all it held replaced.
    pub fn write(self, path: &str, data: &[u8]) -> Result<()> {
        let mut r = ring::lock();
        let (p, io) = path_in(&mut r, path, data.len())?;
        unsafe { core::ptr::copy_nonoverlapping(data.as_ptr(), p.add(FS_PATH), data.len()) };
        let mut e = Entry::new(RO_FS_WRITE, self.h);
        e.handle2 = io;
        e.a1 = FS_PATH as u64;
        e.a2 = data.len() as u64;
        r.call(&e).map(|_| ())
    }

    pub fn mkdir(self, path: &str) -> Result<()> {
        self.op(RO_FS_MKDIR, path, 0, 0).map(|_| ())
    }

    /// A file, or a folder with nothing in it.
    pub fn remove(self, path: &str) -> Result<()> {
        self.op(RO_FS_REMOVE, path, 0, 0).map(|_| ())
    }

    /// Renamed, or moved to another folder of its volume.
    pub fn rename(self, from: &str, to: &str) -> Result<()> {
        if to.len() >= FS_PATH || to.as_bytes().contains(&0) {
            return Err(Error::ARG);
        }
        let mut r = ring::lock();
        let (p, io) = path_in(&mut r, from, FS_PATH)?;
        unsafe {
            core::ptr::write_bytes(p.add(FS_PATH), 0, FS_PATH);
            core::ptr::copy_nonoverlapping(to.as_ptr(), p.add(FS_PATH), to.len());
        }
        let mut e = Entry::new(RO_FS_RENAME, self.h);
        e.handle2 = io;
        e.a1 = FS_PATH as u64;
        r.call(&e).map(|_| ())
    }

    /// A handle to a folder alone, with `rights` (RT_FS_READ, RT_FS_WRITE)
    /// as far as this one has them.
    pub fn sub(self, path: &str, rights: u32) -> Result<Files> {
        self.op(RO_FS_SUB, path, rights as u64, 0).map(|h| Files { h: h as Handle })
    }

    /// What a folder holds ("" for this handle's own folder).
    #[cfg(feature = "alloc")]
    pub fn list(self, path: &str) -> Result<Vec<DirEntry>> {
        let mut room = 64 << 10;
        loop {
            let mut raw = alloc::vec![0u8; room];
            let count = {
                let mut r = ring::lock();
                let (p, io) = path_in(&mut r, path, room)?;
                let mut e = Entry::new(RO_FS_LIST, self.h);
                e.handle2 = io;
                e.a1 = FS_PATH as u64;
                e.a2 = room as u64;
                let count = r.call(&e)?.0 as usize;
                unsafe { core::ptr::copy_nonoverlapping(p.add(FS_PATH), raw.as_mut_ptr(), room) };
                count
            };
            let mut out = Vec::with_capacity(count);
            let mut at = 0;
            while out.len() < count && at + FE_NAME <= room {
                let rec = &raw[at..];
                let len = u32::from_le_bytes(rec[0..4].try_into().unwrap()) as usize;
                if len < FE_NAME || at + len > room {
                    break;
                }
                let name = &rec[FE_NAME..len];
                let name = &name[..name.iter().position(|&b| b == 0).unwrap_or(name.len())];
                out.push(DirEntry {
                    name: String::from_utf8_lossy(name).into_owned(),
                    attr: u32::from_le_bytes(rec[4..8].try_into().unwrap()),
                    size: u64::from_le_bytes(rec[8..16].try_into().unwrap()),
                    written: Written {
                        year: u16::from_le_bytes([rec[16], rec[17]]),
                        month: rec[18],
                        day: rec[19],
                        hour: rec[20],
                        min: rec[21],
                        sec: rec[22],
                    },
                });
                at += len;
            }
            if out.len() == count || room >= 16 << 20 {
                return Ok(out);
            }
            room *= 4; // more than fit
        }
    }

    /// The volumes it reaches.
    #[cfg(feature = "alloc")]
    pub fn volumes(self) -> Result<Vec<Volume>> {
        let room = 64 * FV_SIZE;
        let mut raw = alloc::vec![0u8; room];
        let count = {
            let mut r = ring::lock();
            let (p, io) = r.io(room)?;
            let mut e = Entry::new(RO_FS_VOLUMES, self.h);
            e.handle2 = io;
            e.a1 = room as u64;
            let count = r.call(&e)?.0 as usize;
            unsafe { core::ptr::copy_nonoverlapping(p, raw.as_mut_ptr(), room) };
            count.min(64)
        };
        Ok((0..count)
            .map(|i| {
                let v = &raw[i * FV_SIZE..(i + 1) * FV_SIZE];
                let label = &v[16..64];
                let label = &label[..label.iter().position(|&b| b == 0).unwrap_or(label.len())];
                Volume {
                    index: u32::from_le_bytes(v[0..4].try_into().unwrap()),
                    flags: u32::from_le_bytes(v[4..8].try_into().unwrap()),
                    bytes: u64::from_le_bytes(v[8..16].try_into().unwrap()),
                    free: u64::from_le_bytes(v[64..72].try_into().unwrap()),
                    label: String::from_utf8_lossy(label).into_owned(),
                }
            })
            .collect())
    }

    /// "vol<n>:/Home" on the volume Axiom started from: what is in it may
    /// be written without "vol <n> rw" (the folder itself, and the rest of
    /// the volume, wait for it). Error::ABSENT if no volume is the boot one.
    #[cfg(feature = "alloc")]
    pub fn home(self) -> Result<String> {
        let vols = self.volumes()?;
        let boot = vols.iter().find(|v| v.flags & VOL_BOOT != 0).ok_or(Error::ABSENT)?;
        Ok(alloc::format!("vol{}:/Home", boot.index))
    }
}
