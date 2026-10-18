; =============================================================================
;  objtest.asm - 'objects': every type of object and every task; a task's
;  handles; the audit ring; and 'objects test', the self-test of objects and
;  capabilities
; =============================================================================

OBT_WORKERS     equ 8                   ; threads at once in the stress part
OBT_STRESS_MS   equ 200
OBT_SIGNALS     equ 100000              ; timed
OBT_DUPS        equ 50000
AUDIT_SHOW      equ 32

; a line of the task listing
TKR_ID          equ 0
TKR_PARENT      equ 8
TKR_THREADS     equ 16
TKR_HANDLES     equ 24
TKR_OPS         equ 32
TKR_DENIED      equ 40
TKR_NAME        equ 48
TKR_SIZE        equ 80
TS_MAX          equ 32                  ; tasks stop: programs stopped by one name

; a line of a task's handles
HR_HANDLE       equ 0
HR_STATE        equ 8
HR_TYPE         equ 16
HR_OBJ          equ 24
HR_RIGHTS       equ 32
HR_EXPIRES      equ 40
HR_FROM         equ 48                  ; the handle it was derived from, 0 if none
HR_FROM_TASK    equ 56                  ; and whose
HR_OFF          equ 64
HR_LEN          equ 72
HR_NAME         equ 80
HR_SIZE         equ 112

; what the agent was given, and what it got
AG_SIGNAL       equ 0
AG_GO           equ 8
AG_R            equ 16                  ; 7 results
AG_SIZE         equ 72

; a stress worker
OW_H            equ 0
OW_TH           equ 8
OW_OPS          equ 16
OW_ODD          equ 24
OW_SIZE         equ 32

; OB_WANT value, "what was tried": RAX must be that value
%macro OB_WANT 2
    cmp rax, %1
    je %%ok
    [section .rodata]
    %%what: db %2, 0
    __SECT__
    push rax
    push rcx
    push rsi
    push rdi
    push r8
    mov rcx, rax
    mov rdi, rax
    lea rsi, [ob_why_a]
    call ob_why
    mov r8, rax
    mov rdi, %1
    lea rsi, [ob_why_b]
    call ob_why
    lea rsi, [%%what]
    mov rdi, %1
    KLOG "%s: %s: %d%s, not %d%s", qword [test_name], rsi, rcx, r8, rdi, rax
    pop r8
    pop rdi
    pop rsi
    pop rcx
    pop rax
    inc qword [test_fails]
%%ok:
%endmacro

; OB_GOT "what was tried": RAX must not be an error
%macro OB_GOT 1
    cmp rax, E_ANY
    jb %%ok
    [section .rodata]
    %%what: db %1, 0
    __SECT__
    push rax
    push rsi
    push rdi
    lea rsi, [%%what]
    mov rdi, rax
    call err_text
    KLOG "%s: %s: %s", qword [test_name], rsi, rax
    pop rdi
    pop rsi
    pop rax
    inc qword [test_fails]
%%ok:
%endmacro

section .text

; -----------------------------------------------------------------------------
;  objects [test | audit | <task id>]
; -----------------------------------------------------------------------------
cmd_objects:
    mov rsi, [sh_args]
    cmp byte [rsi], 0
    je objects_list
    call arg_split
    push rdi
    lea rdi, [str_ob_test]
    call streq
    pop rdi
    test eax, eax
    jnz objects_test
    push rdi
    lea rdi, [str_ob_audit]
    call streq
    pop rdi
    test eax, eax
    jnz objects_audit
    call arg_uint
    jc .usage
    mov edi, eax
    jmp objects_task
.usage:
    KLOG "usage: objects [test | audit | <task id>]"
    ret

; -----------------------------------------------------------------------------
;  objects: each type, then each task
; -----------------------------------------------------------------------------
objects_list:
    push rbx
    push r12
    push r13
    push r14
    KLOG "  type       live    made"
    mov r12d, 1
.type:
    cmp r12d, OT_TYPES
    jae .tasks
    mov eax, r12d
    shl eax, 6
    lea rbx, [obj_types]
    add rbx, rax
    KLOG "  %-7s  %6u  %6u", qword [rbx + TY_NAME], qword [rbx + TY_LIVE], qword [rbx + TY_MADE]
    inc r12d
    jmp .type
.tasks:                                 ; a copy, taken under the lock
    mov rdi, [ty_task + TY_LIVE]
    add rdi, 8
    imul rdi, rdi, TKR_SIZE
    call kmalloc
    test rax, rax
    jz .out
    mov r14, rax
    mov r13, [ty_task + TY_LIVE]
    add r13, 8                          ; room
    xor r12d, r12d
    pushfq
    cli
    lea rdi, [ty_task + TY_LOCK]
    call spin_lock
    mov rbx, [ty_task + TY_LIST]
.copy:
    test rbx, rbx
    jz .copied
    cmp r12, r13
    jae .copied
    imul rdi, r12, TKR_SIZE
    add rdi, r14
    mov rax, [rbx + OB_ID]
    mov [rdi + TKR_ID], rax
    xor eax, eax
    mov rcx, [rbx + TK_PARENT]
    test rcx, rcx
    jz .parent
    mov rax, [rcx + OB_ID]
.parent:
    mov [rdi + TKR_PARENT], rax
    mov eax, [rbx + TK_THREADS]
    mov [rdi + TKR_THREADS], rax
    mov eax, [rbx + TK_USED]
    mov [rdi + TKR_HANDLES], rax
    mov rax, [rbx + TK_OPS]
    mov [rdi + TKR_OPS], rax
    mov rax, [rbx + TK_DENIED]
    mov [rdi + TKR_DENIED], rax
    lea rsi, [rbx + OB_NAME]
    add rdi, TKR_NAME
    mov ecx, OB_NAME_LEN
    rep movsb
    inc r12
    mov rbx, [rbx + OB_NEXT]
    jmp .copy
.copied:
    lea rdi, [ty_task + TY_LOCK]
    call spin_unlock
    popfq
    KLOG "  task  name          made by  threads  handles  operations  refused"
    xor r13d, r13d
