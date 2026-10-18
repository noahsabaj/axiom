//! Time, by the TSC: the kernel says how many ticks a microsecond is (the
//! start block), and deadlines on the ring are TSC values.

use core::ops::{Add, Sub};
use core::sync::atomic::{AtomicU64, Ordering};
use core::time::Duration;

use crate::ring;
use crate::sys::*;

static TSC_PER_US: AtomicU64 = AtomicU64::new(1000);

pub(crate) fn init(tsc_per_us: u64) {
    TSC_PER_US.store(tsc_per_us.max(1), Ordering::Relaxed);
}

/// TSC ticks a microsecond.
pub fn tsc_per_us() -> u64 {
    TSC_PER_US.load(Ordering::Relaxed)
}

/// A moment: the TSC then. Steady; its zero is when the machine started.
#[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Debug)]
pub struct Instant(u64);

impl Instant {
    pub fn now() -> Instant {
        Instant(rdtsc())
    }

    /// As the ring's deadlines have it.
    pub fn from_tsc(tsc: u64) -> Instant {
        Instant(tsc)
    }

    pub fn tsc(self) -> u64 {
        self.0
    }

    pub fn duration_since(self, earlier: Instant) -> Duration {
        ticks_to_duration(self.0.saturating_sub(earlier.0))
    }

    pub fn elapsed(self) -> Duration {
        Instant::now().duration_since(self)
    }

    pub fn checked_add(self, d: Duration) -> Option<Instant> {
        self.0.checked_add(duration_to_ticks(d)).map(Instant)
    }
}

impl Add<Duration> for Instant {
    type Output = Instant;
    fn add(self, d: Duration) -> Instant {
        Instant(self.0.saturating_add(duration_to_ticks(d)))
    }
}

impl Sub<Instant> for Instant {
    type Output = Duration;
    fn sub(self, earlier: Instant) -> Duration {
        self.duration_since(earlier)
    }
}

fn ticks_to_duration(t: u64) -> Duration {
    let per = tsc_per_us();
    let us = t / per;
    let ns = (t % per) * 1000 / per;
    Duration::from_micros(us) + Duration::from_nanos(ns)
}

fn duration_to_ticks(d: Duration) -> u64 {
    let per = tsc_per_us() as u128;
    (d.as_nanos() * per / 1000).min(u64::MAX as u128) as u64
}

/// Microseconds since the machine started.
pub fn micros() -> u64 {
    rdtsc() / tsc_per_us()
}

/// Nanoseconds since the machine started.
pub fn nanos() -> u64 {
    ((rdtsc() as u128) * 1000 / tsc_per_us() as u128) as u64
}

/// This thread waits until then (RO_TIMEOUT).
pub fn sleep_until(t: Instant) {
    let mut e = Entry::new(RO_TIMEOUT, 0);
    e.deadline = t.0.max(1);
    let _ = ring::call(&e);
}

pub fn sleep(d: Duration) {
    sleep_until(Instant::now() + d);
}
