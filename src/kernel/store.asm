; =============================================================================
;  store.asm - the store: content-addressed objects, copy-on-write, every
;  change a transaction with its provenance, snapshots, diffs and rollback
;
;  On one NVMe drive, in 4 KiB blocks:
;    0, 1    two superblocks (SU_*); the one in use is the newer whole one
;            (its SHA-256 says so), and the next one goes in the other slot
;    2 ...   the log: objects and journal records, appended, never rewritten
;  An object is bytes named by their SHA-256: a blob (what a name holds), a
;  tree (TR_*: every name, sorted, with its blob's hash and size) or a
;  commit (CM_*: a tree, the commit before, and who made it, through what
;  capability, when and why). Bytes the store already has cost nothing: the
;  same hash is the same object.
;
;  A commit writes the blobs it adds, its tree and itself, then a journal
;  record (JR_*) saying where each of them went, flushes, then writes the
;  superblock (head, the log's end, the newest record) into the slot it is
;  not in, and flushes again. Until that last write the store is as it was:
;  a crash anywhere before leaves the old superblock, and whatever was
;  written after it lies past the log's end. Mounting reads the journal
;  back from the newest record: every object's place into the index (hash
;  to block, in memory), every commit's hash into the chain (by number);
;  then the head's tree.
;
;  Changes are staged first, in a transaction (TX_*): the console has one,
;  and each store capability's object (OT_STORE) one of its own. Each change
;  remembers what the head held under its name when it was staged; a commit
;  that finds the head changed there since is refused (E_CONFLICT), so two
;  transactions never silently undo each other. 'store diff' shows what a
;  commit would do before it does it.
;
;  Nothing is lost by a commit: every earlier state is a commit still in
;  the log. A snapshot names one (in the superblock); a rollback is a new
;  commit whose tree is an earlier one's, so it can be undone in turn. A
;  capability reaches only the names under its prefix ("stash/" for the
;  program STASH): what it stages, reads, lists and rolls back.
;
;  The store writes to QEMU's test drive alone (NVMe, serial AXIOMTEST): a
;  store found on any other drive is mounted read-only, and none is made
;  there. No space is reclaimed yet: the log only grows.
;
;  One operation at a time (st_enter, st_leave), from the console or from
;  any program's thread (ring.asm's RO_ST_*); a holder may park on the
;  drive, so a waiter yields. Hashing is SHA-NI on a kernel thread, plain
;  x86 in a system call, whose SIMD registers are its program's.
; =============================================================================

ST_BLOCK        equ 4096
ST_SHIFT        equ 12
ST_LOG          equ 2                   ; the log's first block
ST_MIN          equ 64                  ; blocks a store needs, at least
ST_OBJ_MAX      equ 1 << 20             ; bytes a name may hold
ST_NAME         equ 64                  ; a name's field: 63 bytes and a NUL
ST_NAMES        equ 1024                ; names in a tree, at most
ST_CHANGES      equ 128                 ; changes in one transaction
ST_REASON       equ 256                 ; why: 255 bytes and a NUL
ST_SNAPS        equ 32
ST_PEND         equ ST_CHANGES + 2      ; objects a commit writes: blobs, a tree, itself
ST_IX_FIRST     equ 4096                ; index slots at first
ST_CHAIN_FIRST  equ 1024                ; commits the chain holds at first
ST_JR_MAX       equ 2                   ; blocks in a journal record, at most
ST_LIST_MAX     equ 65536               ; bytes RO_ST_LIST writes, at most

; a superblock
SU_MAGIC        equ 0                   ; 'AXSTORE1'
SU_VERSION      equ 8                   ; dword: 1
SU_SHIFT        equ 12                  ; dword: log2 of the block size, 12
SU_GEN          equ 16                  ; superblocks written; its slot is gen & 1
SU_BLOCKS       equ 24                  ; the store's size, in blocks
SU_NEXT         equ 32                  ; the log's end: where the next object goes
SU_JOURNAL      equ 40                  ; the newest journal record, 0 if none
SU_SEQ          equ 48                  ; commits made: the head's number
SU_OBJECTS      equ 56                  ; objects stored
SU_HEAD         equ 64                  ; 32: the head commit's hash, zeros if none
SU_UUID         equ 96                  ; 16
SU_MADE         equ 112                 ; when it was formatted (st_time)
SU_BYTES        equ 120                 ; bytes of objects stored
SU_SNAPS        equ 128                 ; ST_SNAPS of SN_SIZE
SU_SUM          equ 4064                ; 32: SHA-256 of the bytes before it
SN_NAME         equ 0                   ; 24, NUL-padded; empty = unused
SN_SEQ          equ 24
SN_HASH         equ 32                  ; the commit
SN_SIZE         equ 64
SN_NAME_MAX     equ 23

; a journal record: one for each commit, after its objects
JR_MAGIC        equ 0                   ; 'AXJRNL01'
JR_SEQ          equ 8                   ; the commit's number
JR_PREV         equ 16                  ; the record before, 0 if none
JR_COUNT        equ 24                  ; dword: objects listed
JR_BLOCKS       equ 28                  ; dword: blocks it spans
JR_COMMIT       equ 32                  ; 32: the commit's hash
JR_SUM          equ 64                  ; 32: SHA-256 of its blocks, this field zeros
JR_ENTRIES      equ 128                 ; JE_SIZE each
JE_HASH         equ 0
JE_BLOCK        equ 32
JE_BYTES        equ 40                  ; dword
JE_KIND         equ 44                  ; dword SK_*
JE_SIZE         equ 48

SK_BLOB         equ 1
SK_TREE         equ 2
SK_COMMIT       equ 3

; a tree: every name and what it holds, sorted by name, byte by byte
TR_MAGIC        equ 0                   ; 'AXTREE01'
TR_COUNT        equ 8                   ; dword
TR_ENTRIES      equ 16
TE_NAME         equ 0                   ; ST_NAME, NUL-padded
TE_HASH         equ 64                  ; 32: its blob
TE_BYTES        equ 96
TE_SEQ          equ 104                 ; the commit that set it
TE_SIZE         equ 128                 ; the rest zeros
TR_MAX          equ TR_ENTRIES + ST_NAMES * TE_SIZE

; a commit: an object of CM_SIZE bytes
CM_MAGIC        equ 0                   ; 'AXCOMMIT'
CM_SEQ          equ 8                   ; its number: the first is 1
CM_TIME         equ 16                  ; YYYYMMDDhhmmss, the clock's local time
CM_TASK         equ 24                  ; the id of the task that made it
CM_PARENT       equ 32                  ; 32: the commit before, zeros for the first
CM_TREE         equ 64                  ; 32
CM_WHO          equ 96                  ; 24: 'console', or the task's name
CM_CAP          equ 120                 ; the id of its capability's object, 0 = the console
CM_RIGHTS       equ 128                 ; dword: what that capability allowed
CM_KIND         equ 132                 ; dword CK_*
CM_ADDED        equ 136                 ; dword: names added
CM_CHANGED      equ 140                 ; dword: names holding something else
CM_REMOVED      equ 144                 ; dword
CM_NAMES        equ 148                 ; dword: names in its tree
CM_TARGET       equ 152                 ; CK_ROLLBACK: the commit it went back to
CM_PREFIX       equ 160                 ; ST_NAME: what its capability reached
CM_REASON       equ 224                 ; ST_REASON: why
CM_SIZE         equ 512
CK_COMMIT       equ 0
CK_ROLLBACK     equ 1

; an index slot: an object's place (in memory)
IX_HASH         equ 0
IX_BLOCK        equ 32                  ; 0 = a free slot
IX_BYTES        equ 40                  ; dword
IX_KIND         equ 44                  ; dword
IX_SIZE         equ 48                  ; as JE_SIZE: an entry is copied in as it is

; a transaction: changes staged (in memory)
TX_COUNT        equ 0                   ; dword
TX_CHANGES      equ 16
SX_NAME         equ 0                   ; ST_NAME: the whole name
SX_HASH         equ 64                  ; XO_PUT: what it will hold
SX_SEEN         equ 96                  ; what the head held when it was first staged
SX_BYTES        equ 128
SX_DATA         equ 136                 ; XO_PUT: the bytes (kmalloc), 0 if none
SX_OP           equ 144                 ; dword XO_*
SX_HAD          equ 148                 ; dword: 1 if the head had the name then
SX_SIZE         equ 160
TX_SIZE         equ TX_CHANGES + ST_CHANGES * SX_SIZE
XO_PUT          equ 1
XO_DEL          equ 2

; a store capability's object (OT_STORE)
SO_PREFIX       equ OB_SIZE             ; ST_NAME: the names it reaches begin so
SO_TX           equ OB_SIZE + ST_NAME   ; its transaction, 0 until it stages one
SO_SIZE         equ SO_TX + 16

section .text

; -----------------------------------------------------------------------------
;  The lock
; -----------------------------------------------------------------------------

; st_enter / st_leave: the store, one operation at a time. Preserve all
; (st_leave flags too).
st_enter:
    push rax
.try:
    lock bts dword [st_lock], 0
    jnc .got
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    push r11
    call thread_yield
    pop r11
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    jmp .try
.got:
    pop rax
    ret

st_leave:
    mov dword [st_lock], 0
    ret

; -----------------------------------------------------------------------------
;  Blocks
; -----------------------------------------------------------------------------

; st_read / st_write(RSI = a block of the store, EDX = blocks, RDI = buffer)
; -> CF on failure. Writes only where st_writable says. Preserve all but RAX.
st_read:
    push rcx
    xor ecx, ecx
    jmp st_io
st_write:
    push rcx
    mov ecx, 1
    cmp byte [st_writable], 0
    jne st_io
    stc
    pop rcx
    ret
st_io:
    push rbx
    push rdx
    push rsi
    mov rbx, [st_disk]
    test rbx, rbx
    jz .fail
    mov eax, ecx
    mov ecx, [st_dshift]
    shl rsi, cl
    shl edx, cl
    test eax, eax
    jnz .write
    call disk_read
    jmp .out
.write:
    call disk_write
    jmp .out
.fail:
    stc
.out:
    pop rsi
    pop rdx
    pop rbx
    pop rcx
    ret

; st_flush -> CF. Preserves all but RAX.
st_flush:
    push rbx
    mov rbx, [st_disk]
    call disk_flush
    pop rbx
    ret

; -----------------------------------------------------------------------------
;  Hashes and names
; -----------------------------------------------------------------------------

; st_sha(RDI = digest[32], RSI = data, RDX = bytes): SHA-256, all at once,
; its state on the stack. Preserves all but RAX.
st_sha:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r12
    push rbp
    mov rbp, rsp
    sub rsp, 32 + 128                   ; the state, then the last blocks
    and rsp, -16
    mov r12, rdi
    mov rbx, rdx
    mov rdi, rsp
    push rsi
    lea rsi, [sha_h0]
    mov ecx, 32
    rep movsb
    pop rsi
    mov rdi, rsp
    mov rdx, rbx
    shr rdx, 6
    call st_blocks                      ; whole blocks straight from the data
    shl rdx, 6
    add rsi, rdx
    lea rdi, [rsp + 32]
    push rdi
    xor eax, eax
    mov ecx, 128 / 8
    rep stosq
    pop rdi
    mov ecx, ebx
    and ecx, 63
    push rcx
    rep movsb
    pop rcx
    mov byte [rsp + 32 + rcx], 0x80
    mov edx, 1
    cmp ecx, 56
    jb .one
    mov edx, 2
.one:
    mov rax, rbx
    shl rax, 3
    bswap rax
    mov ecx, edx
    shl ecx, 6
    mov [rsp + 32 + rcx - 8], rax       ; the length in bits, big-endian, last
    mov rdi, rsp
    lea rsi, [rsp + 32]
    call st_blocks
    xor ecx, ecx
