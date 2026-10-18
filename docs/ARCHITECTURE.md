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
4. The TSC's rate: from CPUID leaf 0x15 (crystal × ratio) when the CPU
   gives all of it and a 5 ms `Stall` agrees within a factor of two; else
   measured against a 50 ms `Stall`. The loader keeps a TSC mark after each
   step for `bench boot`.
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
| 5 | `gfx.asm`, `desk.asm`, `term.asm`, `window.asm`, `ui.asm` | Framebuffer, surfaces, alpha-blended glyphs; the desktop and the first shell's window (the others once the machine is up) |
| 6 | TSS, IST | Guarded stacks: the BSP moves onto its own, the loader's goes back; #DF, NMI and #MC each get one too |
| 7 | `acpi.asm`, `smbios.asm` | MADT (CPUs, I/O APICs, overrides), MCFG, FADT, `_S5_`; board, BIOS and memory strings; OEM strings (`axiom.demo=off`: no zoom at boot) |
| 8 | `pmm.asm` | Reclaim boot-services memory |
| 9 | `apic.asm` | x2APIC through MSRs, else xAPIC MMIO; 8259s masked; I/O APIC entries masked |
| 10 | `object.asm`, `sched.asm`, `ring.asm` | The task `kernel`, which everything at boot acts for; the scheduler: the code running from here on is the thread `main`; the timer is the scheduler's; `async_boot`: the timers' heap and the thread `async` |
| 11 | `smp.asm` | Start every other thread (below), then `sched_topology`: each CPU's kind and SMT sibling |
| 12 | `pci.asm` | Enumerate through ECAM, else ports CF8/CFC |
| 13 | `iommu.asm` | VT-d units from the DMAR, translating before any driver starts: no device reaches memory until its driver maps some |
| 14 | `kbd.asm`, `usb.asm` | PS/2 keyboard on IRQ 1; xHCI controllers and whatever is plugged in at boot (later devices arrive through hot-plug in the main loop) |
| 15 | `nvme.asm`, `disk.asm`, `fat.asm` | NVMe controllers, their partitions (and those of USB sticks found in step 14), FAT32 mounted read-only |
| 16 | `net.asm`, `rtl8168.asm` | Ethernet controllers; DHCP starts once the link is up |
| 17 | `mandel.asm`, `shell.asm` | Palette, view, shell; interrupts on |
| 18 | `store.asm` | The object store, from the first drive holding one (below) |

Then `main_loop`: poll and service USB (enumeration, hot-plug), service the
network (frames in, link, DHCP/ARP/ping timers), save the log if it grew
(every 10 s), apply pointer movement (to the window under it), take keys (to
the window with them), refresh telemetry every 500 ms, render a demo frame at
most every 16 ms while its window is shown (or at once after a click or the
wheel), destroy windows that closed, draw what was printed into each
terminal, compose the screen where it changed, and otherwise park
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
  answers other shootdowns as it waits. A CPU asleep in its idle `hlt`
  (`PC_TLB_LAZY` = 1) is neither sent the IPI nor waited for: the shootdown
  marks it (1 → 2, by `cmpxchg`), and it flushes its whole TLB as it wakes,
  in `isr_common` before any handler runs, so it never touches a page that
  was taken away. The others then get the IPI one by one.
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

## Ring 3: `user.asm`, `src/user/`

- **A program is a task with page tables of its own.** Its name typed in
  the shell (or `run <name>`) reads `/EFI/AXIOM/<NAME>.AXE` from the boot stick (or the volume chosen): a flat
  file assembled at `USER_IMAGE` (0x400000), its header first (`AXE_*`:
  'AXIOMEX2', the entry, where code, constants, data and zeroes end, each
  section on pages of its own, and `AXE_WANTS`: the capabilities it wants,
  `AW_NET`, `AW_STORE`, `AW_DESK`, said in its source by `WANTS`). The loader checks the header, makes a
  task and an address space, and maps the code read-only and executable,
  the constants read-only, the data and zeroes writable and not executable,
  a 64 KiB stack under `USER_STACK_TOP` with nothing below it, and a
  read-only start block at `USER_START` (`SB_*`: handles to the task's ring,
  its memory and the console; to the store, the network and the desktop
  only if it wants them or the shell grants them (`+store`, `+net`,
  `+desk`), 0 otherwise; what the task that started it gave it, where
  the ring is, the TSC rate, the arguments). The first thread starts at the
  entry with RDI = the start block, every other register 0. A file larger
  than `fat_file` (64 KiB) is read whole into a buffer of its own, up to
  `USER_IMAGE_MAX`.
- **Programs start programs.** `SYS_SPAWN` takes "program arguments" from
  a block of memory and a handle to give: the main thread alone reads the
  boot stick, so the request goes to it (`spawn_list`; the main loop, or
  `user_wait` when the main thread is waiting for a program itself, loads
  it) and the caller waits, not to be cut short meanwhile. The new task is
  the caller's child (`TK_PARENT`); the gift moves to it before it runs
  (`task_give`), its number in `SB_GIFT`, and the caller gets handles to the
  task (`RT_TASK_KILL` among its rights, for `RO_KILL`) and its first thread
  (`RO_JOIN`). Eight programs deep, no more.
- **Every set of page tables shares the kernel's upper half**: a new PML4
  copies entries 256 to 511 of the kernel's, which never change after boot.
  The lower half is the task's: user pages are never global. Blocks of
  memory a task maps (`SYS_MAP`) go from `USER_MAPS` up, a guard page after
  each, and are the memory object's own pages, so the kernel and the task
  see the same bytes. **A mapping is its capability's** (`CAP_MAPVA`): it
  goes, and every CPU's TLB forgets it before the memory can, when that
  handle is closed, revoked from the one it was derived from, given to
  another task, or unmapped (`SYS_UNMAP`); the PTEs are cleared under
  `cap_lock` (then the address space's lock) and the shootdown and the
  reference wait until it is let go. Addresses are never used twice, so
  nothing stale can point at a new mapping. `sched_switch` loads the next thread's tables (the kernel's for
  a kernel thread) before it lets go of the one before, so tables are freed
  only once no CPU can be on them, and sets the TSS's RSP0 and the per-CPU
  SYSCALL stack to the next thread's kernel stack.
- **System calls** (`SYS_*`) come in by `SYSCALL` at `syscall_entry`: SWAPGS,
  onto the thread's kernel stack, a frame laid out as an interrupt's
  (`FR_*`, vector `VEC_SYSCALL`), interrupts back on, and out by `SYSRET`.
  Arguments in RDI, RSI, RDX and R10; RAX and RDX back; RCX and R11 lost;
  everything else kept. They are only what a ring cannot do: enter it, make
  rings, memory, events, threads and channels, map and unmap memory, start
  a program, yield, exit. The rest is an
  entry on a ring: a program writes to the console with `RO_WRITE` (a
  handle to the console, `OT_CONSOLE`, with `RT_CON_WRITE`, and text in a
  block of memory). The kernel never touches a program's pages at their
  user addresses, and SMAP would stop it if it did; FSGSBASE is off, since
  the FS and GS bases are not kept for each thread.
- **A fault in ring 3 ends the task, not the machine.** `exception_dispatch`
  sends every exception from ring 3 (but NMI and machine check) to
  `user_fault`, which says what it was and where (for a page fault, what the
  access ran into), marks the task killed by a fault and ends the thread.
  **Killing a task** (`task_kill`) marks it; each of its threads ends the
  next time it would go back to ring 3 (`user_leave`, on the way out of
  every system call and every interrupt from ring 3), one parked is woken
  (`wq_wait_fn` waits no more for a thread whose task is killed), and one
  running on another CPU gets a reschedule IPI; and every task it started is
  killed, and theirs. When a task's first thread ends (`TF_FIRST`), the task
  is killed; once a killed task's last thread has gone, its handles are
  closed even while others hold handles to it, and when the last reference
  goes, its pages, page tables and mappings go too.
