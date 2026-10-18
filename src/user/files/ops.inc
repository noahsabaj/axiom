; =============================================================================
;  files/ops.inc - what is done to things: opening them (a folder in place,
;  text in Notes), looking at them, renaming, making, duplicating, copying,
;  moving and deleting them; and saying what went wrong
;
;  Paths go to the files in the ax_io page (or, for a file's bytes, in
;  memory of their own). Writing needs a volume the user made writable
;  ('vol <n> rw' in Terminal); Files says so rather than ask for it.
; =============================================================================

QL_MEM          equ 256 * 1024          ; a file looked at: as much as fits
QL_REC          equ FE_NAME + FS_PATH
COPY_MAX        equ 16 * 1024 * 1024    ; the largest file copied
RM_MEM          equ 64 * 1024           ; a folder's listing, deleting it
DEPTH_MAX       equ 16                  ; folders in folders, deleting them
KIDS_MAX        equ 32

section .text

; say(RSI = NUL-ended): in the path bar, until the next key or press
say:
    mov [said], rsi
    or dword [need], N_PATH
    ret

; say_name(RSI = before, RDX = a name, RCX = after): before “name”after
say_name:
    push rcx
    push rdx
    lea rdi, [said_buf]
    call str_cat
    lea rsi, [s_lq]
    call str_cat
    pop rsi
    call str_cat
    lea rsi, [s_rq]
    call str_cat
    pop rsi
    call str_cat
    mov byte [rdi], 0
    lea rsi, [said_buf]
    jmp say

; say_error(RAX = E_*)
say_error:
    call error_text
    mov rsi, rax
    jmp say

; error_text(RAX = E_*) -> RAX = what it means, to the user
error_text:
    cmp eax, E_READONLY
    je .readonly
    lea rsi, [errors]
.each:
    cmp dword [rsi], 0
    je .other
    cmp eax, [rsi]
    je .found
    add rsi, 12
    jmp .each
.found:
    mov rax, [rsi + 4]
    ret
.other:
    push rax
    lea rdi, [err_buf]
    lea rsi, [s_e_other]
    call str_cat
    pop rax
    neg eax
    mov byte [rdi], '-'
    inc rdi
    call put_dec
    mov word [rdi], ').'
    mov byte [rdi + 2], 0
    lea rax, [err_buf]
    ret
.readonly:
    call dir_vol
    test eax, eax
    jns readonly_said
    lea rax, [s_e_ro_folder]
    ret

