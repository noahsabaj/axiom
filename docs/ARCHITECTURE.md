# Axiom architecture (M0)

Everything here is NASM in `-f bin` mode: no linker, no object files. Two
images come out of the build, and the second contains the first.

## Boot: `src/boot/uefi.asm`

The loader is a PE32+ UEFI application assembled by hand: DOS stub, PE
header, a `.text` section and a `.reloc` section holding one block of no-op entries (the
code is position-independent, but some firmware refuses images without one).
It calls firmware services with the Microsoft x64 ABI. It refuses to run if
the firmware left 5-level paging on.

1. Pick the largest Graphics Output Protocol mode (up to `GOP_MAX_W×GOP_MAX_H`
   if the build caps it) and record the framebuffer.
2. Find the ACPI 2.0 RSDP and the SMBIOS 3 (or 2) entry point in the
   configuration table.
3. Read the first sector of the volume the loader came from (`LoadedImage`'s
   device handle, its `BlockIo`) and keep its FAT volume serial number, so the
   kernel can find that stick again for its log. Never fatal.
4. Calibrate the TSC against the firmware's `Stall` (50 ms).
5. Copy the embedded `kernel.bin` (an `incbin`) into fresh pages, zero its
   `.bss`, and build page tables:
   - `PML4[0]`: identity map of physical memory in 2 MiB pages, needed for
     the moment of the CR3 switch and for UEFI runtime calls;
   - `PML4[256]`: the same tables again at `0xFFFF800000000000`, the direct map
     the kernel uses for all physical memory (at least the first 4 GiB, so the
     usual MMIO hole is covered);
   - `PML4[511]`: the kernel at `0xFFFFFFFF80000000` in 4 KiB pages, and the
     framebuffer at `0xFFFFFFFF00000000` write-combining (PAT entry 4).

   The kernel replaces these with its own straight away (see Memory); the
   loader's PML4 lives on as the firmware's tables.
6. Take the final memory map and call `ExitBootServices` (retrying if the map
   changed). `SetVirtualAddressMap` is never called: runtime services stay
   identity mapped, so `ResetSystem` keeps working.
7. Load CR3, jump to `kernel_main` with a boot-information block
   (`src/include/bootinfo.inc`): memory map, framebuffer, ACPI, SMBIOS, TSC
   frequency, runtime-services table, boot volume serial.

Placing the kernel in the top 2 GiB matters for assembly: every label is a
sign-extended 32-bit value, so `[table + rax*8]` and `push label` encode
directly with no RIP-relative gymnastics.

## Kernel image: `src/kernel/kernel.asm`

One file that `%include`s every module into four sections (`.text`,
`.rodata`, `.data`, `.bss`) laid out back to back, `.rodata` and `.data`
each starting on a page of their own (`kernel_rodata`, `kernel_data`) so
that each can be mapped as it should be. The first bytes are a header the
loader reads: magic `AXIOMKRN`, entry point, file size, memory size.
`build/kernel.map` lists every symbol.

`kernel_main` (`boot.asm`) brings the machine up in dependency order:

| Step | Module | What |
|---|---|---|
| 1 | `gdt.asm`, `idt.asm` | Our GDT, the BSP's per-CPU block in GS, 256 interrupt stubs |
| 2 | `serial.asm`, `lib.asm`, `log.asm` | COM1 log, TSC time base, `sprintf`, `KLOG`; the clock and the boot volume into the log |
| 3 | `cpu.asm` | CPUID features and brand, hybrid core types, PAT, NX, SSE/AVX through XSETBV, HWP, telemetry MSRs |
| 4 | `pmm.asm`, `vmm.asm`, `heap.asm` | Bitmap page allocator from the UEFI memory map; the kernel's own page tables (no identity map, W^X), the vm region, the heap |
| 5 | `gfx.asm`, `console.asm`, `ui.asm` | Framebuffer, alpha-blended glyphs, the dashboard and console |
| 6 | TSS, IST | Guarded stacks: the BSP moves onto its own, the loader's goes back; #DF, NMI and #MC each get one too |
| 7 | `acpi.asm`, `smbios.asm` | MADT (CPUs, I/O APICs, overrides), MCFG, FADT, `_S5_`; board, BIOS and memory strings |
| 8 | `pmm.asm` | Reclaim boot-services memory |
| 9 | `apic.asm` | x2APIC through MSRs, else xAPIC MMIO; 8259s masked; I/O APIC entries masked |
| 10 | `object.asm`, `sched.asm`, `ring.asm` | The task `kernel`, which everything at boot acts for; the scheduler: the code running from here on is the thread `main`; the timer is the scheduler's; `async_boot`: the timers' heap and the thread `async` |
| 11 | `smp.asm` | Start every other thread (below), then `sched_topology`: each CPU's kind and SMT sibling |
| 12 | `pci.asm` | Enumerate through ECAM, else ports CF8/CFC |
| 13 | `kbd.asm`, `usb.asm` | PS/2 keyboard on IRQ 1; xHCI controllers and whatever is plugged in at boot (later devices arrive through hot-plug in the main loop) |
| 14 | `nvme.asm`, `disk.asm`, `fat.asm` | NVMe controllers, their partitions (and those of USB sticks found in step 13), FAT32 mounted read-only |
| 15 | `net.asm`, `rtl8168.asm` | Ethernet controllers; DHCP starts once the link is up |
| 16 | `mandel.asm`, `shell.asm` | Palette, view, shell; interrupts on |

Then `main_loop`: poll and service USB (enumeration, hot-plug), service the
network (frames in, link, DHCP/ARP/ping timers), save the log if it grew
(every 10 s), apply pointer movement, take input, refresh telemetry every 500 ms, render a demo frame at
most every 16 ms (or at once after a click or the wheel), and otherwise park
the thread `main` (`thread_park_until`) until the next deadline: the next
refresh or frame, the next key repeat, the next network timer, or 4 ms while
a USB controller or a network card needs polling. Any device interrupt
(vectors `0x20` to `0x2F`: a key, a USB event, a network frame, pointer
movement) unparks it early. While it is parked, the BSP runs other threads,
or idles.

