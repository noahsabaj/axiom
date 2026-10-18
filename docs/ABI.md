# Axiom's ABI: what a native program sees

This is the contract between Axiom's kernel and a program it runs natively:
how the program is laid out, how it starts, how it calls the kernel, and
what each call does. It's written for authors in any language that can make
x86-64 machine code without a C runtime: NASM (`src/user/axe.inc`), Rust
(`sdk/rust`), MASM (`sdk/masm`), or anything else that links flat at a fixed
address.

The constants are the kernel's own, in `src/kernel/defs.inc`. Take names
and values from there, or from `sdk/masm/axiom.inc`, which `tools/masm.py`
generates from it, rather than copying them. Where this page and the code
disagree, the code is right, and the page needs fixing.

- [Layout: the .AXE file](#layout-the-axe-file)
- [Starting: the first thread and the start block](#starting-the-first-thread-and-the-start-block)
- [System calls](#system-calls)
- [Handles, rights and errors](#handles-rights-and-errors)
- [The ring](#the-ring)
- [Operations on the ring](#operations-on-the-ring)
- [Memory, buffers and threads](#memory-buffers-and-threads)
- [Windows and their events](#windows-and-their-events)
- [Sound](#sound)
- [Files](#files)
- [Time](#time)
- [What a program may not do](#what-a-program-may-not-do)
- [Limits](#limits)
- [Building](#building): NASM, Rust, MASM

## Layout: the .AXE file

A program is one file, `/EFI/AXIOM/<NAME>.AXE` on the boot stick, its name
eight letters at most. The shell runs it by name (`notes`, or `run notes`).
The file is an image: its first byte is loaded at `USER_IMAGE` (0x400000)
and every address in it is absolute. Its header is the first 56 bytes:

| Offset | Field | What |
|---|---|---|
| 0 | `AXE_MAGIC` | the 8 bytes `AXIOMEX2` |
| 8 | `AXE_ENTRY` | where the first thread starts |
| 16 | `AXE_TEXT_END` | the end of the code, page-aligned |
| 24 | `AXE_RODATA_END` | the end of the constants, page-aligned |
| 32 | `AXE_DATA_END` | the end of the data, and of the file |
| 40 | `AXE_BSS_END` | the end of the zeroes after it |
| 48 | `AXE_WANTS` | the capabilities it wants, `AW_*` |

Every field after the magic is a qword.

The loader checks all of the following, and refuses the program if one
fails:

- The entry is in the code, after the header.
- `TEXT_END ≤ RODATA_END ≤ DATA_END ≤ BSS_END ≤ 0x400000 + 16 MiB`.
- `WANTS` names nothing beyond `AW_ALL`.

It maps the parts like this:

| Part | Range | Access |
|---|---|---|
| Code, the header page included | 0x400000 to `TEXT_END` | read and execute |
| Constants | to `RODATA_END` | read only |
| Data | to `DATA_END` | read and write |
| Zeroes | to `BSS_END` | read and write |

Only the code is executable.

**Wants** (`AW_*`): what the program asks for, each given as a handle in the
start block:

| Flag | Value | Gives |
|---|---|---|
| `AW_NET` | 1 | the network |
| `AW_STORE` | 2 | its own names in the store |
| `AW_DESK` | 4 | the desktop, to open windows on |
| (8) | | reserved for the settings, on their branch |
| `AW_FILES` | 16 | every FAT volume |
| `AW_SOUND` | 32 | the speakers, to open streams of sound on |

The shell gives a program what it wants and no more. The user can grant
more for one run: `+net hello`, `+files notes`. A program started by
another program gets no `AW_*` grants, only the handles it was given.

## Starting: the first thread and the start block

The first thread starts at `AXE_ENTRY` with:

- **RDI** = `USER_START` (0x200000), the start block. Every other
  general-purpose register is 0.
- **RSP** = `USER_STACK_TOP` (0x7FF000000000). This is 16-aligned with
  nothing above it, not even a return address. The stack is
  `USER_STACK_SIZE`, 64 KiB, and nothing is mapped below it.
- RFLAGS = 0x202 (interrupts on, DF clear), FS and GS bases 0, x87
  control word 0x037F, MXCSR 0x1F80.

**The entry never returns.** There is nothing to return to, so a `ret`
faults. It ends with `SYS_EXIT`, and the task ends when its first thread
does, along with every thread and program it started. Any thread can end
the whole task at once with `SYS_EXIT`'s `EXIT_TASK`. An exit code other
than 0 is a failure to the shell's `&&` and `||`.

The start block is a read-only page. Each handle field is a dword, 0 when
the program wasn't given one.

| Offset | Field | Size | What |
|---|---|---|---|
| 0 | `SB_RING` | dword | the task's ring (64 entries) |
| 4 | `SB_RING_MEM` | dword | the ring's memory |
| 8 | `SB_CONSOLE` | dword | the console: `RO_WRITE` to it |
| 12 | `SB_GIFT` | dword | what the program that started it gave it |
| 16 | `SB_RING_VA` | qword | where the ring's memory is mapped |
| 24 | `SB_TSC_PER_US` | qword | TSC ticks in a microsecond |
| 32 | `SB_ARGS_LEN` | dword | bytes of `SB_ARGS` |
| 36 | `SB_STORE` | dword | `AW_STORE` |
| 40 | `SB_NET` | dword | `AW_NET` |
| 44 | `SB_DESK` | dword | `AW_DESK` |
| 48 | | dword | reserved for the settings, on their branch |
| 52 | `SB_FILES` | dword | `AW_FILES` |
| 56 | `SB_GIFT2` | dword | a second gift |
| 60 | `SB_SOUND` | dword | `AW_SOUND` |
| 64 | `SB_ARGS` | bytes | the arguments, NUL-ended, without the program's name: `mhello one two` gives `one two` |

`SB_ARGS` holds at most `SB_ARGS_MAX`, 4031 bytes.

A gift that is a desktop, files, the speakers, the network or the store is also put in
its own slot above, if that slot is empty. So a program handed a desktop
by the Files app finds it in `SB_DESK`, as it would if it had been run
with `+desk`.

## System calls

`SYSCALL`, with:

| | |
|---|---|
| Number | RAX |
| Arguments | RDI, RSI, RDX, R10, and R8 as a fifth |
| Results | RAX, and RDX for those with two (0 otherwise) |
| Lost | RCX and R11 (SYSCALL's return address and flags) |
| Kept | everything else, all SIMD state included |

This is not the Win64 convention, or the System V one for calls: the
fourth argument is in R10, and nothing needs shadow space. The kernel
never writes below the program's RSP, so a red zone is safe. A result is
an error if it is between `E_ANY` (-4096) and -1. An unknown number is
`E_ARG`.

System calls are only what a ring can't do. Everything else is an entry
on a ring.

| # | Name | Arguments | Returns |
|---|---|---|---|
| 0 | `SYS_EXIT` | RDI = code, RSI = `EXIT_TASK` (1) or 0 | (no return) this thread ends; with `EXIT_TASK`, or from the first thread, the task too |
| 1 | `SYS_RING_ENTER` | RDI = ring, RSI = entries to take, RDX = completions to wait for, R10 = a TSC deadline or 0 | RAX = entries taken |
| 2 | `SYS_RING_NEW` | RDI = entries (4096 at most) | RAX = a ring, RDX = its memory |
| 3 | `SYS_MEM_NEW` | RDI = bytes (1 to 64 MiB) | RAX = memory, zeroed, whole pages |
| 4 | `SYS_MAP` | RDI = memory | RAX = where it is mapped |
| 5 | `SYS_EVENT_NEW` | | RAX = an event, not signalled |
| 6 | `SYS_THREAD_NEW` | RDI = entry, RSI = its RSP, RDX = its RDI | RAX = the thread, already running |
| 7 | `SYS_YIELD` | | |
| 8 | `SYS_UNMAP` | RDI = memory | its mapping goes |
| 9 | `SYS_SPAWN` | RDI = memory, RSI = offset, RDX = bytes of `"program args"`, R10 = a handle to give or 0, R8 = a second or 0 | RAX = the task, RDX = its first thread |
| 10 | `SYS_CHANNEL_NEW` | | RAX, RDX = the two ends |
| 11 | `SYS_WINDOW_NEW` | RDI = desktop, RSI = width, RDX = height, R10 = a channel's end, R8 = `WNF_*` | RAX = the window, RDX = its pixels (memory) |
| 12 | `SYS_SOUND_NEW` | RDI = the speakers, RSI = frames | RAX = a stream, playing; RDX = its memory (`SN_*`) |
| 13 | `SYS_TLS` | RDI = an address | this thread's FS base |
| 14 | `SYS_FUTEX_WAIT` | RDI = address, RSI = value, RDX = a TSC deadline or 0 | 0 when woken; `E_CONFLICT` if the dword there isn't the value; `E_TIMEOUT` |
| 15 | `SYS_FUTEX_WAKE` | RDI = address, RSI = how many at most | RAX = how many woke |
| 16 | `SYS_INFO` | RDI = `SI_*` | RAX = what it asked |

Notes:

- **`SYS_RING_ENTER`** doesn't say whether the deadline passed: count the
  completions instead. If another of the task's threads is submitting at
  that moment, it takes nothing and returns 0, so try again.
- **`SYS_MAP`** maps above `USER_MAPS` (0x100000000000), with a guard page
  after each mapping. An address is never used twice. The mapping is read
  and write, or read only, as the handle's rights allow, and never
  executable. A task may have `AS_MAX` (128) mappings at once; beyond that
  it gets `E_FULL`.
- **`SYS_THREAD_NEW`** uses the RSP exactly as given. Give it 16-aligned,
  and the thread's entry starts as the first thread's does: nothing to
  return to, ending with `SYS_EXIT`. RO_JOIN on the thread gets its exit
  code.
- **`SYS_EXIT`**'s code with `EXIT_TASK` is the task's: the shell reports
  it, as if the first thread had ended with it. If two threads say
  `EXIT_TASK` at once, the first one's code is kept.
- **`SYS_TLS`** sets FS's base for the calling thread only; it is kept
  across switches. The address must be below `USER_TOP`, or it is
  `E_ARG`. GS's base stays 0.
- **`SYS_FUTEX_WAIT`** sleeps if the dword at the address (4-aligned, in
  memory already mapped) still holds the value, until a `SYS_FUTEX_WAKE`
  on that address or the deadline. Checking and sleeping are one step,
  so no wake is lost between them. A dword that isn't aligned is `E_ARG`;
  one that isn't mapped, `E_RANGE`. As with any wait, it may wake without
  a reason: check the dword again.
- **`SYS_INFO`**: `SI_CLOCK` (0) is the microseconds since 1970, from the
  RTC read at boot (taken as UTC) and kept by the TSC; `SI_CPUS` (1) is
  the CPUs running. Anything else is `E_ARG`.
- **`SYS_SPAWN`**: the text is at most 255 bytes, and programs nest eight
  deep. The gifts move to the child before it runs. The child is the
  caller's own: the caller's task handle can `RO_KILL` it, and when the
  caller ends, so does the child.
- **`SYS_WINDOW_NEW`**: the window sends its events from the end it is
  given (R10) to that end's peer, which the program keeps. Keep R10's
  handle open too. Closing it cuts off the window's events.

## Handles, rights and errors

A **handle** is a dword: `generation << 16 | slot`. It is never 0, and it
always fits in a positive int32. A task has its own table, which grows to
0x10000 slots.

Each object type has its own `OT_*`:

| Type | Value | Type | Value |
|---|---|---|---|
| `OT_TASK` | 1 | `OT_STORE` | 8 |
| `OT_THREAD` | 2 | `OT_NET` | 9 |
| `OT_EVENT` | 3 | `OT_SOCKET` | 10 |
| `OT_MEMORY` | 4 | `OT_DESK` | 11 |
| `OT_RING` | 5 | `OT_WINDOW` | 12 |
| `OT_CONSOLE` | 6 | (13: the settings) | |
| `OT_CHANNEL` | 7 | `OT_FILES` | 14 |
| `OT_SOUND` | 15 | `OT_STREAM` | 16 |

**Rights** (`RT_*`): three for any object, `RT_DUP` 1, `RT_GIVE` 2 and
`RT_INFO` 4. The rest are by type, from bit 8: `RT_MEM_READ` and
`RT_MEM_WRITE`, `RT_CH_SEND` and `RT_CH_RECV`, `RT_WIN_DRAW`, `RT_FS_READ`
and `RT_FS_WRITE`, `RT_SOUND_PLAY` and `RT_STREAM_PLAY`, and so on.

- `RO_DUP` derives a handle with the same rights or fewer, and an expiry
  (a TSC value, 0 for none) no later than its own.
- `RO_GIVE` moves a handle to another task. It's gone from the giver, with
  any mapping of it.
- `RO_REVOKE` takes back everything derived from a handle. Those handles
  then say `E_REVOKED`.

**Errors** (`E_*`) are negative. Anything from -4096 to -1 is one:

| | | | | | |
|---|---|---|---|---|---|
| -1 `E_BADH` | not a handle | -9 `E_TIMEOUT` | the deadline came | -17 `E_NONAME` | no such name |
| -2 `E_TYPE` | the wrong kind | -10 `E_ARG` | an argument it doesn't take | -18 `E_IO` | the device failed |
| -3 `E_RIGHTS` | not allowed | -11 `E_CANCELED` | `RO_CANCEL`, or a link failed | -19 `E_NOSTORE` | no store |
| -4 `E_EXPIRED` | past its expiry | -12 `E_KILLED` | its task was killed | -20 `E_NET` | the network failed |
| -5 `E_REVOKED` | taken back | -13 `E_FAULT` | ended by a fault | -21 `E_NOFILE` | no such file |
| -6 `E_RANGE` | out of bounds | -14 `E_PEER` | the other end is gone | -22 `E_READONLY` | the volume is read only |
| -7 `E_NOMEM` | out of memory | -15 `E_EMPTY` | nothing there yet | -23 `E_EXISTS` | already there |
| -8 `E_FULL` | no room | -16 `E_CONFLICT` | changed meanwhile | | |

## The ring

A ring is how a program asks for things: it writes requests into memory it
shares with the kernel, and reads what came of them from the same memory.
The task's ring is in the start block (`SB_RING`, mapped at `SB_RING_VA`).
`SYS_RING_NEW` makes more.

**The ring's memory** (`RA_*`). The kernel never trusts what is in it.

| Offset | Field | Written by |
|---|---|---|
| 0 | `RA_SQ_TAIL`: dword, the next request's number | the program |
| 4 | `RA_CQ_HEAD`: dword, the next completion it will read | the program |
| 64 | `RA_SQ_HEAD`: dword, requests the kernel has taken | the kernel |
| 68 | `RA_CQ_TAIL`: dword, completions written | the kernel |
| 128 | `RA_SQ_ENTRIES`, `RA_CQ_ENTRIES`: dwords, powers of two; twice as many completions | the kernel |
| 136 | `RA_SQ_OFF`, `RA_CQ_OFF`: dwords, where the two arrays start | the kernel |
| 144 | `RA_TSC_PER_US`: qword, as in the start block | the kernel |

The four counters run free as u32. A slot is `counter & (entries - 1)`.

**A request** (`SQ_*`, 64 bytes):

| Offset | Field | What |
|---|---|---|
| 0 | `SQ_OP` | byte, `RO_*` |
| 1 | `SQ_FLAGS` | byte, `SQF_LINK` (1) or 0 |
| 4 | `SQ_HANDLE` | dword, what it acts on |
| 8 | `SQ_DATA` | qword, the program's own, given back |
| 16, 24, 32 | `SQ_A0`, `SQ_A1`, `SQ_A2` | qword arguments |
| 40 | `SQ_HANDLE2` | dword, a second handle: usually the memory its bytes are in |
| 48 | `SQ_DEADLINE` | qword, a TSC value, 0 for none |

Clear an entry before filling it: unused fields must be 0.

**A completion** (`CQ_*`, 32 bytes):

| Offset | Field | What |
|---|---|---|
| 0 | `CQ_DATA` | qword, the request's `SQ_DATA` |
| 8 | `CQ_RESULT` | qword, what it returned, or an `E_*` |
| 16 | `CQ_VALUE` | qword, a second result: `RO_JOIN`'s exit code |
| 24 | `CQ_OP` | dword, the request's `RO_*` |

The dword after `CQ_OP` is padding.

**Submitting and reaping**, as `sdk/masm/mhello.asm` does (`ring_call`):

```
submit:  slot = SQ_OFF + (SQ_TAIL & (SQ_ENTRIES - 1)) * 64
         write the request there, then SQ_TAIL += 1      ; in that order
         SYS_RING_ENTER(ring, take = 1, wait = 1, deadline = 0)
reap:    while CQ_HEAD == CQ_TAIL: SYS_RING_ENTER(ring, 0, 1, 0)
         slot = CQ_OFF + (CQ_HEAD & (CQ_ENTRIES - 1)) * 32
         read the completion, then CQ_HEAD += 1          ; in that order
```

On x86-64, plain moves in that order are enough. In Rust, the tail is a
release store and `CQ_TAIL` an acquire load. If several of a task's threads
share a ring, one at a time may submit and reap: the Rust crate holds a
lock around both. Every request taken gets exactly one completion. The
kernel only takes a request once its whole chain's completions have room,
so a full completion queue leaves requests waiting instead of losing them.

**Most requests are done during the enter.** Three wait instead: `RO_WAIT`,
`RO_JOIN` and `RO_TIMEOUT`. They complete when what they wait for happens,
or at their deadline:

- On timeout, `RO_WAIT` and `RO_JOIN` complete with `E_TIMEOUT`, and
  `RO_TIMEOUT` with 0.
- Nothing else blocks while they wait. The program reaps their completions
  whenever it next looks, or waits for them in `SYS_RING_ENTER`.
- **Deadlines are absolute TSC values**, and 0 means none: use 1 for "now".

**Links**: a request with `SQF_LINK` runs only if the one before it
succeeded, up to 16 in a chain. When one fails or times out, the rest
complete `E_CANCELED`. `RO_WAIT` linked to `RO_RECV`, say, receives the next
message once one comes. `RO_CANCEL` (a0 = a `SQ_DATA`) takes back the
requests still waiting with that data.

## Operations on the ring

"handle2 + a0" means bytes at offset a0 in the memory whose handle is in
`SQ_HANDLE2`. Requests never take a program's pointers.

| # | Op | Arguments | Result |
|---|---|---|---|
| 0 | `RO_NOP` | | 0 |
| 1 | `RO_SIGNAL` | handle = an event | |
| 2 | `RO_RESET` | handle = an event | |
| 3 | `RO_WAIT` | handle, deadline: an event (until `RO_RESET`), a channel's end (a message, or the peer gone), a thread, a socket (a0 = 0: something to read; 1: open), a stream of sound (no more than `SN_LOW` frames queued) | 0, or `E_TIMEOUT` |
| 4 | `RO_JOIN` | handle = a thread, deadline | 0, `CQ_VALUE` = its exit code |
| 5 | `RO_TIMEOUT` | deadline | 0, once it comes |
| 6 | `RO_COPY` | handle + a0 → handle2 + a1, a2 bytes | |
| 7 | `RO_DUP` | handle, a0 = rights to keep, a1 = expiry or 0 | a new handle |
| 8 | `RO_CLOSE` | handle | |
| 9 | `RO_GIVE` | handle, handle2 = a task | its handle there |
| 10 | `RO_REVOKE` | handle | how many went |
| 11 | `RO_CANCEL` | a0 = `SQ_DATA` | how many |
| 12 | `RO_WRITE` | handle = the console, handle2 + a0: a1 bytes of UTF-8 | bytes |
| 13 | `RO_SEND` | handle = a channel's end, handle2 + a0: a1 bytes, one message (a socket: what fits) | bytes |
| 14 | `RO_RECV` | handle, into handle2 + a0, a1 bytes at most | its bytes, `E_EMPTY`, or `E_RANGE` (too big; it stays) |
| 15 | `RO_KILL` | handle = a task | |
| 16–23 | `RO_ST_*` | the store: put, get, delete, commit, abort, sub, rollback, list | (defs.inc) |
| 24–29 | `RO_NET_*` | connect, listen, accept, status, shut, sub | (defs.inc) |
| 30 | `RO_WIN_SHOW` | handle = a window, a0 = x, a1 = y, a2 = w \| h << 32; a2 = 0: all of it | |
| 31 | `RO_WIN_TITLE` | handle, handle2 + a0: a1 bytes of UTF-8 | |
| 32, 33 | | reserved for the settings (`RO_SET_LIST`, `RO_SET_CHANGE`, on their branch) | `E_ARG` here |
| 34 | `RO_DESK_LOOK` | handle = the desktop | memory: the look (`LK_*`) |
| 35 | `RO_FS_VOLUMES` | into handle2 + a0, a1 bytes: `FV_*` records | how many |
| 36 | `RO_FS_LIST` | handle2 + a0: a folder; into handle2 + a1, a2 bytes: `FE_*` records | how many |
| 37 | `RO_FS_READ` | handle2 + a0: a file; into handle2 + a1, a2 bytes at most | its size |
| 38 | `RO_FS_WRITE` | handle2 + a0: a file; handle2 + a1: a2 bytes, all of it now | 0 |
| 39 | `RO_FS_MKDIR` | handle2 + a0: a folder | 0, or `E_EXISTS` |
| 40 | `RO_FS_REMOVE` | handle2 + a0: a file or an empty folder | 0 |
| 41 | `RO_FS_RENAME` | handle2 + a0: it, handle2 + a1: its new path, same volume | 0 |
| 42 | `RO_FS_SUB` | handle2 + a0: a folder, a1 = rights | a handle to that folder alone |
| 43 | `RO_WIN_POINTER` | handle = a window, a0 = `PTRM_*` | |

`RO_COUNT` is 44. Anything from there up is `E_ARG`.

**Fixed fields**: a path (`FS_PATH`, 256 bytes), a store name (64), a host
(256) or a pattern (64) is read at its full size from handle2 + a0,
NUL-ended inside it. So the memory has to reach the field's end, even for
a short name.

## Memory, buffers and threads

- **Bytes go to the kernel in memory objects.** `SYS_MEM_NEW` then
  `SYS_MAP`, and write there. Text in the program's own constants is copied
  into such a block before it can be written to the console. `mhello` keeps
  one 4 KiB "io block" for this. Memory objects start zeroed.
- **No pointers in requests**, only handle + offset. So the kernel never
  touches a program's addresses, and the program can't hand it one that
  isn't its own. The futexes are the one exception: an address of the
  program's own, which the kernel looks up in its mappings and only reads.
- **SIMD**: x87, SSE, AVX and AVX-512 state is the thread's own, kept across
  system calls, interrupts and switches. The kernel never uses SIMD itself.
- **Thread-local storage** is FS's base, which `SYS_TLS` sets for each
  thread (FSGSBASE is off: `wrfsbase` is `#UD`). It starts 0. The x86-64
  ELF layout ("variant II") fits: the block below the thread pointer, the
  pointer's own address at `[fs:0]`. The Rust crate does this (axiom::tls).
- **Threads** share the task's handles, mappings and ring. Give each one a
  stack of its own: a mapped block, RSP at its top. Two threads submitting
  on one ring take turns; a thread that waits a lot is better off with a
  ring of its own (`SYS_RING_NEW`).
- **Futexes** (`SYS_FUTEX_WAIT`, `SYS_FUTEX_WAKE`) are how threads wait for
  each other without a ring: locks, joins, condition variables.

## Windows and their events

With `AW_DESK`:

1. Make a channel (`SYS_CHANNEL_NEW`).
2. Open the window with one end: `SYS_WINDOW_NEW(SB_DESK, w, h, end, WNF_*)`.
3. Map its pixels, draw, and `RO_WIN_SHOW` them.

Each side is at most `WIN_MAX` (4096). The window opens a moment later,
showing all that was drawn by then.

- **Pixels**: B, G, R, x, 4 bytes each.
  - A row is `width * 4` bytes.
  - With `WNF_RESIZE` or `WNF_FULL`, a row is the screen's width × 4, with
    the screen's height of rows. `WE_RESIZED` says how much of them shows.
    The screen's size is in the look (`LK_SCR_W`, `LK_SCR_H`).
- **Flags** (`WNF_*`):

  | Flag | Value | What |
  |---|---|---|
  | `WNF_RESIZE` | 1 | the user can resize it |
  | `WNF_FULL` | 2 | resizable, and starts zoomed between the menu bar and the dock |
  | `WNF_KEYS` | 4 | keys down and up too |
  | `WNF_HOVER` | 8 | `WE_MOVE` with no button held, and `WE_LEAVE` |

- **Events**: 16-byte messages (`WE_SIZE`) at the program's end. Read them
  with `RO_RECV`, or `RO_WAIT` then `RO_RECV`. Each is `WE_KIND`, `WE_CODE`,
  `WE_X`, `WE_Y` (dwords; X and Y signed, from the window's top left). At
  most 64 wait at once (`CH_QUEUE_MAX`), and any more are dropped.

  | Kind | Name | Code; X, Y |
  |---|---|---|
  | 1 | `WE_KEY` | the key as text (below); X = `WM_*` |
  | 2 | `WE_PRESS` | the button (1 left, 2 right, 3 middle); where |
  | 3 | `WE_RELEASE` | the button; where, from the press's window |
  | 4 | `WE_MOVE` | `dx \| dy << 16`, each a signed 16-bit raw mouse count, before acceleration; where |
  | 5 | `WE_WHEEL` | notches, up positive |
  | 6 | `WE_CLOSE` | its close button was clicked: it only asks |
  | 7 | `WE_RESIZED` | X, Y = its size now |
  | 8 | `WE_LOOK` | the theme changed: read the look again |
  | 9 | `WE_FOCUS` | 1: it has the keys; 0: lost them (every key is up) |
  | 10 | `WE_KEYDOWN` | with `WNF_KEYS`: the USB HID usage (page 7); X = `WM_*` |
  | 11 | `WE_KEYUP` | the same, once each way |
  | 12 | `WE_LEAVE` | with `WNF_HOVER`: the pointer left it |

- **Keys as text** (`WE_KEY`):
  - A code is a byte of text, or `KEY_UP` 0x80, `DOWN`, `LEFT`, `RIGHT`,
    `HOME`, `END`, `PGUP`, `PGDN`, `INS`, `DEL` 0x89, `BTAB` 0x8A, and
    `KEY_F1`..`KEY_F12` 0x90..0x9B.
  - Ctrl+letter is 1..26. Enter is 10, Tab 9, Backspace 8, Escape 27.
  - Alt+key comes as 27 first.
  - A held key repeats here, never in `WE_KEYDOWN`.
  - Modifiers: `WM_SHIFT` 1, `WM_CTRL` 2, `WM_ALT` 4, `WM_META` 8.
- **The pointer** (`RO_WIN_POINTER`):
  - `PTRM_ARROW` 0 is the arrow.
  - `PTRM_HIDDEN` 1 draws none over the window.
  - `PTRM_GRAB` 2 hides it and holds it at the window's middle while the
    window has the keys. Only `WE_MOVE`'s deltas change then, sent whatever
    the flags. Ctrl+alt lets it go until a click in the window.
- **The look**: `RO_DESK_LOOK` gives memory to map read only: the theme
  (`LK_MODE`, `LK_ACCENT`, the colours by role at `LK_C` + `TC_*`), the
  scale (`LK_S4`: quarters of a pixel a point), the screen's size and the
  desktop's fonts. `LK_SERIAL` counts each change, and `WE_LOOK` says one
  came.
- The window closes when its last handle does, and so when the program
  ends.

## Sound

With `AW_SOUND`:

1. Open a stream: `SYS_SOUND_NEW(SB_SOUND, frames)`. The frames are its
   ring's, made a power of two from 1024 to 65536.
2. Map its memory (`SYS_MAP`): a 64-byte header, then the ring at
   `SN_DATA`.
3. Write frames, then add how many to `SN_WRITE`. `RO_WAIT` on the stream
   for room.

Every stream is 48 kHz (`SN_RATE`), 16-bit signed, stereo
(`SN_CHANNELS`): a frame is 4 bytes, the left sample first. Frame `n` is at
`SN_DATA + (n mod SN_FRAMES) * 4`.

| Offset | Field | Who writes it | What |
|---|---|---|---|
| 0 | `SN_WRITE` | the program | frames written, in all (it wraps at 2^32) |
| 4 | `SN_READ` | the kernel | frames taken to play, in all |
| 8 | `SN_FRAMES` | the kernel | the ring's frames |
| 12 | `SN_RATE` | the kernel | 48000 |
| 16 | `SN_CHANNELS` | the kernel | 2 |
| 20 | `SN_LOW` | the program | `RO_WAIT` completes once no more than this many are queued; half the ring to begin with |
| 24 | `SN_GAIN` | the program | its volume, 65536 (as written) at most |
| 28 | `SN_SHORT` | the kernel | frames it had none for, once it began |

- Queued is `SN_WRITE - SN_READ`; room is `SN_FRAMES` less that. Write the
  frames before `SN_WRITE` says they are there.
- The mixer takes up to 5 ms of frames at a time, and keeps 40 ms ahead of
  the speakers. A stream that runs dry plays silence and counts
  `SN_SHORT`; it plays again from where `SN_WRITE` is once more come.
- Every stream is summed, each by its gain, then all by the volume the
  user set (`sound volume`), and saturated.
- Closing the stream's handle ends it, played or not. Its waits complete.
- With no sound device, a stream plays to nothing at the same pace, so a
  program can't tell.

## Files

With `AW_FILES`:

- **Paths**: a handle to every volume takes `vol<n>:/folder/file`. One made
  by `RO_FS_SUB` takes a path from its folder. No `.`, `..` or `\`.
  A volume that isn't there is `E_NOFILE`.
- **Read only by default**: every write is `E_READONLY` until the user
  types `vol <n> rw` in the shell. A program can't make a volume writable.
  `FV_FLAGS` says whether it is (`FVF_WRITABLE`).
- **Writes**: `RO_FS_WRITE` replaces the whole file. A read or a write is at
  most `FS_ROOM_MAX` (16 MiB).

## Time

The TSC is the clock: `rdtsc` is allowed, and the kernel assumes it is
invariant. A deadline is:

```
rdtsc + microseconds * SB_TSC_PER_US
```

To sleep, `RO_TIMEOUT` at that deadline. To wait for an event or a time,
`RO_WAIT` with that deadline. A wait ends at its deadline or a little
after, as the threads that finish waits are scheduled (the slice is 4 ms).
`SYS_FUTEX_WAIT` with a deadline sleeps without a ring.

The wall clock is `SYS_INFO`'s `SI_CLOCK`: microseconds since 1970, UTC
as far as the RTC knows.

## What a program may not do

Any of these ends the task: every thread, every program it started. The
shell says `ended by a fault` and logs what it ran into.

- Touch memory that isn't mapped, write constants or code, or run data. All
  mapped memory is NX but the code, so there is no JIT.
- `int N`, `int3`, `in`, `out`, `cli`, `hlt`, or any privileged instruction.
  Calls go only through `SYSCALL`.
- `rdfsbase`, `wrfsbase`, or any `gs:` access (its base is 0, and nothing
  is mapped below 0x200000); `fs:` too before `SYS_TLS` has set its base.
- `ret` from the entry.

## Limits

| | |
|---|---|
| Program image | 16 MiB |
| One memory object | 64 MiB |
| Mappings at once | 128 |
| Ring entries | 4096 (the start ring: 64) |
| A linked chain | 16 |
| One `RO_WRITE` | 4096 bytes |
| A channel message / waiting | 4096 bytes / 64 |
| Handles | 0x10000 slots |
| Arguments | 4031 bytes |
| Spawn text / depth | 255 bytes / 8 |
| A window's side | 4096 |
| A stream of sound | 65536 frames |
| A path | 256 bytes; a read or write 16 MiB |
| The first thread's stack | 64 KiB (make a larger one for anything deep) |

## Building

**NASM**: `src/user/*.asm`, with `%include "axe.inc"`.
- `axe.inc` lays the sections out and writes the header.
- `WANTS AW_DESK | AW_FILES` says what it needs.
- It provides `ax_*` helpers for the ring, the console and windows. The
  entry calls `main`, then `SYS_EXIT`.
- `python tools/build.py` assembles every program.

**Rust**: `sdk/rust`, with `std` (threads, locks, `thread_local!`, time,
files) on std's hermit layer, which the `axiom` crate fills in with the
calls above. Its README covers the target, the crate and `entry!`.
`python tools/rust.py` builds it.

**MASM**: `sdk/masm`, assembled by ml64, linked by link.exe and made an
.AXE by `tools/mkaxe.py`:

```
python tools/masm.py               # every program in sdk/masm
python tools/masm.py mhello        # one
```

- **`axiom.inc`** holds the kernel's constants in MASM's form, made from
  defs.inc each build: `INCLUDE axiom.inc`.
- **`; wants: AW_DESK OR AW_FILES`**, a line anywhere in the source, says
  what it wants.
- **The entry** is a PROC named `start`. It gets RDI = the start block, and
  ends with `SYS_EXIT`.
- **The link**, which `tools/masm.py` runs:
  `link /NODEFAULTLIB /ENTRY:start /SUBSYSTEM:NATIVE /BASE:0x400000 /FIXED
  /INCREMENTAL:NO`. The image must import no DLL and have no TLS
  directory.
- **mkaxe.py** turns the PE into an .AXE:
  - It writes the header over the PE's header page.
  - It takes the sections as code (executable), constants (read only) and
    data (written), in that order. `/MERGE:.rdata=.text` folds constants
    into the code if the order comes out wrong.
  - What the data has past its bytes in the file becomes the zeroes.
- **ml64 and link** are found through vswhere, from Visual Studio's C++
  tools. With none, `tools/masm.py` says so and exits 3, and the test
  passes as skipped.

`src/user/tone.asm` (NASM) and `sdk/rust/tone` (Rust, `rtone`) play a
sine through a stream of sound.

`sdk/masm/mhello.asm` is the worked example. It covers the start block, an
io block, the console, `RO_TIMEOUT`, a second thread joined, a window
filled and titled, its keys as text and as usages, and its close button.
`tools/test/masm` runs it in QEMU and checks the log and the screen.
