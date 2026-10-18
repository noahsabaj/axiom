; =============================================================================
;  object.asm - kernel objects, and the capabilities tasks hold to them
;
;  Everything the kernel hands out is an object: a task, a thread, an event,
;  a block of memory. Each begins with the same header (OB_*): its type, a
;  reference count, an id never reused, a name, the task that made it, and
;  how many capabilities point at it. The live objects of each type are on
;  that type's list (obj_types), to be counted and shown.
;
;  A task acts only through capabilities, held in its handle table. A handle
;  is a slot's index and that slot's generation: it means nothing in another
;  task's table, and once closed it means nothing in its own. A capability
;  says what may be done with its object (RT_*: dup, give and info for any,
;  and its type's own), until when, and, for memory, which bytes. From one,
;  its holder derives more with the same rights or fewer, an expiry no later,
;  a window no wider (handle_dup, handle_window); hands one to another task
;  (handle_give); and takes back every capability derived from one, wherever
;  it went (handle_revoke): a revoked handle says so until its holder closes
;  it. A capability to memory its holder has mapped (user.asm) takes the
;  mapping with it when it goes, is revoked, or is given away. Each capability is in the tree of the one it came from; closing one
;  moves those derived from it up to its parent, so a revoke still reaches
;  them.
;
;  When the last capability to an object goes, its type hears of it
;  (TY_ORPHAN): a ring cancels what still waits on it, and a task with no
;  thread left ends.
;
;  Each task counts its handle operations and the refusals among them.
;  Whatever changes the capabilities (made, derived, given, closed, revoked,
;  a task's last ones closed when it ends) and every refusal goes into an
;  audit ring, which 'objects audit' shows.
;
;  Locks: cap_lock covers every handle table and every capability tree,
;  taken with interrupts off; each type's list has a lock of its own, taken
;  alone. Nothing is freed with a lock held: an operation takes what it
;  removes out from under the lock, and drops the references after.
;
;  The handle operations act for the task of the thread that calls them:
;    handle_get(EDI = handle, ESI = OT_* or 0, EDX = rights it needs) -> RAX
;      = the object, with a reference to obj_put; RDX, RCX = the window
;    handle_info(EDI) -> RAX = OT_*, RDX = rights, RCX = the object's id
;    handle_dup(EDI, ESI = rights to keep, RDX = expiry TSC or 0) -> RAX =
;      a new handle (needs RT_DUP)
;    handle_window(EDI, RSI = offset, RDX = length, ECX = rights to keep) ->
;      RAX = a new handle to part of a memory object (needs RT_DUP)
;    handle_give(EDI, ESI = a task's handle) -> RAX = the handle it has in
;      that task now (needs RT_GIVE, and RT_TASK_HANDLES on the task)
;    handle_revoke(EDI) -> RAX = how many capabilities derived from it went
;    handle_close(EDI) -> RAX = 0
;  Each returns E_* (negative) when refused.
; =============================================================================

HT_FIRST        equ 64                  ; slots in a new handle table
HT_MAX          equ 0x10000
AUDIT_LEN       equ 256                 ; records kept, a power of two

; the description of each type
TY_NAME         equ 0
TY_DESTROY      equ 8                   ; (RDI = the object) when its last reference goes
TY_LIST         equ 16
TY_LIVE         equ 24
TY_MADE         equ 32
TY_LOCK         equ 40                  ; dword
TY_RIGHTS       equ 48                  ; the names of its rights, 16 of them
TY_ORPHAN       equ 56                  ; (RDI) when its last capability goes, or 0
TY_SIZE         equ 64

; an audit record
AU_TSC          equ 0
AU_OBJ          equ 8                   ; the object's id, 0 if none
AU_TASK         equ 16                  ; dword: the task acting
AU_HANDLE       equ 20                  ; dword
AU_RIGHTS       equ 24                  ; dword: those it has, or those it needed
AU_OTHER        equ 28                  ; dword: a new handle, a task, a count
AU_OP           equ 32                  ; byte AO_*
AU_ERR          equ 33                  ; byte: the error, negated; 0 = done
AU_TYPE         equ 34                  ; byte: the object's
AU_SIZE         equ 48

AO_MAKE         equ 1
AO_DUP          equ 2
AO_WINDOW       equ 3
AO_GIVE         equ 4
AO_CLOSE        equ 5
AO_REVOKE       equ 6
AO_USE          equ 7                   ; a refusal, only
AO_END          equ 8                   ; a task ended: its handles closed
AO_COUNT        equ 9

%macro CAP_LOCK 0                       ; interrupts off; flags stay on the stack
    pushfq
    cli
    push rdi
    lea rdi, [cap_lock]
    call spin_lock
    pop rdi
%endmacro

%macro CAP_UNLOCK 0
    push rdi
    lea rdi, [cap_lock]
    call spin_unlock
    pop rdi
    popfq
%endmacro

; AUDIT op, error, object, handle, rights, other: 64-bit registers,
; immediates or qword [mem]; R12 = the task acting; cap_lock held
%macro AUDIT 6
    push rdi
    push rsi
    push rdx
    push rcx
    push r8
    push r9
    push %6
    push %5
    push %4
    push %3
    push %2
    push %1
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop r8
    pop r9
    call audit
    pop r9
    pop r8
    pop rcx
    pop rdx
    pop rsi
    pop rdi
%endmacro

section .text

; -----------------------------------------------------------------------------
;  Objects
; -----------------------------------------------------------------------------

; obj_boot: before the scheduler, the task everything at boot acts for
obj_boot:
    lea rdi, [str_task_kernel]
    xor esi, esi
    call task_new
    test rax, rax
    jz .oom
    mov [task_kernel], rax
    ret
.oom:
    xor edi, edi
    lea rsi, [str_obj_oom]
    jmp panic

; obj_init(RDI = zeroed memory, ESI = OT_*, RDX = name or 0) -> RAX = it: an
; object with one reference, an id and its maker, on its type's list.
; Preserves others.
obj_init:
    push rbx
    push rcx
    push rsi
    push rdi
    mov rbx, rdi
    mov [rbx + OB_TYPE], esi
    mov dword [rbx + OB_REFS], 1
    mov eax, 1
    lock xadd [obj_next_id], rax
    mov [rbx + OB_ID], rax
    call cur_task
    test rax, rax
    jz .maker
    mov rax, [rax + OB_ID]
.maker:
    mov [rbx + OB_MAKER], eax
    test rdx, rdx
    jz .named
    lea rdi, [rbx + OB_NAME]
    mov rsi, rdx
    mov ecx, OB_NAME_LEN - 1
.copy:
    lodsb
    test al, al
    jz .named
    stosb
    dec ecx
    jnz .copy
.named:
    mov rdi, rbx
    call obj_link
    mov rax, rbx
    pop rdi
    pop rsi
    pop rcx
    pop rbx
    ret

; obj_new(EDI = OT_*, ESI = bytes, RDX = name or 0) -> RAX = a zeroed object
; from the heap (as obj_init gives), or 0 if out of memory
obj_new:
    push rdi
    mov edi, esi
    call kmalloc
    pop rsi
    test rax, rax
    jz .out
    mov rdi, rax
    jmp obj_init
.out:
    ret

; obj_type(RDI = object) -> RAX = its type's description. Preserves others.
obj_type:
    mov eax, [rdi + OB_TYPE]
    shl eax, 6
    push rcx
    lea rcx, [obj_types]
    add rax, rcx
    pop rcx
    ret

; obj_link(RDI) / obj_unlink(RDI): on or off its type's list. Preserve all.
obj_link:
    push rax
    push rcx
    pushfq
    cli
    call obj_type
    mov rcx, rax
    push rdi
    lea rdi, [rcx + TY_LOCK]
    call spin_lock
    pop rdi
    mov rax, [rcx + TY_LIST]
    mov [rdi + OB_NEXT], rax
    mov qword [rdi + OB_PREV], 0
    test rax, rax
    jz .first
    mov [rax + OB_PREV], rdi
.first:
    mov [rcx + TY_LIST], rdi
    inc qword [rcx + TY_LIVE]
    inc qword [rcx + TY_MADE]
    push rdi
    lea rdi, [rcx + TY_LOCK]
    call spin_unlock
    pop rdi
    popfq
    pop rcx
    pop rax
    ret

obj_unlink:
    push rax
    push rcx
    push rdx
    pushfq
    cli
    call obj_type
    mov rdx, rax
    push rdi
    lea rdi, [rdx + TY_LOCK]
    call spin_lock
    pop rdi
    mov rax, [rdi + OB_NEXT]
    mov rcx, [rdi + OB_PREV]
    test rax, rax
    jz .no_next
    mov [rax + OB_PREV], rcx
.no_next:
    test rcx, rcx
    jz .head
    mov [rcx + OB_NEXT], rax
    jmp .linked
.head:
    mov [rdx + TY_LIST], rax
.linked:
    xor eax, eax
    mov [rdi + OB_NEXT], rax
    mov [rdi + OB_PREV], rax
    dec qword [rdx + TY_LIVE]
    push rdi
    lea rdi, [rdx + TY_LOCK]
    call spin_unlock
    pop rdi
    popfq
    pop rdx
    pop rcx
    pop rax
    ret

; obj_get(RDI): one more reference. obj_put(RDI): one fewer; the last
; destroys it, so never from an interrupt handler nor with a lock held.
; Both preserve all.
obj_get:
    lock inc dword [rdi + OB_REFS]
    ret

; obj_tryget(RDI = an object found on its type's list, that lock held) ->
; one more reference, or CF if it has none left (it is on its way out).
; Preserves all.
obj_tryget:
    push rax
    push rcx
    mov eax, [rdi + OB_REFS]
.again:
    test eax, eax
    jz .gone
    lea ecx, [rax + 1]
    lock cmpxchg [rdi + OB_REFS], ecx
    jne .again
    pop rcx
    pop rax
    clc
    ret
.gone:
    pop rcx
    pop rax
    stc
    ret

obj_put:
    lock dec dword [rdi + OB_REFS]
    jz .last
    js .under
    ret
.last:
    push rax
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    push r11
    call obj_type
    call [rax + TY_DESTROY]
    pop r11
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rax
    ret
.under:
    xor edi, edi
    lea rsi, [str_obj_under]
    jmp panic

; obj_orphaned(RDI): its last capability went; its type's TY_ORPHAN, if it
; has one. No lock held. Preserves all.
obj_orphaned:
    push rax
    call obj_type
    cmp qword [rax + TY_ORPHAN], 0
    je .none
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    push r11
    call [rax + TY_ORPHAN]
    pop r11
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
.none:
    pop rax
    ret

; obj_free(RDI): off its list, back to the heap (a type's destroy, or the
; end of one)
obj_free:
    call obj_unlink
    jmp kfree

; cur_task -> RAX = the task the running thread acts for. Preserves others.
cur_task:
    mov rax, [gs:PC_CURRENT]
    test rax, rax
    jz .kernel
    mov rax, [rax + TH_TASK]
    test rax, rax
    jnz .out
.kernel:
    mov rax, [task_kernel]
.out:
    ret

; op_done(RAX = an operation's result, an E_* if refused): counted for the current task.
; Preserves all.
op_done:
    push rcx
    push rax
    call cur_task
    mov rcx, rax
    pop rax
    lock inc qword [rcx + TK_OPS]
    cmp rax, E_ANY
    jb .out
    lock inc qword [rcx + TK_DENIED]
.out:
    pop rcx
    ret

; -----------------------------------------------------------------------------
;  Handle tables, with cap_lock held unless said otherwise
; -----------------------------------------------------------------------------

; ht_init(RDI = a new task) -> RAX = 0, or E_NOMEM: an empty table. No lock.
ht_init:
    push rbx
    push rcx
    push rdi
    mov rbx, rdi
    mov edi, HT_FIRST * HS_SIZE
    call kmalloc
    test rax, rax
    jz .nomem
    mov [rbx + TK_SLOTS], rax
    mov dword [rbx + TK_NSLOTS], HT_FIRST
    mov rdi, rax
    mov eax, 1                          ; slot 0 is never used: no handle is 0
    mov ecx, HT_FIRST
    call ht_chain
    mov dword [rbx + TK_FREE], 1
    xor eax, eax
    jmp .out
.nomem:
    mov rax, E_NOMEM
.out:
    pop rdi
    pop rcx
    pop rbx
    ret

; ht_chain(RDI = slots, EAX = first, ECX = end): [first, end) free, chained
; in order. Preserves all.
ht_chain:
    push rax
    push rdx
.slot:
    mov edx, eax
    shl rdx, 4
    add rdx, rdi
    mov qword [rdx + HS_CAP], 0
    mov word [rdx + HS_GEN], 1
    mov word [rdx + HS_STATE], HSS_FREE
    inc eax
    cmp eax, ecx
    jb .linked
    mov dword [rdx + HS_NEXT], 0        ; the last
    pop rdx
    pop rax
    ret
.linked:
    mov [rdx + HS_NEXT], eax
    jmp .slot

; ht_grow(RDI = a task) -> RAX = 0, E_NOMEM or E_FULL: twice the slots. No
; lock held; the caller keeps the task alive.
ht_grow:
    push rbx
    push rcx
    push rsi
    push rdi
    push r12
    push r13
    mov r12, rdi
    mov r13d, [r12 + TK_NSLOTS]         ; checked again under the lock
    cmp r13d, HT_MAX
    jae .full
    lea edi, [r13 * 2]
    shl edi, 4
    call kmalloc
    test rax, rax
    jz .nomem
    mov rbx, rax
    CAP_LOCK
    cmp [r12 + TK_NSLOTS], r13d
    jne .raced                          ; another grew it meanwhile
    cmp dword [r12 + TK_FREE], 0
    jne .raced                          ; or a slot came free
    mov rsi, [r12 + TK_SLOTS]
    mov rdi, rbx
    mov ecx, r13d
    shl ecx, 1                          ; two qwords a slot
    rep movsq
    mov rdi, rbx
    mov eax, r13d
    lea ecx, [r13 * 2]
    call ht_chain
    mov [r12 + TK_FREE], r13d
    mov [r12 + TK_NSLOTS], ecx
    xchg rbx, [r12 + TK_SLOTS]          ; RBX = the old, to free
.raced:
    CAP_UNLOCK
    mov rdi, rbx                        ; whichever is not in use
    call kfree
    xor eax, eax
    jmp .out
.full:
    mov rax, E_FULL
    jmp .out
.nomem:
    mov rax, E_NOMEM
.out:
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rcx
    pop rbx
    ret

; ht_take(R12 = task) -> EAX = a slot taken, 0 if none is free. Preserves
; others.
ht_take:
    mov eax, [r12 + TK_FREE]
    test eax, eax
    jz .out
    push rcx
    push rdx
    mov edx, eax
    shl rdx, 4
    add rdx, [r12 + TK_SLOTS]
    mov ecx, [rdx + HS_NEXT]
    mov [r12 + TK_FREE], ecx
    mov word [rdx + HS_STATE], HSS_USED
    inc dword [r12 + TK_USED]
    pop rdx
    pop rcx
.out:
    ret

; ht_set(R12 = task, EAX = a slot taken, RBX = a capability) -> RAX = its
; handle. Preserves others.
ht_set:
    push rdx
    mov edx, eax
    shl rdx, 4
    add rdx, [r12 + TK_SLOTS]
    mov [rdx + HS_CAP], rbx
    mov [rbx + CAP_TASK], r12
    mov [rbx + CAP_SLOT], eax
    movzx edx, word [rdx + HS_GEN]
    shl edx, 16
    or eax, edx
    pop rdx
    ret

; ht_release(R12 = task, EAX = a slot): free again, under a new generation.
; Preserves all.
ht_release:
    push rcx
    push rdx
    mov edx, eax
    shl rdx, 4
    add rdx, [r12 + TK_SLOTS]
    mov qword [rdx + HS_CAP], 0
    mov word [rdx + HS_STATE], HSS_FREE
    movzx ecx, word [rdx + HS_GEN]
    inc ecx
    cmp ecx, 0x7FFF
    jbe .gen
    mov ecx, 1
.gen:
    mov [rdx + HS_GEN], cx
    mov ecx, [r12 + TK_FREE]
    mov [rdx + HS_NEXT], ecx
    mov [r12 + TK_FREE], eax
    dec dword [r12 + TK_USED]
    pop rdx
    pop rcx
    ret

; cap_find(R12 = task, ESI = handle) -> RAX = its capability, or E_BADH or
; E_REVOKED; RDX = its slot. Clobbers RCX.
cap_find:
    mov rax, E_BADH
    mov ecx, esi
    and ecx, 0xFFFF
    jz .out
    cmp ecx, [r12 + TK_NSLOTS]
    jae .out
    mov edx, ecx
    shl rdx, 4
    add rdx, [r12 + TK_SLOTS]
    mov ecx, esi
    shr ecx, 16
    cmp cx, [rdx + HS_GEN]              ; bit 31 set never matches
    jne .out
    cmp word [rdx + HS_STATE], HSS_USED
    je .used
    cmp word [rdx + HS_STATE], HSS_REVOKED
    jne .out
    mov rax, E_REVOKED
    ret
.used:
    mov rax, [rdx + HS_CAP]
    test rax, rax                       ; emptied by cap_drop_all: its task is
    jnz .out                            ; ending, while a request it made runs
    mov rax, E_BADH
.out:
    ret

; cap_check(RAX = a capability, ECX = OT_* or 0 for any, R8D = rights it
; needs) -> RAX = it, or E_TYPE, E_RIGHTS or E_EXPIRED. Preserves others.
cap_check:
    push rdx
    push r9
    mov r9, rax
    test ecx, ecx
    jz .typed
    mov rdx, [r9 + CAP_OBJ]
    cmp [rdx + OB_TYPE], ecx
    mov rax, E_TYPE
    jne .out
.typed:
    mov edx, [r9 + CAP_RIGHTS]
    and edx, r8d
    cmp edx, r8d
    mov rax, E_RIGHTS
    jne .out
    cmp qword [r9 + CAP_EXPIRES], 0
    je .fine
    RDTSC64
    cmp rax, [r9 + CAP_EXPIRES]
    mov rax, E_EXPIRED
    jae .out
.fine:
    mov rax, r9
.out:
    pop r9
    pop rdx
    ret

; cap_link(RDI = a capability, RSI = the one it is derived from). Preserves
; all.
cap_link:
    push rax
    mov [rdi + CAP_PARENT], rsi
    mov rax, [rsi + CAP_CHILD]
    mov [rdi + CAP_SIBLING], rax
    mov [rsi + CAP_CHILD], rdi
    pop rax
    ret

; cap_unlink(RDI = a capability): out of its tree; those derived from it go
; to its parent (or become roots). Preserves all.
cap_unlink:
    push rax
    push rcx
    push rdx
    push rsi
    mov rsi, [rdi + CAP_PARENT]
    test rsi, rsi
    jz .children
    lea rcx, [rsi + CAP_CHILD]          ; off its parent's list
.find:
    mov rax, [rcx]
    test rax, rax
    jz .children
    cmp rax, rdi
    je .found
    lea rcx, [rax + CAP_SIBLING]
    jmp .find
.found:
    mov rax, [rdi + CAP_SIBLING]
    mov [rcx], rax
.children:
    mov rcx, [rdi + CAP_CHILD]
.child:
    test rcx, rcx
    jz .done
    mov rdx, [rcx + CAP_SIBLING]
    mov [rcx + CAP_PARENT], rsi
    mov qword [rcx + CAP_SIBLING], 0
    test rsi, rsi
    jz .next
    mov rax, [rsi + CAP_CHILD]
    mov [rcx + CAP_SIBLING], rax
    mov [rsi + CAP_CHILD], rcx
.next:
    mov rcx, rdx
    jmp .child
.done:
    xor eax, eax
    mov [rdi + CAP_PARENT], rax
    mov [rdi + CAP_CHILD], rax
    mov [rdi + CAP_SIBLING], rax
    pop rsi
    pop rdx
    pop rcx
    pop rax
    ret

; audit(R12 = the task acting, RDI = AO_*, RSI = E_* or 0, RDX = the object
; or 0, ECX = a handle, R8D = rights, R9D = another number): a record in the
; ring. cap_lock held. Preserves all.
audit:
    push rax
    push rbx
    push rdx
    mov rbx, [audit_next]
    inc qword [audit_next]
    and ebx, AUDIT_LEN - 1
    imul rbx, rbx, AU_SIZE
    lea rax, [audit_ring]
    add rbx, rax
    RDTSC64
    mov [rbx + AU_TSC], rax
    pop rdx
    push rdx
    xor eax, eax
    mov [rbx + AU_OBJ], rax
    mov [rbx + AU_TYPE], al
    test rdx, rdx
    jz .no_obj
    mov rax, [rdx + OB_ID]
    mov [rbx + AU_OBJ], rax
    mov eax, [rdx + OB_TYPE]
    mov [rbx + AU_TYPE], al
.no_obj:
    mov rax, [r12 + OB_ID]
    mov [rbx + AU_TASK], eax
    mov [rbx + AU_OP], dil
    mov eax, esi
    neg eax
    mov [rbx + AU_ERR], al
    mov [rbx + AU_HANDLE], ecx
    mov [rbx + AU_RIGHTS], r8d
    mov [rbx + AU_OTHER], r9d
    pop rdx
    pop rbx
    pop rax
    ret

; -----------------------------------------------------------------------------
;  Making capabilities
; -----------------------------------------------------------------------------

; cap_new(RDI = task, RSI = an object (the caller's reference moves into the
; capability), EDX = rights) -> RAX = its handle in that task, or E_NOMEM or
; E_FULL, and the reference is dropped. The caller keeps the task alive.
cap_new:
    push rbx
    push r12
    push r13
    push r14
    mov r12, rdi
    mov r13, rsi
    mov r14d, edx
    mov edi, CAP_SIZE
    call kmalloc
    test rax, rax
    jz .nomem
    mov rbx, rax
    mov [rbx + CAP_OBJ], r13
    mov [rbx + CAP_RIGHTS], r14d
    cmp dword [r13 + OB_TYPE], OT_MEMORY
    jne .retry
    mov rax, [r13 + MO_BYTES]           ; all of it
    mov [rbx + CAP_LEN], rax
.retry:
    CAP_LOCK
    call ht_take
    test eax, eax
    jz .grow
    call ht_set
    lock inc dword [r13 + OB_CAPS]
    AUDIT AO_MAKE, 0, r13, rax, r14, 0
    CAP_UNLOCK
    jmp .out
.grow:
    CAP_UNLOCK
    mov rdi, r12
    call ht_grow
    test rax, rax
    jz .retry
    mov rdi, rbx
    call kfree
    jmp .drop
.nomem:
    mov rax, E_NOMEM
.drop:
    mov rdi, r13
    call obj_put
.out:
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; handle_new(RDI = an object, the caller's reference moving into it, ESI =
; rights) -> RAX = a handle in the current task (as cap_new)
handle_new:
    push rsi
    push rdi
    call cur_task
    pop rsi
    pop rdx
    mov rdi, rax
    jmp cap_new

; -----------------------------------------------------------------------------
;  Using them
; -----------------------------------------------------------------------------

handle_get:
    push rbx
    push r8
    push r9
    push r12
    push r13
    mov r13d, edi
    mov r9d, esi                        ; the type it should be
    mov r8d, edx                        ; the rights it needs
    call cur_task
    mov r12, rax
    xor ebx, ebx
    CAP_LOCK
    mov esi, r13d
    call cap_find
    cmp rax, E_ANY
    jae .refused
    mov rbx, rax
    mov ecx, r9d
    call cap_check
    cmp rax, E_ANY
    jae .refused
    mov rax, [rbx + CAP_OBJ]
    lock inc dword [rax + OB_REFS]
    mov rdx, [rbx + CAP_OFF]
    mov rcx, [rbx + CAP_LEN]
    CAP_UNLOCK
    jmp .out
.refused:
    xor edx, edx
    test rbx, rbx
    jz .say
    mov rdx, [rbx + CAP_OBJ]
.say:
    AUDIT AO_USE, rax, rdx, r13, r8, r9
    CAP_UNLOCK
.out:
    call op_done
    pop r13
    pop r12
    pop r9
    pop r8
    pop rbx
    ret

handle_info:
    push rbx
    push r12
    push r13
    mov r13d, edi
    call cur_task
    mov r12, rax
    CAP_LOCK
    mov esi, r13d
    call cap_find
    cmp rax, E_ANY
    jae .refused
    mov rbx, rax
    mov rax, [rbx + CAP_OBJ]
    mov rcx, [rax + OB_ID]
    mov eax, [rax + OB_TYPE]
    mov edx, [rbx + CAP_RIGHTS]
    CAP_UNLOCK
    jmp .out
.refused:
    AUDIT AO_USE, rax, 0, r13, 0, 0
    CAP_UNLOCK
.out:
    call op_done
    pop r13
    pop r12
    pop rbx
    ret

; -----------------------------------------------------------------------------
;  Deriving, giving, revoking, closing
; -----------------------------------------------------------------------------

handle_dup:
    xor ecx, ecx
    mov r8, -1                          ; the whole window
    mov r9d, AO_DUP
    jmp cap_derive

handle_window:
    mov r8, rdx                         ; the length
    mov eax, ecx
    mov rcx, rsi                        ; the offset
    mov esi, eax                        ; the rights to keep
    xor edx, edx
    mov r9d, AO_WINDOW
    jmp cap_derive

; cap_derive(EDI = handle, ESI = rights to keep, RDX = expiry or 0, RCX =
; window offset, R8 = window length or -1 for the same, R9D = AO_*) -> RAX
; = a new handle in the current task
cap_derive:
    push rbx
    push rbp
    push r12
    push r13
    push r14
    push r15
    sub rsp, 16
    mov r13d, edi
    mov r14d, esi
    mov r15, rdx
    mov [rsp], rcx
    mov [rsp + 8], r8
    mov ebp, r9d
    call cur_task
    mov r12, rax
    mov edi, CAP_SIZE
    call kmalloc
    test rax, rax
    jz .nomem
    mov rbx, rax                        ; the new capability
    mov rcx, [rsp]
    mov [rbx + CAP_OFF], rcx
    mov rcx, [rsp + 8]
    mov [rbx + CAP_LEN], rcx
.retry:
    CAP_LOCK
    mov esi, r13d
    call cap_find
    cmp rax, E_ANY
    jae .refused
    xor ecx, ecx
    mov r8d, RT_DUP
    call cap_check
    cmp rax, E_ANY
    jae .refused
    mov rsi, rax                        ; the one it comes from
    mov rdx, [rsi + CAP_OBJ]
    cmp qword [rbx + CAP_LEN], -1
    je .whole
    mov rax, E_TYPE                     ; a window: memory only, inside its own
    cmp dword [rdx + OB_TYPE], OT_MEMORY
    jne .refused
    mov rax, E_ARG
    cmp qword [rbx + CAP_LEN], 0
    je .refused
    mov rax, E_RANGE
    mov rcx, [rsi + CAP_LEN]
    sub rcx, [rbx + CAP_OFF]
    jb .refused
    cmp [rbx + CAP_LEN], rcx
    ja .refused
    mov rcx, [rsi + CAP_OFF]
    add [rbx + CAP_OFF], rcx
    jmp .placed
.whole:
    mov rcx, [rsi + CAP_OFF]
    mov [rbx + CAP_OFF], rcx
    mov rcx, [rsi + CAP_LEN]
    mov [rbx + CAP_LEN], rcx
.placed:
    call ht_take
    test eax, eax
    jz .grow
    mov [rbx + CAP_OBJ], rdx
    lock inc dword [rdx + OB_REFS]
    lock inc dword [rdx + OB_CAPS]
    mov ecx, [rsi + CAP_RIGHTS]         ; never more than it had
    and ecx, r14d
    mov [rbx + CAP_RIGHTS], ecx
    mov rcx, [rsi + CAP_EXPIRES]        ; never later
    test r15, r15
    jz .expiry
    test rcx, rcx
    jz .asked
    cmp r15, rcx
    jae .expiry
.asked:
    mov rcx, r15
.expiry:
    mov [rbx + CAP_EXPIRES], rcx
    mov rdi, rbx
    call cap_link
    call ht_set
    AUDIT rbp, 0, rdx, r13, qword [rbx + CAP_RIGHTS], rax
    CAP_UNLOCK
    jmp .out
.grow:
    CAP_UNLOCK
    mov rcx, [rsp]                      ; a window's offset is relative again
    mov [rbx + CAP_OFF], rcx
    mov rcx, [rsp + 8]
    mov [rbx + CAP_LEN], rcx
    mov rdi, r12
    call ht_grow
    test rax, rax
    jz .retry
    jmp .free
.refused:
    AUDIT rbp, rax, 0, r13, r14, 0
    CAP_UNLOCK
.free:
    mov rdi, rbx
    call kfree
    jmp .out
.nomem:
    mov rax, E_NOMEM
.out:
    call op_done
    add rsp, 16
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret

handle_give:
    push rbx
    push r12
    push r13
    push r14
    mov r13d, edi
    mov r14d, esi
    call cur_task
    mov r12, rax
    CAP_LOCK
    mov esi, r14d
    call cap_find                       ; the task
    cmp rax, E_ANY
    jae .refused
    mov ecx, OT_TASK
    mov r8d, RT_TASK_HANDLES
    call cap_check
    cmp rax, E_ANY
    jae .refused
    mov rbx, [rax + CAP_OBJ]
    mov rdi, rbx
    call obj_get                        ; alive while it is given to
    CAP_UNLOCK
    mov rdi, r12
    mov esi, r13d
    mov rdx, rbx
    call task_give
    mov rdi, rbx
    call obj_put
    jmp .out
.refused:
    AUDIT AO_GIVE, rax, 0, r13, 0, 0
    CAP_UNLOCK
.out:
    call op_done
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; task_give(RDI = a task, ESI = a handle of its, RDX = another task, kept
; alive by the caller) -> RAX = the handle the other has now (needs RT_GIVE):
; handle_give, for whichever task. Mapped in the first: no more.
task_give:
    push rbx
    push rbp
    push r12
    push r13
    mov r12, rdi
    mov r13d, esi
    mov rbp, rdx
.retry:
    CAP_LOCK
    mov esi, r13d
    call cap_find                       ; what goes to it
    cmp rax, E_ANY
    jae .refused
    xor ecx, ecx
    mov r8d, RT_GIVE
    call cap_check
    cmp rax, E_ANY
    jae .refused
    mov rbx, rax
    mov rax, E_ARG                      ; a task holding itself would never end
    cmp [rbx + CAP_OBJ], rbp
    je .refused
    push r12
    mov r12, rbp
    call ht_take
    pop r12
    test eax, eax
    jz .grow
    push rax
    mov rdi, rbx                        ; mapped in the giver's: no more
    call cap_unmap
    mov eax, [rbx + CAP_SLOT]           ; out of its table
    call ht_release
    pop rax
    push r12
    mov r12, rbp
    call ht_set                         ; into the other's
    pop r12
    AUDIT AO_GIVE, 0, qword [rbx + CAP_OBJ], r13, qword [rbx + CAP_RIGHTS], qword [rbp + OB_ID]
    mov rdi, [rbx + CAP_OBJ]
    xor esi, esi
    xor edx, edx
    xchg rsi, [rbx + CAP_MAPVA]         ; the other's now: what is left to do, ours
    xchg rdx, [rbx + CAP_MAPLEN]
    CAP_UNLOCK
    call unmap_flush
    jmp .out
.grow:
    CAP_UNLOCK
    mov rdi, rbp
    call ht_grow
    test rax, rax
    jz .retry
    jmp .out
.refused:
    AUDIT AO_GIVE, rax, 0, r13, 0, 0
    CAP_UNLOCK
.out:
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret

handle_revoke:
    push rbx
    push r12
    push r13
    push r14
    mov r13d, edi
    call cur_task
    mov r12, rax
    CAP_LOCK
    mov esi, r13d
    call cap_find
    cmp rax, E_ANY
    jae .refused
    mov rbx, rax
    xor r14d, r14d                      ; those revoked, chained through CAP_PARENT
    xor ecx, ecx                        ; how many
.next:
    mov rdi, [rbx + CAP_CHILD]
    test rdi, rdi
    jz .gone
    mov rax, [rdi + CAP_SIBLING]        ; off the list
    mov [rbx + CAP_CHILD], rax
    mov rax, [rdi + CAP_CHILD]          ; and those derived from it onto it
    test rax, rax
    jz .kill
    mov rdx, rax
.last:
    cmp qword [rdx + CAP_SIBLING], 0
    je .splice
    mov rdx, [rdx + CAP_SIBLING]
    jmp .last
.splice:
    mov rsi, [rbx + CAP_CHILD]
    mov [rdx + CAP_SIBLING], rsi
    mov [rbx + CAP_CHILD], rax
.kill:                                  ; its slot says revoked until closed
    mov rsi, [rdi + CAP_TASK]
    mov eax, [rdi + CAP_SLOT]
    shl rax, 4
    add rax, [rsi + TK_SLOTS]
    mov qword [rax + HS_CAP], 0
    mov word [rax + HS_STATE], HSS_REVOKED
    call cap_unmap                      ; and mapped no more (user.asm)
    mov rax, [rdi + CAP_OBJ]
    lock dec dword [rax + OB_CAPS]
    mov [rdi + CAP_PARENT], r14
    mov r14, rdi
    inc ecx
    jmp .next
.gone:
    AUDIT AO_REVOKE, 0, qword [rbx + CAP_OBJ], r13, qword [rbx + CAP_RIGHTS], rcx
    CAP_UNLOCK
    push rcx
.free:
    test r14, r14
    jz .freed
    mov rdi, r14
    call cap_flush
    mov rdi, [r14 + CAP_OBJ]
    call obj_put
    mov rdi, r14
    mov r14, [r14 + CAP_PARENT]
    call kfree
    jmp .free
.freed:
    pop rax
    jmp .out
.refused:
    AUDIT AO_REVOKE, rax, 0, r13, 0, 0
    CAP_UNLOCK
.out:
    call op_done
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

handle_close:
    push rbx
    push r12
    push r13
    mov r13d, edi
    call cur_task
    mov r12, rax
    CAP_LOCK
    mov esi, r13d
    call cap_find
    cmp rax, E_REVOKED
    je .tombstone
    cmp rax, E_ANY
    jae .refused
    mov rbx, rax
    mov rdi, rbx
    call cap_unlink                     ; those derived from it move up
    call cap_unmap
    mov rdx, [rbx + CAP_OBJ]
    lock dec dword [rdx + OB_CAPS]
    setz byte [rbx + CAP_LAST]
    mov eax, [rbx + CAP_SLOT]
    call ht_release
    AUDIT AO_CLOSE, 0, rdx, r13, qword [rbx + CAP_RIGHTS], 0
    CAP_UNLOCK
    mov rdi, rbx
    call cap_flush
    mov rdi, [rbx + CAP_OBJ]
    cmp byte [rbx + CAP_LAST], 0
    je .put
    call obj_orphaned
.put:
    call obj_put
    mov rdi, rbx
    call kfree
    xor eax, eax
    jmp .out
.tombstone:
    mov eax, r13d
    and eax, 0xFFFF
    call ht_release
    AUDIT AO_CLOSE, 0, 0, r13, 0, 0
    CAP_UNLOCK
    xor eax, eax
    jmp .out
.refused:
    AUDIT AO_CLOSE, rax, 0, r13, 0, 0
    CAP_UNLOCK
.out:
    call op_done
    pop r13
    pop r12
    pop rbx
    ret

; cap_drop_all(R12 = a task ending, with no other reference): every handle
; it holds closed. No lock held.
cap_drop_all:
    push rbx
    push rcx
    push rdx
    push rdi
    push r13
    xor r13d, r13d                      ; its capabilities, chained through CAP_PARENT
    xor ebx, ebx                        ; how many
    CAP_LOCK
    mov ecx, 1
.slot:
    cmp ecx, [r12 + TK_NSLOTS]
    jae .emptied
    mov eax, ecx
    shl rax, 4
    add rax, [r12 + TK_SLOTS]
    mov rdi, [rax + HS_CAP]
    test rdi, rdi
    jz .next
    mov qword [rax + HS_CAP], 0
    call cap_unlink
    call cap_unmap
    mov rdx, [rdi + CAP_OBJ]
    lock dec dword [rdx + OB_CAPS]
    setz byte [rdi + CAP_LAST]
    mov [rdi + CAP_PARENT], r13
    mov r13, rdi
    inc ebx
.next:
    inc ecx
    jmp .slot
.emptied:
    test ebx, ebx
    jz .unlock
    AUDIT AO_END, 0, r12, 0, 0, rbx
.unlock:
    CAP_UNLOCK
.put:
    test r13, r13
    jz .out
    mov rdi, r13
    call cap_flush
    mov rdi, [r13 + CAP_OBJ]
    cmp byte [r13 + CAP_LAST], 0
    je .drop
    call obj_orphaned
.drop:
    call obj_put
    mov rdi, r13
    mov r13, [r13 + CAP_PARENT]
    call kfree
    jmp .put
.out:
    pop r13
    pop rdi
    pop rdx
    pop rcx
    pop rbx
    ret

; -----------------------------------------------------------------------------
;  Words for what they mean
; -----------------------------------------------------------------------------

; err_text(RDI = E_* or 0) -> RAX = what it means. Preserves others.
err_text:
    mov rax, rdi
    neg rax
    cmp rax, E_COUNT
    jb .known
    lea rax, [str_e_unknown]
    ret
.known:
    push rcx
    lea rcx, [err_names]
    mov rax, [rcx + rax * 8]
    pop rcx
    ret

; rights_text(RDI = buffer, ESI = rights, EDX = OT_*) -> RAX = length: the
; names of the rights, or "all" or "none". Preserves others.
rights_text:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    mov r8, rdi
    lea rax, [str_rt_all]
    cmp esi, RT_ALL
    je .one
    lea rax, [str_rt_none]
    test esi, esi
    jz .one
    mov eax, edx
    cmp eax, OT_TYPES
    jb .typed
    xor eax, eax
.typed:
    shl eax, 6
    lea rbx, [obj_types]
    mov rbx, [rbx + rax + TY_RIGHTS]
    xor ecx, ecx
.bit:
    bt esi, ecx
    jnc .next
    mov rdx, [rbx + rcx * 8]
    test rdx, rdx
    jz .next
    cmp rdi, r8
    je .copy
    mov byte [rdi], ' '
    inc rdi
.copy:
    mov al, [rdx]
    test al, al
    jz .next
    mov [rdi], al
    inc rdi
    inc rdx
    jmp .copy
.next:
    inc ecx
    cmp ecx, 16
    jb .bit
    mov byte [rdi], 0
    mov rax, rdi
    sub rax, r8
    jmp .out
.one:
    mov rsi, rax
.one_copy:
    lodsb
    mov [rdi], al
    test al, al
    jz .one_done
    inc rdi
    jmp .one_copy
.one_done:
    mov rax, rdi
    sub rax, r8
.out:
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; type_name(EDI = OT_*) -> RAX = its name. Preserves others.
type_name:
    mov eax, edi
    cmp eax, OT_TYPES
    jb .typed
    xor eax, eax
.typed:
    shl eax, 6
    push rcx
    lea rcx, [obj_types]
    mov rax, [rcx + rax + TY_NAME]
    pop rcx
    ret

section .rodata
str_task_kernel: db 'kernel', 0
str_obj_oom:    db 'Out of memory for the kernel task', 0
str_obj_under:  db 'obj_put: no reference left to drop', 0
str_ot_none:    db '-', 0
str_ot_task:    db 'task', 0
str_ot_thread:  db 'thread', 0
str_ot_event:   db 'event', 0
str_ot_memory:  db 'memory', 0
str_ot_ring:    db 'ring', 0
str_rt_all:     db 'all', 0
str_rt_none:    db 'none', 0
str_rt_dup:     db 'dup', 0
str_rt_give:    db 'give', 0
str_rt_info:    db 'info', 0
str_rt_handles: db 'handles', 0
str_rt_spawn:   db 'spawn', 0
str_rt_wait:    db 'wait', 0
str_rt_signal:  db 'signal', 0
str_rt_read:    db 'read', 0
str_rt_write:   db 'write', 0
str_rt_enter:   db 'enter', 0
str_rt_kill:    db 'kill', 0
str_rt_send:    db 'send', 0
str_rt_recv:    db 'receive', 0
str_rt_commit:  db 'commit', 0
str_rt_rollback: db 'rollback', 0
str_rt_connect: db 'connect', 0
str_rt_tls:     db 'tls', 0
str_rt_insecure: db 'insecure', 0
str_rt_listen:  db 'listen', 0
str_rt_window:  db 'window', 0
str_rt_draw:    db 'draw', 0
str_rt_change:  db 'change', 0
str_e_ok:       db 'ok', 0
str_e_badh:     db 'no such handle', 0
str_e_type:     db 'the wrong type', 0
str_e_rights:   db 'not allowed', 0
str_e_expired:  db 'expired', 0
str_e_revoked:  db 'revoked', 0
str_e_range:    db 'out of range', 0
str_e_nomem:    db 'out of memory', 0
str_e_full:     db 'the handle table is full', 0
str_e_timeout:  db 'timed out', 0
str_e_arg:      db 'a bad argument', 0
str_e_canceled: db 'canceled', 0
str_e_killed:   db 'killed', 0
str_e_fault:    db 'a fault in ring 3', 0
str_e_peer:     db 'the other end is closed', 0
str_e_empty:    db 'nothing there', 0
str_e_conflict: db 'changed since it was staged', 0
str_e_noname:   db 'no such name', 0
str_e_io:       db 'the drive failed', 0
str_e_nostore:  db 'no store to write to', 0
str_e_net:      db 'the connection failed', 0
str_e_unknown:  db 'an unknown error', 0

align 8
err_names:      dq str_e_ok, str_e_badh, str_e_type, str_e_rights, str_e_expired
                dq str_e_revoked, str_e_range, str_e_nomem, str_e_full, str_e_timeout, str_e_arg
                dq str_e_canceled, str_e_killed, str_e_fault, str_e_peer, str_e_empty
                dq str_e_conflict, str_e_noname, str_e_io, str_e_nostore, str_e_net
rt_names_none:  dq str_rt_dup, str_rt_give, str_rt_info, 0, 0, 0, 0, 0
                dq 0, 0, 0, 0, 0, 0, 0, 0
rt_names_task:  dq str_rt_dup, str_rt_give, str_rt_info, 0, 0, 0, 0, 0
                dq str_rt_handles, str_rt_spawn, str_rt_kill, 0, 0, 0, 0, 0
rt_names_thread: dq str_rt_dup, str_rt_give, str_rt_info, 0, 0, 0, 0, 0
                dq str_rt_wait, 0, 0, 0, 0, 0, 0, 0
rt_names_event: dq str_rt_dup, str_rt_give, str_rt_info, 0, 0, 0, 0, 0
                dq str_rt_signal, str_rt_wait, 0, 0, 0, 0, 0, 0
rt_names_memory: dq str_rt_dup, str_rt_give, str_rt_info, 0, 0, 0, 0, 0
                dq str_rt_read, str_rt_write, 0, 0, 0, 0, 0, 0
rt_names_ring:  dq str_rt_dup, str_rt_give, str_rt_info, 0, 0, 0, 0, 0
                dq str_rt_enter, 0, 0, 0, 0, 0, 0, 0
rt_names_console: dq str_rt_dup, str_rt_give, str_rt_info, 0, 0, 0, 0, 0
                dq str_rt_write, 0, 0, 0, 0, 0, 0, 0
rt_names_channel: dq str_rt_dup, str_rt_give, str_rt_info, 0, 0, 0, 0, 0
                dq str_rt_send, str_rt_recv, 0, 0, 0, 0, 0, 0
rt_names_store: dq str_rt_dup, str_rt_give, str_rt_info, 0, 0, 0, 0, 0
                dq str_rt_read, str_rt_write, str_rt_commit, str_rt_rollback, 0, 0, 0, 0
rt_names_net:   dq str_rt_dup, str_rt_give, str_rt_info, 0, 0, 0, 0, 0
                dq str_rt_connect, str_rt_tls, str_rt_insecure, str_rt_listen, 0, 0, 0, 0
rt_names_socket: dq str_rt_dup, str_rt_give, str_rt_info, 0, 0, 0, 0, 0
                dq str_rt_send, str_rt_recv, 0, 0, 0, 0, 0, 0
rt_names_desk:  dq str_rt_dup, str_rt_give, str_rt_info, 0, 0, 0, 0, 0
                dq str_rt_window, 0, 0, 0, 0, 0, 0, 0
rt_names_window: dq str_rt_dup, str_rt_give, str_rt_info, 0, 0, 0, 0, 0
                dq str_rt_draw, 0, 0, 0, 0, 0, 0, 0
rt_names_settings: dq str_rt_dup, str_rt_give, str_rt_info, 0, 0, 0, 0, 0
                dq str_rt_read, str_rt_change, 0, 0, 0, 0, 0, 0

section .data
align 8
obj_next_id:    dq 1
obj_types:                              ; TY_SIZE each, by OT_*
                dq str_ot_none, 0, 0, 0, 0, 0, rt_names_none, 0
ty_task:        dq str_ot_task, task_destroy, 0, 0, 0, 0, rt_names_task, task_orphan
ty_thread:      dq str_ot_thread, thread_destroy, 0, 0, 0, 0, rt_names_thread, 0
ty_event:       dq str_ot_event, obj_free, 0, 0, 0, 0, rt_names_event, 0
ty_memory:      dq str_ot_memory, mem_destroy, 0, 0, 0, 0, rt_names_memory, 0
ty_ring:        dq str_ot_ring, ring_destroy, 0, 0, 0, 0, rt_names_ring, ring_orphan
ty_console:     dq str_ot_console, obj_free, 0, 0, 0, 0, rt_names_console, 0
ty_channel:     dq str_ot_channel, ch_destroy, 0, 0, 0, 0, rt_names_channel, ch_orphan
ty_store:       dq str_ot_store, st_obj_destroy, 0, 0, 0, 0, rt_names_store, 0
ty_net:         dq str_ot_net, obj_free, 0, 0, 0, 0, rt_names_net, 0
ty_socket:      dq str_ot_socket, sk_destroy, 0, 0, 0, 0, rt_names_socket, sk_orphan
ty_desk:        dq str_ot_desk, obj_free, 0, 0, 0, 0, rt_names_desk, 0
ty_window:      dq str_ot_window, wo_destroy, 0, 0, 0, 0, rt_names_window, wo_orphan
ty_settings:    dq str_ot_settings, obj_free, 0, 0, 0, 0, rt_names_settings, 0

thread_list     equ ty_thread + TY_LIST
thread_count    equ ty_thread + TY_LIVE
threads_lock    equ ty_thread + TY_LOCK

section .bss
alignb 8
task_kernel:    resq 1
audit_next:     resq 1                  ; records ever written
cap_lock:       resd 1
alignb 16
audit_ring:     resb AUDIT_LEN * AU_SIZE