## Memory: `pmm.asm`, `vmm.asm`, `heap.asm`

- **Physical** (`pmm.asm`): one bit per 4 KiB page, built from the UEFI
  memory map. The kernel, its page tables and the loader's allocations are
  marked used; boot services memory is released after ACPI and SMBIOS have
  been read. `pmm_free` panics on a page that was not in use.
- **The kernel's page tables** (`vmm_init`, right after `pmm_init`). Nothing
  is mapped in the lower half, so a null pointer, or a physical address used
  as a pointer, faults. The upper half:

  | PML4 | At | What |
  |---|---|---|
  | 256 | `0xFFFF800000000000` | The direct map of `[0, phys_top)`, 2 MiB pages, writable, never executable; the 4 KiB pages holding the kernel's code and constants are read-only there too |
  | 257 | `0xFFFF808000000000` | The vm region, 512 GiB in 2 MiB slots (below) |
  | 511 | `0xFFFFFFFF00000000` | The framebuffer, write-combining |
  | 511 | `0xFFFFFFFF80000000` | The kernel: code read-only, constants read-only and not executable, data and `.bss` writable and not executable |

  Every kernel page is global (CR4.PGE); SMEP and SMAP are on where the CPU
  has them. The upper-half PML4 entries never change after `vmm_init`, so any
  set of tables that copies them sees the same kernel. No page anywhere is
  both writable and executable: `mem test` walks every entry to check.
- **The firmware tables** are the loader's PML4 (below 4 GiB): its identity
  map of `[0, phys_top)` in `PML4[0]`, the kernel's upper half copied in.
  UEFI runtime calls switch to them and back (`fw_enter`, `fw_leave`), and an
  AP runs on them from its trampoline until `ap_entry`. Nothing else ever
  sees an identity map.
- **The vm region**: `vm_alloc(bytes)` gives zeroed pages of its own;
  `vm_map_phys(phys, bytes, flags)` maps a physical range (`mmio_map` does,
  uncached, for MMIO above the direct map); `vm_free` takes either back.
  Slots are found next-fit in a bitmap. A mapping sits at the top of its
  slots with at least one unmapped page below it, and the next slot's first
  page is never mapped, so running off either end faults. Every kernel stack
  is one: each CPU's 64 KiB stack and its three 16 KiB interrupt stacks.
- **TLB shootdowns**: `vm_free` unmaps each slot at its PDE, then
  `tlb_shootdown` sends `VEC_TLB` to every other CPU and waits for them all
  (`invlpg` per page, or a full flush past 64), and only then gives the pages
  and page tables back. A CPU waiting for the lock, or for a job to finish,
  answers other shootdowns as it waits.
- **The heap**: `kmalloc(bytes)` gives zeroed, 16-byte aligned memory; up to
  1 KiB it comes from slabs (a page from pmm each, through the direct map,
  one object size per slab: 16 to 1024 bytes), larger from a vm mapping of
  its own, placed to end where the mapping does. A slab's first 128 bytes
  say what it holds, with a bit per object, so `kfree` refuses a pointer it
  never gave out, or one freed twice. A freed object is filled with `0xDF`,
  and `kmalloc` checks it still is before handing it out again. Each size
  keeps one empty slab and gives the rest back.
- **What a fault hit**: a page fault or double fault report ends with a line
  saying what the access was, why it failed and what lives at the address:
  `cause: a write to 0xffffffff80019676, which is read-only: kernel code`;
  `...where nothing is mapped: the guard page below CPU 3's kernel stack (a
  stack overflow)`; `...a null pointer`; `...just past the end of a vm
  mapping (an overrun?)`. Misuse of the allocators panics with its own
  message (`kfree: freed twice: 0x...`).
- `mem` shows all of this; `mem <address>` says what is at an address and
  how it is mapped; `mem test` runs the heap and the vm region hard on one
  CPU and then on all of them at once. `panic null|code|const|nx|stack|
  guard|twice|after|page|vm` makes each kind of fault on purpose.

## Threads and the scheduler: `sched.asm`, `threads.asm`

- **A thread** is one vm mapping: a 32 KiB stack, with the thread's fields
  (`TH_*`) and its XSAVE area on the page above, guarded on both sides, so a
  stack overflow hits a guard page and the report names the thread (`the
  guard page below the stack of thread 17, deep (a stack overflow)`). The
  mappings of the last 32 threads to end are kept for the next ones, so
  starting a thread touches no page tables and ending one sends no
  shootdown. `thread_new(entry, arg, name)` and `thread_start`, or
  `thread_spawn` with a class; `thread_join`, `thread_detach`,
  `thread_exit`, `thread_yield`, `thread_sleep_us`. A thread is an object
  (`OT_THREAD`, below) acting for a task (`TH_TASK`), its creator's unless
  `thread_set_task` says otherwise. It holds two references, its own and its
  creator's handle; an ended one waits on a list until no CPU is on its
  stack, and the idle loops and `thread_new` free it.
- **Park and unpark** are the one way to wait: `thread_park` and
  `thread_park_until(deadline)` sleep until a `thread_unpark` or the
  deadline, and an unpark that comes first is kept, so the next park returns
  at once. Sleeping, the job workers, the main loop and wait queues
  (`wq_wait(queue, flag, deadline)`, `wq_wake`, which joining and events
  use) are built on them. `thread_unpark` and `wq_wake` work from interrupt
  handlers. An entry on a wait queue can also be a function rather than a
  thread (`wq_add`, `wq_remove`, `EW_FN`): `wq_wake` calls it, from
  whatever woke the queue, which is how a ring's waits complete with
  nobody blocked on them.
- **A switch** (`sched_switch`) pushes the callee-saved registers, saves the
  SIMD state with XSAVE (of everything XCR0 enables; the area is sized from
  each component, since some hypervisors understate the total) or FXSAVE,
  and loads the next thread's. A thread coming from another CPU is taken only
  once that CPU is off its stack (`TH_ONCPU`).