.line:
    cmp r13, r12
    jae .free
    imul rbx, r13, TKR_SIZE
    add rbx, r14
    lea rsi, [rbx + TKR_NAME]
    KLOG "  %4u  %-12s  %7u  %7u  %7u  %10u  %7u", qword [rbx + TKR_ID], rsi, qword [rbx + TKR_PARENT], qword [rbx + TKR_THREADS], qword [rbx + TKR_HANDLES], qword [rbx + TKR_OPS], qword [rbx + TKR_DENIED]
    inc r13
    jmp .line
.free:
    mov rdi, r14
    call kfree
.out:
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; -----------------------------------------------------------------------------
;  tasks, tasks stop <id>: records (records.asm), from the words after them
;  (EDI = how many, RSI = them); CF if it failed
; -----------------------------------------------------------------------------

; tasks: every task there is
tasks_list:
    push rbx
    push r12
    push r13
    push r14
    test edi, edi
    jnz .usage
    COLUMN 'id', FT_INT
    COLUMN 'name', FT_TEXT
    COLUMN 'parent', FT_INT
    COLUMN 'threads', FT_INT
    COLUMN 'handles', FT_INT
    COLUMN 'ops', FT_INT
    COLUMN 'denied', FT_INT
    COLUMN 'program', FT_BOOL
    mov rdi, [ty_task + TY_LIVE]        ; a copy, taken under the lock
    add rdi, 8
    imul rdi, rdi, TKR_SIZE + 8
    call kmalloc
    test rax, rax
    jz .no_memory
    mov r14, rax
    mov r13, [ty_task + TY_LIVE]
    add r13, 8                          ; room
    xor r12d, r12d
    pushfq
    cli
    lea rdi, [ty_task + TY_LOCK]
    call spin_lock
    mov rbx, [ty_task + TY_LIST]
.copy:
    test rbx, rbx
    jz .copied
    cmp r12, r13
    jae .copied
    imul rdi, r12, TKR_SIZE + 8
    add rdi, r14
    mov rax, [rbx + OB_ID]
    mov [rdi + TKR_ID], rax
    xor eax, eax
    mov rcx, [rbx + TK_PARENT]
    test rcx, rcx
    jz .parent
    mov rax, [rcx + OB_ID]
.parent:
    mov [rdi + TKR_PARENT], rax
    mov eax, [rbx + TK_THREADS]
    mov [rdi + TKR_THREADS], rax
    mov eax, [rbx + TK_USED]
    mov [rdi + TKR_HANDLES], rax
    mov rax, [rbx + TK_OPS]
    mov [rdi + TKR_OPS], rax
    mov rax, [rbx + TK_DENIED]
    mov [rdi + TKR_DENIED], rax
    xor eax, eax                        ; a program: it has an address space
    cmp qword [rbx + TK_AS], 0
    setne al
    mov [rdi + TKR_SIZE], rax
    lea rsi, [rbx + OB_NAME]
    add rdi, TKR_NAME
    mov ecx, OB_NAME_LEN
    rep movsb
    inc r12
    mov rbx, [rbx + OB_NEXT]
    jmp .copy
.copied:
    lea rdi, [ty_task + TY_LOCK]
    call spin_unlock
    popfq
    xor r13d, r13d
.line:
    cmp r13, r12
    jae .free
    imul rbx, r13, TKR_SIZE + 8
    add rbx, r14
    call rec_row
    xor edi, edi
    mov rsi, [rbx + TKR_ID]
    call rec_set
    mov edi, 1
    lea rsi, [rbx + TKR_NAME]
    call rec_str
    mov edi, 2
    mov rsi, [rbx + TKR_PARENT]
    test rsi, rsi
    jnz .made_by
    call rec_none
    jmp .threads
.made_by:
    call rec_set
.threads:
    mov edi, 3
    mov rsi, [rbx + TKR_THREADS]
    call rec_set
    mov edi, 4
    mov rsi, [rbx + TKR_HANDLES]
    call rec_set
    mov edi, 5
    mov rsi, [rbx + TKR_OPS]
    call rec_set
    mov edi, 6
    mov rsi, [rbx + TKR_DENIED]
    call rec_set
    mov edi, 7
    mov rsi, [rbx + TKR_SIZE]
    call rec_set
    inc r13
    jmp .line
.free:
    mov rdi, r14
    call kfree
    clc
    jmp .out
.no_memory:
    KLOG "tasks: no memory to list them"
    stc
    jmp .out
.usage:
    KLOG "usage: tasks [stop <id or program>...]"
    stc
.out:
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; tasks stop <id or program>...: a program's task killed (by its id, or
; every one of that name), and the tasks it started; the kernel's own are
; not for stopping
tasks_stop:
    push rbx
    push rbp
    push r12
    push r13
    push r14
    push r15
    sub rsp, TS_MAX * 8                 ; the tasks found by a name, at RBP
    mov rbp, rsp                        ; (RSP moves under the lock)
    mov r13d, edi
    mov r14, rsi
    xor r15d, r15d                      ; 1 once one failed
    test r13d, r13d
    jz .usage
.arg:
    test r13d, r13d
    jz .done
    mov rsi, [r14]
    call arg_uint
    jc .by_name
    mov r12d, eax                       ; by id
    xor ebx, ebx
    pushfq
    cli
    lea rdi, [ty_task + TY_LOCK]
    call spin_lock
    mov rax, [ty_task + TY_LIST]
.find:
    test rax, rax
    jz .found
    cmp [rax + OB_ID], r12
    je .hit
    mov rax, [rax + OB_NEXT]
    jmp .find
.hit:
    mov rdi, rax
    call obj_tryget                     ; not one already on its way out
    jc .found
    mov rbx, rdi
.found:
    lea rdi, [ty_task + TY_LOCK]
    call spin_unlock
    popfq
    test rbx, rbx
    jz .none
    cmp qword [rbx + TK_AS], 0
    je .kernel
    mov rdi, rbx
    call ts_kill
    jmp .next
.kernel:
    lea rax, [rbx + OB_NAME]
    KLOG "tasks: %u (%s) is the kernel's own, not a program: it is not for stopping", r12, rax
    mov rdi, rbx
    call obj_put
    mov r15d, 1
    jmp .next
.none:
    KLOG "tasks: there is no task %u", r12
    mov r15d, 1
    jmp .next
.by_name:                               ; every program of that name
    xor r12d, r12d                      ; found
    pushfq
    cli
    lea rdi, [ty_task + TY_LOCK]
    call spin_lock
    mov rbx, [ty_task + TY_LIST]
