; =============================================================================
;  defs.inc - kernel-wide constants and structure layouts
; =============================================================================

AXIOM_VERSION   equ 1                   ; 0.1

MAX_CPUS        equ 256
KSTACK_SIZE     equ 0x10000             ; 64 KiB kernel stack per CPU
IST_SIZE        equ 0x4000              ; 16 KiB per interrupt stack

; per-CPU block: one per logical processor, reached through GS
PC_SELF         equ 0
PC_INDEX        equ 8
PC_APIC_ID      equ 16
PC_KIND         equ 24                  ; CPU_KIND_*
PC_STACK_TOP    equ 32
PC_ONLINE       equ 40
PC_JOB_GEN      equ 48                  ; last job generation this CPU ran
PC_JOB_ITEMS    equ 56                  ; work items done in the last job
PC_JOB_CYCLES   equ 64                  ; TSC cycles spent working in the last job
PC_ITERS        equ 72                  ; escape-time iterations in the last job
PC_MHZ          equ 80                  ; effective MHz from APERF/MPERF, 0 = unknown
PC_TEMP         equ 88                  ; degrees C from the digital sensor, 0 = unknown
PC_APERF        equ 96
PC_MPERF        equ 104
PC_CORE         equ 112                 ; core number within its kind
PC_THREAD       equ 120                 ; SMT thread within the core
PC_TSS          equ 128                 ; 104-byte TSS
PC_TLB_GEN      equ 232                 ; last TLB shootdown this CPU answered
; the scheduler's part (sched.asm)
PC_CURRENT      equ 256                 ; the thread running here
PC_IDLE_TH      equ 264                 ; this CPU's idle thread
PC_RQ           equ 272                 ; threads ready to run, least run first
PC_SLEEPQ       equ 280                 ; parked with a deadline, soonest first
PC_RQ_LOCK      equ 288                 ; dword: both queues
PC_RQ_LEN       equ 292                 ; dword: threads on the run queue
PC_BUSY         equ 296                 ; dword: 1 while a thread other than idle runs
PC_RESCHED      equ 300                 ; byte: switch on the way out of the interrupt
PC_SCHED_ON     equ 301                 ; byte: this CPU takes threads
PC_SKIND        equ 304                 ; the kind the scheduler goes by (CPU_KIND_*)
PC_SIBLING      equ 312                 ; its SMT sibling's index, or -1
PC_MIN_VR       equ 320                 ; the least virtual runtime here, never falls
PC_SLICE_END    equ 328                 ; TSC: the running thread's slice ends
PC_TIMER_AT     equ 336                 ; TSC: what the timer is set for, 0 = off
PC_LAST_TSC     equ 344                 ; TSC: time counted up to here
PC_BUSY_CYC     equ 352                 ; TSC cycles running threads
PC_IDLE_CYC     equ 360                 ; and idle
PC_SWITCHES     equ 368
PC_STEALS       equ 376                 ; threads taken from other queues
PC_PUSHES       equ 384                 ; threads handed to other CPUs
PC_PUSH_TO      equ 392                 ; -1, or where the running thread should go
PC_WORKER       equ 400                 ; the job worker thread (APs)
PC_BALANCE_AT   equ 408                 ; TSC: look for a better core, 0 = no need
PC_PUSH_WHO     equ 416                 ; the thread PC_PUSH_TO is for
PC_WANTS        equ 424                 ; the kind of core the running thread wants, if not this
PC_CUR_VR       equ 432                 ; the running thread's vruntime when last counted
PC_KSTACK       equ 440                 ; the running thread's kernel stack, for SYSCALL
PC_USER_RSP     equ 448                 ; its RSP in ring 3, on the way in
PC_CR3          equ 456                 ; the page tables loaded here, 0 = not known
PC_FSBASE       equ 464                 ; the FS base loaded here (TH_FSBASE)
PC_UGSBASE      equ 472                 ; ring 3's GS base loaded here (TH_GSBASE)
PC_SIZE         equ 512

CPU_KIND_UNKNOWN equ 0
CPU_KIND_P       equ 1                  ; performance core
CPU_KIND_E       equ 2                  ; efficient core

; every kernel object begins with this (object.asm)
OB_TYPE         equ 0                   ; dword OT_*
OB_REFS         equ 4                   ; dword: references; each capability holds one
OB_ID           equ 8                   ; never reused
OB_NEXT         equ 16                  ; every live object of its type
OB_PREV         equ 24
OB_NAME         equ 32                  ; NUL-terminated
OB_NAME_LEN     equ 24
OB_CAPS         equ 56                  ; dword: capabilities that point at it
OB_MAKER        equ 60                  ; dword: the id of the task that made it
OB_SIZE         equ 64

OT_TASK         equ 1
OT_THREAD       equ 2
OT_EVENT        equ 3
OT_MEMORY       equ 4
OT_RING         equ 5
OT_CONSOLE      equ 6                   ; the screen and the serial log (user.asm)
OT_CHANNEL      equ 7                   ; one end of a channel (channel.asm)
OT_STORE        equ 8                   ; names in the store, under a prefix (store.asm)
OT_NET          equ 9                   ; the network, to some hosts and ports (socket.asm)
OT_SOCKET       equ 10                  ; a connection, or a port listened on (socket.asm)
OT_DESK         equ 11                  ; the desktop: windows can be opened on it (window.asm)
OT_WINDOW       equ 12                  ; a program's window (window.asm)
                                        ; (13: the settings, on its own branch)
OT_FILES        equ 14                  ; files on FAT volumes, or in a folder (fscap.asm)
OT_SOUND        equ 15                  ; the speakers: streams can be opened on them (sound.asm)
OT_STREAM       equ 16                  ; a stream of sound, playing (sound.asm)
OT_TYPES        equ 17                  ; with 0, none