- **Jobs:** a program run from the shell is a job (`user_jobs`, `JB_*`, 16
  at most): its task, the terminal it was run from (`JB_CON`; the task's
  `TK_CON`, inherited by every task it starts, is where its console lines
  go), and a thread of its own (`user_waiter`) that waits for it. In front,
  the prompt waits for it; ctrl+C kills it, not those in the background.
  With `&` the prompt comes back at once. When one ends, the main loop
  (`user_service`) says how in its terminal and, if it was in front, the
  prompt comes back; an exit code other than 0 is a failure to `&&` and
  `||` (`TW_SH_FAILED`). A terminal that closes kills its jobs. `user` counts programs and their
  pages. `user test` runs TEST.AXE (which checks the start block, its ring,
  registers kept across calls, refusals, events, a thread of its own, four
  more on a shared counter, a timeout, 64 KiB copied by the kernel, its own
  sections, a second ring, the console's refusals, SIMD registers kept
  across yields, 80 KiB of constants loaded whole, unmapping and mapping
  again, a channel between its own two ends, CHILD.AXE started with a
  channel's end and echoing over it, programs that may not start, programs
  starting programs eight deep, and a child killed with the grandchild it
  started), FAULT.AXE with each kind of fault (memory touched after its
  mapping was unmapped, closed or revoked among them), and SPIN.AXE
  spinning, parked in its ring, calling the kernel, and with a thread that
  faults, each killed and timed; then that nothing is left over.

## Channels: `channel.asm`

- **A channel is two ends**, each an object (`OT_CHANNEL`, `CH_*`); what one
  sends waits at the other, oldest first, a copy of its bytes (`CM_*`, from
  the heap, `CH_MSG_MAX` bytes and `CH_QUEUE_MAX` waiting at most).
  `SYS_CHANNEL_NEW` makes both; a task hands one on by `RO_GIVE` or as a
  program's gift. `RO_SEND` copies from a block of memory; `RO_RECV` copies
  the next message out, or says `E_EMPTY`, or `E_RANGE` (and leaves it)
  when it does not fit. `RO_WAIT` on an end waits, blocking nothing, for
  `CH_READY` (a message waits, or the other end is gone), so `RO_WAIT`
  linked to `RO_RECV` receives the next message when it comes.
- When either end's last handle goes (`TY_ORPHAN`) or the end itself does,
  the two are cut apart (`CH_PEER` = 0) and whatever waits at either is
  woken: the other's sends say `E_PEER`, and its receives do once what was
  sent before is read. `ch_lock` covers every end and queue; no memory is
  copied with it held, and a message the receiver could not take goes back
  first in line.

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
reschedule, `0x43` NVMe completions (an MSI-X entry per queue, each to its
own CPU, outside `0x20` to `0x2F` so the main loop is not woken), `0x44`
VT-d faults (to the BSP), `0xFF` spurious. Every stub saves all general registers and calls
the handler registered with `irq_register`; after a device's (`0x20` to
`0x2F`) it unparks the main loop. The common path sends the EOI, then
switches threads if the scheduler asked. From ring 3, the stub SWAPGSes in
and out, and on the way out a thread whose task is being killed ends
instead. Exceptions from ring 3 end the task (Ring 3, above); those in the
kernel go to `panic`, which stops the other CPUs and paints a full report
(registers, CR2, CR3, segments, the thread, and for a page fault what it ran
into) on screen and serial.

## DMA isolation: `iommu.asm`, `iommutest.asm`

- **Every DMA goes through VT-d.** `iommu_init` (after PCI, before any
  driver) finds each remapping unit in the ACPI DMAR table, maps its
  registers and gives it a root table; the firmware's own translation and
  protected memory regions are turned off first. Page tables are 4-level
  (48-bit) if every unit takes them, else 3-level. Then each unit
  translates, with no device in any domain: a device nobody drives reaches
  no memory at all. Interrupt remapping stays off, so MSIs pass as they are.
