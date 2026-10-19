; axiom.inc: Axiom's constants for MASM programs, made by tools/masm.py from
; the kernel's own (do not edit; see docs/ABI.md)

; from src/kernel/defs.inc
OT_TASK         EQU 1
OT_THREAD       EQU 2
OT_EVENT        EQU 3
OT_MEMORY       EQU 4
OT_RING         EQU 5
OT_CONSOLE      EQU 6  ; the screen and the serial log (user.asm)
OT_CHANNEL      EQU 7  ; one end of a channel (channel.asm)
OT_STORE        EQU 8  ; names in the store, under a prefix (store.asm)
OT_NET          EQU 9  ; the network, to some hosts and ports (socket.asm)
OT_SOCKET       EQU 10  ; a connection, or a port listened on (socket.asm)
OT_DESK         EQU 11  ; the desktop: windows can be opened on it (window.asm)
OT_WINDOW       EQU 12  ; a program's window (window.asm)
OT_FILES        EQU 14  ; files on FAT volumes, or in a folder (fscap.asm)
OT_SOUND        EQU 15  ; the speakers: streams can be opened on them (sound.asm)
OT_STREAM       EQU 16  ; a stream of sound, playing (sound.asm)
OT_TYPES        EQU 17  ; with 0, none
RT_DUP          EQU 1 SHL 0  ; derive more from it
RT_GIVE         EQU 1 SHL 1  ; hand it to another task
RT_INFO         EQU 1 SHL 2  ; see what the object is
RT_TASK_HANDLES EQU 1 SHL 8  ; a task: give it handles
RT_TASK_SPAWN   EQU 1 SHL 9  ; start threads in it
RT_TASK_KILL    EQU 1 SHL 10  ; kill it (and the tasks it started)
RT_THREAD_WAIT  EQU 1 SHL 8  ; a thread: wait for it to end
RT_EV_SIGNAL    EQU 1 SHL 8  ; an event: signal or reset it
RT_EV_WAIT      EQU 1 SHL 9  ; wait for it
RT_MEM_READ     EQU 1 SHL 8  ; memory: read it
RT_MEM_WRITE    EQU 1 SHL 9  ; write it
RT_RING_ENTER   EQU 1 SHL 8  ; a ring: submit to it, wait on it
RT_CON_WRITE    EQU 1 SHL 8  ; the console: write lines to it
RT_CH_SEND      EQU 1 SHL 8  ; a channel's end: send from it
RT_CH_RECV      EQU 1 SHL 9  ; receive at it, and wait to
RT_ST_READ      EQU 1 SHL 8  ; the store: read names, list them
RT_ST_WRITE     EQU 1 SHL 9  ; stage changes, drop them
RT_ST_COMMIT    EQU 1 SHL 10  ; commit what is staged
RT_ST_ROLLBACK  EQU 1 SHL 11  ; put its names back as an earlier commit had them
RT_ST_ALL       EQU RT_ST_READ OR RT_ST_WRITE OR RT_ST_COMMIT OR RT_ST_ROLLBACK
RT_NET_CONNECT  EQU 1 SHL 8  ; the network: connect over plain TCP
RT_NET_TLS      EQU 1 SHL 9  ; over TLS, the server's certificate checked
RT_NET_INSECURE EQU 1 SHL 10  ; over TLS, not checked
RT_NET_LISTEN   EQU 1 SHL 11  ; listen on a port
RT_NET_ALL      EQU RT_NET_CONNECT OR RT_NET_TLS OR RT_NET_INSECURE OR RT_NET_LISTEN
RT_SK_SEND      EQU 1 SHL 8  ; a socket: send on it, shut it
RT_SK_RECV      EQU 1 SHL 9  ; receive from it, accept at it, wait to
RT_DESK_WINDOW  EQU 1 SHL 8  ; the desktop: open windows on it
RT_WIN_DRAW     EQU 1 SHL 8  ; a window: show what was drawn, title it
RT_FS_READ      EQU 1 SHL 8  ; files: list folders, read files
RT_FS_WRITE     EQU 1 SHL 9  ; write, make, rename, remove
RT_FS_KERNEL    EQU 1 SHL 10  ; every volume: a new kernel (RO_FS_UPDATE)
RT_SOUND_PLAY   EQU 1 SHL 8  ; the speakers: open streams on them
RT_STREAM_PLAY  EQU 1 SHL 8  ; a stream: play it, wait on it
RT_ALL          EQU 0FFFFh
E_BADH          EQU - 1  ; no such handle
E_TYPE          EQU - 2  ; the wrong type of object
E_RIGHTS        EQU - 3  ; not allowed by the capability
E_EXPIRED       EQU - 4
E_REVOKED       EQU - 5
E_RANGE         EQU - 6  ; outside a memory window
E_NOMEM         EQU - 7
E_FULL          EQU - 8  ; the handle table is full
E_TIMEOUT       EQU - 9
E_ARG           EQU - 10
E_CANCELED      EQU - 11
E_KILLED        EQU - 12  ; a thread whose task was killed
E_FAULT         EQU - 13  ; one that faulted in ring 3
E_PEER          EQU - 14  ; a channel's other end is closed
E_EMPTY         EQU - 15  ; nothing to receive yet; nothing to commit
E_CONFLICT      EQU - 16  ; the store: the head changed a name since it was staged
E_NONAME        EQU - 17  ; no such name in the store
E_IO            EQU - 18  ; the drive failed
E_NOSTORE       EQU - 19  ; no store, or one that cannot be written
E_NET           EQU - 20  ; a socket failed: RO_NET_STATUS says why
E_NOFILE        EQU - 21  ; no such file, folder or volume
E_READONLY      EQU - 22  ; the volume is not to be written ('vol <n> rw')
E_EXISTS        EQU - 23  ; something has that name already
E_COUNT         EQU 24  ; with 0, none
E_ANY           EQU - 4096  ; what returns a pointer or an E_*: an
RA_SQ_TAIL      EQU 0  ; dword: entries written, by the task
RA_CQ_HEAD      EQU 4  ; dword: completions read, by the task
RA_SQ_HEAD      EQU 64  ; dword: entries taken, by the kernel
RA_CQ_TAIL      EQU 68  ; dword: completions written, by the kernel
RA_SQ_ENTRIES   EQU 128  ; dword
RA_CQ_ENTRIES   EQU 132  ; dword
RA_SQ_OFF       EQU 136  ; dword: where the entries are
RA_CQ_OFF       EQU 140  ; dword: where the completions are
RA_TSC_PER_US   EQU 144  ; for deadlines
RA_HDR          EQU 256
SQ_OP           EQU 0  ; byte RO_*
SQ_FLAGS        EQU 1  ; byte SQF_*
SQ_HANDLE       EQU 4  ; dword
SQ_DATA         EQU 8  ; the task's own, back in its completion
SQ_A0           EQU 16
SQ_A1           EQU 24
SQ_A2           EQU 32
SQ_HANDLE2      EQU 40  ; dword
SQ_DEADLINE     EQU 48  ; TSC, 0 = none
SQ_SIZE         EQU 64
SQF_LINK        EQU 1  ; the next starts once this one succeeds
CQ_DATA         EQU 0
CQ_RESULT       EQU 8  ; what it returned, or E_*
CQ_VALUE        EQU 16  ; RO_JOIN: what the thread returned
CQ_OP           EQU 24  ; dword RO_*
CQ_SIZE         EQU 32
RO_NOP          EQU 0
RO_SIGNAL       EQU 1  ; handle: an event
RO_RESET        EQU 2  ; handle
RO_WAIT         EQU 3  ; handle, deadline: once it is signalled
RO_JOIN         EQU 4  ; handle, deadline: once a thread ended
RO_TIMEOUT      EQU 5  ; deadline: once it comes
RO_COPY         EQU 6  ; handle + a0 -> handle2 + a1, a2 bytes
RO_DUP          EQU 7  ; handle, a0 = rights, a1 = expiry
RO_CLOSE        EQU 8  ; handle
RO_GIVE         EQU 9  ; handle, handle2 = a task
RO_REVOKE       EQU 10  ; handle
RO_CANCEL       EQU 11  ; a0: the data of requests to cancel
RO_WRITE        EQU 12  ; handle = the console, handle2 + a0: a1
RO_SEND         EQU 13  ; handle = a channel, handle2 + a0: a1
RO_RECV         EQU 14  ; handle, the next message into handle2 +
RO_KILL         EQU 15  ; handle = a task
RO_ST_PUT       EQU 16  ; handle = a store, handle2 + a0: a name
RO_ST_GET       EQU 17  ; handle, handle2 + a0: a name; into
RO_ST_DEL       EQU 18  ; handle, handle2 + a0: a name -> 0, staged
RO_ST_COMMIT    EQU 19  ; handle, handle2 + a0: why, a1 bytes ->
RO_ST_ABORT     EQU 20  ; handle -> the changes dropped
RO_ST_SUB       EQU 21  ; handle, handle2 + a0: a name, a1 =
RO_ST_ROLLBACK  EQU 22  ; handle, a0 = a commit's number -> a new
RO_ST_LIST      EQU 23  ; handle, into handle2 + a0, a1 bytes at
RO_NET_CONNECT  EQU 24  ; handle = the network, handle2 + a0: a
RO_NET_LISTEN   EQU 25  ; handle, a0 = port (0: one of ours, any
RO_NET_ACCEPT   EQU 26  ; handle = a socket listening -> a socket,
RO_NET_STATUS   EQU 27  ; handle = a socket -> SKS_* | NETW_* << 8
RO_NET_SHUT     EQU 28  ; handle = a socket: a FIN once what was
RO_NET_SUB      EQU 29  ; handle = the network, handle2 + a0: a
RO_WIN_SHOW     EQU 30  ; handle = a window, a0 = x, a1 = y, a2 =
RO_WIN_TITLE    EQU 31  ; handle, handle2 + a0: a1 bytes of UTF-8, its title
RO_DESK_LOOK    EQU 34  ; handle = the desktop -> a handle to the
RO_FS_VOLUMES   EQU 35  ; handle, into handle2 + a0, a1 bytes at
RO_FS_LIST      EQU 36  ; handle, handle2 + a0: a folder; into
RO_FS_READ      EQU 37  ; handle, handle2 + a0: a file; into
RO_FS_WRITE     EQU 38  ; handle, handle2 + a0: a file; handle2 +
RO_FS_MKDIR     EQU 39  ; handle, handle2 + a0: a folder -> 0, made
RO_FS_REMOVE    EQU 40  ; handle, handle2 + a0: a file or an empty
RO_FS_RENAME    EQU 41  ; handle, handle2 + a0: a file or a folder,
RO_FS_SUB       EQU 42  ; handle, handle2 + a0: a folder, a1 =
RO_WIN_POINTER  EQU 43  ; handle = a window, a0 = PTRM_*: the
RO_NET_ADDR     EQU 44  ; handle = a socket, into handle2 + a0:
RO_FS_UPDATE    EQU 45  ; handle = files, to every volume, with
RO_COUNT        EQU 46
UPD_STATE       EQU 0  ; -> UPS_*
UPD_TRY         EQU 1  ; handle2 + a0: a kernel.bin's path, a2 =
UPD_KEEP        EQU 2  ; on trial -> 0: kept, for every start
UPD_RESTART     EQU 3  ; a2 = seconds, 1 to 60 -> 0: with a trial
UPS_SLOT        EQU 0FFh  ; the kernel running: 'A', 'B'; 0 built in
UPS_TRIAL       EQU 1 SHL 8  ; it is on trial, not kept yet
UPS_KEPT_SHIFT  EQU 16  ; << the one kept: 'A', 'B'; 0 none
UPS_NEXT_SHIFT  EQU 24  ; << the one the next start tries, or 0
FS_PATH         EQU 256  ; a path's field
FV_INDEX        EQU 0  ; a volume (RO_FS_VOLUMES): dword, its n in "vol<n>:"
FV_FLAGS        EQU 4  ; dword FVF_*
FV_BYTES        EQU 8  ; its size
FV_LABEL        EQU 16  ; its name, NUL-ended
FV_FREE         EQU 64  ; bytes free on it
FV_SIZE         EQU 72
FVF_WRITABLE    EQU 1  ; 'vol <n> rw' was said
FVF_REMOVABLE   EQU 2  ; a stick, a card
FVF_BOOT        EQU 4  ; the stick Axiom started from
FE_LEN          EQU 0  ; a thing in a folder (RO_FS_LIST): dword, the record's bytes
FE_ATTR         EQU 4  ; dword FEA_*
FE_SIZE         EQU 8  ; bytes, 0 for a folder
FE_YEAR         EQU 16  ; word: when it was last written (0: never said)
FE_MONTH        EQU 18  ; byte, 1..12
FE_DAY          EQU 19
FE_HOUR         EQU 20
FE_MIN          EQU 21
FE_SEC          EQU 22
FE_NAME         EQU 24  ; UTF-8, NUL-ended; the record is 8-aligned
FEA_DIR         EQU 1
FEA_RO          EQU 2
FEA_HIDDEN      EQU 4
FEA_SYSTEM      EQU 8
NETF_TLS        EQU 1
NETF_INSECURE   EQU 2  ; with NETF_TLS: the certificate not checked
NETF_LOOKUP     EQU 4  ; alone: the host only looked up; the socket
NI_KEY          EQU 0  ; the private key, 32 bytes, big-endian
NI_LEN          EQU 32  ; dword: bytes at NI_CERTS
NI_CERTS        EQU 40  ; the certificates, the leaf first, each a
NI_MAX          EQU 16000  ; bytes at NI_CERTS, at most
NA_PEER         EQU 0  ; the other side's (the host's, looked up)
NA_LOCAL        EQU 16  ; ours (:: until it connects; a listener's)
NA_PEER_PORT    EQU 32  ; dword
NA_PORT         EQU 36  ; dword: ours (a listener's, once it listens)
NA_SIZE         EQU 40
NS_RECV         EQU 1 SHL 24  ; something to receive, or never more
NS_SEND         EQU 1 SHL 25  ; room to send, or never again; a
SKS_LOOKUP      EQU 1  ; its host is being looked up
SKS_CONNECT     EQU 2
SKS_HANDSHAKE   EQU 3  ; TLS's
SKS_OPEN        EQU 4
SKS_ENDED       EQU 5  ; the connection is over, cleanly
SKS_FAILED      EQU 6  ; NETW_* says why
SKS_LISTEN      EQU 7
NETW_NOSERVER   EQU 1  ; no DNS server is known
NETW_BADNAME    EQU 2  ; not a host name
NETW_BUSY       EQU 3  ; too many lookups at once
NETW_NOHOST     EQU 4  ; no such host
NETW_NOADDR     EQU 5  ; it has no IPv4 address
NETW_DNS        EQU 6  ; the DNS server could not answer
NETW_NOANSWER   EQU 7  ; no answer from the DNS server
NETW_DOWN       EQU 8  ; no network, or no address on it
NETW_NOROUTE    EQU 9  ; no connection free, or no route
NETW_REFUSED    EQU 10
NETW_RESET      EQU 11
NETW_TIMEOUT    EQU 12
NETW_TLS        EQU 13  ; TLS's error says why
NETW_INUSE      EQU 14  ; the port is listened on already
NETW_IDENTITY   EQU 15  ; a TLS listener's: the certificates will
USER_START      EQU 0200000h  ; the start block, read-only
USER_IMAGE      EQU 0400000h  ; the program, its header first
USER_IMAGE_MAX  EQU 16 SHL 20
USER_MAPS       EQU 0100000000000h  ; blocks of memory it maps, a guard page after each
USER_STACK_TOP  EQU 07FF000000000h  ; its first thread's stack is below
USER_STACK_SIZE EQU 010000h
USER_TOP        EQU 0800000000000h  ; the end of the lower half
AXE_MAGIC       EQU 0  ; 'AXIOMEX2'
AXE_ENTRY       EQU 8
AXE_TEXT_END    EQU 16  ; code from USER_IMAGE to here
AXE_RODATA_END  EQU 24  ; constants from there to here
AXE_DATA_END    EQU 32  ; data from there to here: the end of the file
AXE_BSS_END     EQU 40  ; and zeroes from there to here
AXE_WANTS       EQU 48  ; what it needs to be given (AW_*), and no more
AXE_HDR         EQU 56
AW_NET          EQU 1  ; the network (SB_NET)
AW_STORE        EQU 2  ; its own names in the store (SB_STORE)
AW_DESK         EQU 4  ; the desktop, to open windows on (SB_DESK)
AW_FILES        EQU 16  ; the files on every volume (SB_FILES)
AW_SOUND        EQU 32  ; the speakers (SB_SOUND)
AW_UPDATE       EQU 64  ; with AW_FILES: a new kernel (RT_FS_KERNEL)
AW_ALL          EQU 7 OR AW_FILES OR AW_SOUND OR AW_UPDATE
SB_RING         EQU 0  ; dword: a handle to the task's ring
SB_RING_MEM     EQU 4  ; dword: to the ring's memory
SB_CONSOLE      EQU 8  ; dword: to the console
SB_GIFT         EQU 12  ; dword: what the task that started it gave, or 0
SB_RING_VA      EQU 16  ; where the ring's memory is mapped
SB_TSC_PER_US   EQU 24  ; for deadlines
SB_ARGS_LEN     EQU 32  ; dword
SB_STORE        EQU 36  ; dword: to the store under "name/", or 0
SB_NET          EQU 40  ; dword: to the network, or 0
SB_DESK         EQU 44  ; dword: to the desktop, or 0
SB_FILES        EQU 52  ; dword: to the files, or 0
SB_GIFT2        EQU 56  ; dword: a second thing it was given, or 0
SB_SOUND        EQU 60  ; dword: to the speakers, or 0
SB_ARGS         EQU 64  ; the arguments it was run with, NUL-ended
SB_ARGS_MAX     EQU 4096 - SB_ARGS - 1
SYS_EXIT        EQU 0  ; (code, EXIT_TASK or 0): this thread ends;
SYS_RING_ENTER  EQU 1  ; (ring, take, wait for, TSC deadline) -> taken
SYS_RING_NEW    EQU 2  ; (entries) -> RAX = a ring, RDX = its memory
SYS_MEM_NEW     EQU 3  ; (bytes) -> zeroed memory
SYS_MAP         EQU 4  ; (memory) -> where it is mapped now
SYS_EVENT_NEW   EQU 5  ; -> an event
SYS_THREAD_NEW  EQU 6  ; (entry, RSP, RDI) -> a thread, started
SYS_YIELD       EQU 7
SYS_UNMAP       EQU 8  ; (memory): its mapping goes
SYS_SPAWN       EQU 9  ; (memory, offset, bytes of "program args"
SYS_CHANNEL_NEW EQU 10  ; -> RAX, RDX = the two ends of a channel
SYS_WINDOW_NEW  EQU 11  ; (desktop, width, height, a channel's end,
SYS_SOUND_NEW   EQU 12  ; (the speakers, frames) -> RAX = a stream
SYS_TLS         EQU 13  ; (FS base): this thread's, for its
SYS_FUTEX_WAIT  EQU 14  ; (address, value, TSC deadline or 0): waits
SYS_FUTEX_WAKE  EQU 15  ; (address, at most) -> threads woken there
SYS_INFO        EQU 16  ; (SI_*) -> RAX
SYS_COUNT       EQU 17
EXIT_TASK       EQU 1  ; SYS_EXIT: the whole task ends
SI_CLOCK        EQU 0  ; microseconds since 1970, by the RTC (as UTC)
SI_CPUS         EQU 1  ; CPUs running
SI_RAM          EQU 2  ; bytes of memory Axiom has
SI_RAM_FREE     EQU 3  ; of those, bytes free
SI_UPTIME       EQU 4  ; milliseconds since power-on
SI_BATTERY      EQU 5  ; the battery as last read (each minute), or E_EMPTY
SI_BAT_PERCENT  EQU 0FFh  ; SI_BATTERY: its charge, in percent
SI_BAT_PLUGGED  EQU 1 SHL 8  ; on its charger
SI_BAT_HELD     EQU 1 SHL 9  ; kept between 75% and 80% ('battery hold')
SI_BAT_MODE_SHIFT EQU 16  ; bits 19:16: 0 charging as the firmware likes, 2 run from the battery, 5 not charging
SN_WRITE        EQU 0  ; dword: frames written, in all (the program's)
SN_READ         EQU 4  ; dword: frames taken to play, in all
SN_FRAMES       EQU 8  ; dword: the ring's, a power of two
SN_RATE         EQU 12  ; dword: 48000
SN_CHANNELS     EQU 16  ; dword: 2
SN_LOW          EQU 20  ; dword: half SN_FRAMES to begin with (the program's)
SN_GAIN         EQU 24  ; dword: its volume, 65536 as written, at most (the program's)
SN_SHORT        EQU 28  ; dword: frames it had none for, once begun
SN_DATA         EQU 64
WE_KIND         EQU 0  ; dword: WE_KEY ...
WE_CODE         EQU 4  ; dword: the key (WE_X: WM_*); the button (1 left, 2
WE_X            EQU 8  ; dword, signed: the pointer, in the window
WE_Y            EQU 12
WE_SIZE         EQU 16
WE_KEY          EQU 1  ; a key, while it has the keys
WE_PRESS        EQU 2  ; a button pressed in it
WE_RELEASE      EQU 3  ; and let go (anywhere)
WE_MOVE         EQU 4  ; the pointer moved, a button held (or
WE_WHEEL        EQU 5
WE_CLOSE        EQU 6  ; its close button: it is asked to go
WE_RESIZED      EQU 7  ; its size now: WE_X wide, WE_Y high (draw
WE_LOOK         EQU 8  ; the look changed (LK_SERIAL): draw again
WE_FOCUS        EQU 9  ; WE_CODE = 1: it has the keys now; 0: not
WE_KEYDOWN      EQU 10  ; WNF_KEYS: a key went down, once (held, it
WE_KEYUP        EQU 11  ; and came up (or one went down before it
WE_LEAVE        EQU 12  ; WNF_HOVER: the pointer left it
WM_SHIFT        EQU 1  ; WE_KEY's WE_X: the modifiers held
WM_CTRL         EQU 2
WM_ALT          EQU 4
WM_META         EQU 8
WNF_RESIZE      EQU 1  ; SYS_WINDOW_NEW: the user may resize it
WNF_FULL        EQU 2  ; as WNF_RESIZE, and zoomed to begin with:
WNF_KEYS        EQU 4  ; WE_KEYDOWN and WE_KEYUP too (games)
WNF_HOVER       EQU 8  ; WE_MOVE without a button, and WE_LEAVE
PTRM_ARROW      EQU 0  ; RO_WIN_POINTER: the arrow, as anywhere
PTRM_HIDDEN     EQU 1  ; none over it (it draws its own)
PTRM_GRAB       EQU 2  ; none, and held in its middle while it
WIN_MAX         EQU 4096  ; a side, at most
TC_WINDOW       EQU 0  ; a window's own background, a terminal's
TC_TITLE        EQU 4  ; the title bar of the window with the keys
TC_TITLE_OFF    EQU 8  ; of the others
TC_SEP          EQU 12  ; the line under a title bar
TC_EDGE         EQU 16  ; a window's outline
TC_EDGE_A       EQU 20
TC_TEXT         EQU 24  ; text: the first, second and third
TC_TEXT2        EQU 28  ; kinds (labels, notes, what is off)
TC_TEXT3        EQU 32
TC_BAR          EQU 36  ; the menu bar's tint, over the blur
TC_BAR_A        EQU 40
TC_DOCK         EQU 44  ; the dock's
TC_DOCK_A       EQU 48
TC_DOCK_EDGE    EQU 52
TC_DOCK_EDGE_A  EQU 56
TC_SHADOW_A     EQU 60  ; the shadow of the window with the keys
TC_SHADOW2_A    EQU 64  ; of the others
TC_LIGHT_OFF    EQU 68  ; a window's buttons, without the keys
TC_TIP          EQU 72  ; a tooltip, a menu
TC_TIP_A        EQU 76
TC_TIP_TEXT     EQU 80
TC_PANEL        EQU 84  ; an area raised in a window (a card)
TC_LINE         EQU 88  ; lines inside a window
TC_T_DIM        EQU 92  ; a terminal's notes
TC_T_FAINT      EQU 96
TC_T_GOOD       EQU 100
TC_T_WARN       EQU 104
TC_T_BAD        EQU 108
TC_T_BLUE       EQU 112
TC_T_PCORE      EQU 116
TC_T_ECORE      EQU 120
TC_T_WHITE      EQU 124  ; what xterm's white and bright white,
TC_T_BRIGHT     EQU 128  ; yellows, are here
TC_T_YELLOW     EQU 132
TC_T_YELLOW2    EQU 136
TC_HOVER        EQU 140  ; under the pointer: a tint
TC_HOVER_A      EQU 144
TC_COUNT        EQU 148
LK_SERIAL       EQU 0  ; dword: one more each time it changes
LK_S4           EQU 4  ; dword: quarters of a pixel a point
LK_MODE         EQU 8  ; dword: TH_*
LK_ACCENT       EQU 12  ; dword: 0xRRGGBB
LK_SCR_W        EQU 16  ; dwords: the screen, pixels
LK_SCR_H        EQU 20
LK_UF           EQU 24  ; dword: where the desktop's font is,
LK_MONO         EQU 28  ; dword: and the monospaced one (MFB_*)
LK_C            EQU 64  ; the theme's colors (TC_*)
LK_HEAD         EQU 256

; from src/kernel/kbd.asm
KEY_UP          EQU 080h  ; (lxtty.asm's lt_key_seqs, in order)
KEY_DOWN        EQU 081h
KEY_LEFT        EQU 082h
KEY_RIGHT       EQU 083h
KEY_HOME        EQU 084h
KEY_END         EQU 085h
KEY_PGUP        EQU 086h
KEY_PGDN        EQU 087h
KEY_INS         EQU 088h
KEY_DEL         EQU 089h
KEY_BTAB        EQU 08Ah  ; shift+tab
KEY_F1          EQU 090h  ; to F12, KEY_F1 + 11
KEY_RING        EQU 256  ; keys down and up waiting (key_head wraps)

; from src/kernel/kobj.asm
MEM_MAX         EQU 64 SHL 20  ; the largest block of memory

; from src/kernel/user.asm
USER_JOBS       EQU 16
USER_RUNNING    EQU 256
AS_MAX          EQU 128  ; blocks mapped at once (a heap, a window, files)
USER_FMASK      EQU ( 1 SHL 8 ) OR ( 1 SHL 9 ) OR ( 1 SHL 10 ) OR ( 1 SHL 14 ) OR ( 1 SHL 18 )  ; TF IF DF NT AC
USER_RFLAGS     EQU 0202h  ; IF, and the bit always set
USER_RING_N     EQU 64  ; entries in a program's ring
CON_WRITE_MAX   EQU 4096  ; bytes in one RO_WRITE
USER_NAME_MAX   EQU 64

; from src/kernel/fscap.asm
FS_ROOM_MAX     EQU 16 * 1024 * 1024  ; a read or a write, at most