; what a capability allows (RT_*): three for any object, the rest by type
RT_DUP          equ 1 << 0              ; derive more from it
RT_GIVE         equ 1 << 1              ; hand it to another task
RT_INFO         equ 1 << 2              ; see what the object is
RT_TASK_HANDLES equ 1 << 8              ; a task: give it handles
RT_TASK_SPAWN   equ 1 << 9              ; start threads in it
RT_TASK_KILL    equ 1 << 10             ; kill it (and the tasks it started)
RT_THREAD_WAIT  equ 1 << 8              ; a thread: wait for it to end
RT_EV_SIGNAL    equ 1 << 8              ; an event: signal or reset it
RT_EV_WAIT      equ 1 << 9              ; wait for it
RT_MEM_READ     equ 1 << 8              ; memory: read it
RT_MEM_WRITE    equ 1 << 9              ; write it
RT_RING_ENTER   equ 1 << 8              ; a ring: submit to it, wait on it
RT_CON_WRITE    equ 1 << 8              ; the console: write lines to it
RT_CH_SEND      equ 1 << 8              ; a channel's end: send from it
RT_CH_RECV      equ 1 << 9              ; receive at it, and wait to
RT_ST_READ      equ 1 << 8              ; the store: read names, list them
RT_ST_WRITE     equ 1 << 9              ; stage changes, drop them
RT_ST_COMMIT    equ 1 << 10             ; commit what is staged
RT_ST_ROLLBACK  equ 1 << 11             ; put its names back as an earlier commit had them
RT_ST_ALL       equ RT_ST_READ | RT_ST_WRITE | RT_ST_COMMIT | RT_ST_ROLLBACK
RT_NET_CONNECT  equ 1 << 8              ; the network: connect over plain TCP
RT_NET_TLS      equ 1 << 9              ; over TLS, the server's certificate checked
RT_NET_INSECURE equ 1 << 10             ; over TLS, not checked
RT_NET_LISTEN   equ 1 << 11             ; listen on a port
RT_NET_ALL      equ RT_NET_CONNECT | RT_NET_TLS | RT_NET_INSECURE | RT_NET_LISTEN
RT_SK_SEND      equ 1 << 8              ; a socket: send on it, shut it
RT_SK_RECV      equ 1 << 9              ; receive from it, accept at it, wait to
RT_DESK_WINDOW  equ 1 << 8              ; the desktop: open windows on it
RT_WIN_DRAW     equ 1 << 8              ; a window: show what was drawn, title it
RT_FS_READ      equ 1 << 8              ; files: list folders, read files
RT_FS_WRITE     equ 1 << 9              ; write, make, rename, remove
RT_FS_KERNEL    equ 1 << 10             ; every volume: a new kernel (RO_FS_UPDATE)
RT_SOUND_PLAY   equ 1 << 8              ; the speakers: open streams on them
RT_STREAM_PLAY  equ 1 << 8              ; a stream: play it, wait on it
RT_ALL          equ 0xFFFF

; what handle operations return when they fail
E_BADH          equ -1                  ; no such handle
E_TYPE          equ -2                  ; the wrong type of object
E_RIGHTS        equ -3                  ; not allowed by the capability
E_EXPIRED       equ -4
E_REVOKED       equ -5
E_RANGE         equ -6                  ; outside a memory window
E_NOMEM         equ -7
E_FULL          equ -8                  ; the handle table is full
E_TIMEOUT       equ -9
E_ARG           equ -10
E_CANCELED      equ -11
E_KILLED        equ -12                 ; a thread whose task was killed
E_FAULT         equ -13                 ; one that faulted in ring 3
E_PEER          equ -14                 ; a channel's other end is closed
E_EMPTY         equ -15                 ; nothing to receive yet; nothing to commit
E_CONFLICT      equ -16                 ; the store: the head changed a name since it was staged
E_NONAME        equ -17                 ; no such name in the store
E_IO            equ -18                 ; the drive failed
E_NOSTORE       equ -19                 ; no store, or one that cannot be written
E_NET           equ -20                 ; a socket failed: RO_NET_STATUS says why
E_NOFILE        equ -21                 ; no such file, folder or volume
E_READONLY      equ -22                 ; the volume is not to be written ('vol <n> rw')
E_EXISTS        equ -23                 ; something has that name already
E_COUNT         equ 24                  ; with 0, none
E_ANY           equ -4096               ; what returns a pointer or an E_*: an
                                        ; error is RAX >= E_ANY, unsigned (the
                                        ; kernel's pointers are negative too)

; a thread (sched.asm), an object
TH_ID           equ OB_ID
TH_REFS         equ OB_REFS             ; its own, and its creator's handle
TH_NAME         equ OB_NAME
TH_NAME_LEN     equ OB_NAME_LEN
TH_ALL_NEXT     equ OB_NEXT             ; every thread, for listings
TH_ALL_PREV     equ OB_PREV
TH_RSP          equ 64                  ; saved stack pointer, while not running
TH_STATE        equ 72                  ; dword TS_*
TH_ONCPU        equ 76                  ; dword: a CPU is on its stack
TH_CPU          equ 80                  ; the CPU it runs or waits on
TH_PIN          equ 88                  ; -1, or the only CPU it may run on
TH_CLASS        equ 96                  ; THC_*: the kind of core it wants
TH_NEXT         equ 104                 ; run queue, sleep queue or zombie link
TH_VR           equ 112                 ; virtual runtime
TH_WAKE_AT      equ 120                 ; TSC deadline while parked with one
TH_TOKEN        equ 128                 ; dword: an unpark came while not parked
TH_WOKEN        equ 132                 ; dword: the last park ended by unpark
TH_STACK        equ 136                 ; its mapping, 0 if it kept the stack it had
TH_STACK_TOP    equ 144
TH_XSAVE        equ 152                 ; its SIMD state, 64-byte aligned
TH_RUN_TSC      equ 160                 ; when it last started running
TH_CYC_P        equ 168                 ; TSC cycles run on P-cores
TH_CYC_E        equ 176                 ; on E-cores
TH_CYC_O        equ 184                 ; on cores of no known kind
TH_SWITCHES     equ 192                 ; times it was switched to
TH_MIGRATIONS   equ 200                 ; times it ran on a different CPU
TH_FLAGS        equ 208                 ; TF_*
TH_EXIT         equ 216                 ; what it returned
TH_ENDED        equ 224                 ; dword: 1 once it has ended
TH_WQ           equ 232                 ; WQ_SIZE: those waiting for it to end
TH_HINT         equ 248                 ; -1, or the CPU to start on (tests)
TH_LAST         equ 256                 ; the CPU it last ran on, -1 if none
TH_TASK         equ 264                 ; the task it acts for (a reference)
TH_CR3          equ 272                 ; its task's page tables, 0 = the kernel's
TH_UENTRY       equ 280                 ; TF_USER: where it starts in ring 3
TH_USTACK       equ 288                 ; its RSP there
TH_UARG         equ 296                 ; and its RDI
; 304 is term.asm's TH_CON; 312 is free
TH_FSBASE       equ 320                 ; ring 3's FS base (a Linux thread's TLS)
TH_GSBASE       equ 328                 ; and its GS base
TH_TID          equ 336                 ; dword: a Linux thread's id
TH_LXFL         equ 340                 ; dword: LXF_* (lxsig.asm)
TH_CTID         equ 344                 ; its clear_child_tid, or 0
TH_SIGMASK      equ 352                 ; signals it blocks
TH_SIGPEND      equ 360                 ; signals sent to it, not yet taken
TH_ALTSP        equ 368                 ; its sigaltstack, 0 if none
TH_ALTSIZE      equ 376
TH_LXINFO       equ 384                 ; 32 bytes: a fault, for its signal (lxsig.asm)
TH_SAVEMASK     equ 416                 ; the mask rt_sigsuspend put aside
TH_SIZE         equ 448

; a wait queue (kobj.asm): threads waiting for a flag
WQ_LOCK         equ 0                   ; dword
WQ_HEAD         equ 8                   ; waiters, each on its thread's stack
WQ_SIZE         equ 16
EW_THREAD       equ 0                   ; the thread to unpark, or EW_FN's
EW_NEXT         equ 8
EW_FN           equ 16                  ; 0, or what to call instead (RDI =
                                        ; the entry; its queue's lock held,
                                        ; interrupts off, from anywhere)
EW_SIZE         equ 24