.look:
    test rbx, rbx
    jz .looked
    cmp r12d, TS_MAX
    jae .looked
    cmp qword [rbx + TK_AS], 0          ; programs alone
    je .look_next
    test dword [rbx + TK_KILL], 1       ; not one stopped already
    jnz .look_next
    lea rdi, [rbx + OB_NAME]
    mov rsi, [r14]
    call rec_ieq
    test eax, eax
    jz .look_next
    mov rdi, rbx
    call obj_tryget
    jc .look_next
    mov [rbp + r12 * 8], rbx
    inc r12d
.look_next:
    mov rbx, [rbx + OB_NEXT]
    jmp .look
.looked:
    lea rdi, [ty_task + TY_LOCK]
    call spin_unlock
    popfq
    test r12d, r12d
    jz .no_name
.each:
    dec r12d
    mov rdi, [rbp + r12 * 8]
    call ts_kill
    test r12d, r12d
    jnz .each
    jmp .next
.no_name:
    mov rax, [r14]
    KLOG "tasks: no program called %s is running", rax
    mov r15d, 1
.next:
    add r14, 8
    dec r13d
    jmp .arg
.done:
    cmp r15d, 1                         ; CF if one failed
    cmc
    jmp .out
.usage:
    KLOG "usage: tasks stop <id or program>..."
    stc
.out:
    lea rsp, [rsp + TS_MAX * 8]
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret

; ts_kill(RDI = a task, a reference we give up): killed, and said
ts_kill:
    push rbx
    mov rbx, rdi
    call task_kill
    lea rax, [rbx + OB_NAME]
    KLOG "tasks: %u (%s) stopped", qword [rbx + OB_ID], rax
    mov rdi, rbx
    call obj_put
    pop rbx
    ret

; -----------------------------------------------------------------------------
;  objects <task id>: the handles it holds
; -----------------------------------------------------------------------------
objects_task:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov r15d, edi
    xor r12d, r12d
    pushfq
    cli
    lea rdi, [ty_task + TY_LOCK]
    call spin_lock
    mov rbx, [ty_task + TY_LIST]
.find:
    test rbx, rbx
    jz .found
    cmp [rbx + OB_ID], r15
    je .hit
    mov rbx, [rbx + OB_NEXT]
    jmp .find
.hit:
    mov rdi, rbx
    call obj_get
    mov r12, rbx
.found:
    lea rdi, [ty_task + TY_LOCK]
    call spin_unlock
    popfq
    test r12, r12
    jnz .have
    KLOG "objects: no task %u", r15
    jmp .out
.have:
    mov r13d, [r12 + TK_USED]
    add r13d, 16                        ; room
    imul edi, r13d, HR_SIZE
    call kmalloc
    test rax, rax
    jz .put
    mov r14, rax
    xor ebx, ebx                        ; lines taken
    CAP_LOCK
    mov ecx, 1
.slot:
    cmp ecx, [r12 + TK_NSLOTS]
    jae .copied
    cmp ebx, r13d
    jae .copied
    mov eax, ecx
    shl rax, 4
    add rax, [r12 + TK_SLOTS]
    movzx edx, word [rax + HS_STATE]
    cmp edx, HSS_FREE
    je .next
    imul rdi, rbx, HR_SIZE
    add rdi, r14
    mov [rdi + HR_STATE], rdx
    movzx esi, word [rax + HS_GEN]
    shl esi, 16
    or esi, ecx
    mov [rdi + HR_HANDLE], rsi
    mov rsi, [rax + HS_CAP]
    test rsi, rsi
    jz .taken                           ; revoked
    mov eax, [rsi + CAP_RIGHTS]
    mov [rdi + HR_RIGHTS], rax
    mov rax, [rsi + CAP_EXPIRES]
    mov [rdi + HR_EXPIRES], rax
    mov rax, [rsi + CAP_OFF]
    mov [rdi + HR_OFF], rax
    mov rax, [rsi + CAP_LEN]
    mov [rdi + HR_LEN], rax
    mov rax, [rsi + CAP_PARENT]
    test rax, rax
    jz .root
    mov rdx, [rax + CAP_TASK]
    mov r8, [rdx + OB_ID]
    mov [rdi + HR_FROM_TASK], r8
    mov r8d, [rax + CAP_SLOT]
    mov r9, r8
    shl r9, 4
    add r9, [rdx + TK_SLOTS]
    movzx r9d, word [r9 + HS_GEN]
    shl r9d, 16
    or r8d, r9d
    mov [rdi + HR_FROM], r8
.root:
    mov rsi, [rsi + CAP_OBJ]
    mov eax, [rsi + OB_TYPE]
    mov [rdi + HR_TYPE], rax
    mov rax, [rsi + OB_ID]
    mov [rdi + HR_OBJ], rax
    push rcx
    lea rsi, [rsi + OB_NAME]
    add rdi, HR_NAME
    mov ecx, OB_NAME_LEN
    rep movsb
    pop rcx
.taken:
    inc ebx
.next:
    inc ecx
    jmp .slot
.copied:
    mov r13d, [r12 + TK_USED]
    mov r15d, [r12 + TK_NSLOTS]
    CAP_UNLOCK
    lea rsi, [r12 + OB_NAME]
    KLOG "  task %u, %s: %u handles, in a table of %u", qword [r12 + OB_ID], rsi, r13, r15
    KLOG "    handle  type    object                     rights                        expires  derived from"
    xor r13d, r13d
.line:
    cmp r13d, ebx
    jae .free
    imul r15, r13, HR_SIZE
    add r15, r14
    cmp qword [r15 + HR_STATE], HSS_REVOKED
    jne .live
    KLOG "  0x%05x  revoked: refused until closed", qword [r15 + HR_HANDLE]
    jmp .line_next
.live:
    lea rdi, [ob_obj]                   ; the object
    lea rsi, [r15 + HR_NAME]
    SPRINTF rdi, "%u %s", qword [r15 + HR_OBJ], rsi
    cmp qword [r15 + HR_TYPE], OT_MEMORY
    jne .rights
    add rdi, rax
    SPRINTF rdi, " [%u, +%u]", qword [r15 + HR_OFF], qword [r15 + HR_LEN]