; readonly_said(EAX = a volume's n) -> RAX = how to make it writable, said
readonly_said:
    lea rdi, [ro_buf]
    push rax
    lea rsi, [s_ro1]
    call str_cat
    pop rax
    call put_dec
    lea rsi, [s_ro2]
    call str_cat
    mov byte [rdi], 0
    lea rax, [ro_buf]
    mov [said], rax
    or dword [need], N_PATH
    ret

; relist: the folder read again, keep_name chosen and in sight
relist:
    call list_dir
    call clamp_scroll
    call reveal
    mov dword [need], N_ALL
    ret

; -----------------------------------------------------------------------------
;  Opening
; -----------------------------------------------------------------------------

; op_open: a folder in place; text in Notes
op_open:
    call sel_entry
    jc .out
    test dword [rsi + FE_ATTR], FEA_DIR
    jz .file
    add rsi, FE_NAME
    call join
    lea rsi, [path_buf]
    jmp nav_to
.file:
    push rbx
    mov rbx, rsi
    call kind_of
    call kind_rec
    mov eax, [rsi + KD_FLAGS]
    test eax, KK_TEXT
    jnz .text
    test eax, KK_PROG
    jnz .program
    call sniff
    jnc .text
    lea rsi, [s_no_app]
    lea rdx, [rbx + FE_NAME]
    lea rcx, [s_stop]
    call say_name
    jmp .done
.program:
    lea rsi, [s_program]
    call say
    jmp .done
.text:
    call open_notes
.done:
    pop rbx
.out:
    ret

; sniff(RBX = a file's record) -> CF if it is not text: a NUL in its first
; page
sniff:
    call ql_ensure
    jc .no
    mov rdi, [ql_va]
    lea rsi, [rbx + FE_NAME]
    call join_to
    mov eax, RO_FS_READ
    mov edi, [ql_h]
    xor esi, esi
    mov edx, FS_PATH
    mov ecx, 4096
    call fsq
    test rax, rax
    js .no
    cmp rax, 4096
    jbe .some
    mov eax, 4096
.some:
    mov ecx, eax
    test ecx, ecx
    jz .yes
    mov rdi, [ql_va]
    add rdi, FS_PATH
    xor eax, eax
    repne scasb
    je .no
.yes:
    clc
    ret
.no:
    stc
    ret

; open_notes(RBX = a file's record): Notes, given this folder alone and a
; window on the desktop
open_notes:
    push r12
    push r13
    call kids_prune
    cmp dword [kids_n], KIDS_MAX
    jae .many
    mov rdi, [ax_io_va]                 ; this folder, alone
    lea rsi, [dir]
    call str_copy
    mov eax, RO_FS_SUB
    mov edi, [ax_io]
    xor esi, esi
    mov edx, RT_FS_READ | RT_FS_WRITE
    xor ecx, ecx
    call fsq
    test rax, rax
    js .failed
    mov r12d, eax                       ; R12D: it
    mov eax, RO_DUP                     ; windows on the desktop
    mov edi, [ax_desk]
    xor esi, esi
    mov edx, RT_DESK_WINDOW | RT_GIVE | RT_INFO
    xor ecx, ecx
    xor r8d, r8d
    call ring_op
    test rax, rax
    js .no_desk
    mov r13d, eax                       ; R13D: that
    lea rdi, [spawn_buf]
    lea rsi, [s_notes_q]
    call str_cat
    lea rsi, [rbx + FE_NAME]
    call str_cat
    mov word [rdi], '"'
    lea rsi, [spawn_buf]
    mov edi, r12d
    mov edx, r13d
    call ax_spawn2
    test rax, rax
    js .no_spawn
    mov r12d, edx                       ; its first thread, to wait for
    mov edi, eax
    call k_close
    mov eax, [kids_n]
    mov [kids + rax * 4], r12d
    inc dword [kids_n]
    jmp .out
.no_spawn:
    push rax
    mov edi, r12d                       ; not given, still ours
    call k_close
    mov edi, r13d
    call k_close
    pop rax
    jmp .failed
.no_desk:
    push rax
    mov edi, r12d
    call k_close
    pop rax
.failed:
    call say_error
    jmp .out
.many:
    lea rsi, [s_many]
    call say
.out:
    pop r13
    pop r12
    ret

; kids_prune: the Notes that have ended let go of
kids_prune:
    push rbx
    xor ebx, ebx
.each:
    cmp ebx, [kids_n]
    jae .out
    mov qword [ring_deadline], 1        ; long past: whether it has ended
    mov eax, RO_JOIN
    mov edi, [kids + rbx * 4]
    xor esi, esi
    xor edx, edx
    xor ecx, ecx
    xor r8d, r8d
    call ring_op
    mov qword [ring_deadline], 0
    cmp rax, E_TIMEOUT
    je .next
    mov edi, [kids + rbx * 4]           ; ended: its place to the last's
    call k_close
    dec dword [kids_n]
    mov eax, [kids_n]
    mov eax, [kids + rax * 4]
    mov [kids + rbx * 4], eax
    jmp .each
.next:
    inc ebx
    jmp .each
.out:
    pop rbx
    ret

; -----------------------------------------------------------------------------
;  Looking
; -----------------------------------------------------------------------------

; ql_ensure -> CF if there is no memory to look at a file with
ql_ensure:
    cmp qword [ql_va], 0
    jne .have
    mov edi, QL_MEM
    call kit_alloc
    jc .out
    mov [ql_va], rax
    mov [ql_h], edx
.have:
    clc
.out:
    ret

; look_open: a look at what is chosen
look_open:
    call sel_entry
    jc .out
    call look_load
    mov dword [over], O_LOOK
    mov dword [need], N_ALL
.out:
    ret

look_close:
    mov dword [over], 0
    mov dword [need], N_ALL
    ret

; look_load: what is chosen read, to look at: its text, if it is text
look_load:
    push rbx
    call sel_entry
    jc .out
    mov rbx, rsi
    mov ecx, [rbx + FE_LEN]             ; its record, kept
    cmp ecx, QL_REC
    jbe .len
    mov ecx, QL_REC
.len:
    lea rdi, [ql_rec]
    rep movsb
    mov byte [ql_rec + QL_REC - 1], 0
    lea rsi, [rbx + FE_NAME]
    lea rdi, [ql_name]
    call str_copy
    mov dword [ql_text], 0
    mov dword [ql_top], 0
    mov dword [ql_lines], 1
    mov qword [ql_len], 0
    mov dword [need], N_ALL
    test dword [rbx + FE_ATTR], FEA_DIR
    jnz .out
    mov rsi, rbx
    call kind_of
    call kind_rec
    test dword [rsi + KD_FLAGS], KK_PROG
    jnz .out
    call ql_ensure
    jc .out
    mov rdi, [ql_va]
    lea rsi, [rbx + FE_NAME]
    call join_to
    mov eax, RO_FS_READ
    mov edi, [ql_h]
    xor esi, esi
    mov edx, FS_PATH
    mov ecx, QL_MEM - FS_PATH
    call fsq
    test rax, rax
    js .out
    cmp rax, QL_MEM - FS_PATH
    jbe .read
    mov eax, QL_MEM - FS_PATH
.read:
    mov [ql_len], rax
    mov rcx, rax
    test rcx, rcx
    jz .text
    mov rdi, [ql_va]                    ; text: no NUL in it
    add rdi, FS_PATH
    push rdi
    push rcx
    xor eax, eax
    repne scasb
    pop rcx
    pop rdi
    je .out
    mov al, 10                          ; and how many lines
    xor edx, edx
.count:
    repne scasb
    jne .counted
    inc edx
    test rcx, rcx
    jnz .count
.counted:
    inc edx
    mov [ql_lines], edx
.text:
    mov dword [ql_text], 1
.out:
    pop rbx
    ret

; -----------------------------------------------------------------------------
;  Names
; -----------------------------------------------------------------------------

; rename_start: the name chosen to be typed again, all but its ending chosen
rename_start:
    call sel_entry
    jc .out
    push rbx
    mov rbx, rsi
    call dir_writable
    jc .done
    lea rax, [rename_buf]
    mov [f_rename + KE_BUF], rax
    mov dword [f_rename + KE_CAP], NAME_CAP
    mov dword [f_rename + KE_INDENT], 0
    lea rsi, [rbx + FE_NAME]
    lea rdi, [ren_old]
    call str_copy
    call k_slen
    cmp ecx, NAME_CAP
    jbe .fits
    mov ecx, NAME_CAP
.fits:
    lea r8, [f_rename]
    call kit_eset
    mov dword [f_rename + KE_ANCHOR], 0
    mov eax, [f_rename + KE_LEN]
    test dword [rbx + FE_ATTR], FEA_DIR
    jnz .caret
    lea rsi, [ren_old]
    call ext_of
    jc .caret
    lea rax, [ren_old]
    sub rsi, rax
    lea eax, [rsi - 1]
.caret:
    mov [f_rename + KE_CARET], eax
    mov dword [kfocus], K_RENAME
    call caret_reset
    call reveal
    or dword [need], N_MAIN
.done:
    pop rbx
.out:
    ret

; rename_key(R12D, R13D): a name being typed has the keys
rename_key:
    cmp r12d, 10
    je rename_commit
    cmp r12d, 9
    je rename_commit
    cmp r12d, 27
    je rename_cancel
    lea r8, [f_rename]
    mov eax, r12d
    mov edx, r13d
    call kit_ekey
    or dword [need], N_MAIN
    ret

rename_cancel:
    mov dword [kfocus], 0
    or dword [need], N_MAIN
    ret

; rename_commit: the name typed given to what is chosen
rename_commit:
    mov dword [kfocus], 0
    or dword [need], N_MAIN | N_PATH
    mov ecx, [f_rename + KE_LEN]
    mov rsi, [f_rename + KE_BUF]
    lea rdi, [ren_new]
    rep movsb
    mov byte [rdi], 0
    lea rdi, [ren_new]
    call trim
    cmp byte [ren_new], 0
    je .out
    lea rsi, [ren_new]
    lea rdi, [ren_old]
    call str_eq
    je .out
    lea rsi, [ren_new]
    call name_ok
    jc .out
    lea rsi, [ren_new]                  ; its case changed: itself, not another
    lea rdi, [ren_old]
    call same_name
    je .rename
    lea rsi, [ren_new]
    call exists
    je .taken
.rename:
    lea rsi, [ren_old]
    lea rdi, [path_buf2]
    call join_to
    lea rsi, [ren_new]
    lea rdi, [path_buf]
    call join_to
    lea rsi, [path_buf2]
    lea rdx, [path_buf]
    call rename_paths
    test rax, rax
    js say_error
    lea rsi, [ren_new]
    lea rdi, [keep_name]
    call str_copy
    jmp relist
.taken:
    lea rsi, [s_taken]
    lea rdx, [ren_new]
    lea rcx, [s_taken2]
    jmp say_name
.out:
    ret

; trim(RDI = NUL-ended): no blanks at its start or end
trim:
    mov rsi, rdi
.lead:
    cmp byte [rsi], ' '
    jne .copy
    inc rsi
    jmp .lead
.copy:
    push rdi
    call str_copy
    call k_slen_rdi
.tail:
    test ecx, ecx
    jz .done
    cmp byte [rdi + rcx - 1], ' '
    jne .done
    dec ecx
    mov byte [rdi + rcx], 0
    jmp .tail
.done:
    pop rdi
    ret

; k_slen_rdi(RDI = NUL-ended) -> ECX = its bytes. Preserves others.
k_slen_rdi:
    push rsi
    mov rsi, rdi
    call k_slen
    pop rsi
    ret

; name_ok(RSI = a name) -> CF (said why) if a name cannot be that
name_ok:
    push rsi
    cmp byte [rsi], '.'                 ; it would be hidden
    je .bad
.each:
    lodsb
    test al, al
    jz .ok
    cmp al, ' '
    jb .bad
    lea rdi, [s_bad_chars]
.char:
    mov ah, [rdi]
    test ah, ah
    jz .each
    cmp al, ah
    je .bad
    inc rdi
    jmp .char
.ok:
    pop rsi
    clc
    ret
.bad:
    pop rsi
    lea rsi, [s_bad_name]
    call say
    stc
    ret

; rename_paths(RSI = a path, RDX = its new one) -> RAX: renamed, or moved
rename_paths:
    mov rdi, [ax_io_va]
    call str_copy
    mov rsi, rdx
    add rdi, FS_PATH
    call str_copy
    mov eax, RO_FS_RENAME
    mov edi, [ax_io]
    xor esi, esi
    mov edx, FS_PATH
    xor ecx, ecx
    jmp fsq

; unique_name(RSI = a name, RDX = an ending, or 0) -> new_name: it, or
; "name 2", "name 3"..., whichever is not here yet
unique_name:
    push rbx
    push r12
    push r13
    mov r12, rsi
    mov r13, rdx
    xor ebx, ebx                        ; EBX: its number, 0 for none
.try:
    lea rdi, [new_name]
    mov rsi, r12
    call str_cat
    test ebx, ebx
    jz .number
    mov byte [rdi], ' '
    inc rdi
    mov eax, ebx
    call put_dec
.number:
    test r13, r13
    jz .ended
    mov rsi, r13
    call str_cat
.ended:
    mov byte [rdi], 0
    lea rsi, [new_name]
    call exists
    jne .out
    test ebx, ebx
    jnz .next
    inc ebx
.next:
    inc ebx
    cmp ebx, 1000
    jb .try
.out:
    pop r13
    pop r12
    pop rbx
    ret

; copy_name(RSI = a name) -> new_name: "name copy.ext", not here yet
copy_name:
    lea rdi, [dup_base]
    call str_copy
    mov byte [dup_ext], 0
    push rsi
    call ext_of
    jc .plain
    dec rsi                             ; from its '.'
    lea rdi, [dup_ext]
    call str_copy
    mov rax, rsi
    pop rsi
    sub rax, rsi
    mov byte [dup_base + rax], 0
    jmp .base
.plain:
    pop rsi
.base:
    lea rdi, [dup_base]
    call k_slen_rdi
    add rdi, rcx
    lea rsi, [s_copy]
    call str_cat
    mov byte [rdi], 0
    lea rsi, [dup_base]
    lea rdx, [dup_ext]
    jmp unique_name

; -----------------------------------------------------------------------------
;  Making, duplicating, deleting
; -----------------------------------------------------------------------------

; op_newdir: "untitled folder", its name to be typed
op_newdir:
    call dir_writable
    jc .out
    lea rsi, [s_new_dir]
    xor edx, edx
    call unique_name
    mov rdi, [ax_io_va]
    lea rsi, [new_name]
    call join_to
    mov eax, RO_FS_MKDIR
    mov edi, [ax_io]
    xor esi, esi
    xor edx, edx
    xor ecx, ecx
    call fsq
    jmp made
.out:
    ret

; op_newtxt: "untitled.txt", empty, its name to be typed
op_newtxt:
    call dir_writable
    jc .out
    lea rsi, [s_new_txt]
    lea rdx, [s_txt]
    call unique_name
    mov rdi, [ax_io_va]
    lea rsi, [new_name]
    call join_to
    mov eax, RO_FS_WRITE
    mov edi, [ax_io]
    xor esi, esi
    mov edx, FS_PATH
    xor ecx, ecx
    call fsq
    jmp made
.out:
    ret

; made(RAX = what the files said): new_name made: chosen, in sight, its name
; to be typed
made:
    test rax, rax
    js say_error
    call search_clear                   ; not hidden by a search
    or dword [need], N_TOOL
    lea rsi, [new_name]
    lea rdi, [keep_name]
    call str_copy
    call relist
    jmp rename_start

; op_dup: a copy of the file chosen, beside it
op_dup:
    call sel_entry
    jc .out
    push rbx
    mov rbx, rsi
    test dword [rbx + FE_ATTR], FEA_DIR
    jnz .folder
    call dir_writable
    jc .done
    lea rsi, [rbx + FE_NAME]
    call copy_name
    lea rsi, [rbx + FE_NAME]
    lea rdi, [path_buf2]
    call join_to
    lea rsi, [new_name]
    lea rdi, [path_buf]
    call join_to
    lea rsi, [path_buf2]
    lea rdx, [path_buf]
    mov rcx, [rbx + FE_SIZE]
    call copy_file
    test rax, rax
    js .failed
    lea rsi, [new_name]
    lea rdi, [keep_name]
    call str_copy
    call relist
    jmp .done
.folder:
    lea rsi, [s_no_dup_dir]
    call say
    jmp .done
.failed:
    call say_error
.done:
    pop rbx
.out:
    ret

; copy_file(RSI = a file's path, RDX = where its copy goes, RCX = its size)
; -> RAX = 0, or E_*
copy_file:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov r12, rsi
    mov r13, rdx
    mov rbx, rcx
    mov rax, E_RANGE
    cmp rbx, COPY_MAX
    ja .out
    lea rdi, [rbx + FS_PATH + 4095]
    and edi, -4096
    call kit_alloc
    mov r8, rax
    mov rax, E_NOMEM
    jc .out
    mov r14, r8                         ; R14: its bytes, after a path
    mov r15d, edx                       ; R15D: their handle
    mov rdi, r14
    mov rsi, r12
    call str_copy
    mov eax, RO_FS_READ
    mov edi, r15d
    xor esi, esi
    mov edx, FS_PATH
    mov rcx, rbx
    call fsq
    test rax, rax
    js .free
    cmp rax, rbx                        ; grown meanwhile: as much as was read
    jae .size
    mov rbx, rax
.size:
    mov rdi, r14
    mov rsi, r13
    call str_copy
    mov eax, RO_FS_WRITE
    mov edi, r15d
    xor esi, esi
    mov edx, FS_PATH
    mov rcx, rbx
    call fsq
.free:
    push rax
    mov edi, r15d
    call kit_free
    pop rax
.out:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; op_ask_delete: whether to delete what is chosen
op_ask_delete:
    call sel_entry
    jc .out
    push rsi
    call dir_writable
    pop rsi
    jc .out
    mov eax, [rsi + FE_ATTR]
    and eax, FEA_DIR
    mov [alert_dir], eax
    add rsi, FE_NAME
    lea rdi, [alert_name]
    call str_copy
    mov dword [over], O_ALERT
    mov dword [need], N_ALL
.out:
    ret

; op_delete: it deleted, and all it held; the next chosen in its place
op_delete:
    call alert_close
    lea rsi, [alert_name]
    lea rdi, [rm_path]
    call join_to
    mov dword [rm_depth], 0
    call remove_tree
    test rax, rax
    js .failed
    mov byte [keep_name], 0
    push qword [sel]
    call list_dir
    pop rax
    cmp eax, [n]
    jb .in
    mov eax, [n]
    dec eax
.in:
    mov [sel], eax
    call clamp_scroll
    call reveal
    mov dword [need], N_ALL
    ret
.failed:
    push rax
    call remember
    call relist
    pop rax
    jmp say_error

; rm_one -> RAX: rm_path removed (a file, or an empty folder)
rm_one:
    mov rdi, [ax_io_va]
    lea rsi, [rm_path]
    call str_copy
    mov eax, RO_FS_REMOVE
    mov edi, [ax_io]
    xor esi, esi
    xor edx, edx
    xor ecx, ecx
    jmp fsq

; remove_tree -> RAX: rm_path removed, and if a folder, what it holds first
remove_tree:
    push rbx
    push r12
    push r13
    push r14
    push r15
    call rm_one
    test rax, rax
    jz .out
    cmp rax, E_ARG                      ; a folder with things in it
    jne .out
    cmp dword [rm_depth], DEPTH_MAX
    jae .out
    lea rsi, [rm_path]
    call k_slen
    mov r15d, ecx                       ; R15D: rm_path's length here
    mov edi, RM_MEM
    call kit_alloc
    mov r8, rax
    mov rax, E_NOMEM
    jc .out
    mov r12, r8                         ; R12: its listing
    mov r13d, edx                       ; R13D: that memory
    inc dword [rm_depth]
.list:
    mov rdi, r12
    lea rsi, [rm_path]
    call str_copy
    mov eax, RO_FS_LIST
    mov edi, r13d
    xor esi, esi
    mov edx, FS_PATH
    mov ecx, RM_MEM - FS_PATH
    call fsq
    test rax, rax
    js .done
    mov ebx, eax                        ; EBX: how many
    lea r14, [r12 + FS_PATH]            ; R14: one
    mov dword [rm_gone], 0
.each:
    test ebx, ebx
    jz .listed
    lea rax, [r14 + FE_NAME + FS_PATH]
    lea rcx, [r12 + RM_MEM]
    cmp rax, rcx
    ja .listed
    mov eax, [r14 + FE_LEN]
    test eax, eax
    jz .listed
    cmp word [r14 + FE_NAME], '.'       ; not "." nor ".."
    je .next
    cmp word [r14 + FE_NAME], '..'
    jne .take
    cmp byte [r14 + FE_NAME + 2], 0
    je .next
.take:
    lea rsi, [r14 + FE_NAME]            ; its path: this one's, '/', its name
    call k_slen
    lea eax, [r15 + rcx + 2]
    cmp eax, FS_PATH
    jae .next
    mov byte [rm_path + r15], '/'
    lea rdi, [rm_path + r15 + 1]
    call str_copy
    call remove_tree
    mov byte [rm_path + r15], 0
    test rax, rax
    js .done
    inc dword [rm_gone]
.next:
    mov eax, [r14 + FE_LEN]
    add r14, rax
    dec ebx
    jmp .each
.listed:
    call rm_one                         ; empty now, or more to list
    test rax, rax
    jz .done
    cmp rax, E_ARG
    jne .done
    cmp dword [rm_gone], 0
    jne .list
.done:
    push rax
    dec dword [rm_depth]
    mov edi, r13d
    call kit_free
    pop rax
.out:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; -----------------------------------------------------------------------------
;  Copying and moving
; -----------------------------------------------------------------------------

op_copy:
    xor eax, eax
    jmp clip_take
op_cut:
    mov eax, 1
; clip_take(EAX = 1 to move it): what is chosen, to paste
clip_take:
    push rax
    call sel_entry
    pop rax
    jc .out
    mov [clip_cut], eax
    mov ecx, [rsi + FE_ATTR]
    and ecx, FEA_DIR
    mov [clip_dir], ecx
    mov rax, [rsi + FE_SIZE]
    mov [clip_size], rax
    add rsi, FE_NAME
    push rsi
    lea rdi, [clip_path]
    call join_to
    pop rdx
    lea rsi, [s_copied]
    cmp dword [clip_cut], 0
    je .say
    lea rsi, [s_cut]
.say:
    lea rcx, [s_to_paste]
    jmp say_name
.out:
    ret

; op_paste: what was copied, copied here; what was cut, moved here
op_paste:
    cmp byte [clip_path], 0
    je .out
    call dir_writable
    jc .out
    push rbx
    lea rsi, [clip_path]
    call last_name
    mov rbx, rsi                        ; RBX: its name
    cmp dword [clip_dir], 0             ; a folder: not into itself
    je .where
    lea rsi, [clip_path]
    lea rdi, [dir]
    call path_under
    jc .inside
.where:
    lea rsi, [clip_path]                ; from this folder?
    lea rdi, [path_buf2]
    call str_copy
    lea rdi, [path_buf2]
    call parent_of
    lea rsi, [path_buf2]
    lea rdi, [dir]
    call str_eq
    jne .elsewhere
    cmp dword [clip_cut], 0             ; moved to where it is: done
    jne .forget
    mov rsi, rbx                        ; copied: "name copy" beside it
    call copy_name
    jmp .copy
.elsewhere:
    mov rsi, rbx
    lea rdi, [new_name]
    call str_copy
    lea rsi, [new_name]
    call exists
    je .taken
    cmp dword [clip_cut], 0
    je .copy
    lea rsi, [new_name]                 ; a move
    lea rdi, [path_buf]
    call join_to
    call same_volume
    jne .across
    lea rsi, [clip_path]
    lea rdx, [path_buf]
    call rename_paths
    test rax, rax
    js .failed
    jmp .moved
.across:
    cmp dword [clip_dir], 0             ; to another volume: copied, then removed
    jne .no_dirs_across
    lea rsi, [clip_path]
    lea rdx, [path_buf]
    mov rcx, [clip_size]
    call copy_file
    test rax, rax
    js .failed
    lea rsi, [clip_path]
    lea rdi, [rm_path]
    call str_copy
    call rm_one
    test rax, rax
    jns .moved
    lea rsi, [s_left]
    call say
.moved:
    mov byte [clip_path], 0
    jmp .kept
.copy:
    cmp dword [clip_dir], 0
    jne .no_dirs
    lea rsi, [new_name]
    lea rdi, [path_buf]
    call join_to
    lea rsi, [clip_path]
    lea rdx, [path_buf]
    mov rcx, [clip_size]
    call copy_file
    test rax, rax
    js .failed
.kept:
    lea rsi, [new_name]
    lea rdi, [keep_name]
    call str_copy
    call relist
    jmp .done
.forget:
    mov byte [clip_path], 0
    jmp .done
.taken:
    lea rsi, [s_here]
    mov rdx, rbx
    lea rcx, [s_here2]
    call say_name
    jmp .done
.inside:
    lea rsi, [s_inside]
    call say
    jmp .done
.no_dirs:
    lea rsi, [s_no_copy_dir]
    call say
    jmp .done
.no_dirs_across:
    lea rsi, [s_no_move_dir]
    call say
    jmp .done
.failed:
    call say_error
.done:
    pop rbx
.out:
    ret

; path_under(RSI = a path, RDI = another) -> CF if the other is it, or in it
path_under:
    xor ecx, ecx
.each:
    mov al, [rsi + rcx]
    test al, al
    jz .end
    mov dl, [rdi + rcx]
    LOWER al
    LOWER dl
    cmp al, dl
    jne .no
    inc ecx
    jmp .each
.end:
    mov al, [rdi + rcx]
    test al, al
    jz .yes
    cmp al, '/'
    je .yes
.no:
    clc
    ret
.yes:
    stc
    ret

; same_volume -> ZF if clip_path is on dir's volume
same_volume:
    cmp dword [confined], 0
    jne .out                            ; ZF: one folder, one volume
    xor ecx, ecx
.each:
    mov al, [clip_path + rcx]
    cmp al, [dir + rcx]
    jne .out
    inc ecx
    cmp al, ':'
    jne .each
.out:
    ret

section .rodata
align 4
errors:         dd E_NOFILE
                dq s_e_nofile
                dd E_EXISTS
                dq s_e_exists
                dd E_ARG
                dq s_e_arg
                dd E_NOMEM
                dq s_e_nomem
                dd E_IO
                dq s_e_io
                dd E_RIGHTS
                dq s_e_rights
                dd E_TIMEOUT
                dq s_e_timeout
                dd E_RANGE
                dq s_e_big
                dd 0
s_e_nofile:     db 'That is not there any more.', 0
s_e_exists:     db 'There is already something with that name here.', 0
s_e_arg:        db 'That cannot be done (the log says why).', 0
s_e_nomem:      db 'There was not enough memory.', 0
s_e_io:         db 'The drive failed.', 0
s_e_rights:     db 'Files is not allowed to do that.', 0
s_e_timeout:    db 'That took too long.', 0
s_e_big:        db 'Files copies files of 16 MB at most.', 0
s_e_other:      db 'That could not be done (error ', 0
s_e_ro_folder:  db 'This folder is read-only.', 0
s_ro1:          db 'This volume is read-only. To write to it, type ', 0xE2, 0x80, 0x9C, 'vol ', 0
s_ro2:          db ' rw', 0xE2, 0x80, 0x9D, ' in Terminal.', 0
s_lq:           db 0xE2, 0x80, 0x9C, 0
s_rq:           db 0xE2, 0x80, 0x9D, 0
s_stop:         db '.', 0
s_no_app:       db 'There is no app to open ', 0
s_program:      db 'Programs start from Terminal, with ', 0xE2, 0x80, 0x9C, 'run', 0xE2, 0x80, 0x9D, '.', 0
s_many:         db 'Files has opened as many windows as it can. Close some first.', 0
s_notes_q:      db 'notes "', 0
s_taken:        db 'The name ', 0
s_taken2:       db ' is taken. Choose another.', 0
s_bad_chars:    db '/\:*?"<>|', 0
s_bad_name:     db 'A name cannot start with a dot, or have / \ : * ? " < > | in it.', 0
s_new_dir:      db 'untitled folder', 0
s_new_txt:      db 'untitled', 0
s_txt:          db '.txt', 0
s_copy:         db ' copy', 0
s_no_dup_dir:   db 'Folders cannot be duplicated yet.', 0
s_no_copy_dir:  db 'Folders can be moved (cut and paste), but not copied yet.', 0
s_no_move_dir:  db 'Folders move within their volume only, for now.', 0
s_copied:       db 'Copied ', 0
s_cut:          db 'Cut ', 0
s_to_paste:     db '. Ctrl+V puts it in the folder shown.', 0
s_here:         db 'There is already something called ', 0
s_here2:        db ' here.', 0
s_inside:       db 'A folder cannot go inside itself.', 0
s_left:         db 'Copied, but the original could not be removed.', 0

section .bss
alignb 8
ring_deadline:  resq 1                  ; ring_op's SQ_DEADLINE, normally 0
ql_va:          resq 1                  ; a file looked at: its path, then it
ql_len:         resq 1
clip_size:      resq 1
ql_h:           resd 1
ql_text:        resd 1                  ; 1: it is text
ql_top:         resd 1                  ; the first line shown
ql_lines:       resd 1
clip_cut:       resd 1                  ; 1: what was cut, to move
clip_dir:       resd 1
alert_dir:      resd 1
rm_depth:       resd 1
rm_gone:        resd 1
ql_rec:         resb QL_REC
ql_name:        resb FS_PATH + 8
clip_path:      resb FS_PATH
alert_name:     resb FS_PATH
rm_path:        resb FS_PATH
rename_buf:     resb NAME_CAP + 8
ren_old:        resb FS_PATH
ren_new:        resb FS_PATH
new_name:       resb FS_PATH + 16
dup_base:       resb FS_PATH + 16
dup_ext:        resb FS_PATH
spawn_buf:      resb FS_PATH + 16
said_buf:       resb FS_PATH + 128
ro_buf:         resb 160
err_buf:        resb 64
