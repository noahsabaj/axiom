# Axiom

An operating system built from first principles, in assembly, for the machine in
front of it and for the agents that will drive it.

## The wrongs

1. **Ambient authority.** Every program you run can read every file you can, reach
   any server, and act as you. "User accounts" have been the security boundary for
   fifty years; malware and supply-chain attacks are the result. An autonomous agent
   can't be handed your whole identity.
2. **Bytes everywhere.** Unix made everything a byte stream, so every tool parses
   and re-serializes text and every interface has its own format. Humans and agents
   spend their effort scraping.
3. **Irreversibility.** `rm`, a bad update, a runaway script: most actions on a
   computer can't be undone. That's why we fear letting agents act.
4. **Legacy theater.** A 2024 CPU still wakes up as a 1978 8086 and emulates a PIC,
   a PIT, VGA text mode and the A20 gate. Kernels carry decades of compatibility
   code while the machine's real capabilities (dozens of hybrid cores, wide SIMD,
   power telemetry, IOMMUs) hide behind abstractions designed for one core and a
   slow disk.
5. **The kernel as a toll booth.** Synchronous syscalls, copies between kernel and
   user buffers, an interrupt per event, global locks. The hardware became a
   thousand times more parallel; the OS interface didn't.
6. **Opaque state.** Ask your computer what is running, why, what it touched and
   what changed, and you get guesses.
7. **Unreadable software.** Millions of lines nobody understands, dependency hell,
   configuration as folklore.

## The axioms

1. **Authority is explicit.** No users, no root, no global namespace. A task holds
   capabilities: unforgeable handles to exactly the objects it may use. Each one can
   be narrowed (read-only, a subtree, a rate, an expiry), revoked and audited. An
   agent runs with exactly the authority of its task.
2. **Everything is a typed object.** The system is a live graph of typed objects with
   schemas: devices, tasks, memory, documents, connections, windows. Programs,
   humans and agents query it and act on it through the same structured interface.
   Text is a rendering, not the interface.
3. **Every change is a transaction.** Storage is a content-addressed, copy-on-write
   object store. Changes are journaled with provenance (which task, which
   capability, why). Anything can be previewed, diffed and rolled back: undo for the
   whole machine.
4. **No legacy.** UEFI and ACPI in, long mode only, x2APIC, TSC-deadline timers,
   MSI-X, IOMMU. Nothing emulates 1981.
5. **Asynchronous by default.** One kernel interface: per-core submission and
   completion rings in shared memory. Messages carry capabilities and move memory
   ownership without copying. Batching is free; blocking is opt-in.
6. **The machine is the spec.** Axiom targets the hardware that is actually present:
   every core online, P-core/E-core aware scheduling, AVX2 in hot paths, per-core
   queues down to the NVMe. Frequency, temperature and power are first-class state.
7. **Small enough to understand.** Written in assembly by humans and agents together,
   readable top to bottom, and every subsystem tested automatically in an emulator.
   If you can't read it, you can't trust it.

## Agents are citizens

An agent in Axiom is a principal with:

- a **capability set** scoped to its job,
- a **budget** for CPU, memory, I/O, network and money,
- a **journal** of every action it took, and
- a **supervisor**: a human or a policy.

Before acting, an agent stages a transaction and shows its diff; the supervisor
commits or discards it. The native interface is a shared workspace where humans and
agents issue structured intents against the object graph.

## Roadmap

| Milestone | Scope |
|---|---|
| **M0 First light** | UEFI boot on real hardware, native-resolution graphics with anti-aliased text, every hardware thread online, live CPU telemetry, parallel AVX2 compute, a shell on a USB keyboard. |
| **M1 Spine** | Physical and virtual memory managers, kernel objects and capability tables, threads, a P/E-aware per-core scheduler, async rings, ring-3 tasks. *Done: the kernel's own page tables (no identity map, W^X, guard-paged stacks), a vm region with TLB shootdowns, a heap, kernel threads with a P/E-aware per-core scheduler (the main loop is the first thread), kernel objects with capability tables (rights, expiry, memory windows, derive, give, revoke, an audit ring), async rings (submission and completion queues in shared memory, waits that block nothing, linked entries, cancel, timers), and ring-3 tasks (programs from the boot stick, each with its own page tables, SYSCALL in and SYSRET out, the console through its ring, a fault ending only its own task; programs that start programs and hand them handles, channels between tasks, mappings a revoke takes back, a kill that reaches every program a program started) work today.* |
| **M2 Reach** | USB hubs and mice, NVMe with per-core queues, Realtek GbE, VT-d isolation for every driver. *Done: hubs, hot-plug, HID mice and keyboards, USB sticks, NVMe (an I/O queue pair per CPU, each completing on its own CPU's MSI-X interrupt), FAT32, Realtek Ethernet (one ring pair), and VT-d: every driver's devices in a DMA domain of their own that holds only what it mapped (an NVMe command's buffer for that command alone), every other device reaching nothing.* |
| **M3 Store** | A transactional, content-addressed object store on NVMe with provenance and snapshots. *Done: a copy-on-write log of objects named by their SHA-256 (blobs, trees, commits) under two superblocks, each commit journaled and made durable by one superblock write, so a crash before it leaves the store as it was; changes staged in transactions, diffed before they are committed, and refused when another commit changed the same name since; every commit saying which task made it, through which capability (its rights and prefix), when and why; snapshots, rollback and undo as new commits, so nothing is lost; programs reaching the store only through a capability scoped to names of their own, over their ring. It writes to QEMU's test drive alone for now, and reclaims no space.* |
| **M4 Net** | TCP/IP, TLS 1.3 on AES-NI/SHA-NI/VAES, HTTP: talk to models in the cloud. *Under way: ARP, IPv4, ICMP, UDP, DHCP, DNS, TCP (client), HTTP and HTTPS over a TLS 1.3 client of our own (AES-128-GCM, X25519, SHA-256 on AES-NI, PCLMULQDQ and SHA-NI) work today, with server certificates verified (X.509, RSA, ECDSA, Mozilla's trusted roots), and `ask` talks to Claude through the Messages API, streamed.* |
| **M5 Agents** | Principals, budgets, staged transactions, the structured workspace, and local inference across all cores. |

## Honest frontiers

- **NVIDIA GPU compute.** Ada has no public programming documentation beyond the open
  GSP firmware interface. The UEFI framebuffer works today; acceleration is a
  research project.
- **Wi-Fi (RTL8852BE).** Needs firmware blobs and a full 802.11 stack. Wired Ethernet
  works meanwhile.
- **Bluetooth (the same card's USB side).** Needs the vendor firmware patch, then HCI,
  pairing and the HID and audio profiles. Started and parked; until it lands, input is
  USB only.