.rights:
    lea rdi, [ob_rights]
    mov esi, [r15 + HR_RIGHTS]
    mov edx, [r15 + HR_TYPE]
    call rights_text
    lea rdi, [ob_exp]                   ; when it expires
    mov rax, [r15 + HR_EXPIRES]
    test rax, rax
    jnz .expires
    SPRINTF rdi, "-"
    jmp .from
.expires:
    mov rcx, rax
    RDTSC64
    sub rcx, rax
    jbe .expired
    mov rax, rcx
    xor edx, edx
    div qword [tsc_per_ms]
    SPRINTF rdi, "%u ms", rax
    jmp .from
.expired:
    SPRINTF rdi, "expired"
.from:
    lea rdi, [ob_from]
    mov rax, [r15 + HR_FROM]
    test rax, rax
    jnz .derived
    SPRINTF rdi, "-"
    jmp .say
.derived:
    mov rcx, [r15 + HR_FROM_TASK]
    cmp rcx, [r12 + OB_ID]
    jne .elsewhere
    SPRINTF rdi, "0x%05x", rax
    jmp .say
.elsewhere:
    SPRINTF rdi, "0x%05x of task %u", rax, rcx
.say:
    mov edi, [r15 + HR_TYPE]
    call type_name
    lea rcx, [ob_obj]
    lea rdx, [ob_rights]
    lea rsi, [ob_exp]
    lea rdi, [ob_from]
    KLOG "  0x%05x  %-6s  %-26s %-28s %8s  %s", qword [r15 + HR_HANDLE], rax, rcx, rdx, rsi, rdi
.line_next:
    inc r13d
    jmp .line
.free:
    mov rdi, r14
    call kfree
.put:
    mov rdi, r12
    call obj_put
.out:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; -----------------------------------------------------------------------------
;  objects audit: the last records of the audit ring, oldest first
; -----------------------------------------------------------------------------
objects_audit:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov edi, AUDIT_LEN * AU_SIZE
    call kmalloc
    test rax, rax
    jz .out
    mov r14, rax
    CAP_LOCK
    lea rsi, [audit_ring]
    mov rdi, r14
    mov ecx, AUDIT_LEN * AU_SIZE / 8
    rep movsq
    mov r15, [audit_next]
    CAP_UNLOCK
    mov r12, r15
    sub r12, AUDIT_SHOW
    jae .from
    xor r12d, r12d
.from:
    mov rax, r15
    sub rax, r12
    KLOG "  %u changes and refusals since boot; the last %u:", r15, rax
    KLOG "       time  task  what     handle   object        rights                        result"
.record:
    cmp r12, r15
    jae .free
    mov rbx, r12
    and ebx, AUDIT_LEN - 1
    imul rbx, rbx, AU_SIZE
    add rbx, r14
    lea rdi, [ob_obj]
    cmp qword [rbx + AU_OBJ], 0
    jne .object
    SPRINTF rdi, "-"
    jmp .rights
.object:
    push rdi
    movzx edi, byte [rbx + AU_TYPE]
    call type_name
    pop rdi
    SPRINTF rdi, "%s %u", rax, qword [rbx + AU_OBJ]
.rights:
    lea rdi, [ob_rights]
    mov esi, [rbx + AU_RIGHTS]
    movzx edx, byte [rbx + AU_TYPE]
    call rights_text
    movzx eax, byte [rbx + AU_OP]       ; what else it says
    lea rdi, [ob_other]
    mov byte [rdi], 0
    mov ecx, [rbx + AU_OTHER]
    cmp byte [rbx + AU_ERR], 0
    jne .result
    cmp eax, AO_DUP
    je .new_handle
    cmp eax, AO_WINDOW
    je .new_handle
    cmp eax, AO_GIVE
    je .given
    cmp eax, AO_REVOKE
    je .revoked
    cmp eax, AO_END
    je .ended
    jmp .result
.new_handle:
    SPRINTF rdi, ": 0x%05x", rcx
    jmp .result
.given:
    SPRINTF rdi, ": to task %u", rcx
    jmp .result
.revoked:
    SPRINTF rdi, ": %u revoked", rcx
    jmp .result
.ended:
    SPRINTF rdi, ": its %u handles closed", rcx
.result:
    movzx edi, byte [rbx + AU_ERR]
    neg rdi
    call err_text
    mov r13, rax
    movzx eax, byte [rbx + AU_OP]
    cmp eax, AO_COUNT
    jb .op
    xor eax, eax
.op:
    lea rcx, [ao_names]
    mov r8, [rcx + rax * 8]
    mov rax, [rbx + AU_TSC]
    xor edx, edx
    div qword [tsc_per_ms]
    xor edx, edx
    mov ecx, 10
    div rcx
    mov edx, [rbx + AU_TASK]
    mov r9d, [rbx + AU_HANDLE]
    lea rcx, [ob_obj]
    lea rsi, [ob_rights]
    lea rdi, [ob_other]
    KLOG "  %7h s  %4u  %-7s  0x%05x  %-13s %-28s  %s%s", rax, rdx, r8, r9, rcx, rsi, r13, rdi
    inc r12
    jmp .record
.free:
    mov rdi, r14
    call kfree
.out:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; -----------------------------------------------------------------------------
;  objects test
; -----------------------------------------------------------------------------
objects_test:
    push rbx
    mov qword [test_fails], 0
    lea rax, [str_ob_name]
    mov [test_name], rax
    call sched_reap
    call ob_counts
    lea rsi, [ob_now]
    lea rdi, [ob_base]
    mov ecx, 8
    rep movsq
    call ob_basics
    call ob_agent
    call ob_expiry
    call ob_window
    call ob_stress
    call ob_speed
    call ob_leaks
    cmp qword [test_fails], 0
    jne .failed
    KLOG "objects test: passed"
    jmp .out
.failed:
    KLOG "objects test: FAILED (%u)", qword [test_fails]
.out:
    pop rbx
    ret

; ob_counts: what there is now, into ob_now
ob_counts:
    mov rax, [ty_task + TY_LIVE]
    mov [ob_now], rax
    mov rax, [ty_thread + TY_LIVE]
    mov [ob_now + 8], rax
    mov rax, [ty_event + TY_LIVE]
    mov [ob_now + 16], rax
    mov rax, [ty_memory + TY_LIVE]
    mov [ob_now + 24], rax
    mov rax, [task_kernel]
    mov eax, [rax + TK_USED]
    mov [ob_now + 32], rax
    mov rax, [heap_objects]
    mov [ob_now + 40], rax
    mov rax, [vm_count]
    sub rax, [stack_cached]
    mov [ob_now + 48], rax
    ret

