//! Memory from the kernel: a block of zeroed pages (SYS_MEM_NEW), mapped
//! into the program (SYS_MAP). A block is at most 64 MiB.

use crate::ring;
use crate::sys::*;

/// A block made and mapped -> its handle, and where it is.
pub fn block_new(bytes: usize) -> Result<(Handle, *mut u8)> {
    let (h, _) = unsafe { syscall(SYS_MEM_NEW, bytes as u64, 0, 0, 0, 0) };
    let h = check(h)? as Handle;
    let (va, _) = unsafe { syscall(SYS_MAP, h as u64, 0, 0, 0, 0) };
    match check(va) {
        Ok(va) => Ok((h, va as *mut u8)),
        Err(e) => {
            ring::close(h);
            Err(e)
        }
    }
}

/// A block's mapping gone, and its handle.
///
/// # Safety
/// Nothing may use the block after.
pub unsafe fn block_free(h: Handle) {
    unsafe { syscall(SYS_UNMAP, h as u64, 0, 0, 0, 0) };
    ring::close(h);
}

/// Memory mapped from a handle (another's, or one made here), unmapped and
/// closed when dropped.
pub struct Block {
    handle: Handle,
    ptr: *mut u8,
    len: usize,
}

unsafe impl Send for Block {}

impl Block {
    /// `bytes` of zeroes (rounded up to pages).
    pub fn new(bytes: usize) -> Result<Block> {
        let len = bytes.max(1).next_multiple_of(4096);
        let (handle, ptr) = block_new(len)?;
        Ok(Block { handle, ptr, len })
    }

    /// Memory given by handle (a window's pixels, the desktop's look),
    /// mapped; `len` is what the caller knows it holds.
    pub fn map(handle: Handle, len: usize) -> Result<Block> {
        let (va, _) = unsafe { syscall(SYS_MAP, handle as u64, 0, 0, 0, 0) };
        let va = check(va)?;
        Ok(Block { handle, ptr: va as *mut u8, len })
    }

    pub fn handle(&self) -> Handle {
        self.handle
    }

    pub fn as_ptr(&self) -> *mut u8 {
        self.ptr
    }

    pub fn len(&self) -> usize {
        self.len
    }

    pub fn is_empty(&self) -> bool {
        self.len == 0
    }

    pub fn bytes(&self) -> &[u8] {
        unsafe { core::slice::from_raw_parts(self.ptr, self.len) }
    }

    pub fn bytes_mut(&mut self) -> &mut [u8] {
        unsafe { core::slice::from_raw_parts_mut(self.ptr, self.len) }
    }
}

impl Drop for Block {
    fn drop(&mut self) {
        unsafe { block_free(self.handle) };
    }
}
