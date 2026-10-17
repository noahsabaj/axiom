; =============================================================================
;  storetest.asm - 'store': the object store from the console. Names are
;  staged in the console's transaction, shown before they are committed,
;  committed with a reason; the log, snapshots, rollback, undo, a check of
;  everything. 'store test': the store checks itself through capabilities
;  of its own, under "test/".
;
;    store                       what is mounted, and what is staged
;    store put <name> <text>     staged: the name holds the text
;    store get <name>            what it holds (staged, else committed)
;    store rm <name>             its removal staged
;    store ls [prefix]           the head's names
;    store diff                  what a commit would do now
;    store diff <a> [<b>]        between two commits (b: the head)
;    store commit <why>          what is staged, committed
;    store abort                 what is staged, dropped
;    store log [n]               the last n commits (10)
;    store snap [<name> [<c>]]   the snapshots, or one more
;    store unsnap <name>
;    store rollback <c> [why]    a new commit holding c's names
;    store undo                  a rollback to the commit before the head
;    store verify                every object read back, every commit checked
;    store format [again]        a store on QEMU's test drive
;    store tear <why>            a commit that stops short of its superblock
;    store test
;  A commit (c) is a number (#12 or 12), 'head', or a snapshot's name.
; =============================================================================

STT_BIG         equ 300 * 1024          ; bytes in the test's big name
SC_SHOW_MAX     equ 1024                ; bytes 'store get' shows, at most

; a check of 'store test': J<cc> taken when it passed
%macro STT 2
    j%1 %%ok
    push rdi
    lea rdi, [%%what]
    call stt_fail
    pop rdi
%%ok:
    inc dword [stt_checks]
    [section .rodata]
    %%what: db %2, 0
    __SECT__
%endmacro

section .text

cmd_store:
    push rbx
    mov rsi, [sh_args]
    cmp byte [rsi], 0
    je .status
    call arg_split
    lea rbx, [store_cmds]
.find:
    mov rax, [rbx]
    test rax, rax
    jz .usage
    push rdi
    mov rdi, rax
    call streq
    pop rdi
    test eax, eax
    jnz .found
    add rbx, 16
    jmp .find
.found:
    mov rsi, rdi                        ; what follows the word
    call [rbx + 8]
    jmp .out
.status:
    call store_status
    jmp .out
.usage:
    KLOG "usage: store [put <name> <text> | get <name> | rm <name> | ls [prefix] | diff [a [b]] | commit <why> | abort | log [n] | snap [name [commit]] | unsnap <name> | rollback <commit> [why] | undo | verify | format [again] | tear <why> | test]"
.out:
    pop rbx
    ret

; sc_err(RDI = what was asked, RAX = E_*): said
sc_err:
    push rax
    push rdi
    mov rdi, rax
    call err_text
    pop rdi
    KLOG "%s: %s", rdi, rax
    pop rax
    ret

; sc_name(RSI = text) -> CF unless it is a name (said); sc_whole holds it
sc_name:
    push rdx
    push rsi
    push rdi
    mov rdx, rsi
    lea rsi, [str_st_empty]
    lea rdi, [sc_whole]
    call st_join
    jnc .out
    KLOG "store: a name is 1 to 63 characters from ! to ~"
    stc
.out:
    pop rdi
    pop rsi
    pop rdx
    ret

; sc_resolve(RSI = text) -> RAX = the commit it names, CF if none (said).
; The lock is held.
sc_resolve:
    push rsi
    push rdi
    cmp qword [st_disk], 0
    je .none
    lea rdi, [str_sc_head]
    call streq
    test eax, eax
    jz .number
    mov rax, [st_sb + SU_SEQ]
    clc
    jmp .out
.number:
    cmp byte [rsi], '#'
    jne .digits
    inc rsi
.digits:
    call arg_uint
    jc .snap
    cmp rax, [st_sb + SU_SEQ]
    ja .past
    clc
    jmp .out
.snap:
    mov rsi, [rsp + 8]
    lea rdi, [st_sb]
    call st_snap_find
    test rax, rax
    jz .unknown
    mov rax, [rax + SN_SEQ]
    clc
    jmp .out
.past:
    KLOG "store: there is no commit #%u yet", rax
    stc
    jmp .out
.unknown:
    mov rsi, [rsp + 8]
    KLOG "store: no commit is called %s (a number, 'head', or a snapshot)", rsi
.none:
    stc
.out:
    pop rdi
    pop rsi
    ret

; sc_when(RAX = YYYYMMDDhhmmss, RDI = 20 bytes): "YYYY-MM-DD hh:mm:ss".
; Preserves all.
sc_when:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    lea rsi, [str_sc_when]
    mov ecx, 20
    push rdi
    rep movsb
    pop rdi
    lea rbx, [sc_when_at]
    xor ecx, ecx
.digit:
    xor edx, edx
    push rcx
    mov ecx, 10
    div rcx
    pop rcx
    add dl, '0'
    movzx esi, byte [rbx + rcx]
    mov [rdi + rsi], dl
    inc ecx
    cmp ecx, 14
    jb .digit
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; sc_show(RAX = a commit's number): two lines about it. The lock is held.
sc_show:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    push r11
    mov rbx, rax
    lea rdi, [st_vcm]
    call st_commit_of
    jc .unreadable
    mov rax, rbx
    call st_chain_at
    mov rsi, rax
    lea rdi, [sc_hex]
    mov ecx, 8
    call st_hex
    mov rax, [st_vcm + CM_TIME]
    lea rdi, [sc_time]
    call sc_when
    lea rdi, [sc_rights]
    mov esi, [st_vcm + CM_RIGHTS]
    mov edx, OT_STORE
    call rights_text
    lea r8, [st_vcm + CM_PREFIX]
    cmp byte [r8], 0
    jne .prefixed
    lea r8, [str_sc_all]
.prefixed:
    lea rax, [sc_hex]
    lea rcx, [sc_time]
    lea rdx, [st_vcm + CM_WHO]
    lea rsi, [sc_rights]
    mov r9d, [st_vcm + CM_ADDED]
    mov r10d, [st_vcm + CM_CHANGED]
    mov r11d, [st_vcm + CM_REMOVED]
    mov edi, [st_vcm + CM_NAMES]
    KLOG "  #%u %s  %s  %s, task %u, capability %u (%s) on %s: +%u ~%u -%u, %u names", rbx, rax, rcx, rdx, qword [st_vcm + CM_TASK], qword [st_vcm + CM_CAP], rsi, r8, r9, r10, r11, rdi
    lea rax, [st_vcm + CM_REASON]
    cmp dword [st_vcm + CM_KIND], CK_ROLLBACK
    je .rollback
    KLOG "      why: %s", rax
    jmp .out
.rollback:
    cmp byte [rax], 0
    je .no_reason
    KLOG "      back to #%u; why: %s", qword [st_vcm + CM_TARGET], rax
    jmp .out
.no_reason:
    KLOG "      back to #%u", qword [st_vcm + CM_TARGET]
    jmp .out
.unreadable:
    KLOG "  #%u: cannot be read", rbx
.out:
    pop r11
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; -----------------------------------------------------------------------------
;  The commands
; -----------------------------------------------------------------------------

store_status:
    push rbx
    call st_enter
    mov rbx, [st_disk]
    test rbx, rbx
    jnz .some
    KLOG "store: none ('store format' makes one on QEMU's test drive)"
    jmp .out
.some:
    call st_say
    mov rax, [st_sb + SU_SEQ]
    test rax, rax
    jz .snaps
    call sc_show
.snaps:
    xor ecx, ecx
    xor edx, edx
    lea rax, [st_sb + SU_SNAPS]
.snap:
    cmp byte [rax], 0
    je .next
    inc edx
.next:
    add rax, SN_SIZE
    inc ecx
    cmp ecx, ST_SNAPS
    jb .snap
    mov rax, [st_console_tx]
    xor ecx, ecx
    test rax, rax
    jz .said
    mov ecx, [rax + TX_COUNT]
.said:
    mov rax, [st_sb + SU_GEN]
    KLOG "store: %u snapshots; %u changes staged here; superblock generation %u", rdx, rcx, rax
.out:
    call st_leave
    pop rbx
    ret

sc_put:
    push rbx
    push r12
    push r13
    call arg_split
    mov r12, rdi                        ; the text
    call sc_name
    jc .out
    mov rdi, r12
    call strlen
    mov r13, rax
    lea rdi, [rax + 1]
    call kmalloc
    test rax, rax
    jz .nomem
    mov rbx, rax
    mov rdi, rbx
    mov rsi, r12
    mov rcx, r13
    rep movsb
    xor edi, edi
    lea rsi, [sc_whole]
    mov rdx, rbx
    mov rcx, r13
    call store_put
    test rax, rax
    jnz .refused
    lea rax, [sc_whole]
    KLOG "store: %s staged, %u bytes", rax, r13
    jmp .out
.nomem:
    mov rax, E_NOMEM
.refused:
    lea rdi, [str_sc_put]
    call sc_err
.out:
    pop r13
    pop r12
    pop rbx
    ret

sc_get:
    push rbx
    push r12
    call arg_split
    call sc_name
    jc .out
    xor edi, edi
    lea rsi, [sc_whole]
    call store_get
    cmp rax, E_ANY
    jae .refused
    mov rbx, rax
    mov r12, rdx
    lea rax, [sc_whole]
    KLOG "store: %s, %u bytes:", rax, r12
    mov rsi, r12
    cmp rsi, SC_SHOW_MAX
    jbe .show
    mov esi, SC_SHOW_MAX
.show:
    test rsi, rsi
    jz .shown
    mov rdi, rbx
    mov al, [rdi + rsi]
    push rax
    mov byte [rdi + rsi], 0
    call con_lines
    pop rax
.shown:
    cmp r12, SC_SHOW_MAX
    jbe .free
    KLOG "  (the first %u bytes)", SC_SHOW_MAX
.free:
    mov rdi, rbx
    call st_free
    jmp .out
.refused:
    lea rdi, [str_sc_get]
    call sc_err
.out:
    pop r12
    pop rbx
    ret

sc_rm:
    call arg_split
    call sc_name
    jc .out
    xor edi, edi
    lea rsi, [sc_whole]
    call store_del
    test rax, rax
    jnz .refused
    lea rax, [sc_whole]
    KLOG "store: %s: its removal staged", rax
    ret
.refused:
    lea rdi, [str_sc_rm]
    call sc_err
.out:
    ret

sc_ls:
    push rbx
    push r12
    push r13
    call arg_split
    mov r12, rsi                        ; the prefix, perhaps empty
    call st_enter
    cmp qword [st_disk], 0
    je .none
    xor ebx, ebx
    xor r13d, r13d
.name:
    mov rax, [st_head]
    cmp ebx, [rax + TR_COUNT]
    jae .listed
    imul rdi, rbx, TE_SIZE
    lea rdi, [rax + TR_ENTRIES + rdi]
    inc ebx
    mov rsi, r12
    call st_under
    test eax, eax
    jz .name
    inc r13d
    lea rsi, [rdi + TE_HASH]
    push rdi
    lea rdi, [sc_hex]
    mov ecx, 8
    call st_hex
    pop rdi
    lea rax, [sc_hex]
    KLOG "  %-40s %8u  #%-4u %s", rdi, qword [rdi + TE_BYTES], qword [rdi + TE_SEQ], rax
    jmp .name
.listed:
    KLOG "store: %u names", r13
    jmp .out
.none:
    KLOG "store: none"
.out:
    call st_leave
    pop r13
    pop r12
    pop rbx
    ret

; sc_diff_one(RDI = a's entry or 0, RSI = b's or 0): one line. Preserves
; all but RAX.
sc_diff_one:
    test rdi, rdi
    jz .added
    test rsi, rsi
    jz .removed
    KLOG "  ~ %s, %u bytes (was %u)", rsi, qword [rsi + TE_BYTES], qword [rdi + TE_BYTES]
    ret
.added:
    KLOG "  + %s, %u bytes", rsi, qword [rsi + TE_BYTES]
    ret
.removed:
    KLOG "  - %s", rdi
    ret

sc_diff:
    push rbx
    push r12
    push r13
    push r14
    call arg_split
    mov r12, rsi                        ; a, perhaps empty
    mov rsi, rdi
    call arg_split
    mov r13, rsi                        ; b, perhaps empty
    call st_enter
    cmp qword [st_disk], 0
    je .none
    cmp byte [r12], 0
    je .staged
    mov rsi, r12
    call sc_resolve
    jc .out
    mov r14, rax                        ; a's number
    call st_chain_at
    mov rsi, rax
    mov rdi, [st_old]
    call st_tree_of
    jc .unreadable
    mov rbx, [st_sb + SU_SEQ]           ; b: the head unless said
    mov rsi, [st_head]
    cmp byte [r13], 0
    je .against
    mov rsi, r13
    call sc_resolve
    jc .out
    mov rbx, rax
    call st_chain_at
    mov rsi, rax
    mov rdi, [st_new]
    call st_tree_of
    jc .unreadable
    mov rsi, [st_new]
.against:
    mov rdi, [st_old]
    lea rdx, [sc_diff_one]
    call tree_diff
    KLOG "store diff #%u #%u: +%u ~%u -%u", r14, rbx, rax, rdx, rcx
    jmp .out
.staged:
    mov r12, [st_console_tx]            ; what the console staged, against the head
    xor r13d, r13d                      ; changes
    xor r14d, r14d                      ; of those, conflicts
    test r12, r12
    jz .total
    xor ebx, ebx
.change:
    cmp ebx, [r12 + TX_COUNT]
    jae .total
    imul rsi, rbx, SX_SIZE
    lea rsi, [r12 + TX_CHANGES + rsi]
    inc ebx
    inc r13d
    mov rdi, [st_head]
    call tree_find
    mov r8, rax                         ; the head's entry, or 0
    lea rdx, [str_sc_ok]                ; still as when staged?
    xor ecx, ecx
    test r8, r8
    setnz cl
    cmp ecx, [rsi + SX_HAD]
    jne .conflict
    test r8, r8
    jz .checked
    push rsi
    lea rdi, [r8 + TE_HASH]
    lea rsi, [rsi + SX_SEEN]
    call st_hash_eq
    pop rsi
    je .checked
.conflict:
    lea rdx, [str_sc_conflict]
    inc r14d
.checked:
    cmp dword [rsi + SX_OP], XO_PUT
    jne .del
    test r8, r8
    jz .add
    KLOG "  ~ %s, %u bytes (was %u)%s", rsi, qword [rsi + SX_BYTES], qword [r8 + TE_BYTES], rdx
    jmp .change
.add:
    KLOG "  + %s, %u bytes%s", rsi, qword [rsi + SX_BYTES], rdx
    jmp .change
.del:
    KLOG "  - %s%s", rsi, rdx
    jmp .change
.total:
    KLOG "store diff: %u changes staged, %u of them in conflict with the head", r13, r14
    jmp .out
.unreadable:
    KLOG "store diff: a commit cannot be read"
    jmp .out
.none:
    KLOG "store: none"
.out:
    call st_leave
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

sc_commit:
    cmp byte [rsi], 0
    jne .why
    KLOG "store commit: say why (store commit <why>)"
    ret
.why:
    xor edi, edi
    mov ecx, RT_ALL
    call store_commit
    cmp rax, E_ANY
    jae .refused
    call st_enter
    KLOG "store: commit #%u", rax
    call sc_show
    call st_leave
    ret
.refused:
    lea rdi, [str_sc_commit]
    jmp sc_err

sc_tear:
    mov byte [st_tear], 1
    call sc_commit
    mov byte [st_tear], 0
    ret

sc_abort:
    xor edi, edi
    call store_abort
    KLOG "store: %u staged changes dropped", rax
    ret

sc_log:
    push rbx
    push r12
    call arg_split
    mov r12d, 10
    cmp byte [rsi], 0
    je .counted
    call arg_uint
    jc .counted
    mov r12d, eax
.counted:
    call st_enter
    cmp qword [st_disk], 0
    je .none
    mov rbx, [st_sb + SU_SEQ]
    KLOG "store log: %u commits, newest first", rbx
.commit:
    test rbx, rbx
    jz .out
    test r12d, r12d
    jz .out
    mov rax, rbx
    call sc_show
    dec rbx
    dec r12d
    jmp .commit
.none:
    KLOG "store: none"
.out:
    call st_leave
    pop r12
    pop rbx
    ret

sc_snap:
    push rbx
    push r12
    push r13
    call arg_split
    mov r12, rsi                        ; a name, perhaps
    mov r13, rdi                        ; a commit, perhaps
    cmp byte [r12], 0
    jne .make
    call st_enter
    cmp qword [st_disk], 0
    je .none
    xor ebx, ebx
.slot:
    cmp ebx, ST_SNAPS
    jae .listed
    imul rax, rbx, SN_SIZE
    lea rsi, [st_sb + SU_SNAPS]
    add rsi, rax
    inc ebx
    cmp byte [rsi], 0
    je .slot
    push rsi
    add rsi, SN_HASH
    lea rdi, [sc_hex]
    mov ecx, 8
    call st_hex
    pop rsi
    lea rax, [sc_hex]
    KLOG "  %-24s #%-4u %s", rsi, qword [rsi + SN_SEQ], rax
    jmp .slot
.listed:
    KLOG "store: snapshots listed"
    jmp .leave
.none:
    KLOG "store: none"
.leave:
    call st_leave
    jmp .out
.make:
    call st_enter
    mov rax, [st_sb + SU_SEQ]
    cmp byte [r13], 0
    je .resolved
    mov rsi, r13
    call sc_resolve
    jc .leave
.resolved:
    call st_leave
    mov rbx, rax
    mov rsi, r12
    mov rdx, rbx
    call store_snap
    test rax, rax
    jnz .refused
    KLOG "store: snapshot %s is #%u", r12, rbx
    jmp .out
.refused:
    lea rdi, [str_sc_snap]
    call sc_err
.out:
    pop r13
    pop r12
    pop rbx
    ret

sc_unsnap:
    call arg_split
    push rsi
    call store_unsnap
    pop rsi
    test rax, rax
    jnz .refused
    KLOG "store: snapshot %s gone (its commit stays)", rsi
    ret
.refused:
    lea rdi, [str_sc_unsnap]
    jmp sc_err

sc_rollback:
    push rbx
    call arg_split
    mov rbx, rdi                        ; why, perhaps
    call st_enter
    call sc_resolve
    call st_leave
    jc .out
    mov rsi, rax
    jmp sc_back
.out:
    pop rbx
    ret

sc_undo:
    push rbx
    lea rbx, [str_sc_undo]
    call st_enter
    mov rax, [st_sb + SU_SEQ]
    call st_leave
    test rax, rax
    jnz .some
    KLOG "store undo: nothing to undo"
    pop rbx
    ret
.some:
    lea rsi, [rax - 1]
    ; fall through
; sc_back(RSI = the commit to go back to, RBX = why), RBX pushed
sc_back:
    xor edi, edi
    mov rdx, rbx
    mov ecx, RT_ALL
    call store_rollback
    cmp rax, E_ANY
    jae .refused
    call st_enter
    KLOG "store: commit #%u", rax
    call sc_show
    call st_leave
    jmp .out
.refused:
    lea rdi, [str_sc_rollback]
    call sc_err
.out:
    pop rbx
    ret

sc_verify:
    call store_verify
    test rax, rax
    jnz .failed
    KLOG "store verify: passed"
    ret
.failed:
    KLOG "store verify: FAILED"
    ret

sc_format:
    push rbx
    push rcx
    push r12
    call arg_split
    lea rdi, [str_sc_again]
    call streq
    mov r12d, eax                       ; 'again'
    xor ecx, ecx
.disk:
    cmp ecx, [disk_count]
    jae .refused
    imul rbx, rcx, DK_SIZE
    lea rax, [disks]
    add rbx, rax
    inc ecx
    test dword [rbx + DK_FLAGS], DKF_GONE
    jnz .disk
    call st_allowed
    test eax, eax
    jz .disk
    cmp [st_disk], rbx
    jne .format
    test r12d, r12d
    jnz .format
    KLOG "store format: disk%u holds a store already ('store format again' starts it over)", qword [rbx + DK_INDEX]
    jmp .out
.format:
    call store_format
    jmp .out
.refused:
    KLOG "store format: refused: only QEMU's test drive (NVMe, serial AXIOMTEST) may hold a store, and there is none"
.out:
    pop r12
    pop rcx
    pop rbx
    ret

; -----------------------------------------------------------------------------
;  store test
; -----------------------------------------------------------------------------

; stt_fail(RDI = what failed): said
stt_fail:
    KLOG "store test: FAILED: %s", rdi
    inc dword [stt_failed]
    ret

; stt_put(RDI = a store object, RSI = a whole name, RDX = bytes, RCX = how
; many) -> RAX = what store_put says, 0 if staged
stt_put:
    push rcx
    push rdx
    push rsi
    push rdi
    push r12
    mov r12, rdx
    push rdi
    lea rdi, [rcx + 1]
    call kmalloc
    pop rdi
    test rax, rax
    jz .nomem
    push rdi
    push rsi
    push rcx
    mov rdi, rax
    mov rsi, r12
    rep movsb
    pop rcx
    pop rsi
    pop rdi
    mov rdx, rax
    call store_put
    jmp .out
.nomem:
    mov rax, E_NOMEM
.out:
    pop r12
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    ret

; stt_text(RDI = a store object, RSI = a whole name, RDX = NUL-ended text)
; -> RAX as stt_put
stt_text:
    push rcx
    push rdi
    mov rdi, rdx
    call strlen
    mov rcx, rax
    pop rdi
    call stt_put
    pop rcx
    ret

; stt_is(RDI = a store object or 0, RSI = a whole name, RDX = bytes, RCX =
; how many) -> ZF if the name holds exactly those, as that object sees it
stt_is:
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    mov r8, rdx
    mov r9, rcx
    call store_get
    cmp rax, E_ANY
    jae .no
    cmp rdx, r9
    jne .no_free
    mov rsi, rax
    mov rdi, r8
    mov rcx, r9
    repe cmpsb
    pushfq
    mov rdi, rax
    call st_free
    popfq
    jmp .out
.no_free:
    mov rdi, rax
    call st_free
.no:
    test rsp, rsp                       ; ZF clear
.out:
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    ret

; stt_is_text(RDI, RSI, RDX = NUL-ended) -> ZF as stt_is
stt_is_text:
    push rcx
    push rdi
    mov rdi, rdx
    call strlen
    mov rcx, rax
    pop rdi
    call stt_is
    pop rcx
    ret

; stt_none(RDI = a store object or 0, RSI = a whole name) -> ZF if it holds
; nothing, as that object sees it
stt_none:
    push rdx
    call store_get
    cmp rax, E_ANY
    jb .some
    cmp rax, E_NONAME
    pop rdx
    ret
.some:
    push rdi
    mov rdi, rax
    call st_free
    pop rdi
    test rsp, rsp
    pop rdx
    ret

; stt_cm(RAX = a commit's number) -> st_vcm holds it; CF if unreadable
stt_cm:
    call st_enter
    push rdi
    lea rdi, [st_vcm]
    call st_commit_of
    pop rdi
    call st_leave
    ret

; stt_clean(RDI = the test's capability, under "test/"): every name under it
; removed and committed, so a run starts as the last one did
stt_clean:
    push rbx
    push rcx
    push rdx
    push rsi
    push r12
    push r13
    mov r12, rdi
    mov edi, ST_LIST_MAX
    call vm_alloc
    test rax, rax
    jz .out
    mov r13, rax
    mov rdi, r12
    mov rsi, r13
    mov edx, ST_LIST_MAX
    call store_list
    mov ebx, eax
    mov rsi, r13
.name:
    test ebx, ebx
    jz .staged
    mov rdx, rsi
    push rsi
    lea rsi, [str_stt_prefix]
    lea rdi, [sc_whole]
    call st_join
    pop rsi
    jc .skip
    push rsi
    mov rdi, r12
    lea rsi, [sc_whole]
    call store_del
    pop rsi
.skip:
    lodsb                               ; past this name
    test al, al
    jnz .skip
    dec ebx
    jmp .name
.staged:
    mov rdi, r12
    lea rsi, [str_stt_clean]
    mov ecx, RT_ALL
    call store_commit
    mov rdi, r12
    call store_abort
    mov rdi, r13
    call st_free
.out:
    pop r13
    pop r12
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

store_test:
    push rbx
    push rbp
    push r12
    push r13
    push r14
    push r15
    mov dword [stt_checks], 0
    mov dword [stt_failed], 0
    cmp qword [st_disk], 0
    je .unwritable
    cmp byte [st_writable], 0
    je .unwritable
    lea rsi, [str_stt_prefix]           ; capabilities of its own: T and U
    call st_obj_new                     ; under "test/", V under "test/sub/"
    mov r12, rax
    call st_obj_new
    mov r13, rax
    lea rsi, [str_stt_sub]
    call st_obj_new
    mov r14, rax
    test r12, r12
    jz .nomem
    test r13, r13
    jz .nomem
    test r14, r14
    jz .nomem
    mov rdi, r12
    call stt_clean
    lea rsi, [str_stt_snap]
    call store_unsnap

    mov rbx, [st_sb + SU_OBJECTS]       ; three names, two of them the same bytes
    mov edi, STT_BIG
    call vm_alloc
    test rax, rax
    jz .nomem
    mov rbp, rax                        ; the big one: a pattern
    xor ecx, ecx
.pattern:
    mov eax, ecx
    imul eax, eax, 7
    mov edx, ecx
    shr edx, 9
    add eax, edx
    mov [rbp + rcx], al
    inc ecx
    cmp ecx, STT_BIG
    jb .pattern
    mov rdi, r12
    lea rsi, [str_stt_a]
    lea rdx, [str_stt_alpha]
    call stt_text
    test rax, rax
    STT z, "a name staged"
    lea rsi, [str_stt_c]
    lea rdx, [str_stt_alpha]
    call stt_text
    lea rsi, [str_stt_b]
    mov rdx, rbp
    mov ecx, STT_BIG
    call stt_put
    test rax, rax
    STT z, "300 KiB staged"
    lea rsi, [str_stt_why1]
    mov ecx, RT_ALL
    call store_commit
    mov r15, rax                        ; the first commit
    cmp rax, E_ANY
    STT b, "the first commit"
    mov rax, [st_sb + SU_OBJECTS]
    sub rax, rbx
    cmp rax, 4
    STT e, "four objects for three names: two blobs (the same bytes once), a tree, a commit"
    xor edi, edi
    lea rsi, [str_stt_a]
    lea rdx, [str_stt_alpha]
    call stt_is_text
    STT e, "a read back"
    lea rsi, [str_stt_c]
    call stt_is_text
    STT e, "c read back"
    lea rsi, [str_stt_b]
    mov rdx, rbp
    mov ecx, STT_BIG
    call stt_is
    STT e, "300 KiB read back"
    lea rsi, [str_stt_snap]
    mov rdx, r15
    call store_snap
    test rax, rax
    STT z, "a snapshot of it"

    mov rdi, r12                        ; one changed, one removed
    lea rsi, [str_stt_a]
    lea rdx, [str_stt_beta]
    call stt_text
    lea rsi, [str_stt_b]
    call store_del
    test rax, rax
    STT z, "a removal staged"
    lea rsi, [str_stt_why2]
    mov ecx, RT_ALL
    call store_commit
    mov rbx, rax                        ; the second
    cmp rax, E_ANY
    STT b, "the second commit"
    mov rax, rbx
    call stt_cm
    STT nc, "the second commit read"
    cmp dword [st_vcm + CM_CHANGED], 1
    STT e, "it says one name changed"
    cmp dword [st_vcm + CM_REMOVED], 1
    STT e, "and one removed"
    cmp dword [st_vcm + CM_ADDED], 0
    STT e, "and none added"
    mov rax, r15
    call st_chain_at
    mov rsi, rax
    lea rdi, [st_vcm + CM_PARENT]
    call st_hash_eq
    STT e, "it comes after the first"
    xor edi, edi
    lea rsi, [str_stt_a]
    lea rdx, [str_stt_beta]
    call stt_is_text
    STT e, "a holds what it was changed to"
    lea rsi, [str_stt_b]
    call stt_none
    STT e, "b is gone"

    mov rdi, r12                        ; staged: seen through its own transaction alone
    lea rsi, [str_stt_d]
    lea rdx, [str_stt_delta]
    call stt_text
    call stt_is_text
    STT e, "a transaction reads what it staged"
    xor edi, edi
    call stt_none
    STT e, "and no other does"
    mov rdi, r12
    call store_abort
    cmp rax, 1
    STT e, "abort drops it"
    call stt_none
    STT e, "and it is gone"
    call store_commit
    cmp rax, E_EMPTY
    STT e, "nothing staged: nothing to commit"

    mov rdi, r12                        ; two transactions, one name
    lea rsi, [str_stt_e]
    lea rdx, [str_stt_one]
    call stt_text
    mov rdi, r13
    lea rdx, [str_stt_two]
    call stt_text
    mov rdi, r12
    lea rsi, [str_stt_why3]
    mov ecx, RT_ALL
    call store_commit
    cmp rax, E_ANY
    STT b, "the first of two transactions commits"
    mov rdi, r13
    call store_commit
    cmp rax, E_CONFLICT
    STT e, "the second, on the name the first changed, is refused"
    call store_abort
    xor edi, edi
    lea rsi, [str_stt_e]
    lea rdx, [str_stt_one]
    call stt_is_text
    STT e, "the first's change stands"
    mov rdi, r12
    call stt_text
    lea rsi, [str_stt_why3]
    call store_commit
    cmp rax, E_EMPTY
    STT e, "staging what is there already changes nothing"
    call store_abort

    mov rdi, r12                        ; back to the snapshot
    mov rsi, r15
    lea rdx, [str_stt_why4]
    mov ecx, RT_ALL
    call store_rollback
    mov [stt_back], rax
    cmp rax, E_ANY
    STT b, "a rollback to the first commit"
    xor edi, edi
    lea rsi, [str_stt_a]
    lea rdx, [str_stt_alpha]
    call stt_is_text
    STT e, "a holds what it did then"
    lea rsi, [str_stt_e]
    call stt_none
    STT e, "e, added since, is gone"
    lea rsi, [str_stt_b]
    call stt_none
    STT ne, "b is back"
    mov rax, [stt_back]
    call stt_cm
    cmp dword [st_vcm + CM_KIND], CK_ROLLBACK
    STT e, "it says it is a rollback"
    cmp [st_vcm + CM_TARGET], r15
    STT e, "to the first commit"
    lea rdi, [stt_tree]
    lea rsi, [st_vcm + CM_TREE]
    call st_hash_copy
    mov rax, r15
    call stt_cm
    lea rdi, [stt_tree]
    lea rsi, [st_vcm + CM_TREE]
    call st_hash_eq
    STT e, "its tree is the first commit's: the same object"

    mov rdi, r12                        ; undone
    mov rsi, [stt_back]
    dec rsi
    lea rdx, [str_stt_undo]
    mov ecx, RT_ALL
    call store_rollback
    cmp rax, E_ANY
    STT b, "the rollback undone"
    xor edi, edi
    lea rsi, [str_stt_a]
    lea rdx, [str_stt_beta]
    call stt_is_text
    STT e, "a as before the rollback"
    lea rsi, [str_stt_e]
    lea rdx, [str_stt_one]
    call stt_is_text
    STT e, "e as before the rollback"

    mov rax, [st_sb + SU_SEQ]           ; a rollback reaches its prefix alone
    mov [stt_back], rax
    mov rdi, r14
    lea rsi, [str_stt_x]
    lea rdx, [str_stt_x]
    call stt_text
    lea rsi, [str_stt_why5]
    mov ecx, RT_ST_ALL
    call store_commit
    mov rbx, rax
    cmp rax, E_ANY
    STT b, "a commit under test/sub/"
    mov rax, rbx
    call stt_cm
    mov rax, [r14 + OB_ID]
    cmp [st_vcm + CM_CAP], rax
    STT e, "it names the capability it came through"
    lea rdi, [st_vcm + CM_PREFIX]
    lea rsi, [str_stt_sub]
    call streq
    test eax, eax
    STT nz, "and what that capability reaches"
    lea rdi, [st_vcm + CM_REASON]
    lea rsi, [str_stt_why5]
    call streq
    test eax, eax
    STT nz, "and why"
    mov eax, [st_vcm + CM_RIGHTS]
    cmp eax, RT_ST_ALL
    STT e, "and its rights"
    mov rdi, r12
    lea rsi, [str_stt_a]
    lea rdx, [str_stt_gamma]
    call stt_text
    lea rsi, [str_stt_why6]
    mov ecx, RT_ALL
    call store_commit
    cmp rax, E_ANY
    STT b, "a commit outside test/sub/"
    mov rdi, r14
    mov rsi, [stt_back]
    lea rdx, [str_stt_why7]
    mov ecx, RT_ST_ALL
    call store_rollback
    cmp rax, E_ANY
    STT b, "a rollback under test/sub/"
    xor edi, edi
    lea rsi, [str_stt_x]
    call stt_none
    STT e, "test/sub/x is gone"
    lea rsi, [str_stt_a]
    lea rdx, [str_stt_gamma]
    call stt_is_text
    STT e, "test/a, outside it, is not"

    call store_verify
    test rax, rax
    STT z, "store verify"
    mov rdi, r12
    call stt_clean
    lea rsi, [str_stt_snap]
    call store_unsnap
    mov rdi, rbp
    call st_free
    jmp .free

.nomem:
    KLOG "store test: out of memory"
    inc dword [stt_failed]
.free:
    mov rdi, r12
    call stt_put_obj
    mov rdi, r13
    call stt_put_obj
    mov rdi, r14
    call stt_put_obj
    mov eax, [stt_checks]
    mov ecx, [stt_failed]
    KLOG "store test: %u checks, %u failed", rax, rcx
    test ecx, ecx
    jnz .failed
    KLOG "store test: passed"
    jmp .out
.failed:
    KLOG "store test: FAILED"
    jmp .out
.unwritable:
    KLOG "store test: no store to write to ('store format' makes one on QEMU's test drive)"
.out:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret

; stt_put_obj(RDI = an object or 0): its reference dropped
stt_put_obj:
    test rdi, rdi
    jz .out
    call obj_put
.out:
    ret

section .rodata
str_sc_put:     db 'store put', 0
str_sc_get:     db 'store get', 0
str_sc_rm:      db 'store rm', 0
str_sc_ls:      db 'ls', 0
str_sc_diff:    db 'diff', 0
str_sc_commit:  db 'store commit', 0
str_sc_abort:   db 'abort', 0
str_sc_log:     db 'log', 0
str_sc_snap:    db 'store snap', 0
str_sc_unsnap:  db 'store unsnap', 0
str_sc_rollback: db 'store rollback', 0
str_sc_undo:    db 'undo', 0
str_sc_verify:  db 'verify', 0
str_sc_format:  db 'format', 0
str_sc_tear:    db 'tear', 0
str_sc_again:   db 'again', 0
str_sc_head:    db 'head', 0
str_sc_all:     db 'everything', 0
str_sc_ok:      db 0
str_sc_conflict: db '  (CONFLICT: the head changed it since)', 0
str_sc_when:    db '0000-00-00 00:00:00', 0
sc_when_at:     db 18, 17, 15, 14, 12, 11, 9, 8, 6, 5, 3, 2, 1, 0
str_stt_prefix: db 'test/', 0
str_stt_sub:    db 'test/sub/', 0
str_stt_snap:   db 'test-1', 0
str_stt_a:      db 'test/a', 0
str_stt_b:      db 'test/b', 0
str_stt_c:      db 'test/c', 0
str_stt_d:      db 'test/d', 0
str_stt_e:      db 'test/e', 0
str_stt_x:      db 'test/sub/x', 0
str_stt_alpha:  db 'alpha', 0
str_stt_beta:   db 'beta', 0
str_stt_gamma:  db 'gamma', 0
str_stt_delta:  db 'delta', 0
str_stt_one:    db 'one', 0
str_stt_two:    db 'two', 0
str_stt_why1:   db 'store test: three names, two the same', 0
str_stt_why2:   db 'store test: a changed, b removed', 0
str_stt_why3:   db 'store test: e, from the first of two', 0
str_stt_why4:   db 'store test: back to test-1', 0
str_stt_why5:   db 'store test: x, under test/sub/', 0
str_stt_why6:   db 'store test: a, outside test/sub/', 0
str_stt_why7:   db 'store test: test/sub/ back', 0
str_stt_clean:  db 'store test: a clean slate', 0
str_stt_undo:   db 'store test: undo', 0

align 8
store_cmds:     dq str_sc_put + 6, sc_put
                dq str_sc_get + 6, sc_get
                dq str_sc_rm + 6, sc_rm
                dq str_sc_ls, sc_ls
                dq str_sc_diff, sc_diff
                dq str_sc_commit + 6, sc_commit
                dq str_sc_abort, sc_abort
                dq str_sc_log, sc_log
                dq str_sc_snap + 6, sc_snap
                dq str_sc_unsnap + 6, sc_unsnap
                dq str_sc_rollback + 6, sc_rollback
                dq str_sc_undo, sc_undo
                dq str_sc_verify, sc_verify
                dq str_sc_format, sc_format
                dq str_sc_tear, sc_tear
                dq str_ob_test, store_test
                dq 0

section .bss
alignb 8
stt_back:       resq 1
stt_checks:     resd 1
stt_failed:     resd 1
stt_tree:       resb 32
sc_whole:       resb ST_NAME
sc_hex:         resb 24
sc_time:        resb 24
sc_rights:      resb 128