.word:
    mov eax, [rsp + rcx * 4]
    bswap eax
    mov [r12 + rcx * 4], eax
    inc ecx
    cmp ecx, 8
    jb .word
    mov rsp, rbp
    pop rbp
    pop r12
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; st_blocks(RDI = state, RSI = data, RDX = 64-byte blocks). Preserves all
; but RAX.
st_blocks:
    test rdx, rdx
    jz .out
    cmp byte [sha256_mode], 0
    jne .known
    call sha256_detect
.known:
    cmp byte [sha256_mode], 2
    jne sha256_blocks_x86
    mov rax, [gs:PC_CURRENT]
    test byte [rax + TH_FLAGS], TF_USER ; a system call: no SIMD
    jnz sha256_blocks_x86
    jmp sha256_blocks_ni
.out:
    ret

; st_hash_eq(RDI, RSI) -> ZF if the 32 bytes match. Preserves all but RAX.
st_hash_eq:
    mov rax, [rdi]
    cmp rax, [rsi]
    jne .out
    mov rax, [rdi + 8]
    cmp rax, [rsi + 8]
    jne .out
    mov rax, [rdi + 16]
    cmp rax, [rsi + 16]
    jne .out
    mov rax, [rdi + 24]
    cmp rax, [rsi + 24]
.out:
    ret

; st_hash_zero(RDI) -> ZF if all 32 bytes are zero. Preserves all but RAX.
st_hash_zero:
    mov rax, [rdi]
    or rax, [rdi + 8]
    or rax, [rdi + 16]
    or rax, [rdi + 24]
    ret

; st_hash_copy(RDI = to, RSI = from). Preserves all but RAX.
st_hash_copy:
    mov rax, [rsi]
    mov [rdi], rax
    mov rax, [rsi + 8]
    mov [rdi + 8], rax
    mov rax, [rsi + 16]
    mov [rdi + 16], rax
    mov rax, [rsi + 24]
    mov [rdi + 24], rax
    ret

; st_hex(RDI = text, 2n + 1 bytes, RSI = bytes, ECX = n): in hex. Preserves all.
st_hex:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    lea rbx, [st_digits]
.byte:
    test ecx, ecx
    jz .end
    movzx eax, byte [rsi]
    mov edx, eax
    shr eax, 4
    and edx, 15
    mov al, [rbx + rax]
    mov [rdi], al
    mov al, [rbx + rdx]
    mov [rdi + 1], al
    add rdi, 2
    inc rsi
    dec ecx
    jmp .byte
.end:
    mov byte [rdi], 0
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; st_name_cmp(RDI = a, RSI = b) -> EAX < 0, 0 or > 0 as a sorts before b,
; with it, or after it (bytes, NUL-ended). Preserves others.
st_name_cmp:
    push rcx
    push rdx
    xor ecx, ecx
.next:
    movzx eax, byte [rdi + rcx]
    movzx edx, byte [rsi + rcx]
    sub eax, edx
    jnz .out
    test edx, edx
    jz .out
    inc ecx
    jmp .next
.out:
    pop rdx
    pop rcx
    ret

; st_name_set(RDI = a field of ST_NAME bytes, RSI = a name): copied (63
; bytes at most), the rest zeros. Preserves all.
st_name_set:
    push rax
    push rcx
    push rsi
    push rdi
    mov ecx, ST_NAME - 1
.copy:
    lodsb
    test al, al
    jz .pad
    stosb
    dec ecx
    jnz .copy
.pad:
    inc ecx
    xor eax, eax
    rep stosb
    pop rdi
    pop rsi
    pop rcx
    pop rax
    ret

; st_name_ok(RSI = a name) -> CF unless it is 1 to 63 bytes from '!' to
; '~'. Preserves all but RAX.
st_name_ok:
    push rcx
    xor ecx, ecx
.next:
    movzx eax, byte [rsi + rcx]
    test eax, eax
    jz .end
    cmp eax, '!'
    jb .bad
    cmp eax, '~'
    ja .bad
    inc ecx
    cmp ecx, ST_NAME - 1
    jbe .next
    jmp .bad
.end:
    test ecx, ecx
    jz .bad
    clc
    pop rcx
    ret
.bad:
    stc
    pop rcx
    ret

; st_join(RDI = a field of ST_NAME bytes, RSI = a prefix, RDX = a name, not
; empty) -> CF unless prefix and name together are a name; the field holds
; them. Preserves all but RAX.
st_join:
    push rcx
    push rsi
    push rdi
    cmp byte [rdx], 0
    je .bad
    mov ecx, ST_NAME - 1
.prefix:
    lodsb
    test al, al
    jz .name
    stosb
    dec ecx
    jnz .prefix
    jmp .bad
.name:
    mov rsi, rdx
.copy:
    lodsb
    stosb
    test al, al
    jz .check
    dec ecx
    jnz .copy
    cmp byte [rsi], 0                   ; no room left: it must end here
    jne .bad
    mov byte [rdi], 0
.check:
    mov rsi, [rsp]
    call st_name_ok
    jmp .out
.bad:
    stc
.out:
    pop rdi
    pop rsi
    pop rcx
    ret

; st_under(RDI = a name, RSI = a prefix) -> EAX = 1 if the name begins with
; it. Preserves others.
st_under:
    push rcx
    xor ecx, ecx
.next:
    movzx eax, byte [rsi + rcx]
    test eax, eax
    jz .yes
    cmp al, [rdi + rcx]
    jne .no
    inc ecx
    jmp .next
.yes:
    mov eax, 1
    pop rcx
    ret
.no:
    xor eax, eax
    pop rcx
    ret

; st_time -> RAX = the clock as YYYYMMDDhhmmss. Preserves others.
st_time:
    call rtc_read
    mov rax, [rtc_year]
    imul rax, rax, 100
    add rax, [rtc_mon]
    imul rax, rax, 100
    add rax, [rtc_day]
    imul rax, rax, 100
    add rax, [rtc_hour]
    imul rax, rax, 100
    add rax, [rtc_min]
    imul rax, rax, 100
    add rax, [rtc_sec]
    ret

; st_allowed(RBX = a disk) -> EAX = 1 if the store may write to it: QEMU's
; NVMe drive, serial AXIOMTEST, and no other. Preserves others.
st_allowed:
    lea rax, [str_nv_kind]
    cmp [rbx + DK_KIND], rax
    jne .no
    push rsi
    push rdi
    mov rdi, [rbx + DK_CTX]
    add rdi, NV_SERIAL
    lea rsi, [str_st_serial]
    call streq
    pop rdi
    pop rsi
    ret
.no:
    xor eax, eax
    ret

; -----------------------------------------------------------------------------
;  The index: where each object is, by its hash
; -----------------------------------------------------------------------------

; ix_slot(RSI = a hash) -> RAX = its slot, or the free one it would take.
; Preserves others.
ix_slot:
    push rcx
    push rdx
    push rdi
    mov ecx, [st_ix_cap]
    dec ecx
    mov rdx, [rsi]
    and rdx, rcx
.probe:
    imul rdi, rdx, IX_SIZE
    add rdi, [st_index]
    cmp qword [rdi + IX_BLOCK], 0
    je .out
    call st_hash_eq
    je .out
    inc edx
    and edx, ecx
    jmp .probe
.out:
    mov rax, rdi
    pop rdi
    pop rdx
    pop rcx
    ret

; ix_find(RSI = a hash) -> RAX = its slot, 0 if the store has no such
; object. Preserves others.
ix_find:
    cmp dword [st_ix_cap], 0
    je .none
    call ix_slot
    cmp qword [rax + IX_BLOCK], 0
    jne .out
.none:
    xor eax, eax
.out:
    ret

; ix_add(RSI = an entry, JE_*) -> CF if out of memory. Preserves others.
ix_add:
    push rcx
    push rsi
    push rdi
    mov eax, [st_ix_used]
    inc eax
    add eax, eax
    cmp eax, [st_ix_cap]
    jbe .room
    call ix_grow
    jc .out
.room:
    call ix_slot
    cmp qword [rax + IX_BLOCK], 0
    jne .known
    mov rdi, rax
    mov ecx, IX_SIZE
    rep movsb
    inc dword [st_ix_used]
.known:
    clc
.out:
    pop rdi
    pop rsi
    pop rcx
    ret

; ix_grow -> CF if out of memory: twice the slots (ST_IX_FIRST at first),
; every entry placed again. Preserves others.
ix_grow:
    push rbx
    push rcx
    push rsi
    push rdi
    push r12
    push r13
    mov r12, [st_index]
    mov r13d, [st_ix_cap]
    lea ecx, [r13d + r13d]
    test r13d, r13d
    jnz .sized
    mov ecx, ST_IX_FIRST
.sized:
    imul rdi, rcx, IX_SIZE
    call vm_alloc
    test rax, rax
    jz .nomem
    mov [st_index], rax
    mov [st_ix_cap], ecx
    xor ebx, ebx
.move:
    cmp ebx, r13d
    jae .moved
    imul rsi, rbx, IX_SIZE
    add rsi, r12
    inc ebx
    cmp qword [rsi + IX_BLOCK], 0
    je .move
    call ix_slot
    mov rdi, rax
    mov ecx, IX_SIZE
    rep movsb
    jmp .move
.moved:
    test r12, r12
    jz .done
    mov rdi, r12
    call vm_free
.done:
    clc
    jmp .out
.nomem:
    stc
.out:
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rcx
    pop rbx
    ret

; -----------------------------------------------------------------------------
;  The chain: each commit's hash, by its number
; -----------------------------------------------------------------------------

; st_chain_at(RAX = a commit's number) -> RAX = where its hash is (number 0:
; zeros, the store before its first commit). Preserves others.
st_chain_at:
    shl rax, 5
    add rax, [st_chain]
    ret

; st_chain_set(RDX = a number, RSI = its hash) -> CF if out of memory.
; Preserves others.
st_chain_set:
    push rcx
    push rdx
    push rsi
    push rdi
    cmp rdx, [st_chain_cap]
    jb .room
    mov rcx, [st_chain_cap]
.double:
    add rcx, rcx
    cmp rdx, rcx
    jae .double
    mov rdi, rcx
    shl rdi, 5
    call vm_alloc
    test rax, rax
    jz .nomem
    push rax
    push rcx
    mov rdi, rax
    mov rsi, [st_chain]
    mov rcx, [st_chain_cap]
    shl rcx, 5
    rep movsb
    pop rcx
    mov rdi, [st_chain]
    call vm_free
    pop rax
    mov [st_chain], rax
    mov [st_chain_cap], rcx
.room:
    mov rdi, rdx
    shl rdi, 5
    add rdi, [st_chain]
    mov rsi, [rsp + 8]
    call st_hash_copy
    clc
    jmp .out
.nomem:
    stc
.out:
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    ret

; -----------------------------------------------------------------------------
;  Objects
; -----------------------------------------------------------------------------

; st_append(RSI = data, RDX = bytes) -> RAX = the block they start at, from
; st_next, which moves past them; CF if the store is full or the drive
; failed. The last block is padded with zeros. Preserves others.
st_append:
    push rcx
    push rdx
    push rsi
    push rdi
    push r12
    mov r12, [st_next]
    lea rax, [rdx + ST_BLOCK - 1]
    shr rax, ST_SHIFT
    add rax, r12
    cmp rax, [st_sb + SU_BLOCKS]
    ja .full
    mov rcx, rdx                        ; bytes
    mov rdi, rsi                        ; from
    mov rsi, r12                        ; to
    mov rdx, rcx
    shr rdx, ST_SHIFT
    jz .tail
    call st_write
    jc .out
    add rsi, rdx
    shl rdx, ST_SHIFT
    add rdi, rdx
    and ecx, ST_BLOCK - 1