; ob_why(RDI = a result, RSI = 48 bytes) -> RAX = " (what the error is)" in
; them, or "" if it is none. Preserves others.
ob_why:
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    lea rax, [str_ob_none]
    cmp rdi, E_ANY
    jb .out
    call err_text
    mov rdi, [rsp + 16]
    SPRINTF rdi, " (%s)", rax
    mov rax, [rsp + 16]
.out:
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    ret

; ob_deadline(EDI = milliseconds from now) -> RAX = that TSC. Preserves others.
ob_deadline:
    push rdx
    mov eax, edi
    imul rax, [tsc_per_ms]
    push rax
    RDTSC64
    add rax, [rsp]
    add rsp, 8
    pop rdx
    ret

; the handles of one event: derived, used, refused, closed
ob_basics:
    push rbx
    push r12
    push r13
    lea rdi, [str_ob_ev]
    call h_event_new
    OB_GOT "making an event"
    mov r12, rax
    mov edi, r12d
    call handle_info
    OB_WANT OT_EVENT, "what a new event's handle says it is"
    mov rax, rdx
    OB_WANT RT_ALL, "the rights of a new event's handle"
    mov edi, r12d
    mov esi, RT_EV_SIGNAL
    xor edx, edx
    call handle_dup
    OB_GOT "deriving a signal-only handle"
    mov r13, rax
    mov edi, r13d
    call handle_info
    mov rax, rdx
    OB_WANT RT_EV_SIGNAL, "the rights of the derived handle"
    mov edi, 1
    call ob_deadline
    mov rsi, rax
    mov edi, r13d
    call h_event_wait
    OB_WANT E_RIGHTS, "waiting through a signal-only handle"
    mov edi, r13d
    call h_event_signal
    OB_WANT 0, "signalling through it"
    mov edi, 100
    call ob_deadline
    mov rsi, rax
    mov edi, r12d
    call h_event_wait
    OB_WANT 0, "waiting for the event it signalled"
    mov edi, r12d
    call h_event_reset
    OB_WANT 0, "resetting it"
    mov edi, 1
    call ob_deadline
    mov rsi, rax
    mov edi, r12d
    call h_event_wait
    OB_WANT E_TIMEOUT, "waiting 1 ms for it, reset"
    mov edi, r13d
    mov esi, RT_ALL
    xor edx, edx
    call handle_dup
    OB_WANT E_RIGHTS, "deriving from a handle without dup"
    mov edi, r13d
    call handle_close
    OB_WANT 0, "closing the derived handle"
    mov edi, r13d
    call handle_close
    OB_WANT E_BADH, "closing it again"
    mov edi, r12d                       ; the slot again, a new generation
    mov esi, RT_EV_SIGNAL
    xor edx, edx
    call handle_dup
    OB_GOT "deriving another"
    mov rbx, rax
    mov eax, ebx
    xor eax, r13d
    cmp eax, 0xFFFF
    seta al
    movzx eax, al
    OB_WANT 1, "a new handle in the closed one's slot, of another generation"
    mov edi, r13d
    call h_event_signal
    OB_WANT E_BADH, "signalling through the closed handle"
    mov edi, ebx
    call h_event_signal
    OB_WANT 0, "signalling through the new one"
    mov edi, ebx
    call handle_close
    OB_WANT 0, "closing it"
    mov edi, r12d
    xor esi, esi
    lea rdx, [ob_buf]
    mov ecx, 16
    call h_mem_read
    OB_WANT E_TYPE, "reading an event as memory"
    mov edi, 0x7FFF1234
    call h_event_signal
    OB_WANT E_BADH, "a handle never given out"
    xor edi, edi
    call h_event_signal
    OB_WANT E_BADH, "handle 0"
    mov edi, r12d
    call handle_close
    OB_WANT 0, "closing the event's handle"
    KLOG "objects test: an event's handles: one derived with fewer rights did what they allow and nothing else; closed, reused, forged and mistyped handles refused"
    pop r13
    pop r12
    pop rbx
    ret

; a task of its own, given narrowed handles; then a revoke
ob_agent:
    push rbx
    push r12
    push r13
    push r14
    push r15
    lea rdi, [ob_ag]
    xor eax, eax
    mov ecx, AG_SIZE / 8
    rep stosq
    lea rdi, [str_ob_agent]
    call h_task_new
    OB_GOT "making a task"
    mov r12, rax                        ; the task
    lea rdi, [str_ob_done]
    call h_event_new
    OB_GOT "making an event"
    mov r13, rax                        ; it signals this
    lea rdi, [str_ob_go]
    call h_event_new
    OB_GOT "making another"
    mov r14, rax                        ; and waits for this
    mov edi, r13d
    mov esi, RT_EV_SIGNAL | RT_GIVE
    xor edx, edx
    call handle_dup
    OB_GOT "deriving a signal-only handle to give"
    mov edi, eax
    mov esi, r12d
    call handle_give
    OB_GOT "giving it to the task"
    mov [ob_ag + AG_SIGNAL], rax
    mov edi, r14d
    mov esi, RT_EV_WAIT | RT_GIVE
    xor edx, edx
    call handle_dup
    OB_GOT "deriving a wait-only handle to give"
    mov edi, eax
    mov esi, r12d
    call handle_give
    OB_GOT "giving that to the task"
    mov [ob_ag + AG_GO], rax
    mov edi, r12d
    lea rsi, [ob_agent_main]
    lea rdx, [ob_ag]
    lea rcx, [str_ob_agent]
    call h_task_spawn
    OB_GOT "starting a thread acting for the task"
    mov r15, rax
    mov edi, 1000
    call ob_deadline
    mov rsi, rax
    mov edi, r13d
    call h_event_wait
    OB_WANT 0, "waiting for the agent to signal"
    mov edi, r13d
    call handle_revoke
    OB_WANT 1, "revoking what was derived from that event"
    mov edi, r14d
    call h_event_signal
    OB_WANT 0, "letting the agent go on"
    mov edi, 1000
    call ob_deadline
    mov rsi, rax
    mov edi, r15d
    call h_thread_wait
    OB_WANT 0, "waiting for the agent's thread to end"
    mov rax, rdx
    OB_WANT 7, "what the agent's thread returned"
    mov rax, [ob_ag + AG_R]
    OB_WANT E_RIGHTS, "the agent waiting through its signal-only handle"
    mov rax, [ob_ag + AG_R + 8]
    OB_WANT E_RIGHTS, "the agent deriving from it"
    mov rax, [ob_ag + AG_R + 16]
    OB_WANT E_TYPE, "the agent giving it to an event"
    mov rax, [ob_ag + AG_R + 24]
    OB_WANT E_BADH, "the agent using a handle it never had"
    mov rax, [ob_ag + AG_R + 32]
    OB_WANT 0, "the agent signalling"
    mov rax, [ob_ag + AG_R + 40]
    OB_WANT 0, "the agent waiting to go on"
    mov rax, [ob_ag + AG_R + 48]
    OB_WANT E_REVOKED, "the agent signalling after the revoke"
    mov edi, r12d                       ; what its task counted
    mov esi, OT_TASK
    xor edx, edx
    call handle_get
    OB_GOT "looking at the task"
    cmp rax, E_ANY
    jae .counted
    mov rbx, rax
    mov rax, [rbx + TK_OPS]
    OB_WANT 7, "the agent's operations"
    mov rax, [rbx + TK_DENIED]
    OB_WANT 5, "the agent's refusals"
    mov rdi, [rbx + OB_ID]
    call ob_audited
    mov [ob_ag_audited], rax
    OB_WANT 5, "the agent's refusals in the audit ring"
    mov edi, [rbx + OB_ID]              ; what it holds: one revoked, one not
    call objects_task
    mov rdi, rbx
    call obj_put