; a task (kobj.asm), an object: who acts, and the capabilities it holds
TK_SLOTS        equ 64                  ; its handle table, HS_SIZE bytes a slot
TK_NSLOTS       equ 72                  ; dword
TK_USED         equ 76                  ; dword: slots not free
TK_FREE         equ 80                  ; dword: the first free slot, 0 if none
TK_THREADS      equ 84                  ; dword: threads acting for it
TK_PARENT       equ 88                  ; the task that made it (a reference)
TK_OPS          equ 96                  ; handle operations it made
TK_DENIED       equ 104                 ; of those, refused
TK_ENDED        equ 112                 ; dword, bit 0: no thread and no handle
                                        ; to it were left, and its handles went
TK_KILL         equ 116                 ; dword, bit 0: killed; bit 1: by a fault;
                                        ; bit 2: by SYS_EXIT's EXIT_TASK, with
                                        ; TK_CODE (bit 3: that code being said)
TK_AS           equ 120                 ; its address space (user.asm), 0 if none
TK_LX           equ 128                 ; a Linux process: its state (linux.asm), or 0
TK_CON          equ 136                 ; the terminal its console writes go to
                                        ; (0: the first); its children's too
TK_CODE         equ 144                 ; what its first thread returns, by EXIT_TASK
TK_OUT          equ 152                 ; a channel's end its console writes go to
                                        ; instead, a message each (counted as a
                                        ; capability), until its last thread ends;
                                        ; its children's too; or 0
TK_SIZE         equ 192

; a slot of a handle table; a handle is (HS_GEN << 16) | its index, never 0
HS_CAP          equ 0                   ; its capability, 0 if free or revoked
HS_GEN          equ 8                   ; word: 1 to 0x7FFF, bumped when freed
HS_STATE        equ 10                  ; word HSS_*
HS_NEXT         equ 12                  ; dword: the next free slot
HS_SIZE         equ 16
HSS_FREE        equ 0
HSS_USED        equ 1
HSS_REVOKED     equ 2                   ; says so until closed

; a capability (object.asm)
CAP_OBJ         equ 0                   ; the object (a reference)
CAP_RIGHTS      equ 8                   ; dword RT_*
CAP_SLOT        equ 12                  ; dword: where in its task's table
CAP_TASK        equ 16                  ; the task holding it
CAP_EXPIRES     equ 24                  ; TSC, 0 = never
CAP_PARENT      equ 32                  ; the capability it was derived from
CAP_CHILD       equ 40                  ; the first derived from it
CAP_SIBLING     equ 48                  ; the next derived from its parent
CAP_OFF         equ 56                  ; memory: the window it allows
CAP_LEN         equ 64
CAP_LAST        equ 72                  ; byte: closing it left its object none
CAP_MAPVA       equ 80                  ; memory: where its holder has it mapped, 0 if not
CAP_MAPLEN      equ 88                  ; and how many bytes (user.asm)
CAP_SIZE        equ 96

; an event (kobj.asm), an object
EV_STATE        equ 64                  ; dword: 1 = signalled
EV_WQ           equ 72                  ; WQ_SIZE
EV_SIGNALS      equ 88                  ; times signalled
EV_SIZE         equ 96

; one end of a channel (channel.asm), an object
CH_PEER         equ 64                  ; the other end, 0 once either is closed
CH_HEAD         equ 72                  ; messages sent to this end, oldest first
CH_TAIL         equ 80
CH_COUNT        equ 88                  ; dword: how many
CH_READY        equ 92                  ; dword: 1 = one waits, or the peer is gone
CH_WQ           equ 96                  ; WQ_SIZE: requests waiting for CH_READY
CH_SENT         equ 112                 ; messages sent from it, ever
CH_RECEIVED     equ 120                 ; received at it
CH_SIZE         equ 128

; the network (OT_NET, socket.asm): what one capability to it reaches
NT_PATTERN      equ 64                  ; 64 bytes: a host, "*.name", or "" for any
NT_PORT         equ 128                 ; dword, 0 = any
NT_SIZE         equ 136

