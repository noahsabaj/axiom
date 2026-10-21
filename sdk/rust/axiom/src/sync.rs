//! A lock for what the program's threads share: the ring, the heap.

use core::cell::UnsafeCell;
use core::ops::{Deref, DerefMut};
use core::sync::atomic::{AtomicBool, Ordering};

pub struct SpinLock<T> {
    held: AtomicBool,
    value: UnsafeCell<T>,
}

unsafe impl<T: Send> Sync for SpinLock<T> {}
unsafe impl<T: Send> Send for SpinLock<T> {}

impl<T> SpinLock<T> {
    pub const fn new(value: T) -> SpinLock<T> {
        SpinLock { held: AtomicBool::new(false), value: UnsafeCell::new(value) }
    }

    pub fn lock(&self) -> Guard<'_, T> {
        let mut spins = 0u32;
        while self
            .held
            .compare_exchange_weak(false, true, Ordering::Acquire, Ordering::Relaxed)
            .is_err()
        {
            spins += 1;
            if spins % 64 == 0 {
                crate::sys::yield_now(); // its holder may be waiting for this CPU
            } else {
                core::hint::spin_loop();
            }
        }
        Guard { lock: self }
    }
}

pub struct Guard<'a, T> {
    lock: &'a SpinLock<T>,
}

impl<T> Deref for Guard<'_, T> {
    type Target = T;
    fn deref(&self) -> &T {
        unsafe { &*self.lock.value.get() }
    }
}

impl<T> DerefMut for Guard<'_, T> {
    fn deref_mut(&mut self) -> &mut T {
        unsafe { &mut *self.lock.value.get() }
    }
}

impl<T> Drop for Guard<'_, T> {
    fn drop(&mut self) {
        self.lock.held.store(false, Ordering::Release);
    }
}