.counted:
    mov edi, r15d
    call handle_close
    OB_WANT 0, "closing the thread's handle"
    mov edi, r12d
    call handle_close
    OB_WANT 0, "closing the task's handle"
    mov edi, r13d
    call handle_close
    OB_WANT 0, "closing an event's handle"
    mov edi, r14d
    call handle_close
    OB_WANT 0, "closing the other's"
    KLOG "objects test: a task given a signal-only and a wait-only handle: it signalled and waited; waiting through the first, deriving from it, giving it to an event and a handle it never had were refused; after a revoke its handle said so; %u refusals in the audit ring", qword [ob_ag_audited]
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

ob_agent_main:                          ; RDI = ob_ag; acts for the agent task
    push rbx
    mov rbx, rdi
    mov edi, 1
    call ob_deadline
    mov rsi, rax
    mov edi, [rbx + AG_SIGNAL]
    call h_event_wait
    mov [rbx + AG_R], rax
    mov edi, [rbx + AG_SIGNAL]
    mov esi, RT_ALL
    xor edx, edx
    call handle_dup
    mov [rbx + AG_R + 8], rax
    mov edi, [rbx + AG_SIGNAL]
    mov esi, [rbx + AG_GO]
    call handle_give
    mov [rbx + AG_R + 16], rax
    mov edi, 0x00010009                 ; a slot it was never given
    call h_event_signal
    mov [rbx + AG_R + 24], rax
    mov edi, [rbx + AG_SIGNAL]
    call h_event_signal
    mov [rbx + AG_R + 32], rax
    mov edi, 1000
    call ob_deadline
    mov rsi, rax
    mov edi, [rbx + AG_GO]
    call h_event_wait
    mov [rbx + AG_R + 40], rax
    mov edi, [rbx + AG_SIGNAL]
    call h_event_signal
    mov [rbx + AG_R + 48], rax
    mov eax, 7
    pop rbx
    ret