; a socket (OT_SOCKET, socket.asm)
SK_BUF          equ 65536               ; bytes each way, a power of two
SK_ACCEPT_MAX   equ 8                   ; connections taken, waiting to be accepted
SK_STATE        equ 64                  ; dword SKS_*
SK_WHY          equ 68                  ; dword NETW_*
SK_TLSE         equ 72                  ; dword: TLS's error, for NETW_TLS
SK_FLAGS        equ 76                  ; dword SKF_*
SK_RREADY       equ 80                  ; dword: something to receive, or no more ever
SK_WREADY       equ 84                  ; dword: room to send, or never again
SK_RWQ          equ 88                  ; WQ_SIZE: requests waiting for SK_RREADY
SK_WWQ          equ 104                 ; for SK_WREADY
SK_NEXT         equ 120                 ; on sk_new, then on sk_list
SK_PREV         equ 128
SK_TCP          equ 136                 ; the connection, while there is one
SK_TLS          equ 144                 ; the session, for TLS
SK_LISTENER     equ 152                 ; tcp.asm's, while listening
SK_RX           equ 160                 ; SK_BUF: what came, for the program
SK_RX_HEAD      equ 168                 ; dword
SK_RX_LEN       equ 172                 ; dword
SK_TX           equ 176                 ; SK_BUF: what the program sent
SK_TX_HEAD      equ 184
SK_TX_LEN       equ 188
SK_CIN          equ 192                 ; TLS: what came, still encrypted
SK_CIN_HEAD     equ 200
SK_CIN_LEN      equ 204
SK_FREED        equ 208                 ; dword: received, not yet told to TCP
SK_BUSY         equ 212                 ; dword: bit 0 a send, bit 1 a receive, copying
SK_PORT         equ 220                 ; dword
SK_GONE_AT      equ 224                 ; TSC: no handle; reset if not closed by then
SK_ACN          equ 232                 ; dword: accepted connections waiting
SK_ACQ          equ 240                 ; SK_ACCEPT_MAX of them, oldest first
SK_RXBY         equ 304                 ; bytes received, ever
SK_TXBY         equ 312                 ; sent
SK_HOST         equ 320                 ; 256 bytes, NUL-ended
SK_ADDR         equ 576                 ; the other side's address (16 bytes)
SK_LADDR        equ 592                 ; ours, once it is connecting (16 bytes)
SK_LPORT        equ 608                 ; dword: our port (a listener's own)
SK_IDENT        equ 616                 ; TLS: a listener's identity (TID_*), or
                                        ; the one a socket it took serves with
SK_PARENT       equ 624                 ; that socket's listener (a reference)
SK_SIZE         equ 632

; a block of memory (kobj.asm), an object
MO_BASE         equ 64                  ; its pages, in the vm region
MO_BYTES        equ 72
MO_SIZE         equ 80

; a ring (ring.asm), an object: a submission queue and a completion queue
; in a block of memory its task shares with the kernel
RG_AREA         equ 64                  ; the memory (a reference)
RG_BASE         equ 72                  ; where it is
RG_SQ_BASE      equ 80                  ; its submission entries
RG_CQ_BASE      equ 88                  ; its completions
RG_SQN          equ 96                  ; dword: entries, a power of two
RG_CQN          equ 100                 ; dword: completions, twice as many
RG_SQ_HEAD      equ 104                 ; dword: entries taken
RG_CQ_TAIL      equ 108                 ; dword: completions written
RG_PROMISED     equ 112                 ; dword: completions owed or written
RG_FLAGS        equ 116                 ; dword: RGF_* bits
RG_LOCK         equ 120                 ; dword
RG_LIVE         equ 124                 ; dword: its requests waiting
RG_PENDING      equ 128                 ; those requests
RG_WQ           equ 136                 ; WQ_SIZE: threads waiting for completions
RG_SUBMITTED    equ 152                 ; entries taken, ever
RG_COMPLETED    equ 160
RG_ASYNC        equ 168                 ; entries that waited
RG_CANCELED     equ 176
RG_SIZE         equ 192
RGF_SUBMIT      equ 0                   ; a thread is taking entries
RGF_ORPHAN      equ 1                   ; no handle to it is left

; a ring's memory: first the indices, each written by one side only
RA_SQ_TAIL      equ 0                   ; dword: entries written, by the task
RA_CQ_HEAD      equ 4                   ; dword: completions read, by the task
RA_SQ_HEAD      equ 64                  ; dword: entries taken, by the kernel
RA_CQ_TAIL      equ 68                  ; dword: completions written, by the kernel
RA_SQ_ENTRIES   equ 128                 ; dword
RA_CQ_ENTRIES   equ 132                 ; dword
RA_SQ_OFF       equ 136                 ; dword: where the entries are
RA_CQ_OFF       equ 140                 ; dword: where the completions are
RA_TSC_PER_US   equ 144                 ; for deadlines
RA_HDR          equ 256

; a submission entry
SQ_OP           equ 0                   ; byte RO_*
SQ_FLAGS        equ 1                   ; byte SQF_*
SQ_HANDLE       equ 4                   ; dword
SQ_DATA         equ 8                   ; the task's own, back in its completion
SQ_A0           equ 16
SQ_A1           equ 24
SQ_A2           equ 32
SQ_HANDLE2      equ 40                  ; dword
SQ_DEADLINE     equ 48                  ; TSC, 0 = none
SQ_SIZE         equ 64
SQF_LINK        equ 1                   ; the next starts once this one succeeds

; a completion
CQ_DATA         equ 0
CQ_RESULT       equ 8                   ; what it returned, or E_*
CQ_VALUE        equ 16                  ; RO_JOIN: what the thread returned
CQ_OP           equ 24                  ; dword RO_*
CQ_SIZE         equ 32

; what an entry asks for
RO_NOP          equ 0
RO_SIGNAL       equ 1                   ; handle: an event
RO_RESET        equ 2                   ; handle
RO_WAIT         equ 3                   ; handle, deadline: once it is signalled
RO_JOIN         equ 4                   ; handle, deadline: once a thread ended
RO_TIMEOUT      equ 5                   ; deadline: once it comes
RO_COPY         equ 6                   ; handle + a0 -> handle2 + a1, a2 bytes
RO_DUP          equ 7                   ; handle, a0 = rights, a1 = expiry
RO_CLOSE        equ 8                   ; handle
RO_GIVE         equ 9                   ; handle, handle2 = a task
RO_REVOKE       equ 10                  ; handle
RO_CANCEL       equ 11                  ; a0: the data of requests to cancel
RO_WRITE        equ 12                  ; handle = the console, handle2 + a0: a1
                                        ; bytes of text -> the bytes
RO_SEND         equ 13                  ; handle = a channel, handle2 + a0: a1
                                        ; bytes, a message -> the bytes; or a
                                        ; socket: as many as there is room for
RO_RECV         equ 14                  ; handle, the next message into handle2 +
                                        ; a0, a1 bytes at most -> its bytes, or
                                        ; E_EMPTY (RO_WAIT on it waits for one);
                                        ; a socket: as many as came, and fit
RO_KILL         equ 15                  ; handle = a task
RO_ST_PUT       equ 16                  ; handle = a store, handle2 + a0: a name
                                        ; (a 64-byte field, NUL-ended), handle2 +
                                        ; a1: a2 bytes for it -> 0, staged
RO_ST_GET       equ 17                  ; handle, handle2 + a0: a name; into
                                        ; handle2 + a1, a2 bytes at most -> the
                                        ; bytes it holds (staged, else committed)
RO_ST_DEL       equ 18                  ; handle, handle2 + a0: a name -> 0, staged
RO_ST_COMMIT    equ 19                  ; handle, handle2 + a0: why, a1 bytes ->
                                        ; the commit's number
RO_ST_ABORT     equ 20                  ; handle -> the changes dropped
RO_ST_SUB       equ 21                  ; handle, handle2 + a0: a name, a1 =
                                        ; rights -> a handle to the names under
                                        ; "name/" alone
RO_ST_ROLLBACK  equ 22                  ; handle, a0 = a commit's number -> a new
                                        ; commit: its names as they were then
RO_ST_LIST      equ 23                  ; handle, into handle2 + a0, a1 bytes at
                                        ; most: its names, NUL-ended -> how many
RO_NET_CONNECT  equ 24                  ; handle = the network, handle2 + a0: a
                                        ; host (a 256-byte field, NUL-ended: a
                                        ; name or a dotted quad), a1 = port, a2 =
                                        ; NETF_* -> a socket, at once (RO_WAIT
                                        ; with a0 = 1 until it is open)
RO_NET_LISTEN   equ 25                  ; handle, a0 = port (0: one of ours, any
                                        ; that is free), a2 = NETF_TLS or 0; for
                                        ; TLS, handle2 + a1: the identity (NI_*)
                                        ; -> a socket listening (RO_WAIT with
                                        ; a0 = 1 until it does)
RO_NET_ACCEPT   equ 26                 ; handle = a socket listening -> a socket,
                                        ; the oldest connection it took, or
                                        ; E_EMPTY (RO_WAIT on it waits for one)
RO_NET_STATUS   equ 27                  ; handle = a socket -> SKS_* | NETW_* << 8
                                        ; | TLS's error << 16 | NS_* (what RO_WAIT
                                        ; would wait for, there now)
RO_NET_SHUT     equ 28                  ; handle = a socket: a FIN once what was
                                        ; sent has gone (plain TCP)
RO_NET_SUB      equ 29                  ; handle = the network, handle2 + a0: a
                                        ; host pattern (a 64-byte field: a host,
                                        ; "*.name" for those under it, "" any),
                                        ; a1 = a port or 0, a2 = rights -> a
                                        ; handle reaching no more than both
RO_WIN_SHOW     equ 30                  ; handle = a window, a0 = x, a1 = y, a2 =
                                        ; w | h << 32 (0: all of it): what was
                                        ; drawn there is shown