.tail:
    test ecx, ecx
    jz .done
    push rsi
    push rdi
    mov rsi, rdi
    lea rdi, [st_tail]
    mov edx, ST_BLOCK
    sub edx, ecx
    rep movsb
    mov ecx, edx
    xor eax, eax
    rep stosb
    pop rdi
    pop rsi
    lea rdi, [st_tail]
    mov edx, 1
    call st_write
    jc .out
    inc rsi
.done:
    mov [st_next], rsi
    mov rax, r12
    clc
    jmp .out
.full:
    KLOG "store: full: the log has reached the drive's end"
    stc
.out:
    pop r12
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    ret

; st_pend_find(RSI = a hash) -> RAX = this commit's entry for it, or 0.
; Preserves others.
st_pend_find:
    push rcx
    push rdi
    xor ecx, ecx
.next:
    cmp ecx, [st_pend_n]
    jae .none
    imul rdi, rcx, JE_SIZE
    lea rax, [st_pend]
    add rdi, rax
    inc ecx
    call st_hash_eq
    jne .next
    mov rax, rdi
    jmp .out
.none:
    xor eax, eax
.out:
    pop rdi
    pop rcx
    ret

; st_object(RSI = data, RDX = bytes, ECX = SK_*, RDI = its hash, out) -> CF
; on failure. Appended unless the store, or this commit, has it already;
; listed for this commit's journal record. Preserves others.
st_object:
    push rbx
    push rcx
    push rsi
    push rdi
    push r12
    mov r12, rdi
    mov ebx, ecx
    call st_sha
    push rsi
    mov rsi, r12
    call ix_find
    test rax, rax
    jnz .have_pop
    call st_pend_find
    test rax, rax
    jnz .have_pop
    pop rsi
    cmp dword [st_pend_n], ST_PEND
    jae .full
    call st_append
    jc .out
    mov ecx, [st_pend_n]
    imul rdi, rcx, JE_SIZE
    lea rcx, [st_pend]
    add rdi, rcx
    mov [rdi + JE_BLOCK], rax
    mov [rdi + JE_BYTES], edx
    mov [rdi + JE_KIND], ebx
    mov rsi, r12
    call st_hash_copy
    inc dword [st_pend_n]
    clc
    jmp .out
.have_pop:
    pop rsi
    clc
    jmp .out
.full:
    stc
.out:
    pop r12
    pop rdi
    pop rsi
    pop rcx
    pop rbx
    ret

; st_load(RSI = a hash) -> RAX = the object's bytes, in memory from
; vm_alloc (zeros after them, one byte at least), RDX = how many, ECX =
; SK_*; CF if the store has no such object, or the drive's blocks are not
; it (said). Preserves others.
st_load:
    push rbx
    push rsi
    push rdi
    push rbp
    push r12
    push r13
    mov r13, rsi
    call ix_find
    test rax, rax
    jz .missing
    mov rbx, rax
    mov edi, [rbx + IX_BYTES]
    add rdi, ST_BLOCK                   ; a byte to spare, whole blocks
    and rdi, -ST_BLOCK
    mov r12, rdi
    call vm_alloc
    test rax, rax
    jz .missing
    mov rbp, rax
    mov edx, [rbx + IX_BYTES]
    add edx, ST_BLOCK - 1
    shr edx, ST_SHIFT
    jz .read
    mov rdi, rbp
    mov rsi, [rbx + IX_BLOCK]
    call st_read
    jc .bad
.read:
    lea rdi, [st_digest]
    mov rsi, rbp
    mov edx, [rbx + IX_BYTES]
    call st_sha
    mov rsi, r13
    call st_hash_eq
    jne .corrupt
    mov rax, rbp
    mov edx, [rbx + IX_BYTES]
    mov ecx, [rbx + IX_KIND]
    clc
    jmp .out
.corrupt:
    sub rsp, 24
    mov rdi, rsp
    mov rsi, r13
    mov ecx, 8
    call st_hex
    mov rax, rsp
    KLOG "store: object %s is not what block %u holds", rax, qword [rbx + IX_BLOCK]
    add rsp, 24
.bad:
    mov rdi, rbp
    call vm_free
.missing:
    stc
.out:
    pop r13
    pop r12
    pop rbp
    pop rdi
    pop rsi
    pop rbx
    ret

; st_free(RDI = what st_load or store_get gave, or 0). Preserves all.
st_free:
    test rdi, rdi
    jz .out
    push rax
    call vm_free
    pop rax
.out:
    ret

; -----------------------------------------------------------------------------
;  Trees
; -----------------------------------------------------------------------------

; tree_init(RDI = a tree): empty. Preserves all but RAX.
tree_init:
    mov rax, 'AXTREE01'
    mov [rdi + TR_MAGIC], rax
    mov qword [rdi + TR_COUNT], 0
    ret

; tree_bytes(RDI = a tree) -> RAX = its size as an object. Preserves others.
tree_bytes:
    mov eax, [rdi + TR_COUNT]
    shl rax, 7
    add rax, TR_ENTRIES
    ret

; tree_copy(RDI = to, RSI = from). Preserves all but RAX.
tree_copy:
    push rcx
    push rsi
    push rdi
    push rdi
    mov rdi, rsi
    call tree_bytes
    pop rdi
    mov rcx, rax
    rep movsb
    pop rdi
    pop rsi
    pop rcx
    ret

; tree_find(RDI = a tree, RSI = a name) -> RAX = its entry, or 0; EDX = its
; place, or the place it would take. Preserves others.
tree_find:
    push rbx
    push rcx
    push rdi
    push r8
    mov r8, rdi
    xor ebx, ebx
    mov ecx, [r8 + TR_COUNT]
.half:
    cmp ebx, ecx
    jae .none
    lea edx, [ebx + ecx]
    shr edx, 1
    imul rdi, rdx, TE_SIZE
    lea rdi, [r8 + TR_ENTRIES + rdi]
    call st_name_cmp
    test eax, eax
    jz .found
    jl .after
    mov ecx, edx
    jmp .half
.after:
    lea ebx, [edx + 1]
    jmp .half
.found:
    mov rax, rdi
    jmp .out
.none:
    xor eax, eax
    mov edx, ebx
.out:
    pop r8
    pop rdi
    pop rcx
    pop rbx
    ret

; tree_put(RDI = a tree, RSI = a name, RDX = its hash, RCX = bytes, R8 =
; the commit setting it) -> EAX = 1 added, 2 changed, 0 the same as it was;
; CF if the tree is full. Preserves others.
tree_put:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    mov rbx, rdi
    mov r12, rdx
    mov r13, rcx
    mov r14, rsi
    call tree_find
    test rax, rax
    jz .insert
    mov rcx, rax
    lea rdi, [rcx + TE_HASH]
    mov rsi, r12
    call st_hash_eq
    jne .change
    xor eax, eax
    jmp .done
.change:
    call st_hash_copy
    mov [rcx + TE_BYTES], r13
    mov [rcx + TE_SEQ], r8
    mov eax, 2
    jmp .done
.insert:
    mov ecx, [rbx + TR_COUNT]
    cmp ecx, ST_NAMES
    jae .full
    sub ecx, edx                        ; those after it move up one
    shl ecx, 7
    imul rsi, rdx, TE_SIZE
    lea rsi, [rbx + TR_ENTRIES + rsi]
.shift:
    test ecx, ecx
    jz .shifted
    sub ecx, 8
    mov rax, [rsi + rcx]
    mov [rsi + rcx + TE_SIZE], rax
    jmp .shift
.shifted:
    mov rcx, rsi
    mov rdi, rcx
    mov rsi, r14
    call st_name_set
    lea rdi, [rcx + TE_HASH]
    mov rsi, r12
    call st_hash_copy
    mov [rcx + TE_BYTES], r13
    mov [rcx + TE_SEQ], r8
    mov qword [rcx + 112], 0
    mov qword [rcx + 120], 0
    inc dword [rbx + TR_COUNT]
    mov eax, 1
.done:
    clc
    jmp .out
.full:
    stc
.out:
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; tree_del(RDI = a tree, RSI = a name) -> EAX = 1 if it was there (gone
; now), else 0. Preserves others.
tree_del:
    push rcx
    push rdx
    push rsi
    call tree_find
    test rax, rax
    jz .out
    mov ecx, [rdi + TR_COUNT]
    dec ecx
    sub ecx, edx
    shl ecx, 7
    xor edx, edx
.shift:
    cmp edx, ecx
    jae .shifted
    mov rsi, [rax + rdx + TE_SIZE]
    mov [rax + rdx], rsi
    add edx, 8
    jmp .shift
.shifted:
    dec dword [rdi + TR_COUNT]
    mov eax, 1
.out:
    pop rsi
    pop rdx
    pop rcx
    ret

; tree_diff(RDI = a, RSI = b, RDX = fn(RDI = a's entry or 0, RSI = b's or
; 0), for each name they differ in, or 0) -> EAX = names only b has, EDX =
; those in both holding different things, ECX = those only a has. fn
; preserves all but RAX. Preserves others.
tree_diff:
    push rbx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    push r11
    push r12
    push r13
    push r14
    push r15
    mov r8, rdi
    mov r9, rsi
    mov r10, rdx
    xor r11d, r11d
    xor r12d, r12d
    xor r13d, r13d
    xor r14d, r14d
    xor r15d, r15d
.step:
    cmp r11d, [r8 + TR_COUNT]
    jae .a_done
    imul rdi, r11, TE_SIZE
    lea rdi, [r8 + TR_ENTRIES + rdi]
    cmp r12d, [r9 + TR_COUNT]
    jae .only_a
    imul rsi, r12, TE_SIZE
    lea rsi, [r9 + TR_ENTRIES + rsi]
    call st_name_cmp
    test eax, eax
    jl .only_a
    jg .only_b
    inc r11d
    inc r12d
    push rdi
    push rsi
    lea rdi, [rdi + TE_HASH]
    lea rsi, [rsi + TE_HASH]
    call st_hash_eq
    pop rsi
    pop rdi
    je .step
    inc r14d
    call .tell
    jmp .step
.only_a:
    inc r11d
    inc r15d
    xor esi, esi
    call .tell
    jmp .step
.only_b:
    inc r12d
    inc r13d
    xor edi, edi
    call .tell
    jmp .step
.a_done:
    cmp r12d, [r9 + TR_COUNT]
    jae .done
    imul rsi, r12, TE_SIZE
    lea rsi, [r9 + TR_ENTRIES + rsi]
    jmp .only_b
.tell:
    test r10, r10
    jz .told
    call r10
.told:
    ret
.done:
    mov eax, r13d
    mov edx, r14d
    mov ecx, r15d
    pop r15
    pop r14
    pop r13
    pop r12
    pop r11
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rbx
    ret