; ob_audited(RDI = a task's id) -> RAX = its refusals in the audit ring
ob_audited:
    push rbx
    push rcx
    xor eax, eax
    CAP_LOCK
    mov rcx, [audit_next]
    cmp rcx, AUDIT_LEN
    jbe .count
    mov ecx, AUDIT_LEN
.count:
    lea rbx, [audit_ring]
.record:
    test rcx, rcx
    jz .done
    cmp [rbx + AU_TASK], edi
    jne .next
    cmp byte [rbx + AU_ERR], 0
    je .next
    inc eax
.next:
    add rbx, AU_SIZE
    dec rcx
    jmp .record
.done:
    CAP_UNLOCK
    pop rcx
    pop rbx
    ret

; a handle that expires
ob_expiry:
    push r12
    push r13
    lea rdi, [str_ob_ev]
    call h_event_new
    OB_GOT "making an event"
    mov r12, rax
    mov edi, 2
    call ob_deadline
    mov rdx, rax
    mov edi, r12d
    mov esi, RT_ALL
    call handle_dup
    OB_GOT "deriving a handle that expires in 2 ms"
    mov r13, rax
    mov edi, r13d
    call h_event_signal
    OB_WANT 0, "signalling through it at once"
    mov edi, 3000
    call thread_sleep_us
    mov edi, r13d
    call h_event_signal
    OB_WANT E_EXPIRED, "signalling through it 3 ms later"
    mov edi, r13d
    mov esi, RT_ALL
    xor edx, edx
    call handle_dup
    OB_WANT E_EXPIRED, "deriving from it then"
    mov edi, r13d
    call handle_close
    OB_WANT 0, "closing it"
    mov edi, r12d
    call handle_close
    OB_WANT 0, "closing the event's handle"
    KLOG "objects test: a handle expiring in 2 ms worked at once, and said it had expired 3 ms later"
    pop r13
    pop r12
    ret

; windows on a block of memory
ob_window:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov edi, 8192
    lea rsi, [str_ob_pages]
    call h_mem_new
    OB_GOT "making 8 KiB of memory"
    mov r12, rax
    xor eax, eax
.fill:
    lea rdi, [ob_buf]
    mov [rdi + rax], al
    inc eax
    cmp eax, 256
    jb .fill
    xor ebx, ebx
.write:
    mov edi, r12d
    mov rsi, rbx
    lea rdx, [ob_buf]
    mov ecx, 256
    call h_mem_write
    OB_WANT 256, "writing it"
    add ebx, 256
    cmp ebx, 8192
    jb .write
    mov edi, r12d
    mov rsi, 8192
    lea rdx, [ob_buf]
    mov ecx, 1
    call h_mem_write
    OB_WANT E_RANGE, "writing past its end"
    mov edi, r12d
    mov esi, 4096
    mov edx, 100
    mov ecx, RT_MEM_READ | RT_DUP
    call handle_window
    OB_GOT "a window of 100 bytes at 4096"
    mov r13, rax
    mov edi, r13d
    xor esi, esi
    lea rdx, [ob_buf2]
    mov ecx, 100
    call h_mem_read
    OB_WANT 100, "reading the window"
    movzx eax, byte [ob_buf2 + 99]
    OB_WANT 99, "the window's last byte, 4195 bytes in"
    mov edi, r13d
    mov esi, 50
    lea rdx, [ob_buf2]
    mov ecx, 100
    call h_mem_read
    OB_WANT E_RANGE, "reading past the window's end"
    mov edi, r13d
    xor esi, esi
    lea rdx, [ob_buf]
    mov ecx, 10
    call h_mem_write
    OB_WANT E_RIGHTS, "writing through a read-only window"
    mov edi, r13d
    xor esi, esi
    mov edx, 200
    mov ecx, RT_ALL
    call handle_window
    OB_WANT E_RANGE, "widening the window"
    mov edi, r13d
    mov esi, 10
    mov edx, 20
    mov ecx, RT_ALL
    call handle_window
    OB_GOT "a window inside the window"
    mov r14, rax
    mov edi, r14d
    xor esi, esi
    lea rdx, [ob_buf2]
    mov ecx, 20
    call h_mem_read
    OB_WANT 20, "reading it"
    movzx eax, byte [ob_buf2]
    OB_WANT 10, "its first byte, 4106 bytes in"
    mov edi, r14d
    call handle_info
    mov rax, rdx
    OB_WANT RT_MEM_READ | RT_DUP, "its rights, no more than the window's"
    lea rdi, [str_ob_ev]
    call h_event_new
    OB_GOT "making an event"
    mov r15, rax
    mov edi, r15d
    xor esi, esi
    mov edx, 1
    mov ecx, RT_ALL
    call handle_window
    OB_WANT E_TYPE, "a window on an event"
    mov edi, r15d
    call handle_close
    mov edi, r14d
    call handle_close
    OB_WANT 0, "closing the inner window"
    mov edi, r13d
    call handle_close
    OB_WANT 0, "closing the window"
    mov edi, r12d
    call handle_close
    OB_WANT 0, "closing the memory's handle"
    KLOG "objects test: a read-only window of 100 bytes at 4096 of 8 KiB read its bytes; reading past it, writing and widening it were refused; a window inside it read the right bytes"
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; threads deriving and closing handles while their parent is revoked
ob_stress:
    push rbx
    push r12
    push r13
    push r14
    push r15
    lea rdi, [str_ob_shared]
    call h_event_new
    OB_GOT "making an event"
    mov r12, rax
    mov byte [ob_stop], 0
    lea rdi, [ob_workers]
    xor eax, eax
    mov ecx, OBT_WORKERS * OW_SIZE / 8
    rep stosq
    mov r15d, [cpus_online]
    cmp r15d, OBT_WORKERS
    jbe .some
    mov r15d, OBT_WORKERS
.some:
    cmp r15d, 2
    jae .enough
    mov r15d, 2
.enough:
    xor ebx, ebx
.start:
    cmp ebx, r15d
    jae .started
    imul rsi, rbx, OW_SIZE
    lea rax, [ob_workers]
    add rsi, rax
    mov [rsi + OW_H], r12
    push rsi
    lea rdi, [ob_worker]
    lea rdx, [str_ob_worker]
    mov ecx, THC_ANY
    call thread_spawn
    pop rsi
    mov [rsi + OW_TH], rax
    inc ebx
    jmp .start
.started:
    mov edi, OBT_STRESS_MS
    call ob_deadline
    mov r14, rax
    xor r13d, r13d                      ; revokes
    mov qword [ob_revoked], 0
.revoke:
    mov edi, r12d
    call handle_revoke
    OB_GOT "revoking"
    test rax, rax
    js .revoked
    add [ob_revoked], rax
.revoked:
    inc r13
    mov edi, 500
    call thread_sleep_us
    RDTSC64
    cmp rax, r14
    jb .revoke
    mov byte [ob_stop], 1
    xor ebx, ebx
    mov qword [ob_ops], 0
    mov qword [ob_odd], 0
.join:
    cmp ebx, r15d
    jae .joined
    imul rsi, rbx, OW_SIZE
    lea rax, [ob_workers]
    add rsi, rax
    mov rax, [rsi + OW_OPS]
    add [ob_ops], rax
    mov rdi, [rsi + OW_TH]
    test rdi, rdi
    jz .no_thread
    push rsi
    call thread_join
    pop rsi
.no_thread:
    mov rax, [rsi + OW_OPS]             ; counted once it ended
    mov rcx, [rsi + OW_ODD]
    add [ob_odd], rcx
    inc ebx
    jmp .join
.joined:
    xor ebx, ebx                        ; the operations, now final
    mov qword [ob_ops], 0
.sum:
    cmp ebx, r15d
    jae .summed
    imul rsi, rbx, OW_SIZE
    lea rax, [ob_workers]
    add rsi, rax
    mov rax, [rsi + OW_OPS]
    add [ob_ops], rax
    inc ebx
    jmp .sum
.summed:
    mov edi, r12d                       ; and what the event has now
    mov esi, OT_EVENT
    xor edx, edx
    call handle_get
    OB_GOT "looking at the event"
    xor ecx, ecx
    xor edx, edx
    cmp rax, E_ANY
    jae .looked
    mov ecx, [rax + OB_CAPS]
    mov edx, [rax + OB_REFS]
    mov rdi, rax
    call obj_put
.looked:
    mov [ob_caps], rcx
    mov [ob_refs], rdx
    mov edi, r12d
    call handle_close
    OB_WANT 0, "closing the event's handle"
    KLOG "objects test: %u threads deriving, using and closing handles to one event while what was derived from it was revoked %u times (%u handles in all): %u operations, %u unexpected results; then %u capability and %u references to it", r15, r13, qword [ob_revoked], qword [ob_ops], qword [ob_odd], qword [ob_caps], qword [ob_refs]
    mov rax, [ob_odd]
    OB_WANT 0, "unexpected results"
    mov rax, [ob_caps]
    OB_WANT 1, "the event's capabilities after"
    mov rax, [ob_refs]
    OB_WANT 2, "its references after (the handle's and the look's)"
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

ob_worker:                              ; RDI = its OW_* slot
    push rbx
    push r12
    push r13
    mov rbx, rdi
.loop:
    cmp byte [ob_stop], 0
    jne .done
    mov edi, [rbx + OW_H]               ; from the root, which is never revoked
    mov esi, RT_ALL
    xor edx, edx
    call handle_dup
    inc qword [rbx + OW_OPS]
    test rax, rax
    js .odd
    mov r12, rax
    mov edi, r12d                       ; from that, which may be revoked by now
    mov esi, RT_EV_SIGNAL | RT_DUP
    xor edx, edx
    call handle_dup
    inc qword [rbx + OW_OPS]
    mov r13, rax
    test rax, rax
    jns .derived
    cmp rax, E_REVOKED
    je .close_first
    inc qword [rbx + OW_ODD]
    jmp .close_first
.derived:
    mov edi, r13d
    call h_event_signal
    inc qword [rbx + OW_OPS]
    test rax, rax
    jz .signalled
    cmp rax, E_REVOKED
    je .signalled
    inc qword [rbx + OW_ODD]
.signalled:
    mov edi, r13d
    call handle_close
    inc qword [rbx + OW_OPS]
    test rax, rax
    jz .close_first
    inc qword [rbx + OW_ODD]
.close_first:
    mov edi, r12d
    call handle_close
    inc qword [rbx + OW_OPS]
    test rax, rax
    jz .loop
.odd:
    inc qword [rbx + OW_ODD]
    jmp .loop
.done:
    xor eax, eax
    pop r13
    pop r12
    pop rbx
    ret

; how long the common operations take
ob_speed:
    push rbx
    push r12
    push r13
    lea rdi, [str_ob_ev]
    call h_event_new
    OB_GOT "making an event"
    mov r12, rax
    RDTSC64
    mov r13, rax
    mov ebx, OBT_SIGNALS
.signal:
    mov edi, r12d
    call h_event_signal
    dec ebx
    jnz .signal
    RDTSC64
    sub rax, r13
    mov ecx, OBT_SIGNALS
    call ob_ns
    mov [ob_signal_ns], rax
    RDTSC64
    mov r13, rax
    mov ebx, OBT_DUPS
.dup:
    mov edi, r12d
    mov esi, RT_ALL
    xor edx, edx
    call handle_dup
    mov edi, eax
    call handle_close
    dec ebx
    jnz .dup
    RDTSC64
    sub rax, r13
    mov ecx, OBT_DUPS
    call ob_ns
    mov [ob_dup_ns], rax
    mov edi, r12d
    call handle_close
    KLOG "objects test: signalling an event by handle (finding it, checking it, signalling) %u ns; deriving a handle and closing it %u ns", qword [ob_signal_ns], qword [ob_dup_ns]
    pop r13
    pop r12
    pop rbx
    ret

; ob_ns(RAX = TSC ticks, ECX = times) -> RAX = nanoseconds each
ob_ns:
    imul rax, rax, 1000
    xor edx, edx
    div qword [tsc_per_us]
    xor edx, edx
    div rcx
    ret

; everything made is gone
ob_leaks:
    mov edi, 20000
    call thread_sleep_us
    call sched_reap
    call ob_counts
    KLOG "objects test: %u tasks (%u before), %u threads (%u), %u events (%u), %u blocks of memory (%u), %u handles held by the kernel (%u), %u heap objects (%u), %u vm mappings (%u)", qword [ob_now], qword [ob_base], qword [ob_now + 8], qword [ob_base + 8], qword [ob_now + 16], qword [ob_base + 16], qword [ob_now + 24], qword [ob_base + 24], qword [ob_now + 32], qword [ob_base + 32], qword [ob_now + 40], qword [ob_base + 40], qword [ob_now + 48], qword [ob_base + 48]
    xor ecx, ecx
.compare:
    lea rdx, [ob_now]
    mov rax, [rdx + rcx * 8]
    lea rdx, [ob_base]
    cmp rax, [rdx + rcx * 8]
    jne .leak
    inc ecx
    cmp ecx, 7
    jb .compare
    ret
.leak:
    KLOG "objects test: not all of it came back"
    inc qword [test_fails]
    ret

section .rodata
str_ob_test:    db 'test', 0
str_ob_none:    db 0
str_ob_name:    db 'objects test', 0
str_ob_audit:   db 'audit', 0
str_ob_ev:      db 'test', 0
str_ob_agent:   db 'agent', 0
str_ob_done:    db 'done', 0
str_ob_go:      db 'go', 0
str_ob_pages:   db 'pages', 0
str_ob_shared:  db 'shared', 0
str_ob_worker:  db 'worker', 0
str_ao_none:    db '?', 0
str_ao_make:    db 'make', 0
str_ao_dup:     db 'dup', 0
str_ao_window:  db 'window', 0
str_ao_give:    db 'give', 0
str_ao_close:   db 'close', 0
str_ao_revoke:  db 'revoke', 0
str_ao_use:     db 'use', 0
str_ao_end:     db 'end', 0

align 8
ao_names:       dq str_ao_none, str_ao_make, str_ao_dup, str_ao_window, str_ao_give
                dq str_ao_close, str_ao_revoke, str_ao_use, str_ao_end

section .bss
alignb 8
test_fails:     resq 1                  ; of the self-test running
test_name:      resq 1                  ; and what it is called
ob_base:        resq 8
ob_now:         resq 8
ob_ag:          resb AG_SIZE
ob_ag_audited:  resq 1
ob_revoked:     resq 1
ob_ops:         resq 1
ob_odd:         resq 1
ob_caps:        resq 1
ob_refs:        resq 1
ob_signal_ns:   resq 1
ob_dup_ns:      resq 1
ob_workers:     resb OBT_WORKERS * OW_SIZE
ob_obj:         resb 64
ob_rights:      resb 64
ob_exp:         resb 32
ob_from:        resb 48
ob_other:       resb 48
ob_why_a:       resb 48
ob_why_b:       resb 48
ob_buf:         resb 256
ob_buf2:        resb 256
ob_stop:        resb 1