RO_WIN_TITLE    equ 31                  ; handle, handle2 + a0: a1 bytes of UTF-8, its title
                                        ; (32, 33: the settings', on their branch)
RO_DESK_LOOK    equ 34                  ; handle = the desktop -> a handle to the
                                        ; look, memory to map and read (LK_*)
; files (fscap.asm): handle = files, handle2 + a0: a path (an FS_PATH field,
; NUL-ended: "vol<n>:/a/b" with a handle to every volume, else from its folder)
RO_FS_VOLUMES   equ 35                  ; handle, into handle2 + a0, a1 bytes at
                                        ; most: FV_* records -> how many volumes
RO_FS_LIST      equ 36                  ; handle, handle2 + a0: a folder; into
                                        ; handle2 + a1, a2 bytes at most: FE_*
                                        ; records -> how many things it holds
RO_FS_READ      equ 37                  ; handle, handle2 + a0: a file; into
                                        ; handle2 + a1, a2 bytes at most -> its size
RO_FS_WRITE     equ 38                  ; handle, handle2 + a0: a file; handle2 +
                                        ; a1: a2 bytes, all it holds now -> 0
RO_FS_MKDIR     equ 39                  ; handle, handle2 + a0: a folder -> 0, made
RO_FS_REMOVE    equ 40                  ; handle, handle2 + a0: a file or an empty
                                        ; folder -> 0, gone
RO_FS_RENAME    equ 41                  ; handle, handle2 + a0: a file or a folder,
                                        ; handle2 + a1: its new path, on the same
                                        ; volume -> 0 (renamed, or moved, in place)
RO_FS_SUB       equ 42                  ; handle, handle2 + a0: a folder, a1 =
                                        ; rights -> a handle to it alone
RO_WIN_POINTER  equ 43                  ; handle = a window, a0 = PTRM_*: the
                                        ; pointer over it, or held by it
RO_NET_ADDR     equ 44                  ; handle = a socket, into handle2 + a0:
                                        ; NA_SIZE bytes, its addresses -> 0;
                                        ; E_EMPTY while its host is looked up
RO_FS_UPDATE    equ 45                  ; handle = files, to every volume, with
                                        ; RT_FS_KERNEL; a1 = UPD_*: a new kernel,
                                        ; as the shell's 'update' (update.asm)
RO_WIN_ZOOM     equ 46                  ; handle = a window that may be resized,
                                        ; a0 = WZ_*: full screen, zoomed or
                                        ; neither (WE_ZOOM says so, once done)
RO_COUNT        equ 47

; a new kernel (RO_FS_UPDATE's a1)
UPD_STATE       equ 0                   ; -> UPS_*
UPD_TRY         equ 1                   ; handle2 + a0: a kernel.bin's path, a2 =
                                        ; seconds to keep it in (0: 600) -> 0: in
                                        ; the slot not kept, tried at the next start
UPD_KEEP        equ 2                   ; on trial -> 0: kept, for every start
UPD_RESTART     equ 3                   ; a2 = seconds, 1 to 60 -> 0: with a trial
                                        ; to come, the machine restarts into it
UPS_SLOT        equ 0xFF                ; the kernel running: 'A', 'B'; 0 built in
UPS_TRIAL       equ 1 << 8              ; it is on trial, not kept yet
UPS_KEPT_SHIFT  equ 16                  ; << the one kept: 'A', 'B'; 0 none
UPS_NEXT_SHIFT  equ 24                  ; << the one the next start tries, or 0

; files (fscap.asm)
FS_PATH         equ 256                 ; a path's field
FV_INDEX        equ 0                   ; a volume (RO_FS_VOLUMES): dword, its n in "vol<n>:"
FV_FLAGS        equ 4                   ; dword FVF_*
FV_BYTES        equ 8                   ; its size
FV_LABEL        equ 16                  ; its name, NUL-ended
FV_FREE         equ 64                  ; bytes free on it
FV_SIZE         equ 72
FVF_WRITABLE    equ 1                   ; 'vol <n> rw' was said
FVF_REMOVABLE   equ 2                   ; a stick, a card
FVF_BOOT        equ 4                   ; the stick Axiom started from
FE_LEN          equ 0                   ; a thing in a folder (RO_FS_LIST): dword, the record's bytes
FE_ATTR         equ 4                   ; dword FEA_*
FE_SIZE         equ 8                   ; bytes, 0 for a folder
FE_YEAR         equ 16                  ; word: when it was last written (0: never said)
FE_MONTH        equ 18                  ; byte, 1..12
FE_DAY          equ 19
FE_HOUR         equ 20
FE_MIN          equ 21
FE_SEC          equ 22
FE_NAME         equ 24                  ; UTF-8, NUL-ended; the record is 8-aligned
FEA_DIR         equ 1
FEA_RO          equ 2
FEA_HIDDEN      equ 4
FEA_SYSTEM      equ 8

; RO_NET_CONNECT's a2 (and RO_NET_LISTEN's: NETF_TLS)
NETF_TLS        equ 1
NETF_INSECURE   equ 2                   ; with NETF_TLS: the certificate not checked
NETF_LOOKUP     equ 4                   ; alone: the host only looked up; the socket
                                        ; ends once its address is known (RO_WAIT,
                                        ; a0 = 0), for RO_NET_ADDR to say

; what a TLS listener proves it is (RO_NET_LISTEN): its connections are
; TLS 1.3, signed with the key (ECDSA P-256), sending the certificates
NI_KEY          equ 0                   ; the private key, 32 bytes, big-endian
NI_LEN          equ 32                  ; dword: bytes at NI_CERTS
NI_CERTS        equ 40                  ; the certificates, the leaf first, each a
                                        ; 24-bit big-endian length, its DER and
                                        ; two zero bytes (as TLS lists them)
NI_MAX          equ 16000               ; bytes at NI_CERTS, at most

; a socket's addresses (RO_NET_ADDR); 16 bytes each, IPv4 as ::ffff:a.b.c.d
NA_PEER         equ 0                   ; the other side's (the host's, looked up)
NA_LOCAL        equ 16                  ; ours (:: until it connects; a listener's)
NA_PEER_PORT    equ 32                  ; dword
NA_PORT         equ 36                  ; dword: ours (a listener's, once it listens)
NA_SIZE         equ 40

; RO_NET_STATUS's, besides the state
NS_RECV         equ 1 << 24             ; something to receive, or never more
NS_SEND         equ 1 << 25             ; room to send, or never again; a
                                        ; listener: it listens, or failed

; a socket's state (RO_NET_STATUS)
SKS_LOOKUP      equ 1                   ; its host is being looked up
SKS_CONNECT     equ 2
SKS_HANDSHAKE   equ 3                   ; TLS's
SKS_OPEN        equ 4
SKS_ENDED       equ 5                   ; the connection is over, cleanly
SKS_FAILED      equ 6                   ; NETW_* says why
SKS_LISTEN      equ 7

; why it failed
NETW_NOSERVER   equ 1                   ; no DNS server is known
NETW_BADNAME    equ 2                   ; not a host name
NETW_BUSY       equ 3                   ; too many lookups at once
NETW_NOHOST     equ 4                   ; no such host
NETW_NOADDR     equ 5                   ; it has no IPv4 address
NETW_DNS        equ 6                   ; the DNS server could not answer
NETW_NOANSWER   equ 7                   ; no answer from the DNS server
NETW_DOWN       equ 8                   ; no network, or no address on it
NETW_NOROUTE    equ 9                   ; no connection free, or no route
NETW_REFUSED    equ 10
NETW_RESET      equ 11
NETW_TIMEOUT    equ 12
NETW_TLS        equ 13                  ; TLS's error says why
NETW_INUSE      equ 14                  ; the port is listened on already
NETW_IDENTITY   equ 15                  ; a TLS listener's: the certificates will
                                        ; not do, or the key is not the leaf's

TS_NEW          equ 0
TS_READY        equ 1
TS_RUNNING      equ 2
TS_PARKED       equ 3
TS_DEAD         equ 4

THC_ANY         equ 0                   ; any core, P-cores a little sooner
THC_PERF        equ 1                   ; wants a P-core
THC_EFF         equ 2                   ; wants an E-core

TF_IDLE         equ 1
TF_MAIN         equ 2
TF_WORKER       equ 4
TF_USER         equ 8                   ; runs in ring 3 (user.asm)
TF_FIRST        equ 16                  ; its task's first: when it ends, the task does
TF_LINUX        equ 32                  ; a Linux program's: Linux system calls (linux.asm)

; 64-bit TSS
TSS_RSP0        equ 4
TSS_IST1        equ 36
TSS_IST2        equ 44
TSS_IST3        equ 52
TSS_IOPB        equ 102
TSS_LIMIT       equ 103

; GDT selectors
SEL_KCODE       equ 0x08
SEL_KDATA       equ 0x10
SEL_UDATA       equ 0x18 | 3
SEL_UCODE       equ 0x20 | 3
SEL_TSS0        equ 0x28                ; CPU n uses SEL_TSS0 + 16 * n

; interrupt vectors
VEC_KBD         equ 0x21
VEC_USB         equ 0x22
VEC_NET         equ 0x23
VEC_SERIAL      equ 0x24                ; COM1's bytes in, to the BSP
VEC_TIMER       equ 0x30
VEC_WAKE        equ 0x40
VEC_TLB         equ 0x41
VEC_RESCHED     equ 0x42
VEC_NVME        equ 0x43                ; NVMe completions, each queue to its CPU
VEC_IOMMU       equ 0x44                ; VT-d faults, to the BSP
VEC_SPURIOUS    equ 0xFF
VEC_SYSCALL     equ 0x100               ; not a vector: a frame SYSCALL built

; interrupt frame built by isr_common (offsets from the frame pointer)
FR_R15          equ 0
FR_R14          equ 8
FR_R13          equ 16
FR_R12          equ 24
FR_R11          equ 32
FR_R10          equ 40
FR_R9           equ 48
FR_R8           equ 56
FR_RBP          equ 64
FR_RDI          equ 72
FR_RSI          equ 80
FR_RDX          equ 88
FR_RCX          equ 96
FR_RBX          equ 104
FR_RAX          equ 112
FR_VECTOR       equ 120
FR_ERROR        equ 128
FR_RIP          equ 136
FR_CS           equ 144
FR_RFLAGS       equ 152
FR_RSP          equ 160
FR_SS           equ 168

; model-specific registers
MSR_APIC_BASE   equ 0x1B
MSR_TSC_DEADLINE equ 0x6E0
MSR_MPERF       equ 0xE7
MSR_APERF       equ 0xE8
MSR_THERM_STATUS equ 0x19C
MSR_TEMP_TARGET equ 0x1A2
MSR_PKG_THERM_STATUS equ 0x1B1
MSR_RAPL_UNIT   equ 0x606
MSR_PKG_ENERGY  equ 0x611
MSR_PM_ENABLE   equ 0x770
MSR_HWP_CAPS    equ 0x771
MSR_HWP_REQUEST equ 0x774
MSR_EFER        equ 0xC0000080
MSR_STAR        equ 0xC0000081
MSR_LSTAR       equ 0xC0000082
MSR_FMASK       equ 0xC0000084
MSR_FS_BASE     equ 0xC0000100
MSR_GS_BASE     equ 0xC0000101
MSR_KGS_BASE    equ 0xC0000102

; ring 3 (user.asm): what a program sees. Programs include this file.
USER_START      equ 0x200000            ; the start block, read-only
USER_IMAGE      equ 0x400000            ; the program, its header first
USER_IMAGE_MAX  equ 16 << 20
USER_MAPS       equ 0x100000000000      ; blocks of memory it maps, a guard page after each
USER_STACK_TOP  equ 0x7FF000000000      ; its first thread's stack is below
USER_STACK_SIZE equ 0x10000
USER_TOP        equ 0x800000000000      ; the end of the lower half

; a program's header, at USER_IMAGE (the start of its file)
AXE_MAGIC       equ 0                   ; 'AXIOMEX2'
AXE_ENTRY       equ 8
AXE_TEXT_END    equ 16                  ; code from USER_IMAGE to here
AXE_RODATA_END  equ 24                  ; constants from there to here
AXE_DATA_END    equ 32                  ; data from there to here: the end of the file
AXE_BSS_END     equ 40                  ; and zeroes from there to here
AXE_WANTS       equ 48                  ; what it needs to be given (AW_*), and no more
AXE_HDR         equ 56

; what a program can be given when it is run from the shell: declared in its
; header (WANTS, axe.inc), or granted for one run (+net, +store, +desk)
AW_NET          equ 1                   ; the network (SB_NET)
AW_STORE        equ 2                   ; its own names in the store (SB_STORE)
AW_DESK         equ 4                   ; the desktop, to open windows on (SB_DESK)
                                        ; (8: the settings, on their branch)
AW_FILES        equ 16                  ; the files on every volume (SB_FILES)
AW_SOUND        equ 32                  ; the speakers (SB_SOUND)
AW_UPDATE       equ 64                  ; with AW_FILES: a new kernel (RT_FS_KERNEL)
AW_ALL          equ 7 | AW_FILES | AW_SOUND | AW_UPDATE

; the start block, at USER_START; the first thread starts with RDI = it
SB_RING         equ 0                   ; dword: a handle to the task's ring
SB_RING_MEM     equ 4                   ; dword: to the ring's memory
SB_CONSOLE      equ 8                   ; dword: to the console
SB_GIFT         equ 12                  ; dword: what the task that started it gave, or 0
SB_RING_VA      equ 16                  ; where the ring's memory is mapped
SB_TSC_PER_US   equ 24                  ; for deadlines
SB_ARGS_LEN     equ 32                  ; dword
SB_STORE        equ 36                  ; dword: to the store under "name/", or 0
SB_NET          equ 40                  ; dword: to the network, or 0
SB_DESK         equ 44                  ; dword: to the desktop, or 0
SB_FILES        equ 52                  ; dword: to the files, or 0
SB_GIFT2        equ 56                  ; dword: a second thing it was given, or 0
                                        ; (each given handle to a desktop, files,
                                        ; the speakers, the network or the store
                                        ; is in its slot too, if that was empty)
SB_SOUND        equ 60                  ; dword: to the speakers, or 0
SB_ARGS         equ 64                  ; the arguments it was run with, NUL-ended
SB_ARGS_MAX     equ 4096 - SB_ARGS - 1

; system calls: SYSCALL with RAX = the number and the arguments in RDI, RSI,
; RDX, R10 (and R8, a fifth); the result in RAX (and RDX), RCX and R11 lost,
; the rest kept (docs/ABI.md)
SYS_EXIT        equ 0                   ; (code, EXIT_TASK or 0): this thread ends;
                                        ; with EXIT_TASK its task too, with that code
SYS_RING_ENTER  equ 1                  ; (ring, take, wait for, TSC deadline) -> taken
SYS_RING_NEW    equ 2                   ; (entries) -> RAX = a ring, RDX = its memory
SYS_MEM_NEW     equ 3                   ; (bytes) -> zeroed memory
SYS_MAP         equ 4                   ; (memory) -> where it is mapped now
SYS_EVENT_NEW   equ 5                   ; -> an event
SYS_THREAD_NEW  equ 6                   ; (entry, RSP, RDI) -> a thread, started
SYS_YIELD       equ 7
SYS_UNMAP       equ 8                   ; (memory): its mapping goes
SYS_SPAWN       equ 9                   ; (memory, offset, bytes of "program args"
                                        ; | a channel's end << 32 for what its
                                        ; console writes, or 0; a handle to give
                                        ; it or 0, a second or 0) -> RAX = the
                                        ; task, RDX = its first thread
SYS_CHANNEL_NEW equ 10                  ; -> RAX, RDX = the two ends of a channel
SYS_WINDOW_NEW  equ 11                  ; (desktop, width, height, a channel's end,
                                        ; the window's events come to its peer
                                        ; while it is open, WNF_*) -> RAX =
                                        ; the window, RDX = its pixels: memory,
                                        ; B,G,R,x at width * 4 bytes a row (with
                                        ; WNF_RESIZE, WNF_FULL or WNF_SCREEN: the
                                        ; screen's width * 4 a row, its height
                                        ; of rows)
SYS_SOUND_NEW   equ 12                  ; (the speakers, frames) -> RAX = a stream
                                        ; playing, RDX = its memory (SN_*)
SYS_TLS         equ 13                  ; (FS base): this thread's, for its
                                        ; thread-local storage
SYS_FUTEX_WAIT  equ 14                  ; (address, value, TSC deadline or 0): waits
                                        ; while the dword there holds that value,
                                        ; until a SYS_FUTEX_WAKE -> 0, E_CONFLICT
                                        ; (it held another), E_TIMEOUT
SYS_FUTEX_WAKE  equ 15                  ; (address, at most) -> threads woken there
SYS_INFO        equ 16                  ; (SI_*) -> RAX
SYS_COUNT       equ 17
EXIT_TASK       equ 1                   ; SYS_EXIT: the whole task ends
SI_CLOCK        equ 0                   ; microseconds since 1970, by the RTC (as UTC)
SI_CPUS         equ 1                   ; CPUs running
SI_RAM          equ 2                   ; bytes of memory Axiom has
SI_RAM_FREE     equ 3                   ; of those, bytes free
SI_UPTIME       equ 4                   ; milliseconds since power-on
SI_BATTERY      equ 5                   ; the battery as last read (each minute), or E_EMPTY
SI_BAT_PERCENT  equ 0xFF                ; SI_BATTERY: its charge, in percent
SI_BAT_PLUGGED  equ 1 << 8              ; on its charger
SI_BAT_HELD     equ 1 << 9              ; kept between 75% and 80% ('battery hold')
SI_BAT_MODE_SHIFT equ 16                ; bits 19:16: 0 charging as the firmware likes, 2 run from the battery, 5 not charging
SI_TEMP         equ 6                   ; the CPU's temperature now, degrees C (its package's sensor), or E_EMPTY
SI_LOAD         equ 7                   ; the load average over the last minute, in hundredths

; a stream's memory (SYS_SOUND_NEW): this header, then SN_FRAMES frames at
; SN_DATA, each a left and a right sample, 16 bits signed, SN_RATE a second.
; The program writes frames at SN_WRITE (mod SN_FRAMES) and adds to it; the
; mixer takes them and adds to SN_READ. RO_WAIT on the stream completes once
; no more than SN_LOW frames wait to be played.
SN_WRITE        equ 0                   ; dword: frames written, in all (the program's)
SN_READ         equ 4                   ; dword: frames taken to play, in all
SN_FRAMES       equ 8                   ; dword: the ring's, a power of two
SN_RATE         equ 12                  ; dword: 48000
SN_CHANNELS     equ 16                  ; dword: 2
SN_LOW          equ 20                  ; dword: half SN_FRAMES to begin with (the program's)
SN_GAIN         equ 24                  ; dword: its volume, 65536 as written, at most (the program's)
SN_SHORT        equ 28                  ; dword: frames it had none for, once begun
SN_DATA         equ 64

; what a window says, from the channel end it was given: a message of WE_SIZE
; bytes to its peer for each
WE_KIND         equ 0                   ; dword: WE_KEY ...
WE_CODE         equ 4                   ; dword: the key (WE_X: WM_*); the button (1 left, 2
                                        ; right, 3 middle); the wheel's notches
                                        ; (up positive); how far the pointer
                                        ; moved, dx | dy << 16, 16 bits signed
                                        ; each (the mouse's own counts, before
                                        ; it is sped up or stopped at an edge)
WE_X            equ 8                   ; dword, signed: the pointer, in the window
WE_Y            equ 12
WE_SIZE         equ 16
WE_KEY          equ 1                   ; a key, while it has the keys
WE_PRESS        equ 2                   ; a button pressed in it
WE_RELEASE      equ 3                   ; and let go (anywhere)
WE_MOVE         equ 4                   ; the pointer moved, a button held (or
                                        ; with WNF_HOVER, over it)
WE_WHEEL        equ 5
WE_CLOSE        equ 6                   ; its close button: it is asked to go
WE_RESIZED      equ 7                   ; its size now: WE_X wide, WE_Y high (draw
                                        ; it all again, then show it)
WE_LOOK         equ 8                   ; the look changed (LK_SERIAL): draw again
WE_FOCUS        equ 9                   ; WE_CODE = 1: it has the keys now; 0: not
WE_KEYDOWN      equ 10                  ; WNF_KEYS: a key went down, once (held, it
                                        ; repeats only WE_KEY): WE_CODE = its USB
                                        ; HID usage (page 7: 4 A ... 0x2C space,
                                        ; 0x4F-0x52 the arrows, 0xE0-0xE7 the
                                        ; modifiers), WE_X = WM_*, either keyboard
WE_KEYUP        equ 11                  ; and came up (or one went down before it
                                        ; had the keys: losing them, WE_FOCUS 0,
                                        ; is every key up)
WE_LEAVE        equ 12                  ; WNF_HOVER: the pointer left it
WE_ZOOM         equ 13                  ; WE_CODE = WZ_*: full screen, zoomed or
                                        ; neither now, however it came to be
                                        ; (before the WE_RESIZED that follows)
WM_SHIFT        equ 1                   ; WE_KEY's WE_X: the modifiers held
WM_CTRL         equ 2
WM_ALT          equ 4
WM_META         equ 8
WNF_RESIZE      equ 1                   ; SYS_WINDOW_NEW: the user may resize it
WNF_FULL        equ 2                   ; as WNF_RESIZE, and zoomed to begin with:
                                        ; the screen between the bar and the dock
WNF_KEYS        equ 4                   ; WE_KEYDOWN and WE_KEYUP too (games)
WNF_HOVER       equ 8                   ; WE_MOVE without a button, and WE_LEAVE
WNF_SCREEN      equ 16                  ; as WNF_RESIZE, and full screen to begin
                                        ; with (WZ_SCREEN)
PTRM_ARROW      equ 0                   ; RO_WIN_POINTER: the arrow, as anywhere
PTRM_HIDDEN     equ 1                   ; none over it (it draws its own)
PTRM_GRAB       equ 2                   ; none, and held in its middle while it
                                        ; has the keys: WE_MOVE (WNF_HOVER or
                                        ; not) says how far the mouse moved;
                                        ; ctrl+alt lets go until it is clicked
WZ_NORMAL       equ 0                   ; RO_WIN_ZOOM, WE_ZOOM: where it was put
WZ_ZOOMED       equ 1                   ; the screen between the bar and the dock
WZ_SCREEN       equ 2                   ; the whole screen, over all else, with
                                        ; the keys: no title bar, bar or dock
                                        ; (another window taking the keys, or
                                        ; ctrl+meta+F, ends it)
WIN_MAX         equ 4096                ; a side, at most

; the desktop's themes (theme.asm), and the names of their colors
TH_DARK         equ 0
TH_LIGHT        equ 1

; the theme's colors, dwords (0xRRGGBB, or an alpha 0..256)
TC_WINDOW       equ 0                   ; a window's own background, a terminal's
TC_TITLE        equ 4                   ; the title bar of the window with the keys
TC_TITLE_OFF    equ 8                   ; of the others
TC_SEP          equ 12                  ; the line under a title bar
TC_EDGE         equ 16                  ; a window's outline
TC_EDGE_A       equ 20
TC_TEXT         equ 24                  ; text: the first, second and third
TC_TEXT2        equ 28                  ; kinds (labels, notes, what is off)
TC_TEXT3        equ 32
TC_BAR          equ 36                  ; the menu bar's tint, over the blur
TC_BAR_A        equ 40
TC_DOCK         equ 44                  ; the dock's
TC_DOCK_A       equ 48
TC_DOCK_EDGE    equ 52
TC_DOCK_EDGE_A  equ 56
TC_SHADOW_A     equ 60                  ; the shadow of the window with the keys
TC_SHADOW2_A    equ 64                  ; of the others
TC_LIGHT_OFF    equ 68                  ; a window's buttons, without the keys
TC_TIP          equ 72                  ; a tooltip, a menu
TC_TIP_A        equ 76
TC_TIP_TEXT     equ 80
TC_PANEL        equ 84                  ; an area raised in a window (a card)
TC_LINE         equ 88                  ; lines inside a window
TC_T_DIM        equ 92                  ; a terminal's notes
TC_T_FAINT      equ 96
TC_T_GOOD       equ 100
TC_T_WARN       equ 104
TC_T_BAD        equ 108
TC_T_BLUE       equ 112
TC_T_PCORE      equ 116
TC_T_ECORE      equ 120
TC_T_WHITE      equ 124                 ; what xterm's white and bright white,
TC_T_BRIGHT     equ 128                 ; yellows, are here
TC_T_YELLOW     equ 132
TC_T_YELLOW2    equ 136
TC_HOVER        equ 140                 ; under the pointer: a tint
TC_HOVER_A      equ 144
TC_COUNT        equ 148

; the look: how the desktop looks, in memory it shares with programs, read
; only (RO_DESK_LOOK): the theme, the scale, the screen's size, and the
; fonts the desktop draws in
LK_SERIAL       equ 0                   ; dword: one more each time it changes
                                        ; (and windows are sent WE_LOOK)
LK_S4           equ 4                   ; dword: quarters of a pixel a point
LK_MODE         equ 8                   ; dword: TH_*
LK_ACCENT       equ 12                  ; dword: 0xRRGGBB
LK_SCR_W        equ 16                  ; dwords: the screen, pixels
LK_SCR_H        equ 20
LK_UF           equ 24                  ; dword: where the desktop's font is,
                                        ; from the look's start (UFB_*)
LK_MONO         equ 28                  ; dword: and the monospaced one (MFB_*)
LK_C            equ 64                  ; the theme's colors (TC_*)
LK_HEAD         equ 256
; the desktop's font (Noto Sans): UFB_WEIGHTS weights (0 regular, 1
; semibold) by UFB_SIZES sizes
UFB_WEIGHTS     equ 0                   ; dword
UFB_SIZES       equ 4                   ; dword
UFB_UNIS        equ 8                   ; dword: entries in the code point table
UFB_UNI         equ 12                  ; dword: where it is, from the font's
                                        ; start: dword code point, dword glyph,
                                        ; by code point
UFB_DATA        equ 16                  ; dword: where its glyph tables and
                                        ; coverage are; LKF_GLYPHS and LG_DATA
                                        ; count from there
UFB_PX          equ 20                  ; 12 bytes: each size's, in pixels
UFB_FONTS       equ 32                  ; a font's table (LKF_*) for each, by
                                        ; weight, then size
LKF_GLYPHS      equ 0                   ; qword: its glyphs (LG_*), by number
LKF_ASCENT      equ 8                   ; dwords, pixels: above the baseline,
LKF_DESCENT     equ 12                  ; below it,
LKF_LINE        equ 16                  ; a line,
LKF_CAP         equ 20                  ; a capital letter's height
LKF_SIZE        equ 24
LG_DATA         equ 0                   ; dword: its coverage, a byte a pixel
LG_ADV          equ 4                   ; word: its advance, 1/64 pixels
LG_W            equ 6                   ; bytes: its bitmap's size
LG_H            equ 7
LG_LEFT         equ 8                   ; signed bytes: from the pen to its
LG_TOP          equ 9                   ; left; from the baseline up to its top
LG_SIZE         equ 12
; the monospaced font (Cascadia Mono), MFB_SIZES sizes of cell
MFB_SIZES       equ 0                   ; dword
MFB_UNIS        equ 4                   ; dword: entries in the code point table
MFB_UNI         equ 8                   ; dword: where it is: dword code point,
                                        ; dword glyph code, by code point
MFB_DATA        equ 12                  ; dword: where the coverage begins
MFB_FONTS       equ 16                  ; for each size: qword where its glyphs
                                        ; are, from MFB_DATA; dwords: a cell's
                                        ; width and height. A glyph code: 32 to
                                        ; 126 the glyph code - 32, 128 and up
                                        ; code - 128 + 95; w * h bytes each

; UEFI memory types
MT_RESERVED     equ 0
MT_LOADER_CODE  equ 1
MT_LOADER_DATA  equ 2
MT_BS_CODE      equ 3
MT_BS_DATA      equ 4
MT_RT_CODE      equ 5
MT_RT_DATA      equ 6
MT_CONVENTIONAL equ 7
MT_ACPI_RECLAIM equ 9
MT_ACPI_NVS     equ 10
MT_MMIO         equ 11

; palette (0xRRGGBB; the framebuffer stores B,G,R,x)
COL_BG          equ 0x0A0D13
COL_PANEL       equ 0x10151F
COL_PANEL2      equ 0x161C29
COL_LINE        equ 0x232B3B
COL_TEXT        equ 0xE6EDF3
COL_DIM         equ 0x7D8796
COL_FAINT       equ 0x4A5262
COL_ACCENT      equ 0x5EEAD4
COL_BLUE        equ 0x7AA2F7
COL_PCORE       equ 0xF5A524
COL_ECORE       equ 0x38BDF8
COL_GOOD        equ 0x3FB950
COL_WARN        equ 0xE3B341
COL_BAD         equ 0xF85149
COL_PANIC_BG    equ 0x2A0A10