- **Each CPU** has a run queue ordered by virtual runtime (the CPU time each
  thread has had), a sleep queue ordered by deadline, and an idle thread. The
  least-run thread runs; while others wait, it gets a 4 ms slice. The timer
  (TSC-deadline, else the LAPIC's one-shot timed against the TSC) is set for
  the soonest of the slice's end, the first sleeper, the next look for a
  better core, and a 50 ms count while busy; an idle CPU with nothing to wake
  gets none. A switch happens on the way out of an interrupt that asked for
  one (`PC_RESCHED`, or the IPI on `0x42` from another CPU), or at once on a
  park or a yield. A parked thread keeps its place in time while the others
  run on, and comes back at most half a slice ahead of the least-run thread,
  preempting the running one if it is 1 ms or more behind it: so the shell
  answers at once while every CPU is busy.
- **Where a thread goes**: where it is pinned (`TH_PIN`), where it is hinted
  once (`TH_HINT`), or the CPU that costs least: 64 for each thread there,
  24 for the wrong kind of core for its class (perf: P-cores; eff: E-cores;
  any: P-cores, with 4 for an E-core), 16 if its SMT sibling is busy, 8 for
  the BSP (it runs the shell and takes the interrupts), and 2 less where it
  last ran.
- **Balancing**: a CPU about to idle steals a waiting thread from the
  busiest queue (an eff thread is left for an idle E-core, the others for an
  idle P-core); a CPU's timer hands a waiting thread to a CPU with two fewer;
  a thread on the wrong kind of core looks every 10 ms for an idle whole core
  of the right kind (the BSP last), or swaps with a thread on the wrong kind
  the other way.
- **At boot**, `sched_init` (after the LAPIC) makes the running code the
  thread `main`, pinned to the BSP on the stack it has, and gives the BSP an
  idle thread; each AP's boot code becomes its `idle/N` thread, and each AP
  gets a job worker, `jobs/N`. `sched_topology` takes each CPU's kind and
  SMT sibling from `smp_topology` once every AP is up.
- **Locks**: each CPU's queues have one spinlock, taken with interrupts off,
  never two at once; a thread moving between CPUs is off both queues for a
  moment.
- `threads` lists each CPU (its kind, threads waiting, busy time, switches,
  steals, hand-overs) and each thread (state, CPU, class, pin, CPU time on
  P-, E- and other cores, switches, moves). `threads test` starts and joins
  2000 threads, times switches and wake-ups, checks sleeps, fairness, the
  main thread's lateness under load, SIMD state across switches, spreading
  out, P/E placement (pretending where there is one kind of core) and that
  nothing is left over. `threads spin <n> [perf|eff|any] [s]` puts load on
  to watch; `panic thread` overflows a thread's stack.

## Objects and capabilities: `object.asm`, `kobj.asm`, `objtest.asm`

- **Everything the kernel hands out is an object**: a task, a thread, an
  event, a block of memory, a ring (below). Each begins with the same header (`OB_*`): its
  type, a reference count, an id never reused, a name, the task that made
  it, and how many capabilities point at it. `obj_types` describes each
  type (its destroy function, the names of its rights, and what to do
  when the last capability to one goes, `TY_ORPHAN`) and keeps its live
  objects on a list, counted, with how many were ever made. `obj_get` and
  `obj_put`; the last `obj_put` calls the type's destroy.
- **A task** (`TK_*`) is what acts: a handle table, the task that made it,
  how many threads act for it, and how many handle operations it made and
  how many were refused. Each thread holds its task, and lets go when it is
  reaped, so a task lives while it has threads or someone holds it. It
  ends (`task_end`, once) when it has no threads and no capability points at
  it: every handle it still holds is closed, which lets go of whatever its
  rings still waited for, and of the references those held to it.
- **A task acts only through capabilities**, held in its handle table. A
  handle is a slot's index and that slot's generation (`HS_*`): it means
  nothing in another task's table, and once closed it means nothing in its
  own, even when the slot is used again. A capability (`CAP_*`) says what
  may be done (`RT_*`: dup, give and info for every type, and each type's
  own, such as an event's signal and wait or memory's read and write), until
  when (a TSC deadline), and for memory, which bytes (a window).
- **Deriving**: `handle_dup(h, rights, expiry)` makes a capability with the
  same rights or fewer and an expiry no later; `handle_window(h, offset,
  length, rights)` one to part of a memory object's window, never wider.
  Both need `RT_DUP`. `handle_give(h, task)` moves a capability into another
  task's table (it needs `RT_GIVE`, and `RT_TASK_HANDLES` on the task).
- **Revoking**: each capability is in the tree of the one it came from, in
  whatever task it went to. `handle_revoke(h)` takes back every capability
  derived from `h`; each revoked handle answers `E_REVOKED` until its holder
  closes it. Closing a capability moves those derived from it up to its
  parent, so a revoke from higher up still reaches them.
- **Using**: `handle_get(h, type, rights)` finds, checks (type, rights,
  expiry) and holds the object; the operations are built on it:
  `h_task_new`, `h_task_spawn` (a thread acting for a task), `h_thread_wait`,
  `h_event_new`, `h_event_signal`, `h_event_reset`, `h_event_wait`,
  `h_mem_new`, `h_mem_read`, `h_mem_write`, `h_mem_copy` (between two
  blocks, each through its handle's window). They are what system calls
  will be, and what a ring's entries do. Every refusal is an `E_*` (negative), and `err_text` says it in words.
- **The audit ring**: whatever changes the capabilities (made, derived,
  given, closed, revoked, a task's last ones closed as it ends) and every
  refusal goes into a ring of the last 256, with the task, the handle, the
  object, the rights and the result.
- **Locks**: one lock, `cap_lock`, taken with interrupts off, covers every
  handle table and capability tree; each type's list has its own. Nothing is
  freed with either held: an operation takes out what it removes, and drops
  the references after.
- `objects` lists each type (live, made) and each task (who made it, its
  threads, handles, operations and refusals); `objects <task id>` the
  handles a task holds (type, object, rights, expiry, what each was derived
  from, revoked ones); `objects audit` the last 32 records. `objects test`
  checks an event's handles (fewer rights; closed, reused, forged and
  mistyped handles), a task of its own given narrowed handles and then
  revoked, its refusals counted and audited, a handle that expires, windows
  on memory, threads on every CPU deriving and closing handles while what
  they derive from is revoked, the cost of a signal by handle and of a dup
  and close, and that nothing is left over.

## Rings: `ring.asm`, `ringtest.asm`

- **A ring is how a task asks for many things at once.** `h_ring_new(n)`
  makes a ring and a block of memory it shares with the kernel (`RA_*`): a
  header, n submission entries (`SQ_*`, 64 bytes: an operation, flags, a
  handle, the task's own data, arguments, a deadline) and 2n completions
  (`CQ_*`, 32 bytes: the data back, a result, a value). The task writes
  entries and moves the submission tail; `h_ring_enter(ring, take, wait,
  deadline)` takes up to `take` of them, does each, and waits until `wait`
  completions are there to read, or the deadline. The task reads them and
  moves the completion head. The kernel trusts nothing in that memory: a
  tail too far ahead is refused, a head past the tail takes nothing.
- **Operations** (`RO_*`): nop, signal, reset, dup, close, give, revoke,
  copy (memory to memory), cancel, and three that wait: an event (`RO_WAIT`),
  a thread's end (`RO_JOIN`) and a time (`RO_TIMEOUT`). Those that wait
  block nothing: each becomes a request (`RQ_*`), on the object's wait queue
  as a function and, with a deadline, on a timer; whatever wakes it (another
  thread, an interrupt handler, the timer) writes its completion, and the
  task finds it on its next enter, or is woken if it waits in one.
- **Linked entries** (`SQF_LINK`) run in order, each once the one before it
  succeeded, up to 16 in a chain; when one fails or times out, the rest
  complete `E_CANCELED`. `RO_CANCEL` takes back requests still waiting that
  carry a given data.
- **Every entry taken gets exactly one completion**, and an entry is taken
  only when its whole chain's completions have a place: the ring counts
  those owed or written (`RG_PROMISED`) against the task's head, so a full
  completion queue leaves entries in the submission queue instead of losing
  completions.
- **The thread `async`** finishes requests once they have completed (off
  their queue and timer, references dropped) and does what was linked after
  them, acting for the task that asked. It also runs the kernel's timers
  (`timer_add`, `timer_cancel`: a heap by TSC deadline, each timer's
  function called on that thread).
- **A request arms without races**: it goes from arming to pending, and a
  wake, timeout or cancel that comes while it arms is kept (`RQS_EARLY`) and
  acted on once it is armed. Exactly one of them completes it.
- **When no handle to a ring is left** (its `TY_ORPHAN`), whatever still
  waits on it is canceled, its timers too, and it is freed once the last
  request lets go.
- `rings` lists the rings (entries, completions owed, requests waiting,
  entries taken, completed, waited and canceled) and the requests and timers
  in being. `rings test` checks entries done at once, a wait completed from
  another thread, timeouts in the order of their deadlines, links, cancel,
  join, copies, a full completion queue, a corrupt ring, a ring closed with
  requests waiting, a ring per CPU under load, the cost of an entry, and
  that nothing is left over.

## Processors: `smp.asm`

- The MADT gives the APIC IDs. The BSP is moved to index 0.
- A 16-bit trampoline is copied below 1 MiB. The BSP patches in the GDT, the
  firmware tables' CR3 (below 4 GiB, with the identity map the trampoline
  needs), the EFER bits (long mode, and NX, which the kernel's tables use)
  and the 64-bit entry, then sends INIT to every AP at once, waits 10 ms and
  sends two rounds of SIPIs. Each AP goes 16 → 32 → 64-bit, moves onto the
  kernel's tables in `ap_entry`, finds its own index by matching its x2APIC
  ID (CPUID leaf 0xB) and sets up its GS block, TSS, IST stacks, LAPIC and
  features.
- `smp_topology` sorts threads by kind (P-core, E-core, other), then APIC ID,
  and numbers cores within each kind. That order drives the dashboard tiles.
- **Jobs:** `job_run(fn, items, arg)` wakes every AP's worker thread
  (`jobs/N`, pinned there) with an IPI on `VEC_WAKE`, which unparks it; all
  of them, and the thread that asked on the BSP, claim items with `lock
  xadd` until none are left and check in. `job_run_each` runs a function once
  per CPU (telemetry sampling uses it). Between jobs the workers are parked
  and the APs run other threads, or idle in `hlt`.
- `smp_stop_others` sends NMI to every other CPU; panic uses it.

## Interrupts

Vectors: `0x21` PS/2 keyboard (I/O APIC, with MADT overrides applied), `0x22`
xHCI and `0x23` network cards (MSI-X or MSI to the BSP, set up by `pci_msi`),
`0x30` the scheduler's timer, `0x40` job wake-up, `0x41` TLB shootdown, `0x42`
reschedule, `0xFF` spurious. Every stub saves all general registers and calls
the handler registered with `irq_register`; after a device's (`0x20` to
`0x2F`) it unparks the main loop. The common path sends the EOI, then
switches threads if the scheduler asked. Exceptions go to `panic`, which
stops the other CPUs and paints a full report (registers, CR2, CR3,
segments, the thread, and for a page fault what it ran into) on screen and
serial.

## USB: `usb.asm`, `usbdev.asm`, `usbhub.asm`, `hid.asm`, `usbmsc.asm`, `pointer.asm`

- **Controllers** (`usb.asm`): each xHCI controller (PCI class 0C/03/30) is
  taken from the firmware through the USB legacy-support capability (BIOS
  semaphore, SMIs off), reset, and given a device context array, scratchpad
  buffers, a command ring and one 256-entry event ring. Events arrive by MSI-X
  or MSI, aimed at the BSP; the main loop also drains the event rings with
  interrupts off, so a controller without either still works.
- **Devices** (`usbdev.asm`): enumeration and hot-plug run from the main loop
  with synchronous control transfers, one device at a time. Each device gets
  a slot, an address and its descriptors; each interface is offered to the
  class drivers in turn. `usb` lists the tree.
- **Hubs** (`usbhub.asm`): USB 2 and USB 3 hubs, nested, with the route string
  and transaction-translator fields xHCI needs for low- and full-speed devices
  behind high-speed hubs. The status-change endpoint drives hot-plug.
- **HID** (`hid.asm`): the report descriptor is parsed into the fields Axiom
  uses: key arrays and bitmaps (6-key and N-key rollover), buttons, X/Y
  (relative or absolute), wheel and pan, each with its report ID. Devices that
  describe nothing useful but claim the boot subclass fall back to boot
  protocol. Keys become characters through a usage table, with a 500 ms /
  30 Hz repeat.
- **Mass storage** (`usbmsc.asm`): sticks and card readers that speak
  Bulk-Only Transport with SCSI commands (class 08/06/50). INQUIRY names the
  device, TEST UNIT READY waits up to 3 s for a medium, READ CAPACITY (10,
  else 16) sizes it, and the stick becomes a removable disk. Reads and
  writes go in 64 KiB pieces through one bounce buffer (READ/WRITE 10, or 16
  past 2^32 blocks), polled, 8 s per transfer. A stalled endpoint is reset
  and cleared; a command that goes wrong gets a Bulk-Only reset; a unit
  attention is retried once; a write-protect switch is reported. Pulling the
  stick marks its disk and volumes gone, and a stick plugged in later reuses
  the slots.
- **Pointer** (`pointer.asm`): HID posts movement into a ring from interrupt
  context; the main loop applies it with acceleration, scaled to the screen.
  The cursor is drawn only on the framebuffer: `gfx_blit` repaints it over
  whatever it copies, so the back buffer never holds it.

## Storage: `nvme.asm`, `usbmsc.asm`, `disk.asm`, `fat.asm`

- **NVMe** (`nvme.asm`): each controller (PCI 01/08/02) is reset and given an
  admin queue pair and one I/O queue pair, polled. Commands complete in
  microseconds, so the caller waits. Identify gives the model, firmware,
  transfer limit and the first active namespace. Data moves through one
  physically contiguous 64 KiB bounce buffer with a prebuilt PRP list, so
  callers can use any kernel buffer. Per-core queues and interrupts come with
  M1's scheduler.
- **Disks and volumes** (`disk.asm`): a driver registers a disk with a table
  of operations (read, write, flush, describe). GPT partitions (else MBR, else
  a filesystem on the bare disk) become volumes, each probed for FAT32, FAT16,
  exFAT or NTFS. Every volume starts **read-only**: `vol <n> rw` unlocks one,
  `vol <n> ro` locks it again, and `vol_write` refuses anything else. The
  one exception is the log on the boot stick (below).
  The current volume is the first FAT32 volume on a removable disk (the USB
  stick Axiom booted from, usually), else the first FAT32 volume anywhere,
  until `vol <n>` picks one. A disk that goes away takes its volumes with
  it; a stick plugged in again comes back read-only.
- **FAT32** (`fat.asm`): long names are read and written; a new long name gets
  the shortest `NAME~n.EXT` alias nothing else in the directory has, and an 8.3
  name in one case is stored as 8.3 with the lowercase flags Windows uses.
  There is one cached FAT sector (written to every FAT copy) and one cached
  directory sector; file data goes straight to its clusters. Every operation
  ends by flushing both caches, updating FSInfo's next-free hint and telling
  the drive to flush. Replacing a file empties its entry before freeing the
  old clusters, so an interrupted write leaves an empty file, not a dangling
  chain.
- Shell: `disks`, `vol`, `ls`, `cd`, `cat`, `cp`, `write`, `mkdir`, `rm`.
  File times come from the CMOS clock (`rtc.asm`, also `date`).
- Tested in QEMU against images from `tools/mkdisk.py` (512-byte and 64 KiB
  clusters, two drives at once, a USB stick direct and behind a hub, pulled
  and plugged in again), checked by `tools/fatcheck.py` and 7-Zip.
  Not yet: 4 KiB-sector drives tested, UAS (USB Attached SCSI), exFAT/NTFS.

## Log: `log.asm`

Every `KLOG` line (and every shell command line) also goes into a 1 MiB
buffer, so the whole log of a boot is kept; past 1 MiB it says it is full and
stops. `log.asm` saves it as `/AXIOM.LOG` on the boot stick: the one
**removable**, mounted FAT32 volume whose serial number matches the one the
loader read. A fixed disk never qualifies, nor does any other stick; two
sticks with the same serial and neither is written. That one file needs no
`vol <n> rw`: the volume is made writable for the save and put back as it was.

Saved once the stick is mounted after boot, then every 10 s while the log
grows, before `reboot` and `poweroff`, and after a panic: the report is
appended and saved, unless the crash came in the middle of a FAT write
(`fat_need_rw` sets `fat_writing`, the shell clears it between commands),
when the FAT code's state can't be trusted. USB transfers are polled, so the
save works with interrupts off. A failed automatic save turns automatic saving
off. `log` shows the state; `log save`, `log on`, `log off`.

## Network: `rtl8168.asm`, `net.asm`, `tcp.asm`, `netapp.asm`, `http.asm`

- **Realtek** (`rtl8168.asm`): the RTL8111/8168 family (the Victus's "Gaming
  GbE", 10EC:8168), and the RTL8139C+ QEMU emulates, whose C+ mode uses the
  same descriptor rings and registers except the transmit poll and the link
  bits. G-family chips (XID 4c0 and later) are first taken from their
  out-of-band firmware and their RX gate is closed around the reset, as
  Linux does; the PHY gets an autonegotiation restart only if it was left
  powered down, isolated or forced. One receive ring (64 descriptors) and
  one transmit ring (32), a 2 KiB buffer each; frames are copied in and out.
  MSI-X or MSI wakes the main loop, which polls the ring; without either
  (QEMU's 8139) it polls every 4 ms.
- **Stack** (`net.asm`): drivers register an interface with a table of
  operations (send, poll, link, ack) and hand frames to `net_receive`. The
  first interface carries the one IPv4 address. ARP keeps 16 neighbours for
  five minutes and holds up to four frames while it asks (three times, a
  second apart). IPv4 checks header checksums, drops fragments, and routes
  through the gateway when the destination is off the subnet. ICMP answers
  echo requests sent to us; UDP checks checksums and hands port 68 to DHCP
  and the resolver's port to DNS; protocol 6 goes to TCP. Addresses stay in network byte order
  throughout (`%I` prints them, `%M` prints a MAC).
- **Clients** (`netapp.asm`): DHCP (discover, request, renew at half the
  lease, start over on NAK or link up), an A-record resolver (three tries,
  2 s apart) and ping (a TSC stamp in each request gives the round trip).
  Each runs on `net_service`'s timers, so the prompt comes back at once;
  ctrl+C stops a ping or a lookup.
- **TCP** (`tcp.asm`): the client side, eight connections. Something in
  the kernel opens one with a table of four handlers (open, data, the other
  side's FIN, gone and why) and writes into an 8 KiB send buffer. MSS 1460
  is offered and the peer's honoured; the window offered is a fixed 64240,
  because handlers take every byte as it comes. Retransmission follows RFC
  6298 (smoothed RTT and its variation in TSC ticks, Karn's rule, doubling,
  200 ms to 60 s, eight tries); RFC 5681's slow start and congestion
  avoidance start from a ten-segment window; three duplicate ACKs resend
  the oldest segment at once, and during that recovery each partial ACK
  resends the next hole (NewReno, RFC 6582). A closed window is probed one byte at a time,
  and when it opens the probe is resent at once. Segments
  after a gap are dropped and the ACK repeats what is missing; overlapping
  ones are trimmed. A segment for no connection gets a reset. Both closes
  work; TIME_WAIT lasts 10 s, and a new connection may take over a slot in
  it. `tcp` lists connections with their state, bytes and round trip.
- **HTTP** (`http.asm`): one request at a time for a client, a table of
  four handlers (the request, data, done, lost), so that `http` and `ask`
  share the connection, TLS and failure handling. `http_hangup` lets a
  client close as soon as it has what it wants. `http <host[:port][/path]>
  [file]` is its own client: one GET over HTTP/1.0 (so no chunks, and the
  server's close ends the body).
  Up to 1 MiB of the answer is kept; then the status line, `Content-Type`
  and `Location`, and the first 20 lines of the body, or the body goes to a
  file on the current volume. `https://` goes over `tls.asm` (below), port
  443 unless given: the TCP handlers pass bytes to `tls_input`, and the TLS
  handlers hand the plaintext to the same code. A TCP FIN without a
  close_notify first is reported (the answer may be cut short).
- Shell: `net`, `ip`, `dhcp`, `ping`, `host`, `arp`, `tcp`, `http`.
- Tested in QEMU with `tools/run.py --nic rtl8139`: DHCP, ping and DNS
  through QEMU's user network, and two Axiom VMs joined by a socket pinging
  each other, with every frame's checksums checked in the dump
  (`build/net-PORT.pcap`). HTTP from a server on the host (QEMU's 10.0.2.2)
  and from example.com, a 300 KB file saved and compared byte for byte.
  `tools/netpeer.py` is a deliberately unreliable peer on QEMU's socket
  backend: it drops the first SYN, the request, and data segments; reorders
  and duplicates others; refuses, resets, keeps silent, holds a zero window,
  and asks for 64-byte segments, with three duplicate ACKs at a gap. Every
  case completes, and the 200 KB it serves through the losses arrives
  intact. The RTL8168 code paths (G-family takeover, PHY, MSI) run only on
  real hardware. Not yet: a TCP server side, IPv6,
  other NICs.

## TLS: `tls.asm`, `rand.asm`, `sha256.asm`, `aesgcm.asm`, `x25519.asm`, and certificates

A TLS 1.3 client (RFC 8446) and the crypto under it.

- **The client** (`tls.asm`): one connection at a time, independent of what
  carries its bytes (a send function in, `tls_input` for what arrives, and
  four handlers out: READY, DATA, CLOSED, FAIL). It offers only
  TLS_AES_128_GCM_SHA256 and an X25519 key share, with server name
  indication, a random session id and the change_cipher_spec of RFC 8446
  D.4 for middleboxes. It reassembles records across TCP segments and
  handshake messages across records (up to 64 KiB each), keeps the
  transcript hash, runs the key schedule (early, handshake, master secrets;
  traffic keys and IVs; per-record nonces), checks the server's Finished in
  constant time, sends its own, strips record padding, ignores session
  tickets, follows KeyUpdate both ways, and ends with close_notify. A
  failure sends the matching alert and wipes every key. The certificate
  chain goes to `x509_chain` (below) with the server's name and the RTC's
  time; CertificateVerify is checked against the leaf's key, in a scheme
  that must suit it (ECDSA P-256 with 0x0403, P-384 with 0x0503, RSA with
  PSS 0x0804-0x0806; PKCS #1 v1.5 is refused there, as RFC 8446 says). With
  `http -k` the chain is not checked, only parsed for the leaf's key, so
  CertificateVerify still proves the server holds the key it sent.
- **Certificates** (`x509.asm`): X.509 v3 in DER. The leaf must name the
  host in a subjectAltName (DNS, with a wildcard only as the whole first
  label, or an IPv4 address; no Common Name fallback), be in date, and allow
  serverAuth and digitalSignature when it says what it is for. Each issuer
  is looked up among the trusted roots by the SHA-256 of its Name, else
  among the certificates sent (byte-exact Name match, any order, up to 8):
  it must be a CA, allowed keyCertSign, within its pathLen, in date, and
  its signature on the one below must hold. An unknown critical extension
  is refused. Dates get a day of slack (the RTC holds local time), and a
  clock before 2025 is reported rather than trusted. Each failure has its
  own message and TLS alert.
- **The trusted roots** (`gen/roots.asm`, made by `tools/mkroots.py`): the
  136 CAs of Mozilla's list, as certifi ships it, each reduced to the
  SHA-256 of its Name, its key and its name, 55 KB in all. `x509_extra`
  can point to one more table (the tests' CA).
- **Signatures** (`pubkey.asm`, on `bignum.asm`): RSA with 2048- to
  4096-bit keys, PKCS #1 v1.5 and PSS (MGF1, salt as long as the hash);
  ECDSA on P-256 and P-384 in Jacobian coordinates with Shamir's trick;
  each with SHA-256, SHA-384 or SHA-512 (`sha512.asm`). `bignum.asm` is
  Montgomery arithmetic (CIOS) on 64-bit limbs up to 4096 bits. Only public
  values pass through it, so it is not constant-time, and need not be.
- `tools/test/pki/run.py` checks all of it on the host: SHA-384/512 against
  hashlib; Montgomery products, powers and inverses against Python's
  integers over 141 moduli; 264 RSA and 442 ECDSA signatures, from OpenSSL
  and an independent reference, good and damaged; 43 chains made by OpenSSL
  (RSA and EC, intermediates, wildcards, addresses, every refusal) and 400
  damaged at random; the built-in roots compared with certifi; the chains
  of 20 real sites; register preservation. On this CPU an RSA-2048 check
  takes about 55 us, P-256 320 us, P-384 1 ms, a two-certificate chain
  under 0.5 ms.
- **Random numbers** (`rand.asm`): a SHA-256 pool stirred with RDSEED (else
  RDRAND) and the TSC on every call, moved on after each use; TLS refuses
  to start on a CPU with neither.
- `tools/test/tlsclient/run.py` builds the client into a DLL and runs it
  against Python's ssl module (OpenSSL 3.5) as the server, over memory
  buffers that deliver bytes in pieces down to one at a time: RSA and ECDSA
  certificates, a 21-certificate chain of 16 KB, no SNI for an address,
  200 KB down, 40 handshakes writing from inside READY, close_notify both
  ways; a flipped bit, TLS 1.2-only, client-certificate and P-256-only
  servers, a full connection, a cut-off handshake. A hand-made server
  (`minisrv.py`, on the pure-Python references) covers what OpenSSL will not
  do on request: a wrong Finished, KeyUpdate with and without a request,
  padding, empty records, messages cut across records, oversized records.
  Live, the same DLL fetched pages from example.com, cloudflare.com,
  google.com and github.com. With certificates checked: the test CA as
  an extra root, then a chain to no trusted root, another name, another
  address, twenty years on and a clock in 2024 each refused with the
  right alert; a forged CertificateVerify and three in the wrong scheme
  refused; `--live` fetches from eight real sites, each verified.
- In QEMU, `http https://example.com/` (verified to its root), and from
  `tools/httpsd.py`, whose test CA Axiom does not trust: refused, then a
  300 KB file with `http -k` (saved, compared byte for byte).

- **SHA-256** (`sha256.asm`): one call or init/update/final over a context
  the caller owns (copyable, so a transcript hash can be forked). Blocks go
  through the SHA extensions when CPUID has them (`sha256rnds2`,
  `sha256msg1/2`), else plain x86; `sha256_mode` says which. On top: HMAC,
  HKDF-Extract and -Expand (RFC 5869) and TLS 1.3's HKDF-Expand-Label
  (RFC 8446 7.1).
- **AES-128-GCM** (`aesgcm.asm`): key expansion with `aeskeygenassist`,
  counter mode with `aesenc`, GHASH with four `pclmulqdq` and Gueron's
  reduction on byte-reflected blocks. Seals and opens in place, tag after
  the data; opening compares the tag in constant time and leaves the record
  untouched when it is wrong. `gcm_supported` says whether the CPU can.
- **X25519** (`x25519.asm`, RFC 7748): field elements as four 64-bit limbs,
  products folded with 2^256 = 38 (mod p), a 255-step Montgomery ladder with
  masked swaps; no branch or memory address depends on the secret scalar,
  and the scratch is wiped afterwards.
- All three preserve every general register but RAX and clobber at most
  XMM0-XMM10; their scratch is in .bss, so main loop only.
- `cryptotest.asm` checks each against its published vectors (FIPS 180-4,
  RFC 4231, RFC 5869, RFC 8448, GCM test case 4 with a forged tag refused,
  RFC 7748, SHA-384/512 of "abc", RFC 6979's P-256 signature, and RSA-2048
  PKCS #1 v1.5 and PSS and P-384 signatures made for the tests, each also
  with a changed byte that must be refused) at boot, both SHA-256 paths
  when the CPU has SHA-NI, and logs one line. `crypto` repeats the check
  and times SHA-256 (each way), AES-GCM, one X25519 and each signature
  check.
- `tools/test/tls/run.py` runs them on the host: the published vectors plus
  about 670 random cases from independent references (hashlib; a pure-Python
  AES-GCM and X25519 written from SP 800-38D and RFC 7748, each made to
  reproduce the published vectors first), every buffer at odd addresses or
  against a no-access page, hashes fed in uneven pieces, a flipped bit in
  tag, ciphertext and additional data refused, X25519's non-canonical inputs,
  RFC 7748's 1000-fold iteration, register preservation through `kcall`, all
  with plain-x86 SHA-256 and again with SHA-NI. On this i7-14700F: SHA-256
  about 1.6 GB/s on SHA-NI (210 MB/s plain), AES-128-GCM 575 MB/s, X25519
  64 us.

## Claude: `claude.asm`, `json.asm`, `text.asm`

`ask <question>` talks to Claude through the Messages API.

- **The request**: `POST /v1/messages` over HTTP/1.1 with `x-api-key`,
  `anthropic-version: 2023-06-01` and `Connection: close`; the JSON body
  holds the model (`claude-opus-5-5` unless `claude model` says otherwise),
  `max_tokens` 4096, `stream: true`, a system prompt saying the console shows
  plain text only, and the whole conversation, which is kept in memory (80
  KiB, the oldest exchanges dropped first) and sent each time. A question
  that gets no answer leaves it again; a partial answer stays.
- **The answer** is undone a byte at a time, so it may arrive cut anywhere:
  the headers (status, `Transfer-Encoding: chunked`, `Content-Type:
  text/event-stream`, `Content-Length`), the chunks, lines of server-sent
  events, and each event's JSON. `content_block_delta` text is shown as it
  comes; thinking and other blocks are not; `message_start` and
  `message_delta` give the token counts and the stop reason; at
  `message_stop` Axiom hangs up without waiting for the server's close. An
  `error` event, or a body that is not events (401, 400, 529...), is said
  with the API's own message.
- **On the screen** the answer is wrapped at word boundaries, tracking the
  console's column; its UTF-8 is decoded (`text.asm`) and each code point
  drawn as the font has it (ASCII, or one of its 39 symbols: bullets,
  arrows, box drawing, check marks), as a look-alike (curly quotes, dashes,
  accented Latin letters) or as `?`. The log and the serial port get the
  UTF-8 itself.
- **JSON** (`json.asm`): find a key in an object, read a string (escapes,
  `\u` and surrogate pairs to UTF-8, cut on a character boundary), a number,
  skip any value; and escape text for a string.
- **The key** is typed (`claude key <key>`: the shell shows it as stars and
  logs `claude key (not logged)` instead, and it never enters the line
  history) or read from `CLAUDE.KEY` at the top of the boot stick (`NAME=`
  and quotes around it are dropped). It lives in memory only; the request
  buffer that held it is wiped after each answer.
- The shell waits for the answer: its prompt comes back when it is over, and
  ctrl+C stops it (`shell_wait`, `shell_resume`; `http` does the same).
- `tools/test/claude/run.py` boots Axiom in QEMU against
  `tools/claudemock.py`, a mock of the API that checks every request (the
  JSON, the headers, each earlier answer sent back byte for byte) and
  answers in chunks of random sizes sent in random pieces, with `\u`
  escapes or raw UTF-8 at random, so every layer sees its input split
  anywhere. It covers echoed Unicode, 7.5 KB answers, thinking blocks,
  bodies that end at the close, max_tokens, an error event, a dropped
  connection, 400, 401, ctrl+C mid-answer, a conversation that grows to 21
  messages, `claude new`, and a server whose certificate is not trusted;
  `--live` asks the real API with a made-up key (401) and fetches
  example.com.

## Graphics and text: `gfx.asm`, `console.asm`, `ui.asm`

The framebuffer is mapped write-combining, so stores stream out in 64-byte
bursts. The font is Cascadia Mono rasterized at three sizes by
`tools/mkfont.py` into 8-bit coverage maps; glyphs are alpha-blended over the
background. The kernel picks the largest size that still leaves at least 50
text rows. The dashboard is laid out in font cells: header, SYSTEM and
CONSOLE on the left, PROCESSORS tiles and the MANDELBROT view on the right.

## Telemetry: `cpu.asm`

- **Clock:** the APERF/MPERF ratio over each 500 ms interval, times the TSC
  frequency.
- **Temperature:** `IA32_THERM_STATUS` against `MSR_TEMPERATURE_TARGET`
  (TjMax).
- **Package power:** the RAPL energy counter's delta, scaled by its unit.
- Every CPU samples its own MSRs in a `job_run_each`. A reading that isn't
  available (as under QEMU) shows as "--".

## Demo: `mandel.asm`

Four 64-bit doubles per YMM register, two registers interleaved per step to
hide FMA latency, so 8 pixels per inner iteration. `vcmppd` builds the escape
mask, `vpsubq` counts iterations in each lane, and `vtestpd` leaves as soon as
all 8 have escaped. Rows are jobs. The zoom heads into the seahorse valley at
0.965× per frame, with the iteration limit rising from 192 to 4096, and
restarts before double precision runs out.

## Power: `power.asm`

Reboot and power-off use UEFI `ResetSystem` first, on the firmware tables. Fallbacks: the ACPI reset
register, port CF9, the 8042 and a triple fault for reboot; ACPI S5 (SLP_TYP
from `_S5_`) for power-off, then QEMU's port 0x604.

## Conventions

- System V-like: arguments in RDI, RSI, RDX, RCX, R8, R9; result in RAX;
  RBX, RBP, R12 to R15 preserved. Many leaf helpers preserve more, and say so
  in their header comment.
- `KLOG "fmt", args...` logs to serial and, once the console exists, to the
  screen; `SPRINTF buf, "fmt", args...` formats into memory. Arguments are
  64-bit registers, immediates or `qword [mem]`.
- Structures are `equ` offsets (`PC_*`, `TH_*`, `OB_*`, `TK_*`, `CAP_*`,
  `HS_*`, `EV_*`, `MO_*`, `RG_*`, `RA_*`, `SQ_*`, `CQ_*`, `RQ_*`, `TM_*`, `PE_*`, `XC_*`, `DV_*`, `NV_*`, `DK_*`, `VO_*`,
  `VF_*`).
- Errors are `E_*`, small negative numbers. The kernel's pointers are
  negative too (the upper half), so a function that returns a pointer or an
  error is checked with `cmp rax, E_ANY` and `jae`, not the sign.
- Self-contained modules are also tested on the host: `tools/test/<module>/`
  assembles the module with a small shim and drives it from C or Python.