- **A domain per driver** (`DM_*`): USB (every xHCI controller), NVMe
  (every controller) and the network (every card). A driver makes its
  domain with `iommu_domain_new` and puts each of its devices in it
  (`iommu_attach`: the context entry for its bus and function, made under
  its unit's lock, every cached context and IOTLB entry forgotten) before
  it turns bus mastering on. Addresses are one to one: a device is handed
  physical addresses as before, and any its domain does not hold fault.
  The firmware's reserved regions (RMRR) are mapped for the devices they
  name, in a domain of the firmware's until a driver claims the device,
  then in the driver's.
- **What a driver maps** (`iommu_map`, `iommu_unmap`, and `_va` forms that
  look each page up): `usb_alloc_page` and `nvme_alloc_page` map every page
  they hand out (rings, contexts, queues, PRP lists), a USB device's pages
  are unmapped before they are freed, the USB sticks' bounce buffer and the
  network card's rings and buffers are mapped once. **An NVMe command's
  buffer is mapped for the command alone**: in the domain (writable for a
  read, readable for a write) when it is submitted, out once it completes,
  left in only if it timed out. A leaf entry counts the maps holding its
  page in bits the unit ignores (52-61), so two commands sharing a page
  each leave it as they found it. Unmapping a page forgets it in every
  translating unit's IOTLB (page-selective if the unit can, else the whole
  domain) before it returns; a buffer of many pages (`iommu_map_va`,
  `iommu_unmap_va`) is forgotten once for all of them, as a unit in caching
  mode (QEMU's) is told once of all the pages mapped. On a unit that does not snoop the caches,
  every table and entry written is flushed with `clflush`.
- **Faults** are recorded by the interrupt (or by `iommu_faults` when
  asked): who (bus, device, function), reading or writing what page, and
  why, kept in a ring of the last 16; the main loop says each one
  (`iommu: fault: ...`).
- `iommu` lists the units, the domains (devices, pages, page tables, maps,
  unmaps) and the last faults. `iommu test` tells the first NVMe controller
  to read into a page no domain holds (`nvme_io_raw`, the buffer left out):
  a fault must name the controller writing that page, and the page must be
  untouched; then the page is mapped and read into, then unmapped and
  refused again, which shows the IOTLB forgot it. Under QEMU
  (`tools/run.py` gives every boot an `intel-iommu` unless `--no-iommu`)
  every suite runs with its DMA confined; `tools/test/iommu/` checks the
  NVMe, a USB stick and a network card through their domains, and a boot
  without VT-d.

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
  admin queue pair, polled, for setting it up. Identify gives the model,
  firmware, transfer limit (64 KiB at most) and the first active namespace.
  Then **an I/O queue pair per CPU**: as many as Set Features (Number of
  Queues) grants, the MSI-X table holds and `NV_QMAX` (32) allows. MSI-X
  entry *i* is aimed at CPU *i* with `VEC_NVME`, and queue *i* + 1's
  completions come through it; CPU *c* submits on queue *c* mod *n* + 1, so
  with a queue for every CPU a command is submitted and completed on the
  same CPU. Each queue (`NQ_*`) has its own lock, taken with interrupts off.
- **A command** (`nvme_io`) goes straight from or into the caller's buffer,
  dword-aligned and mapped: PRP1 is where it starts, PRP2 the second page
  or the slot's own PRP list of the rest, each page looked up in the page
  tables, so vm-region buffers scattered in physical memory are fine. The
  command and its request (`NR_*`) are on the caller's stack; the slot is
  the command identifier. The caller parks (`thread_park_until`, 10 ms at a
  time) and the interrupt on the queue's CPU (`nvme_irq`) drains the
  completion queue (`nvme_drain`): each request gets its status, is marked
  done, its thread unparked, then marked let go, and only then may the
  waiter return. A waiter whose 10 ms pass drains the queue itself; at boot
  (interrupts off) or without MSI-X it polls. A command that times out
  leaves its slot taken until the controller answers. The disk operations
  split a transfer into commands and send a buffer that is not
  dword-aligned through a copy from the heap.
- `nvme` lists each controller and its queues (CPU, commands, interrupts,
  polls that found something, errors). `nvme test` reads the first MiB once,
  then a thread pinned to every CPU makes 200 reads of 1 to 128 blocks at
  random places and at random dword offsets, each checked against the first
  read; every queue must be used and interrupted. Only on a drive whose
  serial is `AXIOMTEST` (QEMU's, in `tools/test/nvme/`) does each thread
  then write 128 KiB of its own after the first MiB, read it back and flush;
  the Victus's drive is never written.
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
  directory sector; file data goes straight to its clusters, a run of
  clusters one after another read in one request (up to 1 MiB). Every operation
  ends by flushing both caches, updating FSInfo's next-free hint and telling
  the drive to flush. Replacing a file empties its entry before freeing the
  old clusters, so an interrupted write leaves an empty file, not a dangling
  chain.
- Shell: `disks`, `vol`, and the `files` thing (`files show`, `copy`,
  `move`, `new`, `write`, `remove`, `find`), `go`, `here`.
  File times come from the CMOS clock (`rtc.asm`, also `date`).
- Tested in QEMU against images from `tools/mkdisk.py` (512-byte and 64 KiB
  clusters, two drives at once, a USB stick direct and behind a hub, pulled
  and plugged in again), checked by `tools/fatcheck.py` and 7-Zip.
  Not yet: 4 KiB-sector drives tested, UAS (USB Attached SCSI), exFAT/NTFS.

## Store: `store.asm`, `storetest.asm`

- **On disk**, in 4 KiB blocks: two superblocks (blocks 0 and 1, `SU_*`),
  then a log that is only ever appended to. The superblock in use is the
  newer one whose SHA-256 is right; the next goes into the other slot, so a
  torn superblock write leaves the one before. It holds the head (the newest
  commit's hash and number), where the log ends, the newest journal record,
  and up to 32 snapshots (a name, a commit).
- **Objects are named by their SHA-256**: a blob is what a name holds (up to
  1 MiB), a tree (`TR_*`) every name, sorted, with its blob's hash, size and
  the commit that set it (up to 1024 names), and a commit (`CM_*`, 512
  bytes) its tree, the commit before, and its provenance: the task, its name
  (or `console`), the capability object, its rights and prefix, the time, why,
  and how many names it added, changed and removed; a rollback also says to
  which commit. Bytes already there cost nothing: the same hash is the same
  object.
- **A commit** writes its new blobs, its tree and itself, then a journal
  record (`JR_*`: the commit, the one before's record, and each new object's
  hash, block and size, all under a SHA-256), flushes, writes the
  superblock, and flushes again. Until that superblock is down the store is
  as it was: whatever was written lies past the log's end and is written
  over by the next commit. `store tear` stops a commit just short of it, on
  purpose. **Mounting** walks the journal back from the newest record, each
  one checked: every object into the index (an open-addressed table from
  hash to block, in memory) and every commit into the chain (number to
  hash); then the head's tree is read, its hash checked like every object
  read.
- **Transactions**: changes (`SX_*`: put or remove, a name, a copy of the
  bytes) are staged in a transaction (`TX_*`), the console's own or a store
  capability's, up to 128 at once; reads through it see them first. Each
  change keeps what the head held under its name when it was staged, and a
  commit that finds the head changed there since is refused (`E_CONFLICT`)
  and drops nothing; one that changes nothing is `E_EMPTY`. `store diff`
  shows what is staged, or what changed between two commits.
- **Rollback** is a new commit: under the capability's prefix its names are
  those of the commit asked for, each with the commit that set it then, so
  rolling everything back makes that commit's very tree again; names outside
  the prefix stay as they are. Undo is a rollback to the commit before the
  head. Nothing is ever lost, since every commit is still in the log.
- **Programs reach the store by capability** (`OT_STORE`): an object with a
  prefix and a transaction of its own; rights `RT_ST_READ`, `RT_ST_WRITE`,
  `RT_ST_COMMIT` and `RT_ST_ROLLBACK`. A program that wants the store
  (`AW_STORE`, or run with `+store`) gets one on `<name>/` (`SB_STORE`; read-only when the store is), and its names are
  seen without that prefix. Ring entries `RO_ST_PUT`, `RO_ST_GET`,
  `RO_ST_DEL`, `RO_ST_COMMIT` (why in a block of memory), `RO_ST_ABORT`,
  `RO_ST_SUB` (a capability on a narrower prefix, with fewer rights),
  `RO_ST_ROLLBACK` and `RO_ST_LIST`. Its errors: `E_CONFLICT`, `E_NONAME`,
  `E_IO`, `E_NOSTORE`.
- **Safety**: the store writes only to an NVMe drive whose serial is
  `AXIOMTEST` (QEMU's test drive): a store on any other drive is mounted
  read-only, and `store format` makes none there. No space is reclaimed yet.
- One operation at a time, under a lock a waiter yields on (the holder may
  park on the drive). Hashing uses SHA-NI on a kernel thread and plain x86
  in a system call, whose SIMD registers are its program's; both keep their
  working state on the stack.
- `store` says what is mounted; `store put|get|rm|ls|diff|commit|abort|log`
  work on the console's transaction; `store snap|unsnap|rollback|undo`,
  `store verify` (every object read back and hashed, the chain, both
  superblocks), `store format`, `store tear`, and `store test` (46 checks,
  through capabilities of its own). STASH (`src/user/stash.asm`) checks the
  same from ring 3 through its own, then keeps names for `stash put|get|ls`.

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

## Network: `rtl8168.asm`, `net.asm`, `ip6.asm`, `tcp.asm`, `netapp.asm`, `http.asm`, `httpd.asm`, `socket.asm`

- **Realtek** (`rtl8168.asm`): the RTL8111/8168 family (the Victus's "Gaming
  GbE", 10EC:8168), and the RTL8139C+ QEMU emulates, whose C+ mode uses the
  same descriptor rings and registers except the transmit poll and the link
  bits. G-family chips (XID 4c0 and later) are first taken from their
  out-of-band firmware and their RX gate is closed around the reset, as
  Linux does; the PHY gets an autonegotiation restart only if it was left
  powered down, isolated or forced. One receive ring (128 descriptors) and
  one transmit ring (32), a 2 KiB buffer each; frames are copied in and out.
  (With 64, a burst of small segments between two polls overran the ring,
  and each lost one cost TCP a retransmission timeout: over a second.)
  MSI-X or MSI wakes the main loop, which polls the ring; without either
  (QEMU's 8139) it polls every 4 ms.
- **Stack** (`net.asm`): drivers register an interface with a table of
  operations (send, poll, link, ack) and hand frames to `net_receive`. The
  first interface carries the one IPv4 address. ARP keeps 16 neighbours for
  five minutes and holds up to four frames while it asks (three times, a
  second apart). IPv4 checks header checksums, drops fragments, and routes
  through the gateway when the destination is off the subnet. ICMP answers
  echo requests sent to us; UDP checks checksums and hands port 68 to DHCP
  and ports from 49152 up to DNS; protocol 6 goes to TCP; IPv6 frames go
  to `ip6.asm`. Addresses stay in network byte order throughout (`%I`
  prints an IPv4 one, `%A` a 16-byte address of either family, `%M` a
  MAC).
- **IPv6** (`ip6.asm`), beside IPv4 on the same interface. Above IP an
  address is 16 bytes for either family, IPv4 as `::ffff:a.b.c.d`, so DNS,
  ping, TCP, `http` and sockets each keep one kind. At link up: a
  link-local address from the MAC (EUI-64), checked to be free (an NS from
  `::`, a second's wait), then up to three router solicitations 4 s apart.
  A router advertisement gives the router (and its lifetime), the hop
  limit, the MTU, a DNS server (RDNSS), the /64 on the link, and from the
  first prefix offered for it a global address (SLAAC), checked the same
  way; its valid lifetime is kept. NDP finds neighbours as ARP does (16
  kept, four frames held while it asks, three times a second apart) and
  answers solicitations for our addresses; an advertisement or a check for
  an address we are still checking means it is someone else's, and it is
  given up. An MLDv2 report says we listen to our solicited-node group,
  again when a router asks, so a switch that watches for them still passes
  NDP's multicasts to us. Hop-by-hop, routing and destination headers are
  passed over; fragments are dropped. ICMPv6 echo is answered; UDP (its
  checksum required) goes to DNS, TCP to `tcp.asm`. Sources: link-local
  for link-local and multicast destinations, else the global address; the
  router for what is off the link. `ip6` shows the addresses, router, DNS
  and neighbours; `ip6 <address>/64 [router] [dns]` sets them by hand,
  `ip6 auto` goes back to the router's, `ip6 prefer` puts AAAA before A.
  No DHCPv6, no privacy addresses, one global address.
- **Clients** (`netapp.asm`): DHCP (discover, request, renew at half the
  lease, start over on NAK or link up), a resolver for A and AAAA records,
  and ping over ICMP or ICMPv6 (a TSC stamp in each request gives the round
  trip). The resolver asks IPv4's DNS server while there is an IPv4
  address, else the one a router named; `host` asks for both kinds of
  record, the others for what can be reached: A, then AAAA when there is
  none, AAAA alone without an IPv4 address (AAAA first after `ip6
  prefer`). It keeps
  eight lookups at once (`dns_slots`), each from a random port of its own
  with a random id, both checked along with the server on the answer;
  three tries, 2 s apart; it reports to the shell or to a socket
  (`sock_dns_done`, `sock_dns_failed`, with why: no server, a bad name,
  busy, no such host, no address, refused, no answer). Each runs on
  `net_service`'s timers, so the prompt comes back at once; ctrl+C stops a
  ping or the shell's lookups.
- **TCP** (`tcp.asm`): sixteen connections, each with a 128 KiB send
  buffer. Something in the kernel opens one with a table of four handlers
  (open, data, the other side's FIN, gone and why) and a word of its own
  (`TC_USER`), or listens on a port (`tcp_listen`, eight listeners): a SYN
  there makes a connection half open (SYN_RCVD, eight at most per listener,
  its SYN+ACK resent on the timer and forgotten without a word if the
  handshake never ends), and the last ACK of the handshake makes it
  established and asks the listener's accept function, which may refuse it
  (a reset) or take it; then the listener's handlers hear TH_OPEN and the
  rest of that segment. Over IPv4 or IPv6, by the address's form; MSS 1460
  is offered (1440 over IPv6) and the peer's honoured. The
  window offered is a fixed 64240 for handlers that take every byte as it
  comes; one that asks for flow control (`tcp_flow`) is offered its limit
  less what it holds, data beyond that is left for the peer to send again,
  and `tcp_consumed` opens the window, with an ACK once it has grown by a
  segment from nearly shut, or by half. Retransmission follows RFC
  6298 (smoothed RTT and its variation in TSC ticks, Karn's rule, doubling,
  200 ms to 60 s, eight tries); RFC 5681's slow start and congestion
  avoidance start from a ten-segment window; three duplicate ACKs resend
  the oldest segment at once, and during that recovery each partial ACK
  resends the next hole (NewReno, RFC 6582). Going back to resend leaves
  `TC_MAX`, the furthest ever sent, where it was: an ACK up to it is taken
  and sending goes on from there, and only one beyond it is for something
  never sent (until this, the ACK for data sent before a timeout was
  refused, with all that came with it, and each side's ACK drew the other's
  forever). A closed window is probed one byte at a time,
  and when it opens the probe is resent at once. Segments
  after a gap are dropped and the ACK repeats what is missing; overlapping
  ones are trimmed. A segment for no connection gets a reset. Both closes
  work; TIME_WAIT lasts 10 s, and a new connection may take over a slot in
  it. `tcp` lists connections with their state, bytes, round trip and
  window, and listeners; `tcp echo <port>` sends back whatever comes to that
  port, through a 16 KiB window, consuming only what TCP's send buffer has
  taken (`tcp stop <port>` ends it).
- **HTTP** (`http.asm`): HTTP/1.1, one request at a time for a client, a
  table of five handlers (the request, the headers, data, done, lost), so
  that `http` and `ask` share the connection, TLS, failure handling and the
  taking apart of the answer, a byte at a time so that it may arrive cut
  anywhere: the status line and headers (8 KiB at most; 1xx answers passed
  over), then a body of `Content-Length` bytes, in chunks (extensions and
  trailers passed over), or up to the close, as the headers say, none
  after 204 and 304. Done says whether the body was whole. When it is and
  the server allows (HTTP/1.1 unless `Connection: close`; 1.0 only with
  `keep-alive`, and never for a body ended by the close), the connection
  is kept, one at most, for 30 s: the next request to the same host, port
  and scheme goes on it with no new handshake, and a kept one that closes
  meanwhile is forgotten. If it closes just as it is used, before anything
  comes back, the request goes again, once, on a new connection.
  `http_hangup` lets a client close as soon as it has what it wants.
  `http <host[:port][/path]> [file]` is its own client: a GET. Up to 1 MiB
  of the answer is kept; then the status line, `Content-Type`, `Location`
  and `Transfer-Encoding`, and the first 20 lines of the body, or the body
  goes to a file on the current volume. `https://` goes over `tls.asm`
  (below), port 443 unless given: the TCP handlers pass bytes to
  `tls_input`, and the TLS handlers hand the plaintext to the same code. A
  TCP FIN without a close_notify first is reported when the close is what
  ends the body (it may be cut short).
- **Server** (`httpd.asm`): `httpd <port>` serves the current volume, read
  only, until `httpd stop`; `httpd` says what it has done. GET and HEAD; a
  file with its length and a type from its extension, read whole into
  memory first (8 MiB at most, the main loop waiting on the drive); a
  directory with its `index.html`, or a listing of it in HTML, and one
  asked for without its last `/` is sent there first (301), so the
  listing's links work. Paths have `%XX` undone and may not climb out with
  `..`. Connections are kept as HTTP/1.1 has them (1.0 only with
  `keep-alive`), closed after 30 s unused; requests sent together are
  answered in order. Each connection's requests come through a window of
  4 KiB (`tcp_flow`), consumed as they are answered, so a client cannot
  send faster than it is served; a request's body is passed over (405 for
  any method but GET and HEAD). Answers go out as TCP's send buffer takes
  them, the rest after each round of the network (`hd_tick`). Bad
  requests get 400, 414, 431, 501 (a body in chunks) or 505, and the
  connection is closed. Every request is logged: who, what, the status and
  the body's size.
- **Sockets** (`socket.asm`): the network for ring 3, by capability. `run`
  gives a program that wants it (`AW_NET`, or `+net`) one on the whole
  network (`OT_NET`, `SB_NET`);
  `RO_NET_SUB` makes narrower ones, on a host, every host under a name
  (`*.example.com`) or one port, with fewer of the rights `RT_NET_CONNECT`
  (plain TCP), `RT_NET_TLS` (TLS, the certificate checked),
  `RT_NET_INSECURE` (TLS, not checked) and `RT_NET_LISTEN`. A host is a
  name, an IPv4 address or an IPv6 one (bare or in brackets). A socket
  (`OT_SOCKET`, 32 at once) is a connection or a port listened on, with
  64 KiB each way in the kernel: `RO_SEND` and `RO_RECV` copy in what fits
  and out what came, and the main loop (`sk_tick`, from `net_service`)
  moves bytes between those and TCP, through TLS when asked, TCP's window
  (`tcp_flow`) being what is free on the way in. `RO_NET_CONNECT` gives
  the socket at once, the lookup, connection and handshake following;
  `RO_WAIT` on it waits for room to send (a0 = 1) or something to receive
  (a0 = 0), or for neither ever to come. `RO_NET_STATUS` says the state
  (lookup, connect, handshake, open, ended, failed, listening) and why it
  failed (`NETW_*`: the lookup's reasons, no link, no route, refused,
  reset, timed out, TLS with its alert, a port in use). `RO_NET_SHUT`
  sends a FIN once what was sent has gone; `RO_NET_LISTEN` and
  `RO_NET_ACCEPT` take connections, eight waiting at most. Errors: `E_FULL`
  and `E_EMPTY` for now, `E_PEER` at the end, `E_NET` on failure. When a
  socket's last handle goes, what it sent still goes out, then it is
  closed, or reset after 10 s. The program's side runs on any CPU, under
  `sk_lock` for state and with one sender and one receiver at a time
  copying without it. `sockets` lists them. NET.AXE (`src/user/net.asm`)
  is a client and server for it: `net get`, `net echo`, `net serve`, and
  `net test` (41 checks).
- Shell: `net`, `ip`, `ip6`, `dhcp`, `ping`, `host`, `arp`, `tcp`, `http`, `httpd`, `sockets`.
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
  intact. `tools/test/tcp/run.py` forwards host ports to `tcp echo` in the
  guest: 1 MiB echoed while read; 3 MB sent while nothing is read back,
  through a client with a 4 KiB receive buffer, until the guest's window
  is shut with all 16 KiB held, then all of it back in order; both FINs;
  twelve clients at once; a reset from a port nobody listens on; `tcp stop`.
  `tools/test/net/run.py` runs NET.AXE against servers on the host: `net
  test`, plain and TLS requests (the certificate refused when checked),
  eight connections echoing 200 KB each at once, four TLS sessions 100 KB
  each, eight by name through a DNS server of its own and a name that does
  not exist, three clients for `net serve`, and no socket left at the end.
  `tools/test/http/run.py` runs `http` against servers on the host: bodies
  by length, in chunks of random sizes sent in random pieces, up to the
  close, none, after a 100 Continue; the connection kept and used again
  (over TLS too), the retry when a kept one closes as it is used, a server
  saying `Connection: close`, one closing while idle, a body cut short,
  broken chunks; each body saved on the stick and compared afterwards, the
  host counting which requests came on which connection. Then `httpd`
  against clients on the host: files compared with `build/esp`, HEAD, 404,
  301, a listing, an `index.html`, `%20`, a POST passed over on a
  connection that goes on, three requests sent together, HTTP/1.0 closed
  or kept, five kinds of bad request, eight clients at once.
  `tools/test/ip6/run.py` boots three guests at once. One on QEMU's user
  network takes its address from QEMU's router, pings it, fetches from a
  server on the host's `[::1]` by length and in chunks on one connection
  and twice over TLS on another, and echoes through sockets on four
  connections at once. Two on a hub written in Python, which is also their
  router (prefix, RDNSS, NDP, a DNS server) and has no IPv4: the server
  runs `httpd`; the client pings it by name and the router by both its
  addresses, looks names up, and fetches 92 KB and 552 KB by the server's
  global address and by name, compared with `build/esp`, and a listing by
  its link-local address. The hub checks DAD for each address, the MLD
  reports and the solicitations.
  The RTL8168 code paths (G-family takeover, PHY, MSI) run only on
  real hardware. Not yet: IPv6, other NICs.

## TLS: `tls.asm`, `rand.asm`, `sha256.asm`, `aesgcm.asm`, `x25519.asm`, and certificates

A TLS 1.3 client (RFC 8446) and the crypto under it.

- **The client** (`tls.asm`): any number of connections, each a session
  (`TLS_SESSION`, about 100 KiB: keys, transcript, record and handshake
  buffers, the server's key and what its chain proved) that the caller owns
  and names in every call, independent of what carries its bytes (a send
  function in, `tls_input` for what arrives, and four handlers out: READY,
  DATA, CLOSED, FAIL, each told which session). Inside, RBP holds the
  session. The server's key is copied out of `x509.asm` as soon as its
  chain is checked, so another session's certificate cannot replace it
  before this one's CertificateVerify. It offers only
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
  ways; four sessions at once, fed a few bytes of each in turn, one's
  Certificate made to land between another's Certificate and
  CertificateVerify, then data both ways on all four; a flipped bit, TLS 1.2-only, client-certificate and P-256-only
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
  reduction on byte-reflected blocks. On a CPU with VAES, VPCLMULQDQ and
  AVX2 (`gcm_mode` 2; the i7-14700F has them) 128 bytes go at a time
  through YMM registers, two blocks to each: eight counter blocks encrypted
  together, and eight blocks hashed with a single reduction, each times the
  power of H it needs (H^8 down to H, made by `gcm_init`); the rest goes a
  block at a time. Seals and opens in place, tag after the data; opening
  compares the tag in constant time and leaves the record untouched when it
  is wrong. `gcm_supported` says whether the CPU can. Its scratch (the
  round keys copied out aligned, the counter, the hash) is on the stack and
  wiped, so a context may be used from any kernel thread, several at once.
- All three preserve every general register but RAX and clobber at most
  XMM0-XMM10 (AES-GCM on VAES also the upper halves of the YMM registers);
  AES-GCM keeps its scratch on the stack; SHA-256's one-call form, HMAC,
  HKDF and X25519 keep theirs in .bss (main loop only).
- `cryptotest.asm` checks each against its published vectors (FIPS 180-4,
  RFC 4231, RFC 5869, RFC 8448, GCM test case 4 with a forged tag refused,
  RFC 7748, SHA-384/512 of "abc", RFC 6979's P-256 signature, and RSA-2048
  PKCS #1 v1.5 and PSS and P-384 signatures made for the tests, each also
  with a changed byte that must be refused) at boot, both SHA-256 paths
  when the CPU has SHA-NI, AES-GCM on VAES against AES-NI (300 bytes after
  200 of AAD, sealed each way and opened) when it has VAES, and logs one
  line. `crypto` repeats the check and times SHA-256 and AES-GCM (each
  way), one X25519 and each signature check.
- `tools/test/tls/run.py` runs them on the host: the published vectors plus
  about 670 random cases from independent references (hashlib; a pure-Python
  AES-GCM and X25519 written from SP 800-38D and RFC 7748, each made to
  reproduce the published vectors first), every buffer at odd addresses or
  against a no-access page, hashes fed in uneven pieces, a flipped bit in
  tag, ciphertext and additional data refused, X25519's non-canonical inputs,
  RFC 7748's 1000-fold iteration, register preservation through `kcall`, all
  with plain-x86 SHA-256 and again with SHA-NI. On this i7-14700F: SHA-256
  about 1.6 GB/s on SHA-NI (210 MB/s plain), AES-128-GCM 640 MB/s on AES-NI and 3.3 GB/s on VAES, X25519
  64 us.

## Claude: `claude.asm`, `json.asm`, `text.asm`

`ask <question>` talks to Claude through the Messages API.

- **The request**: `POST /v1/messages` over HTTP/1.1 with `x-api-key` and
  `anthropic-version: 2023-06-01`, on the connection kept from the last
  question when there is one (no new TLS handshake); the JSON body
  holds the model (`claude-opus-5-5` unless `claude model` says otherwise),
  `max_tokens` 4096, `stream: true`, a system prompt saying the console shows
  plain text only, and the whole conversation, which is kept in memory (80
  KiB, the oldest exchanges dropped first) and sent each time. A question
  that gets no answer leaves it again; a partial answer stays.
- **The answer** is undone a byte at a time, so it may arrive cut anywhere:
  `http.asm` takes the HTTP apart (the status, headers and chunks); here,
  `Content-Type: text/event-stream` with a 200 says events come, then
  lines of server-sent events, and each event's JSON. `content_block_delta`
  text is shown as it comes; thinking and other blocks are not;
  `message_start` and `message_delta` give the token counts and the stop
  reason, `message_stop` the end. An `error` event, or a body that is not
  events (401, 400, 529...), is said with the API's own message; a body
  that ends before `message_stop` is said to be cut short.
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

## Graphics and text: `gfx.asm`

The framebuffer is mapped write-combining, so stores stream out in 64-byte
bursts; everything is drawn into memory first and copied out where it
changed. The font is Cascadia Mono rasterized at three sizes by
`tools/mkfont.py` into 8-bit coverage maps; glyphs are alpha-blended over the
background. The kernel picks the largest size that still leaves at least 50
text rows.

- **Surfaces** (`SF_*`): pixels, pitch, width, height, and the bytes
  allocated (`sf_size` grows them in 64 KiB steps; `sf_free`). The back
  buffer is one, each window's client another.
- **The target:** `gfx_fill`, `gfx_glyph` and the text functions draw into
  the surface `gfx_target` names (`gfx_target_back`: the back buffer),
  within a clip rectangle (`gfx_set_clip`; signed, so a window half off the
  screen clips right). `gfx_save`/`gfx_restore` keep the caller's.

## The desktop: `desk.asm`

- **Windows** (`WN_*`): where the frame is, the client's size, its surface,
  flags (`WF_SHOWN`, `WF_CLOSE`, `WF_RESIZE`, `WF_CLOSING`, `WF_PROGRAM`), an
  id, a title, and an ops table: paint, key, click (press and release, at a
  point in the client), wheel, close, move. `win_new` makes one, cascaded
  unless told where; `win_move`, `win_resize` (`win_fit`: at least its
  minimum, at most the screen, repainted), `win_focus` (raised, with the
  keys), `win_minimise`, `win_close` (destroyed by the main loop, after its
  own close op).
- **Stacking:** `desk_z` bottom to top, `desk_wins` by slot (the bar's
  order), `desk_focus` the window with the keys. A title bar always stays
  on the screen, under the bar.
- **Damage:** `win_damage` (any thread) adds a rectangle of the screen to a
  list of 16 under a lock (once it is full, one rectangle around them
  all).
  `desk_update`, on the main thread, composes each one into the back buffer
  (the background, the windows bottom to top, each frame then its client
  copied in, the bar last) and copies it to the screen.
- **The frame:** a border, a title bar with a minimise button (and a close
  button if the window can close), and a grip in the client's corner if it
  resizes. **The bar** across the top: AXIOM, `+ shell`, a button per window
  (a click shows, raises or minimises it), the status at the right end.
- **The pointer** (`desk_press`, `desk_release`, `desk_motion`,
  `desk_wheel`): a press raises and focuses what is under it; on a title
  bar it drags, on the grip it resizes, on a button it waits for the release
  over the same button; in a client it goes to the window's click op, and so
  does the release. The wheel goes to the client under the pointer.
- `win` lists the windows (a shell's with its lines and how far it is
  scrolled back); `win move|size|raise|min|close <n>` acts on one.

## Program windows: `window.asm`

- A program that wants the desktop (`AW_DESK`, or `+desk`) gets a handle to it (`OT_DESK`,
  `SB_DESK`, right `RT_DESK_WINDOW`). `SYS_WINDOW_NEW(desktop, width,
  height, a channel's end)` opens a window (`OT_WINDOW`, `WO_*`) and returns
  it and its pixels: a block of memory the program maps, B,G,R,x at width ×
  4 bytes a row, which the desktop copies from as it composes. Its size is
  fixed (no grip); its title starts as the program's name.
- **What happens to it** goes to the program as messages of `WE_SIZE`
  bytes, sent from the end it was given (`ch_post`, the kernel's own send)
  so they arrive at the end the program kept: `WE_KEY` while it has the
  keys, `WE_PRESS` and `WE_RELEASE` (the button, where), `WE_MOVE` while a
  button is held in it, `WE_WHEEL`, and `WE_CLOSE` from its close button or
  `win close`, which only ask (`OP_ASK`).
- **On its ring:** `RO_WIN_SHOW` (a rectangle, or all of it) puts what was
  drawn on the screen; `RO_WIN_TITLE` retitles it. Both need `RT_WIN_DRAW`.
- The program's side runs on any CPU and never touches the desktop's own
  structures: it notes what it wants in the object under `win_lock`
  (`WOF_OPEN`, `WOF_TITLE`, `WOF_GONE`) and wakes the main loop, whose
  `wo_service` (from `desk_service`) opens, retitles and closes. Showing only
  adds damage, which any thread may. The window closes when its last handle
  goes (`wo_orphan`): the program ended, was killed, or its shell closed.

## The browser: `src/user/browse.asm`, `src/user/web/`

- A ring-3 program in a 1400×1000 window of its own: a toolbar (back,
  forward, reload, the address field), the page, a scrollbar and a status
  line. It reaches the network through sockets (`sock.inc`), so only by the
  capability its shell gave it.
- **Fetching** (`web/url.inc`, `web/fetch.inc`): a URL parsed and resolved
  against the page's (relative paths, `..`, queries, fragments, `//host`;
  userinfo dropped), then a GET over plain TCP or TLS, the body read by its
  length, chunked, or to the close. Up to 8 redirects are followed; a
  fragment within the same document only scrolls.
- **Parsing** (`web/html.inc`): a tokenizer and tree builder for the HTML
  that is out there: implied ends (`p`, `li`, `td`, `tr`, …), raw text for
  `script` and `style`, named and numeric references, into nodes in an
  arena. The charset comes from the Content-Type, a `<meta charset>` in the
  first kilobyte, or whether the bytes are UTF-8; otherwise Windows-1252.
  `text/plain` is shown as `pre`.
- **Layout** (`web/layout.inc`): one walk of the tree with a stack of
  styles (from the tags alone: block or inline, hidden, the heading sizes,
  bold, italic, monospace, links, `align=center`), lines filled and wrapped
  at the page's width, whitespace collapsed outside `pre`, margins
  collapsed, list markers, quotes indented, rules, and tables in columns
  measured from what their cells want. What comes out is a display list in
  document coordinates (text runs and rectangles, each run with its link),
  a link table and the anchors (`id`, `name`).
- **Drawing** (`web/draw.inc`): the visible part of the display list at the
  scroll offset, clipped, each glyph's coverage blended into the window's
  pixels. The fonts are DejaVu Sans, Sans Mono and their bold and oblique
  faces at six sizes, rasterised on the host by `tools/mkwebfont.py` into
  `src/user/gen/webfont.bin` (8-bit coverage) and `webfont.inc` (the
  glyph tables), which `tools/build.py` makes if they are missing.
- Each load logs `browse: <url>: <status>, <bytes> bytes, <elements>
  elements, <links> links`; the window is titled `<title> · browse`.
- `tools/test/browse/render.py` assembles the same `web/*.inc` into a DLL
  for the host, so a page can be laid out and drawn there; the QEMU suite,
  `tools/test/browse/run.py`, compares browse's window with that.

## Linux programs: `linux.asm`, `lxmm.asm`, `lxfs.asm`, `lxsig.asm`, `lxtty.asm`, `lxproc.asm`, `lxpipe.asm`

- `linux <program> [arguments]` runs an unchanged Linux x86-64 program
  from a root on the boot stick: `tools/mkroot.py` copies programs and
  every library they need (DT_NEEDED, followed, with the links on the way)
  from a WSL distribution into `build/linux/ROOT`, gives it an `/etc` of
  Axiom's own, and writes `META`, a line per path with what FAT cannot
  keep (kind, mode, size, a link's target); `mkstick.py --linux` puts both
  at `/LINUX` with 4 KiB clusters. A name without a slash is looked for on
  the Linux PATH. One runs at a time in a shell, as its session's leader
  (with whatever it forks), and has its window's keys while it runs
  (ctrl+C is its terminal's: SIGINT to the foreground group); closing the
  window kills it, its end takes the session with it, and the shell says
  how it ended (`exited with N`, `ended by signal N`, `stopped`).
- **A process** is a task (its own address space, as `run`'s) with a
  Linux process's state in `TK_LX` (`LP_*`): its pid, descriptors,
  directory, program and terminal. Its threads are user threads marked
  `TF_LINUX`: `syscall_entry` hands their calls to `lx_syscall`, which
  indexes `lx_table` by Linux's numbers and goes back by IRETQ with every
  register but RAX as it was. A call not there yet is said once
  (`system call N is not there yet`) and gets `-ENOSYS`. Each thread has
  its own FS base (`arch_prctl`, `TH_FSBASE`), loaded by `sched_switch`.
  It ends with its last thread: `exit_group`, the last `exit`, a signal's
  default action, a fault with no handler (said as `run`'s are, and ending
  it as the signal would), or a kill.
- **Loading** (`lx_elf_map`, `lx_exec_image`): the program's PT_LOAD
  segments are mapped from its file in the cache, ET_EXEC where it was
  linked and ET_DYN at 0x555555554000; its PT_INTERP (ld.so) highest below
  0x7FFFF7FFF000. The first thread starts at the interpreter's entry on a
  stack laid out as Linux's: argc, argv, envp, then the auxiliary vector
  (AT_PHDR, AT_PHENT, AT_PHNUM, AT_PAGESZ, AT_BASE, AT_ENTRY, the ids,
  AT_HWCAP, AT_CLKTCK, AT_RANDOM, AT_PLATFORM, AT_EXECFN), with the
  strings and 16 random bytes above it. The break starts after the
  program's last segment.
- **Memory** (`lxmm.asm`): each address space keeps a sorted array of
  areas (start, end, protection, flags, the file and its offset), changed
  under the space's lock by mmap, munmap, mprotect, mremap, madvise and
  brk; mmap places areas down from below the stack and honours MAP_FIXED,
  MAP_FIXED_NOREPLACE and MAP_32BIT. Nothing is mapped until it is
  touched: a fault in an area fills that page in (zeroes, or the file's
  own page from the cache, read-only, so programs share it), a write to a
  file's page takes a private copy, and PROT_NONE keeps a page present but
  out of ring 3's reach. The kernel reaches a program's memory by walking
  its tables (SMAP stays on), filling pages in as a fault would.
- **Files** (`lxfs.asm`): a read-only tree in RAM built from META, plus
  `/dev/null`, `/dev/zero`, `/dev/random`, `/dev/urandom`, `/dev/tty`
  (and `/dev/stdin`, `stdout`, `stderr` to it) and `/proc/self/exe`. A
  file's bytes are read from the stick whole, once, by the main thread
  (a program's thread queues it and waits); `open`, `openat`, `read`,
  `pread64`, `readv`, `writev`, `lseek`, `close`, `dup`s, `fcntl`, the
  `stat` family with `statx`, `getdents64`, `readlink`, `access`,
  `getcwd`, `chdir` work on it, and writing is refused (`EROFS`).
- **The terminal** (`lxtty.asm`): a shell's window has one terminal for
  programs (`LY_*`), made the first time one runs there, with what a tty
  has on Linux: termios (`TCGETS`, `TCSETS` and the termios2 calls, reset
  for each program to a cooked terminal), the window's size
  (`TIOCGWINSZ`; the program gets SIGWINCH when it changes), the
  foreground process group and session, `FIONREAD`, `TIOCSTI`, `TCFLSH`.
  Keys go through a line discipline: ICRNL and the other input flags,
  ISIG (ctrl+C, ctrl+\ and ctrl+Z send SIGINT, SIGQUIT and SIGTSTP to
  the program, the input flushed), ICANON's line editing (erase, kill,
  word erase, ctrl+D) with ECHO and ECHOCTL, or raw bytes with VMIN and
  VTIME; arrows, home and end, page up and down, insert, delete and F1 to
  F12 arrive as xterm's sequences (`ESC O x` for the arrows under
  DECCKM), alt as an ESC before the key. A read waits for a line, or for
  VMIN bytes or VTIME; `O_NONBLOCK` (`fcntl`, `FIONBIO`) says `EAGAIN`; a
  signal ends the wait (`EINTR`, or the read made again with
  `SA_RESTART`). Output goes through OPOST's ONLCR to `vt.asm`, and a
  copy, escape sequences left out, to the serial log a line at a time.
  `poll`, `ppoll`, `select` and `pselect6` are here too: a terminal is
  readable when a read would not wait, and writable always, as is every
  other file.
- **Processes** (`lxproc.asm`): every process is on one list
  (`lx_procs`, `LP_NEXT`, under a spinlock), which holds its task until
  it is waited for. `fork`, `vfork` and `clone` without `CLONE_THREAD`
  make a task of its own with a copy of the parent's descriptors (the open
  files shared), signal actions, directory, group and session, and either
  a copy of its memory (`lx_as_fork`: the areas, and each page of its own
  copied there and then; the file cache's pages shared as they were) or,
  with `CLONE_VM`, the same address space, the parent waiting
  (`CLONE_VFORK`, no signal cutting it short) until the child execs or
  ends. `execve` and `execveat` read the arguments and environment into
  the kernel, follow `#!` (the interpreter, its one argument, the path, up
  to four deep), map the program into a new address space and only then
  commit: the old space released, `FD_CLOEXEC` descriptors closed,
  handled signals back to `SIG_DFL`, registers, TLS and SIMD state clean.
  A process that ends sends its exit signal (SIGCHLD) to its parent, is
  kept for `wait4` and `waitid` (by pid, group or any, `WNOHANG`,
  `WNOWAIT`; the status and `siginfo` as Linux has them) unless the
  parent ignores SIGCHLD or has none, and leaves its children without one.
  `setpgid`, `setsid`, `getpgid`, `getsid`; `kill` to a process, a group
  (ctrl+C's way too), or the session's every other one; `tgkill` to any
  thread. `execve` while other threads run says `EAGAIN` (not yet), and
  stop signals are ignored (no job stopping yet).
- **Pipes** (`lxpipe.asm`): `pipe` and `pipe2` make a ring of 64 KiB with
  a reader's and a writer's open file. A read waits for bytes, says 0 once
  no writer is left; a write of up to 4 KiB goes in whole (`PIPE_BUF`),
  a longer one as room comes, and with no reader left the writer gets
  SIGPIPE and `EPIPE`. `O_NONBLOCK`, `poll` and `select`, `FIONREAD`,
  `F_GETPIPE_SZ`, `fstat` (a FIFO) and `ESPIPE` for offsets are as Linux
  has them. Every wait for a process or a pipe is on the one queue `poll`
  uses, kicked whenever something changes.
- **Threads** (`lxsig.asm`): `clone` with `CLONE_VM | CLONE_THREAD |
  CLONE_SIGHAND` (what `pthread_create` asks for; `clone3` says `ENOSYS`,
  so glibc falls back to it) makes another `TF_LINUX` thread of the task,
  starting from a copy of its parent's frame with RAX 0, its own stack and
  TLS (`CLONE_SETTLS`), its id written where `CLONE_PARENT_SETTID` and
  `CLONE_CHILD_SETTID` say; as it exits, its `CLONE_CHILD_CLEARTID` word
  is zeroed and a waiter there woken (`pthread_join`). Every Linux thread
  starts from a frame (`lx_thread_new`, `lx_thread_begin`), so whenever
  one goes back to ring 3 RBP is its frame.
- **Futexes**: a waiter waits on a queue of its own, on its stack, in one
  of 256 buckets keyed by where the direct map has the word (made
  writable first, so a copy on write cannot come between a wait and its
  wake). WAIT and WAIT_BITSET (relative on the monotonic clock, or
  absolute on either), WAKE and WAKE_BITSET, REQUEUE and CMP_REQUEUE
  (waiters moved between buckets, both locked, the lower first), and
  WAKE_OP (the operation done with a locked CMPXCHG). The PI ones say
  `ENOSYS`.
- **Signals**: a process has its actions (`LP_SIGACTS`, `rt_sigaction`)
  and the signals sent to it (`LP_SIGPEND`); a thread has its mask, its
  own pending signals, its alternate stack (`sigaltstack`) and what a
  fault said (`TH_LXINFO`). Sending one (`kill`, `tkill`, `tgkill`,
  ctrl+C) sets it pending, unless it would be ignored,
  and kicks the threads that may take it: unparked if parked, an IPI if
  running on another CPU. `user_leave` sends a Linux thread to
  `lx_leave`, which takes the lowest signal its mask lets through: the
  default action (nothing, or the process ends by it), or a frame on its
  stack as Linux builds one (`siginfo`, a `ucontext` with the registers
  and mask, and the XSAVE state with Linux's magic numbers, the handler
  starting with a clean one), entered with RDI, RSI, RDX the signal,
  `&siginfo` and `&ucontext` and the restorer as its return address;
  `rt_sigreturn` puts it all back, the flags and the XSAVE header made
  safe first. A wait in a system call ends early when a signal its mask
  lets through is pending (`user_killed` asks `lx_interrupted`): with
  `EINTR`, or for the calls Linux restarts (futex waits), made again when
  no handler runs or the handler has `SA_RESTART`. A fault the process
  has a handler for, and does not block, is delivered the same way, with
  its address and code. Also `rt_sigprocmask`, `rt_sigpending`,
  `rt_sigsuspend` and `pause`.
- The rest: `uname` (`Linux axiom 6.8.0-axiom`), the ids (root's),
  `clock_gettime` and the other clocks (the CMOS clock at boot taken as
  UTC, then the TSC), `nanosleep` and `clock_nanosleep` (cut short by a
  signal), `getrandom`, `sysinfo`, `prlimit64`, `sched_getaffinity`, and
  `prctl`'s name.
- `tools/test/linux/run.py` builds the root and a stick and runs, in QEMU,
  `/test/hello` (`tools/test/linux/hello.asm`, a static program of our
  own), then Ubuntu's `true`, `false`, `echo`, `cat`, `ls -la`, `uname
  -a`, `id`, `date`, `sha256sum`, `env`, `wc` and `sleep`, checking what
  each prints against the host; `/test/threads` (`threads.c`, compiled by
  WSL's gcc against Ubuntu's glibc) with its sixteen checks of threads,
  futexes and signals, and its ways out (`abort`, an unhandled fault, the
  last thread's exit, `exit` from a thread); ctrl+C on `sleep 60`
  (SIGINT), and ctrl+\ on a program that ignores SIGINT (SIGQUIT);
  `/test/tty` (`tty.c`) with its checks of the terminal (termios, the
  size, xterm's answers, the alternate screen, VMIN and VTIME, poll,
  select, SIGWINCH) and of keys typed (a line edited, arrows, ctrl+C raw
  and as SIGINT, ctrl+D); `/test/tty draw`, checked row by row through
  the shell's `screen`; and Ubuntu's `stty`, `tput`, `clear` and `less`
  through libtinfo and the root's terminfo; `/test/procs` (`procs.c`)
  with its checks of `fork`, `exec`, `vfork`, `posix_spawn`, pipes, waits,
  SIGCHLD, groups, sessions, `#!` and `FD_CLOEXEC`; `bash -c` and `sh -c`
  (dash) with pipelines, command substitution and loops through
  coreutils, `grep`, `sort`, `tr`, `cut` and `xargs`; and bash typed at,
  ctrl+C ending a command it runs in its own process group, and readline's
  history. `build.py --define LX_TRACE` makes a kernel that says every
  Linux system call with its arguments and result.

## Terminals: `term.asm`, `vt.asm`

- Each shell is a window with a terminal (`TW_*`): 1000 lines of 256 cells
  (a glyph, its attributes, a foreground and a background colour of 24
  bits each), the cursor, the scroll-back, its own input line and history
  (`TW_SH_*`, `shell.asm`), and whether a command is still running in it.
  `+ shell` or `shell` opens one; its close button closes it. `screen`
  writes what the window shows to the serial log, as text (for tests).
- **xterm** (`vt.asm`): what a Linux program writes is read as xterm
  would: UTF-8 (wide characters take two cells, combining ones none, a
  character the font lacks drawn as one like it or '?'), cursor movement,
  erasing, inserting and deleting characters and lines, scroll regions,
  SGR (bold, dim, italic, underline, inverse, hidden; 16, 256 and 24-bit
  colours), DEC's line drawing, the alternate screen (1049, 1047, 47),
  DECCKM, DECAWM, DECTCEM, origin and insert modes, saved cursors, tabs,
  synchronized output (2026, drawing held back up to 150 ms), and the OSC
  title, shown as the window's. Questions are answered as typed input:
  DSR and the cursor's place, DA1, DA2, XTVERSION, DECRQM, the size in
  cells and pixels, and the OSC colours. Scrolling the main screen keeps
  its top rows in the scroll-back; a program's end resets the terminal.
- **Where output goes:** a thread's `TH_CON` names the terminal it prints
  to (`con_target`: if that one is gone, the first shell, else the oldest).
  Work that answers later records its terminal when it starts (a lookup, a
  ping, a fetch, a TCP connection or listener, a program) and prints there
  through `con_call`, which sets `TH_CON` around a call. ctrl+C, or closing
  a terminal, stops what was started from it (`net_forget`, `user_forget`).
- `con_write` puts text into a terminal's cells under `print_lock` (from any
  CPU); `term_service` draws what changed into its window on the main
  thread, scrolling the surface by moving its rows when it can.
- **The dashboard** (`ui.asm`): System and Processors are windows too, and
  the Mandelbrot, which renders straight into its window's surface
  (`mandel_set_view`) and only while it is shown; its title carries the
  live statistics.

## The shell: `shell.asm`, `records.asm`

Axiom's own command language: what a command gives is records, not text;
a command names a thing, then what to do with it; a program gets only the
capabilities it says it needs.

- **A line** is commands joined by `;` (then), `&&` (then, if that worked)
  and `||` (then, if it failed). A command is a pipeline: a head, stages
  after `|`, and at the end at most one `> file` (written) or `>> file`
  (added to). The line is split at `;`, `&&` and `||` first, outside quotes;
  each command's words are made only as it runs, so `set n 5; files $n`
  sees the 5.
- **Words** are split at spaces. `"…"` keeps spaces and expands variables;
  `'…'` keeps everything as it is. A `\` before a character the shell
  would read (a space, a quote, `\`, `$`, `|`, `>`, `;`, `&`) takes it as
  it is; before any other it stays, so `\n` reaches a program as typed.
  `$name` and `${name}` are a variable's value (one word, never split
  again); a word that was only an unset variable, unquoted, is dropped.
  `set name value…` sets one, `set name` removes it, `set` lists them; the
  variables are the machine's, shared by its shells. Wildcards (`*`, `?`)
  are not expanded by the shell: the actions that take paths match them,
  without regard to case, as FAT names are.
- **Thing, then action.** A command's first word names a thing (`files`,
  `cpus`, `tasks`, …) or a verb (`go`, `here`, `set`, `help`); case does
  not matter. Alone, a thing shows itself. If the next word is one of its
  actions, that action runs on the rest; otherwise the rest goes to its
  default action (`files old/` lists `old/`). `help` lists every command,
  `help <thing>` its actions, each with what it takes. A command that
  fails (unknown, a bad argument, a stage that cannot apply, a file that is
  not there) sets the status `&&` and `||` look at.
- **Records** (`records.asm`): what a command gives is a table (`TB_*`): up
  to 16 columns, each with a name and a type, and up to 8192 rows of
  8-byte cells, their text in a heap after the rows. The types (`FT_*`):
  text; a number, with decimals and a unit (`2400 MHz`); a size in bytes
  (shown as `1.5 KiB`); a duration (`12 ms`); a time
  (`2026-10-17 14:05`); hex; yes or no. A cell may hold no value (`--`).
  The table is built in place by the head and changed in place by each
  stage; the text it ends as is made only at the end.
- **Stages:** `where <field> <op> <value>` keeps the rows that pass (`=`
  `!=` `<` `>` `<=` `>=`, and `~` / `!~`: contains, or matches a pattern if
  the value has `*` or `?`; the value is read as the field's type: `4K`,
  `2M`, `10ms`, `2s`, `2026-10-17`, `yes`); `sort <field> [down]` (stable);
  `pick <field>…` (those columns, in that order); `first <n>`, `last <n>`;
  `count`; `to text` and `to json`, last, for what a file gets. Fields are
  named as their columns are, one word each (`heap-size`, `other-time`), so
  they never need quotes; a wrong one is named, with the ones there are.
  In `where <field> > <value>` the `>` is the comparison, not a file: it
  is one only there, as the third word of a `where`.
- **At the end** the table is shown: the columns as wide as what they hold,
  numbers to the right, the header in the accent colour, `(none)` when no
  row passed. A thing with one record to say (`mem`) shows it as
  `field  value` lines. A table of lines (`files show`, `here`) is shown as
  the lines. `> file` writes it as text, or as JSON after `to json` (sizes
  in bytes, durations in milliseconds, times as `2026-10-17T14:05`, no
  value as `null`).
- **Commands that print** (not yet records) still print; piped or sent to a
  file, what they print on the main thread becomes a table of lines, one
  column called `text` (`kprint` hands the lines to `rec_capture` while
  `rec_capturing` is set, instead of to the terminal). A command that
  answers later (`ping`, `http`, `ask`) cannot be piped: its answer goes to
  the terminal. What follows it on the line runs once it is done
  (`TW_SH_REST`, run from the main loop by `shell_service`).
- **Files** are a thing: `files [folder | pattern]` (name, kind, size,
  changed), `files show <file>` (its lines), `files copy <from>…  <to>`,
  `files move <from>… <to>` (a copy, then the original removed; into a
  folder if `<to>` is one), `files new <name>` (an empty file, or a folder
  if the name ends in `/`), `files write <file> <text>…`, `files remove
  <path or pattern>…`, `files find [pattern]` (everything below here, with
  its path, folders breadth-first). `go [folder]` moves (to `/` alone);
  `here` says where. The old short commands are gone.
- **The first things:** `cpus` (cpu, kind, apic, core, thread, clock,
  heat, jobs, mcycles), `mem` (one record: usable, free, kernel, code,
  constants, data, tables, fw-tables, vm-maps, vm-size, shootdowns,
  heap-objects, heap-size, slabs, large, large-size; `mem kinds` (kind,
  size) by firmware type, `mem at <hex>` (address, what, mapped, physical,
  access, runs, caching, page), `mem test`), `threads` (id, name, state,
  cpu, class, pinned, p-time, e-time, other-time, switches, moves;
  `threads cpus` (cpu, kind, waiting, busy, switches, stolen, handed),
  `threads test`, `threads spin`), `tasks` (id, name, parent, threads,
  handles, ops, denied, program; `tasks stop <id or program>…`: a task by
  its number, or every program running by that name; the kernel's own
  tasks are not for stopping).
- **Programs** run by name: a word that is not a command and names a file
  `/EFI/AXIOM/<NAME>.AXE` (or a path to one) runs it, with the rest as its
  arguments; `run <name>` does the same for a name a command hides (`run
  net`). Several run at once: `&` at the end of a command runs it in the
  background, the job's task number said, and `tasks` lists them. A
  program gets only the capabilities it declares in its header (paint: the
  desktop; browse: the desktop and the network; net: the network; stash:
  the store; the rest nothing); `+net`, `+store` and `+desk` before its name
  grant more, for that run (`+net hello`). Commands take neither grants nor
  `&`, and a program in the background takes no `|` or `>`.
- **Completion (S3):** Tab completes a command, an action, a field after a
  stage, or a path, and says what could come next.

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
- `KLOG "fmt", args...` logs to serial and, once there is a terminal, to the
  one the thread prints to; `SPRINTF buf, "fmt", args...` formats into memory. Arguments are
  64-bit registers, immediates or `qword [mem]`.
- Structures are `equ` offsets (`PC_*`, `TH_*`, `OB_*`, `TK_*`, `CAP_*`,
  `HS_*`, `EV_*`, `MO_*`, `RG_*`, `RA_*`, `SQ_*`, `CQ_*`, `RQ_*`, `TM_*`, `AS_*`, `AM_*`, `AXE_*`, `SF_*`, `WN_*`, `TW_*`, `WO_*`, `WE_*`,
  `SB_*`, `SR_*`, `CH_*`, `CM_*`, `PE_*`, `XC_*`, `DV_*`, `NV_*`, `DK_*`, `VO_*`, `VF_*`). Programs include
  `defs.inc` too: it is their ABI.
- No code a system call or an interrupt reaches uses SIMD, so neither saves
  a program's SIMD registers; the scheduler keeps each thread's. SIMD stays
  in code the shell runs (crypto, the Mandelbrot, tests).
- Errors are `E_*`, small negative numbers. The kernel's pointers are
  negative too (the upper half), so a function that returns a pointer or an
  error is checked with `cmp rax, E_ANY` and `jae`, not the sign.
- Self-contained modules are also tested on the host: `tools/test/<module>/`
  assembles the module with a small shim and drives it from C or Python.