; st_commit_of(RAX = a commit's number, RDI = CM_SIZE bytes) -> CF if it
; cannot be read. Preserves others.
st_commit_of:
    push rcx
    push rdx
    push rsi
    push rdi
    cmp rax, [st_sb + SU_SEQ]
    ja .bad
    test rax, rax
    jz .bad
    call st_chain_at
    mov rsi, rax
    call st_load
    jc .out
    mov rsi, rax
    cmp ecx, SK_COMMIT
    jne .wrong
    cmp rdx, CM_SIZE
    jne .wrong
    mov rcx, 'AXCOMMIT'
    cmp [rsi + CM_MAGIC], rcx
    jne .wrong
    mov ecx, CM_SIZE
    rep movsb
    mov rdi, rax
    call st_free
    clc
    jmp .out
.wrong:
    mov rdi, rax
    call st_free
    KLOG "store: a commit's object is not a commit"
.bad:
    stc
.out:
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    ret

; st_tree_of(RDI = a tree's room, TR_MAX bytes, RSI = a commit's hash, zeros
; for the store before its first) -> CF if its tree cannot be read.
; Preserves others.
st_tree_of:
    push rcx
    push rdx
    push rsi
    push rdi
    push r12
    push r13
    mov r12, rdi
    mov rdi, rsi
    call st_hash_zero
    jnz .commit
    mov rdi, r12
    call tree_init
    clc
    jmp .out
.commit:
    call st_load
    jc .out
    mov r13, rax
    cmp ecx, SK_COMMIT
    jne .wrong
    cmp rdx, CM_SIZE
    jne .wrong
    mov rax, 'AXCOMMIT'
    cmp [r13 + CM_MAGIC], rax
    jne .wrong
    lea rdi, [st_want]
    lea rsi, [r13 + CM_TREE]
    call st_hash_copy
    mov rdi, r13
    call st_free
    lea rsi, [st_want]
    call st_load
    jc .out
    mov r13, rax
    cmp ecx, SK_TREE
    jne .wrong
    mov rax, 'AXTREE01'
    cmp [r13 + TR_MAGIC], rax
    jne .wrong
    cmp dword [r13 + TR_COUNT], ST_NAMES
    ja .wrong
    mov rdi, r13
    call tree_bytes
    cmp rax, rdx
    jne .wrong
    mov rdi, r12
    mov rsi, r13
    mov rcx, rdx
    rep movsb
    mov rdi, r13
    call st_free
    clc
    jmp .out
.wrong:
    mov rdi, r13
    call st_free
    KLOG "store: an object is not the kind it should be"
    stc
.out:
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    ret

; -----------------------------------------------------------------------------
;  Superblocks
; -----------------------------------------------------------------------------

; st_sb_check(RDI = a block) -> EAX = 0 no superblock, 1 a damaged one, 2 a
; whole one. Preserves others.
st_sb_check:
    push rdx
    push rsi
    push rdi
    mov rax, 'AXSTORE1'
    cmp [rdi + SU_MAGIC], rax
    jne .none
    mov rsi, rdi
    lea rdi, [st_digest]
    mov edx, SU_SUM
    call st_sha
    lea rsi, [rsi + SU_SUM]
    call st_hash_eq
    jne .damaged
    cmp dword [rsi - SU_SUM + SU_VERSION], 1
    jne .damaged
    cmp dword [rsi - SU_SUM + SU_SHIFT], ST_SHIFT
    jne .damaged
    mov eax, 2
    jmp .out
.damaged:
    mov eax, 1
    jmp .out
.none:
    xor eax, eax
.out:
    pop rdi
    pop rsi
    pop rdx
    ret

; st_sb_put -> CF if the drive failed: st_sbuf, one generation past st_sb,
; summed, into the slot that generation gives, flushed; st_sb is it then.
; Preserves all but RAX.
st_sb_put:
    push rcx
    push rdx
    push rsi
    push rdi
    mov rax, [st_sb + SU_GEN]
    inc rax
    mov [st_sbuf + SU_GEN], rax
    call st_sb_seal
    mov rsi, [st_sbuf + SU_GEN]
    and esi, 1
    lea rdi, [st_sbuf]
    mov edx, 1
    call st_write
    jc .out
    call st_flush
    jc .out
    lea rsi, [st_sbuf]
    lea rdi, [st_sb]
    mov ecx, ST_BLOCK
    rep movsb
    clc
.out:
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    ret

; st_sb_seal: st_sbuf's sum. Preserves all but RAX.
st_sb_seal:
    push rdx
    push rsi
    push rdi
    lea rdi, [st_sbuf + SU_SUM]
    lea rsi, [st_sbuf]
    mov edx, SU_SUM
    call st_sha
    pop rdi
    pop rsi
    pop rdx
    ret

; st_jr_sum -> ZF if the record in st_jbuf (JR_BLOCKS of it) sums as it
; says. Preserves all but RAX.
st_jr_sum:
    push rdx
    push rsi
    push rdi
    sub rsp, 32
    mov rdi, rsp
    lea rsi, [st_jbuf + JR_SUM]
    call st_hash_copy
    xor eax, eax
    mov [st_jbuf + JR_SUM], rax
    mov [st_jbuf + JR_SUM + 8], rax
    mov [st_jbuf + JR_SUM + 16], rax
    mov [st_jbuf + JR_SUM + 24], rax
    lea rdi, [st_digest]
    lea rsi, [st_jbuf]
    mov edx, [st_jbuf + JR_BLOCKS]
    shl edx, ST_SHIFT
    call st_sha
    lea rdi, [st_jbuf + JR_SUM]
    mov rsi, rsp
    call st_hash_copy
    lea rdi, [st_digest]
    call st_hash_eq
    lea rsp, [rsp + 32]
    pop rdi
    pop rsi
    pop rdx
    ret

; -----------------------------------------------------------------------------
;  Mounting
; -----------------------------------------------------------------------------

; st_buffers -> CF if out of memory: the three trees' room, once.
; Preserves others.
st_buffers:
    push rdi
    cmp qword [st_old], 0
    jne .have
    mov edi, TR_MAX
    call vm_alloc
    test rax, rax
    jz .nomem
    mov [st_head], rax
    call vm_alloc
    test rax, rax
    jz .nomem
    mov [st_new], rax
    call vm_alloc
    test rax, rax
    jz .nomem
    mov [st_old], rax
.have:
    clc
    pop rdi
    ret
.nomem:
    stc
    pop rdi
    ret

; st_unmount: no store; the index and chain go. Preserves all.
st_unmount:
    push rax
    push rdi
    mov qword [st_disk], 0
    mov byte [st_writable], 0
    mov rdi, [st_index]
    call st_free
    mov qword [st_index], 0
    mov dword [st_ix_cap], 0
    mov dword [st_ix_used], 0
    mov rdi, [st_chain]
    call st_free
    mov qword [st_chain], 0
    mov qword [st_chain_cap], 0
    pop rdi
    pop rax
    ret

; st_mount(RBX = a disk) -> CF if no store is on it, or a damaged one (said).
; The newer whole superblock, then the journal back to the first commit:
; every object into the index, every commit into the chain; then the
; head's tree. Writable only on QEMU's test drive. The lock is held.
st_mount:
    push rcx
    push rdx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    call st_unmount
    mov ecx, [rbx + DK_SHIFT]
    cmp ecx, ST_SHIFT
    ja .none
    mov eax, ST_SHIFT
    sub eax, ecx
    mov [st_dshift], eax
    mov [st_disk], rbx
    mov qword [st_bad_slot], -1
    lea rdi, [st_sbuf]                  ; slot 0, kept in st_sb
    xor esi, esi
    mov edx, 1
    call st_read
    jc .none
    call st_sb_check
    mov r12d, eax
    lea rsi, [st_sbuf]
    lea rdi, [st_sb]
    mov ecx, ST_BLOCK
    rep movsb
    lea rdi, [st_sbuf]                  ; slot 1
    mov esi, 1
    mov edx, 1
    call st_read
    jc .none
    call st_sb_check
    mov r13d, eax
    mov eax, r12d
    or eax, r13d
    jz .none
    cmp r12d, 2
    je .zero_whole
    cmp r13d, 2
    jne .both_bad
    test r12d, r12d
    jz .take_one
    mov qword [st_bad_slot], 0
    jmp .take_one
.zero_whole:
    cmp r13d, 2
    je .newer
    test r13d, r13d
    jz .chosen
    mov qword [st_bad_slot], 1
    jmp .chosen
.newer:
    mov rax, [st_sbuf + SU_GEN]
    cmp rax, [st_sb + SU_GEN]
    jbe .chosen
.take_one:
    lea rsi, [st_sbuf]
    lea rdi, [st_sb]
    mov ecx, ST_BLOCK
    rep movsb
.chosen:
    cmp qword [st_bad_slot], 0
    jl .sane
    KLOG "store: disk%u: superblock %u is damaged; the other is used", qword [rbx + DK_INDEX], qword [st_bad_slot]
.sane:
    mov rax, [rbx + DK_BLOCKS]          ; what it says must make sense
    mov ecx, [st_dshift]
    shr rax, cl
    mov rcx, [st_sb + SU_BLOCKS]
    cmp rcx, rax
    ja .damaged
    mov rax, [st_sb + SU_NEXT]
    cmp rax, ST_LOG
    jb .damaged
    cmp rax, rcx
    ja .damaged
    cmp [st_sb + SU_JOURNAL], rax
    jae .damaged
    call ix_grow
    jc .nomem
    mov edi, ST_CHAIN_FIRST * 32
    call vm_alloc
    test rax, rax
    jz .nomem
    mov [st_chain], rax
    mov qword [st_chain_cap], ST_CHAIN_FIRST
    mov r12, [st_sb + SU_JOURNAL]       ; the journal, newest first
    mov r13, [st_sb + SU_SEQ]
.record:
    test r12, r12
    jz .walked
    test r13, r13
    jz .damaged
    lea rdi, [st_jbuf]
    mov rsi, r12
    mov edx, 1
    call st_read
    jc .damaged
    mov rax, 'AXJRNL01'
    cmp [st_jbuf + JR_MAGIC], rax
    jne .damaged
    cmp [st_jbuf + JR_SEQ], r13
    jne .damaged
    mov edx, [st_jbuf + JR_BLOCKS]
    test edx, edx
    jz .damaged
    cmp edx, ST_JR_MAX
    ja .damaged
    lea rax, [r12 + rdx]
    cmp rax, [st_sb + SU_NEXT]
    ja .damaged
    dec edx
    jz .whole
    lea rsi, [r12 + 1]
    lea rdi, [st_jbuf + ST_BLOCK]
    call st_read
    jc .damaged
.whole:
    mov eax, [st_jbuf + JR_COUNT]
    cmp eax, ST_PEND
    ja .damaged
    imul eax, eax, JE_SIZE
    add eax, JR_ENTRIES
    mov edx, [st_jbuf + JR_BLOCKS]
    shl edx, ST_SHIFT
    cmp eax, edx
    ja .damaged
    call st_jr_sum
    jne .damaged
    xor r14d, r14d
.entry:
    cmp r14d, [st_jbuf + JR_COUNT]
    jae .entries
    imul rsi, r14, JE_SIZE
    lea rax, [st_jbuf + JR_ENTRIES]
    add rsi, rax
    inc r14d
    mov eax, [rsi + JE_BYTES]
    add rax, ST_BLOCK - 1
    shr rax, ST_SHIFT
    add rax, [rsi + JE_BLOCK]
    cmp rax, r12                        ; before its record
    ja .damaged
    cmp qword [rsi + JE_BLOCK], ST_LOG
    jb .damaged
    call ix_add
    jc .nomem
    jmp .entry
.entries:
    mov rdx, r13
    lea rsi, [st_jbuf + JR_COMMIT]
    call st_chain_set
    jc .nomem
    mov r12, [st_jbuf + JR_PREV]
    dec r13
    jmp .record
.walked:
    test r13, r13
    jnz .damaged
    mov rdi, [st_head]
    lea rsi, [st_sb + SU_HEAD]
    call st_tree_of
    jc .damaged
    call st_allowed
    mov [st_writable], al
    call st_say
    clc
    jmp .out
.both_bad:
    KLOG "store: disk%u: both superblocks are damaged", qword [rbx + DK_INDEX]
    jmp .none
.damaged:
    KLOG "store: disk%u: the store is damaged (its journal, or what its superblock says); not mounted", qword [rbx + DK_INDEX]
    jmp .none
.nomem:
    KLOG "store: out of memory to mount it"
.none:
    call st_unmount
    stc
.out:
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    ret

; st_say: one line about the store mounted. Preserves all.
st_say:
    push rax
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    mov rax, [st_disk]
    mov rcx, [st_sb + SU_NEXT]
    shl rcx, ST_SHIFT
    mov rdx, [st_sb + SU_BLOCKS]
    shl rdx, ST_SHIFT
    mov rsi, [st_head]
    mov esi, [rsi + TR_COUNT]
    lea rdi, [str_st_rw]
    cmp byte [st_writable], 0
    jne .say
    lea rdi, [str_st_ro]
.say:
    mov r8d, [st_ix_used]
    mov r9, [st_sb + SU_SEQ]
    KLOG "store: disk%u: %u commits, %u names, %u objects; %b of %b used; %s", qword [rax + DK_INDEX], r9, rsi, r8, rcx, rdx, rdi
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rax
    ret

; store_init: the first NVMe drive holding a store is mounted
store_init:
    push rbx
    push rcx
    call st_enter
    call st_buffers
    jc .out
    xor ecx, ecx
.disk:
    cmp ecx, [disk_count]
    jae .none
    imul rbx, rcx, DK_SIZE
    lea rax, [disks]
    add rbx, rax
    inc ecx
    test dword [rbx + DK_FLAGS], DKF_GONE
    jnz .disk
    lea rax, [str_nv_kind]
    cmp [rbx + DK_KIND], rax
    jne .disk
    call st_mount
    jc .disk
    jmp .out
.none:
    KLOG "store: none on any drive ('store format' makes one on QEMU's test drive)"
.out:
    call st_leave
    pop rcx
    pop rbx
    ret

; store_format(RBX = a disk) -> CF if refused (said why): an empty store on
; it, then mounted. QEMU's test drive alone.
store_format:
    push rcx
    push rdx
    push rsi
    push rdi
    call st_enter
    call st_allowed
    test eax, eax
    jz .refused
    call st_buffers
    jc .nomem
    call st_unmount
    mov ecx, [rbx + DK_SHIFT]
    cmp ecx, ST_SHIFT
    ja .refused
    mov eax, ST_SHIFT
    sub eax, ecx
    mov [st_dshift], eax
    mov rdx, [rbx + DK_BLOCKS]
    mov ecx, eax
    shr rdx, cl
    cmp rdx, ST_MIN
    jb .small
    mov [st_disk], rbx
    mov byte [st_writable], 1
    lea rdi, [st_sbuf]
    xor eax, eax
    mov ecx, ST_BLOCK / 8
    rep stosq
    mov rax, 'AXSTORE1'
    mov [st_sbuf + SU_MAGIC], rax
    mov dword [st_sbuf + SU_VERSION], 1
    mov dword [st_sbuf + SU_SHIFT], ST_SHIFT
    mov [st_sbuf + SU_BLOCKS], rdx
    mov qword [st_sbuf + SU_NEXT], ST_LOG
    lea rdi, [st_sbuf + SU_UUID]
    mov ecx, 16
    call rand_bytes
    call st_time
    mov [st_sbuf + SU_MADE], rax
    call st_sb_seal                     ; generation 0 into slot 0
    lea rdi, [st_sbuf]
    xor esi, esi
    mov edx, 1
    call st_write
    jc .failed
    mov qword [st_sbuf + SU_GEN], 1     ; 1 into slot 1, the newer
    call st_sb_seal
    lea rdi, [st_sbuf]
    mov esi, 1
    mov edx, 1
    call st_write
    jc .failed
    call st_flush
    jc .failed
    mov rdx, [st_sbuf + SU_BLOCKS]
    mov rax, rdx
    shl rax, ST_SHIFT
    KLOG "store: disk%u formatted: %b, %u blocks of 4 KiB", qword [rbx + DK_INDEX], rax, rdx
    call st_mount
    jmp .out
.small:
    KLOG "store: disk%u is too small for a store", qword [rbx + DK_INDEX]
    stc
    jmp .out
.failed:
    KLOG "store: disk%u: writing the superblocks failed", qword [rbx + DK_INDEX]
    call st_unmount
    stc
    jmp .out
.nomem:
    KLOG "store: out of memory"
    stc
    jmp .out
.refused:
    KLOG "store format: refused: only QEMU's test drive (NVMe, serial AXIOMTEST) may hold a store"
    stc
.out:
    call st_leave
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    ret

; -----------------------------------------------------------------------------
;  Transactions
; -----------------------------------------------------------------------------

; st_txp(RDI = a store object, 0 = the console) -> RAX = where the pointer
; to its transaction is. Preserves others.
st_txp:
    lea rax, [st_console_tx]
    test rdi, rdi
    jz .out
    lea rax, [rdi + SO_TX]
.out:
    ret

; st_tx(RDI = a store object or 0) -> RAX = its transaction, made if need
; be; 0 if out of memory. Preserves others.
st_tx:
    push rdi
    call st_txp
    mov rdi, rax
    mov rax, [rdi]
    test rax, rax
    jnz .out
    push rdi
    mov edi, TX_SIZE
    call kmalloc
    pop rdi
    mov [rdi], rax
.out:
    pop rdi
    ret

; st_prefix(RDI = a store object or 0) -> RAX = what the names it reaches
; begin with. Preserves others.
st_prefix:
    lea rax, [str_st_empty]
    test rdi, rdi
    jz .out
    lea rax, [rdi + SO_PREFIX]
.out:
    ret

; st_change_find(RDI = a transaction or 0, RSI = a whole name) -> RAX =
; its change, or 0. Preserves others.
st_change_find:
    push rcx
    push rdi
    push r8
    xor eax, eax
    test rdi, rdi
    jz .out
    mov r8, rdi
    xor ecx, ecx
.next:
    cmp ecx, [r8 + TX_COUNT]
    jae .none
    imul rdi, rcx, SX_SIZE
    lea rdi, [r8 + TX_CHANGES + rdi]
    inc ecx
    call st_name_cmp
    test eax, eax
    jnz .next
    mov rax, rdi
    jmp .out
.none:
    xor eax, eax
.out:
    pop r8
    pop rdi
    pop rcx
    ret

; st_change(RDI = a transaction, RSI = a whole name) -> RAX = its change, a
; new one if it has none (which remembers what the head held under the
; name now); CF if the transaction is full. Preserves others.
st_change:
    push rcx
    push rdx
    push rdi
    push r8
    call st_change_find
    test rax, rax
    jnz .have
    mov r8, rdi
    mov ecx, [r8 + TX_COUNT]
    cmp ecx, ST_CHANGES
    jae .full
    imul rdi, rcx, SX_SIZE
    lea rdi, [r8 + TX_CHANGES + rdi]
    inc dword [r8 + TX_COUNT]
    push rdi
    mov ecx, SX_SIZE / 8
    xor eax, eax
    rep stosq
    pop rdi
    call st_name_set
    push rdi
    mov rdi, [st_head]
    call tree_find
    pop rdi
    test rax, rax
    jz .new
    mov dword [rdi + SX_HAD], 1
    push rsi
    push rdi
    lea rsi, [rax + TE_HASH]
    lea rdi, [rdi + SX_SEEN]
    call st_hash_copy
    pop rdi
    pop rsi
.new:
    mov rax, rdi
.have:
    clc
    jmp .out
.full:
    stc
.out:
    pop r8
    pop rdi
    pop rdx
    pop rcx
    ret

; st_tx_clear(RDI = a transaction or 0): no changes; their bytes freed.
; Preserves all.
st_tx_clear:
    push rax
    push rcx
    push rdi
    push r8
    test rdi, rdi
    jz .out
    mov r8, rdi
    xor ecx, ecx
.next:
    cmp ecx, [r8 + TX_COUNT]
    jae .done
    imul rax, rcx, SX_SIZE
    mov rdi, [r8 + TX_CHANGES + rax + SX_DATA]
    call kfree
    inc ecx
    jmp .next
.done:
    mov dword [r8 + TX_COUNT], 0
.out:
    pop r8
    pop rdi
    pop rcx
    pop rax
    ret

; st_check(EDX = 1 to need writes) -> RAX = 0, or E_NOSTORE. Preserves others.
st_check:
    mov rax, E_NOSTORE
    cmp qword [st_disk], 0
    je .out
    test edx, edx
    jz .ok
    cmp byte [st_writable], 0
    je .out
.ok:
    xor eax, eax
.out:
    ret

; store_put(RDI = a store object or 0, RSI = a whole name, RDX = its bytes,
; from kmalloc, which the store owns now, RCX = how many) -> RAX = 0 or E_*:
; staged. Preserves others.
store_put:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    mov r12, rsi
    mov r13, rdx
    mov r14, rcx
    call st_enter
    mov edx, 1
    call st_check
    test rax, rax
    jnz .fail
    mov rax, E_ARG
    cmp r14, ST_OBJ_MAX
    ja .fail
    call st_tx
    test rax, rax
    jz .nomem
    mov rbx, rax
    mov rdi, rbx
    mov rsi, r12
    call st_change
    jc .full
    mov rbx, rax
    mov rdi, [rbx + SX_DATA]
    call kfree
    mov [rbx + SX_DATA], r13
    mov [rbx + SX_BYTES], r14
    mov dword [rbx + SX_OP], XO_PUT
    lea rdi, [rbx + SX_HASH]
    mov rsi, r13
    mov rdx, r14
    call st_sha
    xor eax, eax
    jmp .out
.full:
    mov rax, E_FULL
    jmp .fail
.nomem:
    mov rax, E_NOMEM
.fail:
    mov rdi, r13
    call kfree
.out:
    call st_leave
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; store_del(RDI = a store object or 0, RSI = a whole name) -> RAX = 0 or
; E_*: its removal staged (E_NONAME if neither the head nor the
; transaction has it). Preserves others.
store_del:
    push rbx
    push rdx
    push rsi
    push rdi
    push r12
    push r13
    mov r12, rsi
    mov r13, rdi
    call st_enter
    mov edx, 1
    call st_check
    test rax, rax
    jnz .out
    call st_tx
    test rax, rax
    jz .nomem
    mov rbx, rax
    mov rdi, rbx
    call st_change_find
    test rax, rax
    jz .head
    cmp dword [rax + SX_OP], XO_PUT
    je .stage
    jmp .noname
.head:
    mov rdi, [st_head]
    call tree_find
    test rax, rax
    jz .noname
.stage:
    mov rdi, rbx
    call st_change
    jc .full
    mov rdi, [rax + SX_DATA]
    call kfree
    mov qword [rax + SX_DATA], 0
    mov qword [rax + SX_BYTES], 0
    mov dword [rax + SX_OP], XO_DEL
    xor eax, eax
    jmp .out
.noname:
    mov rax, E_NONAME
    jmp .out
.full:
    mov rax, E_FULL
    jmp .out
.nomem:
    mov rax, E_NOMEM
.out:
    call st_leave
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rdx
    pop rbx
    ret

; store_get(RDI = a store object or 0, RSI = a whole name) -> RAX = what it
; holds, in memory for st_free, RDX = bytes; or RAX = E_*. What its
; transaction staged first, else the head.
store_get:
    push rbx
    push rcx
    push rsi
    push rdi
    push r12
    mov r12, rsi
    call st_enter
    xor edx, edx
    call st_check
    test rax, rax
    jnz .out
    call st_txp
    mov rdi, [rax]
    call st_change_find
    test rax, rax
    jz .head
    cmp dword [rax + SX_OP], XO_PUT
    jne .noname
    mov rbx, rax
    mov rdi, [rbx + SX_BYTES]
    inc rdi
    call vm_alloc
    test rax, rax
    jz .nomem
    mov rdi, rax
    mov rsi, [rbx + SX_DATA]
    mov rcx, [rbx + SX_BYTES]
    rep movsb
    mov rdx, [rbx + SX_BYTES]
    jmp .out
.head:
    mov rdi, [st_head]
    call tree_find
    test rax, rax
    jz .noname
    lea rsi, [rax + TE_HASH]
    call st_load
    jnc .out
    mov rax, E_IO
    jmp .out
.noname:
    mov rax, E_NONAME
    jmp .out
.nomem:
    mov rax, E_NOMEM
.out:
    call st_leave
    pop r12
    pop rdi
    pop rsi
    pop rcx
    pop rbx
    ret

; store_abort(RDI = a store object or 0) -> RAX = changes dropped
store_abort:
    push rdi
    call st_enter
    call st_txp
    mov rdi, [rax]
    xor eax, eax
    test rdi, rdi
    jz .out
    mov eax, [rdi + TX_COUNT]
    call st_tx_clear
.out:
    call st_leave
    pop rdi
    ret

; store_list(RDI = a store object or 0, RSI = room, RDX = its bytes) -> RAX
; = names written there, each NUL-ended, without the object's prefix: the
; head's names under it, as many whole ones as fit; RDX = bytes used
store_list:
    push rbx
    push rcx
    push rsi
    push rdi
    push r8
    push r9
    push r12
    mov r8, rsi
    lea r9, [rsi + rdx]
    call st_prefix
    mov r12, rax
    call st_enter
    xor ebx, ebx
    xor ecx, ecx
    cmp qword [st_disk], 0
    je .done
.name:
    mov rax, [st_head]
    cmp ecx, [rax + TR_COUNT]
    jae .done
    imul rdi, rcx, TE_SIZE
    lea rdi, [rax + TR_ENTRIES + rdi]
    inc ecx
    mov rsi, r12
    call st_under
    test eax, eax
    jz .name
    mov rsi, rdi
    mov rdi, r12
    push rcx
    call strlen
    pop rcx
    add rsi, rax
    mov rdi, r8
.copy:
    cmp rdi, r9
    jae .done
    lodsb
    stosb
    test al, al
    jnz .copy
    mov r8, rdi
    inc ebx
    jmp .name
.done:
    call st_leave
    mov rdx, r8
    sub rdx, [rsp + 32]
    mov eax, ebx
    pop r12
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rcx
    pop rbx
    ret

; -----------------------------------------------------------------------------
;  Commits
; -----------------------------------------------------------------------------

; store_commit(RDI = a store object or 0, RSI = why, ECX = the rights its
; capability has) -> RAX = the commit's number, or E_*: E_EMPTY if nothing
; is staged or nothing would change, E_CONFLICT if the head changed a name
; since it was staged (nothing is committed then, and the transaction is
; as it was). Preserves others.
store_commit:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push rbp
    push r12
    push r13
    push r14
    push r15
    mov r12, rdi
    mov r13, rsi
    mov r14d, ecx
    call st_enter
    mov edx, 1
    call st_check
    test rax, rax
    jnz .out
    mov rdi, r12
    call st_txp
    mov rbx, [rax]
    mov rax, E_EMPTY
    test rbx, rbx
    jz .out
    cmp dword [rbx + TX_COUNT], 0
    je .out
    xor ebp, ebp                        ; each change against the head now
.check:
    cmp ebp, [rbx + TX_COUNT]
    jae .checked
    imul r15, rbp, SX_SIZE
    lea r15, [rbx + TX_CHANGES + r15]
    inc ebp
    mov rdi, [st_head]
    mov rsi, r15
    call tree_find
    xor ecx, ecx
    test rax, rax
    setnz cl
    cmp ecx, [r15 + SX_HAD]
    jne .conflict
    test rax, rax
    jz .check
    lea rdi, [rax + TE_HASH]
    lea rsi, [r15 + SX_SEEN]
    call st_hash_eq
    je .check
.conflict:
    KLOG "store: %s changed since it was staged; nothing committed", r15
    mov rax, E_CONFLICT
    jmp .out
.checked:
    mov rdi, [st_new]                   ; the head's tree, changed
    mov rsi, [st_head]
    call tree_copy
    mov dword [st_pend_n], 0
    mov rax, [st_sb + SU_NEXT]
    mov [st_next], rax
    mov r8, [st_sb + SU_SEQ]
    inc r8
    xor ebp, ebp
.apply:
    cmp ebp, [rbx + TX_COUNT]
    jae .applied
    imul r15, rbp, SX_SIZE
    lea r15, [rbx + TX_CHANGES + r15]
    inc ebp
    cmp dword [r15 + SX_OP], XO_PUT
    jne .delete
    mov rsi, [r15 + SX_DATA]
    mov rdx, [r15 + SX_BYTES]
    mov ecx, SK_BLOB
    lea rdi, [r15 + SX_HASH]
    call st_object
    jc .io
    mov rdi, [st_new]
    mov rsi, r15
    lea rdx, [r15 + SX_HASH]
    mov rcx, [r15 + SX_BYTES]
    call tree_put
    jc .names
    jmp .apply
.delete:
    mov rdi, [st_new]
    mov rsi, r15
    call tree_del
    jmp .apply
.applied:
    mov rdi, [st_new]
    mov rsi, r13
    mov rdx, r12
    mov ecx, r14d
    mov r8d, CK_COMMIT
    xor r9d, r9d
    call st_seal
    cmp rax, E_ANY
    jae .out
    mov rdi, rbx
    call st_tx_clear
    jmp .out
.names:
    KLOG "store: more than %u names", ST_NAMES
    mov rax, E_FULL
    jmp .out
.io:
    KLOG "store: the drive failed; nothing committed"
    mov rax, E_IO
.out:
    call st_leave
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; store_rollback(RDI = a store object or 0, RSI = the number of the commit
; to go back to, 0 for the empty store, RDX = why, ECX = its capability's
; rights) -> RAX = the new commit's number, or E_*: the names under the
; object's prefix as that commit had them, every other name as it is.
; Preserves others.
store_rollback:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push rbp
    push r12
    push r13
    push r14
    push r15
    mov r12, rdi
    mov rbx, rsi
    mov r13, rdx
    mov r14d, ecx
    call st_enter
    mov edx, 1
    call st_check
    test rax, rax
    jnz .out
    mov rax, E_ARG
    cmp rbx, [st_sb + SU_SEQ]
    ja .out
    mov rax, rbx
    call st_chain_at
    mov rsi, rax
    mov rdi, [st_old]
    call st_tree_of
    jc .io
    mov rdi, [st_new]
    mov rsi, [st_head]
    call tree_copy
    mov rdi, r12
    call st_prefix
    mov r15, rax
    mov rax, [st_new]                   ; names under it that commit lacked go
    mov ebp, [rax + TR_COUNT]
.drop:
    test ebp, ebp
    jz .dropped
    dec ebp
    mov rax, [st_new]
    imul rdi, rbp, TE_SIZE
    lea rdi, [rax + TR_ENTRIES + rdi]
    mov rsi, r15
    call st_under
    test eax, eax
    jz .drop
    mov rsi, rdi
    mov rdi, [st_old]
    call tree_find
    test rax, rax
    jnz .drop
    mov rdi, [st_new]
    call tree_del
    jmp .drop
.dropped:
    xor ebp, ebp                        ; and what it had there comes back, each
.back:                                  ; name with the commit that set it then
    mov rax, [st_old]
    cmp ebp, [rax + TR_COUNT]
    jae .built
    imul rdi, rbp, TE_SIZE
    lea rdi, [rax + TR_ENTRIES + rdi]
    inc ebp
    mov rsi, r15
    call st_under
    test eax, eax
    jz .back
    mov rsi, rdi
    lea rdx, [rsi + TE_HASH]
    mov rcx, [rsi + TE_BYTES]
    mov r8, [rsi + TE_SEQ]
    mov rdi, [st_new]
    call tree_put
    jc .names
    jmp .back
.built:
    mov dword [st_pend_n], 0
    mov rax, [st_sb + SU_NEXT]
    mov [st_next], rax
    mov rdi, [st_new]
    mov rsi, r13
    mov rdx, r12
    mov ecx, r14d
    mov r8d, CK_ROLLBACK
    mov r9, rbx
    call st_seal
    jmp .out
.names:
    mov rax, E_FULL
    jmp .out
.io:
    mov rax, E_IO
.out:
    call st_leave
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; st_seal(RDI = the new tree, st_new, RSI = why, RDX = a store object or 0,
; ECX = its rights, R8D = CK_*, R9 = the commit a rollback goes back to)
; -> RAX = the commit's number, or E_*. Whatever st_object wrote already
; (st_pend_n, st_next), then the tree and the commit, the journal record, a
; flush, the superblock. The head is the new tree only once that is down.
st_seal:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push rbp
    push r12
    push r13
    push r14
    push r15
    mov r12, rdi
    mov r13, rsi
    mov r14, rdx
    mov r15d, ecx
    mov ebp, r8d
    mov rbx, r9
    lea rdi, [st_cm]
    xor eax, eax
    mov ecx, CM_SIZE / 8
    rep stosq
    mov rdi, [st_head]                  ; what changes
    mov rsi, r12
    xor edx, edx
    call tree_diff
    mov [st_cm + CM_ADDED], eax
    mov [st_cm + CM_CHANGED], edx
    mov [st_cm + CM_REMOVED], ecx
    or eax, edx
    or eax, ecx
    jz .same
    mov rdi, r12                        ; the tree
    call tree_bytes
    mov rdx, rax
    mov rsi, r12
    mov ecx, SK_TREE
    lea rdi, [st_cm + CM_TREE]
    call st_object
    jc .io
    mov rax, 'AXCOMMIT'                 ; the commit: what, who, how, why
    mov [st_cm + CM_MAGIC], rax
    mov rax, [st_sb + SU_SEQ]
    inc rax
    mov [st_cm + CM_SEQ], rax
    call st_time
    mov [st_cm + CM_TIME], rax
    lea rdi, [st_cm + CM_PARENT]
    lea rsi, [st_sb + SU_HEAD]
    call st_hash_copy
    lea rsi, [str_st_console]
    mov rax, [gs:PC_CURRENT]
    mov rax, [rax + TH_TASK]
    test rax, rax
    jz .who
    mov rcx, [rax + OB_ID]
    mov [st_cm + CM_TASK], rcx
    test r14, r14
    jz .who
    lea rsi, [rax + OB_NAME]
.who:
    lea rdi, [st_cm + CM_WHO]
    mov ecx, OB_NAME_LEN - 1
.who_char:
    lodsb
    test al, al
    jz .who_done
    stosb
    dec ecx
    jnz .who_char
.who_done:
    test r14, r14
    jz .console
    mov rax, [r14 + OB_ID]
    mov [st_cm + CM_CAP], rax
.console:
    mov [st_cm + CM_RIGHTS], r15d
    mov [st_cm + CM_KIND], ebp
    mov eax, [r12 + TR_COUNT]
    mov [st_cm + CM_NAMES], eax
    mov [st_cm + CM_TARGET], rbx
    mov rdi, r14
    call st_prefix
    mov rsi, rax
    lea rdi, [st_cm + CM_PREFIX]
    call st_name_set
    lea rdi, [st_cm + CM_REASON]
    mov rsi, r13
    mov ecx, ST_REASON - 1
    test rsi, rsi
    jz .reasoned
.why:
    lodsb
    test al, al
    jz .reasoned
    cmp al, ' '
    jae .shown
    mov al, '.'
.shown:
    stosb
    dec ecx
    jnz .why
.reasoned:
    lea rsi, [st_cm]
    mov edx, CM_SIZE
    mov ecx, SK_COMMIT
    lea rdi, [st_cm_hash]
    call st_object
    jc .io
    lea rdi, [st_jbuf]                  ; the journal record: where each went
    xor eax, eax
    mov ecx, ST_JR_MAX * ST_BLOCK / 8
    rep stosq
    mov rax, 'AXJRNL01'
    mov [st_jbuf + JR_MAGIC], rax
    mov rax, [st_cm + CM_SEQ]
    mov [st_jbuf + JR_SEQ], rax
    mov rax, [st_sb + SU_JOURNAL]
    mov [st_jbuf + JR_PREV], rax
    mov ecx, [st_pend_n]
    mov [st_jbuf + JR_COUNT], ecx
    lea rdi, [st_jbuf + JR_COMMIT]
    lea rsi, [st_cm_hash]
    call st_hash_copy
    imul ecx, ecx, JE_SIZE
    lea rdi, [st_jbuf + JR_ENTRIES]
    lea rsi, [st_pend]
    rep movsb
    mov eax, [st_pend_n]
    imul eax, eax, JE_SIZE
    add eax, JR_ENTRIES + ST_BLOCK - 1
    shr eax, ST_SHIFT
    mov [st_jbuf + JR_BLOCKS], eax
    shl eax, ST_SHIFT
    mov edx, eax
    lea rdi, [st_jbuf + JR_SUM]
    lea rsi, [st_jbuf]
    call st_sha
    call st_append
    jc .io
    mov [st_jblock], rax
    call st_flush                       ; all of it down before the superblock
    jc .io
    cmp byte [st_tear], 0
    jne .torn
    lea rsi, [st_sb]                    ; the superblock: the commit is there
    lea rdi, [st_sbuf]
    mov ecx, ST_BLOCK
    rep movsb
    lea rdi, [st_sbuf + SU_HEAD]
    lea rsi, [st_cm_hash]
    call st_hash_copy
    mov rax, [st_cm + CM_SEQ]
    mov [st_sbuf + SU_SEQ], rax
    mov rax, [st_next]
    mov [st_sbuf + SU_NEXT], rax
    mov rax, [st_jblock]
    mov [st_sbuf + SU_JOURNAL], rax
    mov eax, [st_pend_n]
    add [st_sbuf + SU_OBJECTS], rax
    xor ecx, ecx
.bytes:
    cmp ecx, [st_pend_n]
    jae .counted
    imul rax, rcx, JE_SIZE
    lea rdx, [st_pend]
    mov eax, [rdx + rax + JE_BYTES]
    add [st_sbuf + SU_BYTES], rax
    inc ecx
    jmp .bytes
.counted:
    call st_sb_put
    jc .io
    xor ecx, ecx                        ; down: now the index, the chain, the head
.index:
    cmp ecx, [st_pend_n]
    jae .indexed
    imul rsi, rcx, JE_SIZE
    lea rax, [st_pend]
    add rsi, rax
    call ix_add
    jc .lost
    inc ecx
    jmp .index
.indexed:
    mov rdx, [st_cm + CM_SEQ]
    lea rsi, [st_cm_hash]
    call st_chain_set
    jc .lost
    mov rax, [st_head]
    mov [st_new], rax
    mov [st_head], r12
    mov dword [st_pend_n], 0
    mov rax, [st_cm + CM_SEQ]
    jmp .out
.lost:
    KLOG "store: out of memory after a commit: 'store' mounts it again at the next boot"
    call st_unmount
    mov rax, E_NOMEM
    jmp .out
.torn:
    mov byte [st_tear], 0
    mov dword [st_pend_n], 0
    KLOG "store: commit #%u written up to its superblock, which was not: as if the power failed there", qword [st_cm + CM_SEQ]
    mov rax, E_CANCELED
    jmp .out
.same:
    mov dword [st_pend_n], 0
    mov rax, E_EMPTY
    jmp .out
.io:
    KLOG "store: the drive failed; nothing committed"
    mov dword [st_pend_n], 0
    mov rax, E_IO
.out:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; -----------------------------------------------------------------------------
;  Snapshots
; -----------------------------------------------------------------------------

; st_snap_find(RDI = a superblock, RSI = a name) -> RAX = its snapshot, or
; 0. Preserves others.
st_snap_find:
    push rcx
    push rdi
    add rdi, SU_SNAPS
    xor ecx, ecx
.next:
    cmp ecx, ST_SNAPS
    jae .none
    cmp byte [rdi], 0
    je .skip
    call streq
    test eax, eax
    jz .skip
    mov rax, rdi
    jmp .out
.skip:
    add rdi, SN_SIZE
    inc ecx
    jmp .next
.none:
    xor eax, eax
.out:
    pop rdi
    pop rcx
    ret

; store_snap(RSI = a name, RDX = a commit's number) -> RAX = 0 or E_*: the
; name for it, kept in the superblock (one of the name before is replaced)
store_snap:
    push rcx
    push rdx
    push rsi
    push rdi
    push r12
    push r13
    mov r12, rdx
    mov r13, rsi
    call st_enter
    mov edx, 1
    call st_check
    test rax, rax
    jnz .out
    mov rax, E_ARG
    cmp r12, [st_sb + SU_SEQ]
    ja .out
    call st_name_ok
    jc .arg
    mov rdi, r13
    call strlen
    cmp rax, SN_NAME_MAX
    ja .arg
    lea rsi, [st_sb]
    lea rdi, [st_sbuf]
    mov ecx, ST_BLOCK
    rep movsb
    lea rdi, [st_sbuf]
    mov rsi, r13
    call st_snap_find
    test rax, rax
    jnz .slot
    lea rax, [st_sbuf + SU_SNAPS]       ; else the first free
    xor ecx, ecx
.free:
    cmp byte [rax], 0
    je .slot
    add rax, SN_SIZE
    inc ecx
    cmp ecx, ST_SNAPS
    jb .free
    mov rax, E_FULL
    jmp .out
.slot:
    mov rdx, rax
    mov rdi, rdx
    mov ecx, SN_SIZE
    xor eax, eax
    rep stosb
    mov rdi, rdx
    mov rsi, r13
.copy:
    lodsb
    stosb
    test al, al
    jnz .copy
    mov [rdx + SN_SEQ], r12
    mov rax, r12
    call st_chain_at
    mov rsi, rax
    lea rdi, [rdx + SN_HASH]
    call st_hash_copy
    call st_sb_put
    mov rax, E_IO
    jc .out
    xor eax, eax
    jmp .out
.arg:
    mov rax, E_ARG
.out:
    call st_leave
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    ret

; store_unsnap(RSI = a name) -> RAX = 0, or E_NONAME
store_unsnap:
    push rcx
    push rdx
    push rsi
    push rdi
    call st_enter
    mov edx, 1
    call st_check
    test rax, rax
    jnz .out
    lea rsi, [st_sb]
    lea rdi, [st_sbuf]
    mov ecx, ST_BLOCK
    rep movsb
    mov rsi, [rsp + 8]
    lea rdi, [st_sbuf]
    call st_snap_find
    test rax, rax
    jz .noname
    mov rdi, rax
    mov ecx, SN_SIZE
    xor eax, eax
    rep stosb
    call st_sb_put
    mov rax, E_IO
    jc .out
    xor eax, eax
    jmp .out
.noname:
    mov rax, E_NONAME
.out:
    call st_leave
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    ret

; -----------------------------------------------------------------------------
;  Checking it all
; -----------------------------------------------------------------------------

; store_verify -> RAX = what was wrong (each said): every object read back
; and hashed, every commit's parent the one before it, every tree whole
store_verify:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    call st_enter
    xor r13d, r13d                      ; wrong
    cmp qword [st_disk], 0
    je .none
    xor r12d, r12d                      ; objects whole
    xor r14d, r14d                      ; their bytes
    xor ebx, ebx
.object:
    cmp ebx, [st_ix_cap]
    jae .objects
    imul rsi, rbx, IX_SIZE
    add rsi, [st_index]
    inc ebx
    cmp qword [rsi + IX_BLOCK], 0
    je .object
    call st_load
    jc .bad_object
    inc r12d
    add r14, rdx
    mov rdi, rax
    call st_free
    jmp .object
.bad_object:
    inc r13d
    jmp .object
.objects:
    mov ebx, 1                          ; each commit on the one before
.commit:
    cmp rbx, [st_sb + SU_SEQ]
    ja .commits
    mov rax, rbx
    lea rdi, [st_vcm]
    call st_commit_of
    jc .bad_commit
    cmp [st_vcm + CM_SEQ], rbx
    jne .bad_commit
    lea rax, [rbx - 1]
    call st_chain_at
    mov rsi, rax
    lea rdi, [st_vcm + CM_PARENT]
    call st_hash_eq
    jne .bad_commit
    mov rax, rbx
    call st_chain_at
    mov rsi, rax
    mov rdi, [st_old]
    call st_tree_of
    jc .bad_commit
    inc rbx
    jmp .commit
.bad_commit:
    KLOG "store verify: commit #%u is not as it should be", rbx
    inc r13d
    inc rbx
    jmp .commit
.commits:
    lea rdi, [st_sbuf]                  ; both superblocks
    xor esi, esi
    mov edx, 1
    call st_read
    jc .bad_sb
    call st_sb_check
    mov r15d, eax
    mov esi, 1
    call st_read
    jc .bad_sb
    call st_sb_check
    cmp eax, 2
    jne .bad_sb
    cmp r15d, 2
    je .said
.bad_sb:
    KLOG "store verify: a superblock is damaged (the other holds the store)"
    inc r13d
.said:
    dec rbx
    KLOG "store verify: %u objects (%b) read back whole, %u commits each on the one before, %u things wrong", r12, r14, rbx, r13
    jmp .out
.none:
    KLOG "store verify: no store"
    inc r13d
.out:
    call st_leave
    mov rax, r13
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; -----------------------------------------------------------------------------
;  Ring 3: store capabilities
; -----------------------------------------------------------------------------

; st_obj_new(RSI = a prefix, a name's field) -> RAX = a store object (one
; reference) reaching the names under it, 0 if out of memory. Preserves
; others.
st_obj_new:
    push rdx
    push rsi
    push rdi
    mov rdx, rsi
    mov edi, OT_STORE
    mov esi, SO_SIZE
    call obj_new
    test rax, rax
    jz .out
    lea rdi, [rax + SO_PREFIX]
    mov rsi, [rsp + 8]
    call st_name_set
.out:
    pop rdi
    pop rsi
    pop rdx
    ret

; st_obj_destroy(RDI): its last reference went; so does its transaction
st_obj_destroy:
    push rdi
    mov rdi, [rdi + SO_TX]
    call st_tx_clear
    call kfree
    pop rdi
    jmp obj_free

; st_program(RDI = a program's name) -> EAX = a handle, in the current task,
; to the store under "name/" (lower case), with every right; read alone if
; the store cannot be written; 0 if there is no store
st_program:
    push rcx
    push rdx
    push rsi
    push rdi
    sub rsp, ST_NAME
    cmp qword [st_disk], 0
    je .none
    mov rsi, rdi
    mov rdi, rsp
    mov ecx, ST_NAME - 2
.char:
    lodsb
    test al, al
    jz .named
    cmp al, 'A'
    jb .keep
    cmp al, 'Z'
    ja .keep
    add al, 'a' - 'A'
.keep:
    stosb
    dec ecx
    jnz .char
.named:
    mov word [rdi], '/'
    mov rsi, rsp
    call st_obj_new
    test rax, rax
    jz .none
    mov rdi, rax
    mov esi, RT_ST_ALL | RT_DUP | RT_GIVE | RT_INFO
    cmp byte [st_writable], 0
    jne .rights
    mov esi, RT_ST_READ | RT_DUP | RT_GIVE | RT_INFO
.rights:
    call handle_new
    cmp rax, E_ANY
    jb .out
.none:
    xor eax, eax
.out:
    add rsp, ST_NAME
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    ret

; st_h_name(RBX = a store object, ESI = a memory handle, RDX = an offset in
; it, RDI = a name's field, out) -> RAX = 0 or E_*: the name there (a field
; of ST_NAME bytes, NUL-ended), under the object's prefix
st_h_name:
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    sub rsp, ST_NAME
    mov r8, rdi
    mov edi, esi
    mov rsi, rdx
    mov rdx, rsp
    mov ecx, ST_NAME
    call h_mem_read
    cmp rax, E_ANY
    jae .out
    xor ecx, ecx
.nul:
    cmp byte [rsp + rcx], 0
    je .ended
    inc ecx
    cmp ecx, ST_NAME
    jb .nul
    jmp .arg
.ended:
    mov rdi, rbx
    call st_prefix
    mov rsi, rax
    mov rdi, r8
    mov rdx, rsp
    call st_join
    jc .arg
    xor eax, eax
    jmp .out
.arg:
    mov rax, E_ARG
.out:
    add rsp, ST_NAME
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    ret

; h_st_put(EDI = a store, ESI = memory, RDX = where the name is, RCX = where
; the bytes are, R8 = how many) -> RAX = 0 or E_*: staged (needs
; RT_ST_WRITE)
h_st_put:
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, ST_NAME
    mov r12d, esi
    mov r13, rdx
    mov r14, rcx
    mov r15, r8
    mov esi, OT_STORE
    mov edx, RT_ST_WRITE
    call handle_get
    cmp rax, E_ANY
    jae .out
    mov rbx, rax
    mov esi, r12d
    mov rdx, r13
    mov rdi, rsp
    call st_h_name
    test rax, rax
    jnz .put
    mov rax, E_ARG
    cmp r15, ST_OBJ_MAX
    ja .put
    lea rdi, [r15 + 1]
    call kmalloc
    test rax, rax
    jz .nomem
    mov r13, rax
    mov edi, r12d
    mov rsi, r14
    mov rdx, r13
    mov rcx, r15
    call h_mem_read
    cmp rax, E_ANY
    jae .free
    mov rdi, rbx
    mov rsi, rsp
    mov rdx, r13
    mov rcx, r15
    call store_put
    jmp .put
.free:
    mov rdi, r13
    call kfree
    jmp .put
.nomem:
    mov rax, E_NOMEM
.put:
    mov rdi, rbx
    call obj_put
.out:
    add rsp, ST_NAME
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; h_st_get(EDI = a store, ESI = memory, RDX = where the name is, RCX =
; where its bytes go, R8 = room there) -> RAX = the bytes it holds (as many
; as there is room for are written) or E_* (needs RT_ST_READ)
h_st_get:
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, ST_NAME + 16
    mov r12d, esi
    mov r13, rdx
    mov r14, rcx
    mov r15, r8
    mov esi, OT_STORE
    mov edx, RT_ST_READ
    call handle_get
    cmp rax, E_ANY
    jae .out
    mov rbx, rax
    mov esi, r12d
    mov rdx, r13
    mov rdi, rsp
    call st_h_name
    test rax, rax
    jnz .put
    mov rdi, rbx
    mov rsi, rsp
    call store_get
    cmp rax, E_ANY
    jae .put
    mov r13, rax
    mov [rsp + ST_NAME], rdx
    mov rcx, rdx
    cmp rcx, r15
    cmova rcx, r15
    mov edi, r12d
    mov rsi, r14
    mov rdx, r13
    call h_mem_write
    mov rdi, r13
    call st_free
    cmp rax, E_ANY
    jae .put
    mov rax, [rsp + ST_NAME]
.put:
    mov rdi, rbx
    call obj_put
.out:
    add rsp, ST_NAME + 16
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; h_st_del(EDI = a store, ESI = memory, RDX = where the name is) -> RAX = 0
; or E_*: its removal staged (needs RT_ST_WRITE)
h_st_del:
    push rbx
    push r12
    push r13
    sub rsp, ST_NAME
    mov r12d, esi
    mov r13, rdx
    mov esi, OT_STORE
    mov edx, RT_ST_WRITE
    call handle_get
    cmp rax, E_ANY
    jae .out
    mov rbx, rax
    mov esi, r12d
    mov rdx, r13
    mov rdi, rsp
    call st_h_name
    test rax, rax
    jnz .put
    mov rdi, rbx
    mov rsi, rsp
    call store_del
.put:
    mov rdi, rbx
    call obj_put
.out:
    add rsp, ST_NAME
    pop r13
    pop r12
    pop rbx
    ret

; h_st_commit(EDI = a store, ESI = memory, RDX = where why is, RCX = its
; bytes, 0 for no reason) -> RAX = the commit's number or E_* (needs
; RT_ST_COMMIT)
h_st_commit:
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, ST_REASON
    mov r12d, esi
    mov r13, rdx
    mov r14, rcx
    mov r15d, edi
    mov esi, OT_STORE
    mov edx, RT_ST_COMMIT
    call handle_get
    cmp rax, E_ANY
    jae .out
    mov rbx, rax
    mov rax, E_ARG
    cmp r14, ST_REASON - 1
    ja .put
    mov byte [rsp], 0
    test r14, r14
    jz .reasoned
    mov edi, r12d
    mov rsi, r13
    mov rdx, rsp
    mov rcx, r14
    call h_mem_read
    cmp rax, E_ANY
    jae .put
    mov byte [rsp + r14], 0
.reasoned:
    mov edi, r15d
    call handle_info
    mov ecx, edx
    mov rdi, rbx
    mov rsi, rsp
    call store_commit
.put:
    mov rdi, rbx
    call obj_put
.out:
    add rsp, ST_REASON
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; h_st_abort(EDI = a store) -> RAX = the changes dropped (needs RT_ST_WRITE)
h_st_abort:
    push rbx
    mov esi, OT_STORE
    mov edx, RT_ST_WRITE
    call handle_get
    cmp rax, E_ANY
    jae .out
    mov rbx, rax
    mov rdi, rbx
    call store_abort
    mov rdi, rbx
    call obj_put
.out:
    pop rbx
    ret

; h_st_sub(EDI = a store, ESI = memory, RDX = where a name is, ECX = rights
; to keep) -> RAX = a handle to a store object of its own (its own
; transaction) reaching the names under "name/" alone (needs RT_DUP)
h_st_sub:
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, ST_NAME
    mov r12d, esi
    mov r13, rdx
    mov r14d, ecx
    mov r15d, edi
    mov esi, OT_STORE
    mov edx, RT_DUP
    call handle_get
    cmp rax, E_ANY
    jae .out
    mov rbx, rax
    mov esi, r12d
    mov rdx, r13
    mov rdi, rsp
    call st_h_name
    test rax, rax
    jnz .put
    mov rdi, rsp
    call strlen
    cmp rax, ST_NAME - 2
    ja .arg
    mov word [rsp + rax], '/'
    mov edi, r15d
    call handle_info
    and r14d, edx
    mov rsi, rsp
    call st_obj_new
    test rax, rax
    jz .nomem
    mov rdi, rax
    mov esi, r14d
    call handle_new
    jmp .put
.arg:
    mov rax, E_ARG
    jmp .put
.nomem:
    mov rax, E_NOMEM
.put:
    push rax
    mov rdi, rbx
    call obj_put
    pop rax
.out:
    add rsp, ST_NAME
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; h_st_rollback(EDI = a store, RSI = the number of a commit) -> RAX = the
; new commit's number or E_*: the names under its prefix as they were then
; (needs RT_ST_ROLLBACK)
h_st_rollback:
    push rbx
    push r12
    push r13
    mov r12, rsi
    mov r13d, edi
    mov esi, OT_STORE
    mov edx, RT_ST_ROLLBACK
    call handle_get
    cmp rax, E_ANY
    jae .out
    mov rbx, rax
    mov edi, r13d
    call handle_info
    mov ecx, edx
    mov rdi, rbx
    mov rsi, r12
    xor edx, edx
    call store_rollback
    push rax
    mov rdi, rbx
    call obj_put
    pop rax
.out:
    pop r13
    pop r12
    pop rbx
    ret

; h_st_list(EDI = a store, ESI = memory, RDX = where, RCX = room there) ->
; RAX = names written there (as store_list) or E_* (needs RT_ST_READ)
h_st_list:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov r12d, esi
    mov r13, rdx
    mov r14, rcx
    mov esi, OT_STORE
    mov edx, RT_ST_READ
    call handle_get
    cmp rax, E_ANY
    jae .out
    mov rbx, rax
    mov rax, E_ARG
    cmp r14, ST_LIST_MAX
    ja .put
    lea rdi, [r14 + 1]
    call kmalloc
    test rax, rax
    jz .nomem
    mov r15, rax
    mov rdi, rbx
    mov rsi, r15
    mov rdx, r14
    call store_list
    push rax
    mov edi, r12d
    mov rsi, r13
    mov rcx, rdx
    mov rdx, r15
    call h_mem_write
    mov rdi, r15
    call kfree
    pop rdx
    cmp rax, E_ANY
    jae .put
    mov rax, rdx
    jmp .put
.nomem:
    mov rax, E_NOMEM
.put:
    push rax
    mov rdi, rbx
    call obj_put
    pop rax
.out:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

section .rodata
str_st_serial:  db 'AXIOMTEST', 0
str_st_console: db 'console', 0
str_st_empty:   db 0
str_st_rw:      db 'writable', 0
str_st_ro:      db 'read-only (not QEMU', 39, 's test drive)', 0
str_ot_store:   db 'store', 0
st_digits:      db '0123456789abcdef'

section .bss
alignb 4096
st_sb:          resb ST_BLOCK           ; the superblock in use
st_sbuf:        resb ST_BLOCK           ; the next one, or one being read
st_tail:        resb ST_BLOCK           ; an object's last block, padded
st_jbuf:        resb ST_JR_MAX * ST_BLOCK
alignb 16
st_cm:          resb CM_SIZE            ; the commit being made
st_vcm:         resb CM_SIZE            ; one being looked at
st_pend:        resb ST_PEND * JE_SIZE  ; what this commit wrote
st_digest:      resb 32
st_want:        resb 32
st_cm_hash:     resb 32
alignb 8
st_disk:        resq 1                  ; 0: no store
st_index:       resq 1                  ; IX_SIZE slots
st_chain:       resq 1                  ; 32 bytes for each commit, by number
st_chain_cap:   resq 1
st_head:        resq 1                  ; the head's tree (TR_MAX bytes)
st_new:         resq 1                  ; a tree being made
st_old:         resq 1                  ; a tree being looked at
st_next:        resq 1                  ; the log's end while a commit writes
st_jblock:      resq 1
st_console_tx:  resq 1                  ; the console's transaction
st_bad_slot:    resq 1                  ; -1, or a superblock found damaged
st_ix_cap:      resd 1
st_ix_used:     resd 1
st_pend_n:      resd 1
st_dshift:      resd 1                  ; log2 of disk blocks in one of ours
st_lock:        resd 1
st_writable:    resb 1
st_tear:        resb 1                  ; 'store tear': the next commit stops short
