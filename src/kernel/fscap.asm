; =============================================================================
;  fscap.asm - files for programs, by capability
;
;  A program run with AW_FILES gets a handle to every FAT volume (OT_FILES,
;  SB_FILES). RO_FS_SUB makes one that reaches a single folder and what is
;  under it, to hand to another program. A path is FS_PATH bytes, NUL-ended:
;  with a handle to every volume, "vol<n>:/folder/file"; with one to a
;  folder, from that folder ("" or "/" is the folder itself). No "." or "..":
;  a program works its paths out itself. What a volume allows still holds:
;  it is written only after 'vol <n> rw' (E_READONLY until then), but for
;  the boot stick's /Home: what is in it may always be written (fs_home),
;  so programs keep their files there; the folder itself, and the rest of
;  the stick, wait for 'vol <n> rw' as any volume does.
;
;  The FAT code is the main thread's alone: the program's thread queues what
;  it asks for (fs_call) and waits, and fs_service, from the main loop, does
;  it. Data crosses in kernel buffers; the program's thread copies them.
; =============================================================================

FO_VOL          equ OB_SIZE             ; qword: -1, every volume; else its index
FO_ROOT         equ OB_SIZE + 8         ; FS_PATH bytes: its folder, "" for all
FO_SIZE         equ FO_ROOT + FS_PATH   ; of the volume

; a request, on the asking thread's stack
FQ_NEXT         equ 0
FQ_THREAD       equ 8                   ; the thread asking
FQ_OP           equ 16                  ; dword FSQ_*
FQ_DONE         equ 20                  ; dword: 1 once done
FQ_VOL          equ 24                  ; the volume
FQ_RESULT       equ 32                  ; what the op returns
FQ_BUF          equ 40                  ; a kernel buffer: what is read, or written
FQ_LEN          equ 48                  ; its bytes
FQ_ROOM         equ 56                  ; what the program has room for
FQ_VOLS         equ 64                  ; FSQ_VOLUMES: the handle's FO_VOL
FQ_PATH         equ 72                  ; FS_PATH bytes, from the volume's root
FQ_PATH2        equ FQ_PATH + FS_PATH
FQ_RAW          equ FQ_PATH2 + FS_PATH  ; a path as the program gave it
FQ_SIZE         equ FQ_RAW + FS_PATH

FSQ_VOLUMES     equ 0
FSQ_LIST        equ 1
FSQ_READ        equ 2
FSQ_WRITE       equ 3
FSQ_MKDIR       equ 4
FSQ_REMOVE      equ 5
FSQ_RENAME      equ 6
FSQ_FOLDER      equ 7                   ; is it a folder? (RO_FS_SUB)

FS_ROOM_MAX     equ 16 * 1024 * 1024    ; a read or a write, at most

section .text

; files_program -> EAX = a handle to every volume, in the current task, for
; a program run from the console; 0 if none could be made. Preserves others.
files_program:
    push rcx
    push rdx
    push rsi
    push rdi
    mov edi, OT_FILES
    mov esi, FO_SIZE
    lea rdx, [str_ot_files]
    call obj_new
    test rax, rax
    jz .none
    mov qword [rax + FO_VOL], -1
    mov byte [rax + FO_ROOT], 0
    mov rdi, rax
    mov esi, RT_FS_READ | RT_FS_WRITE | RT_DUP | RT_GIVE | RT_INFO
    call handle_new
    cmp rax, E_ANY
    jb .out
.none:
    xor eax, eax
.out:
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    ret

; -----------------------------------------------------------------------------
;  The program's side: RBX = the request, R12 = the handle's object
; -----------------------------------------------------------------------------

; fs_open(EDI = a handle, EDX = rights it needs) -> R12 = its object, a
; reference; CF and RAX = E_* if refused
fs_open:
    mov esi, OT_FILES
    call handle_get
    cmp rax, E_ANY
    jae .no
    mov r12, rax
    clc
    ret
.no:
    stc
    ret

; fs_take(EDI = memory, RSI = where in it, RDX = FQ_PATH or FQ_PATH2): the
; program's path there, as a path from its volume's root; FQ_VOL = the volume
; (the same for both). CF and RAX = E_* if it is not one this handle reaches.
fs_take:
    push rdx
    lea rdx, [rbx + FQ_RAW]
    mov ecx, FS_PATH
    call h_mem_read
    pop rdx
    cmp rax, E_ANY
    jae .no
    mov byte [rbx + FQ_RAW + FS_PATH - 1], 0
    push r14
    lea rsi, [rbx + FQ_RAW]
    lea rdi, [rbx + rdx]
    call fs_path
    jc .bad
    cmp rdx, FQ_PATH2                   ; a second path: on the same volume
    jne .first
    cmp r14, [rbx + FQ_VOL]
    mov rax, E_ARG
    jne .bad
.first:
    mov [rbx + FQ_VOL], r14
    pop r14
    clc
    ret
.bad:
    pop r14
.no:
    stc
    ret

; fs_path(R12 = the handle's object, RSI = a path, RDI = FS_PATH bytes) ->
; R14 = its volume, the path there from the volume's root; CF and RAX = E_*
; if it is not one the handle reaches. Preserves others.
fs_path:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    mov r8, rdi
    mov rax, [r12 + FO_VOL]
    cmp rax, -1
    jne .confined
    mov rax, E_NOFILE                   ; "vol<n>:"
    cmp byte [rsi], 'v'
    jne .fail
    cmp byte [rsi + 1], 'o'
    jne .fail
    cmp byte [rsi + 2], 'l'
    jne .fail
    add rsi, 3
    xor eax, eax
    xor ecx, ecx
.digit:
    movzx edx, byte [rsi]
    sub edx, '0'
    cmp edx, 9
    ja .digits
    imul eax, eax, 10
    add eax, edx
    inc rsi
    inc ecx
    cmp ecx, 3
    jb .digit
.digits:
    test ecx, ecx
    jz .nofile
    cmp byte [rsi], ':'
    jne .nofile
    inc rsi
    xor ecx, ecx                        ; no folder before it
    jmp .volume
.confined:
    xor ecx, ecx                        ; its folder first
.root:
    mov dl, [r12 + FO_ROOT + rcx]
    test dl, dl
    jz .volume
    mov [r8 + rcx], dl
    inc ecx
    jmp .root
.volume:
    cmp eax, [vol_count]
    jae .nofile
    imul r14, rax, VO_SIZE
    lea rdx, [volumes]
    add r14, rdx
    cmp byte [r14 + VO_GONE], 0
    jne .nofile
    cmp byte [r14 + VF_MOUNTED], 0
    je .nofile
    cmp ecx, FS_PATH - 1
    jae .arg
    mov byte [r8 + rcx], '/'            ; then the rest, from a /
    inc ecx
    cmp byte [rsi], '/'
    jne .rest
    inc rsi
.rest:
    mov dl, [rsi]
    test dl, dl
    jz .ended
    cmp ecx, FS_PATH - 1
    jae .arg
    mov [r8 + rcx], dl
    inc rsi
    inc ecx
    jmp .rest
.ended:
    cmp ecx, 1                          ; a / at its end goes
    jbe .closed
    cmp byte [r8 + rcx - 1], '/'
    jne .closed
    dec ecx
.closed:
    mov byte [r8 + rcx], 0
    mov rsi, r8                         ; each part: not "", ".", ".."
.part:
    inc rsi                             ; past its /
    cmp byte [rsi], 0
    je .ok                              ; (only the root ends so)
    xor ecx, ecx
.len:
    mov dl, [rsi + rcx]
    test dl, dl
    jz .measured
    cmp dl, '/'
    je .measured
    cmp dl, '\'
    je .arg
    inc ecx
    jmp .len
.measured:
    test ecx, ecx
    jz .arg
    cmp ecx, 2
    ja .next
    cmp byte [rsi], '.'
    jne .next
    cmp ecx, 1
    je .arg
    cmp byte [rsi + 1], '.'
    je .arg
.next:
    add rsi, rcx
    cmp byte [rsi], 0
    jne .part
.ok:
    clc
    jmp .out
.nofile:
    mov rax, E_NOFILE
    jmp .fail
.arg:
    mov rax, E_ARG
.fail:
    stc
.out:
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; fs_call(RBX = the request): done by the main thread; this one waits
fs_call:
    mov dword [rbx + FQ_DONE], 0
    mov rax, [gs:PC_CURRENT]
    cmp rax, [main_thread]
    je fs_run                           ; (the main thread does it itself)
    mov [rbx + FQ_THREAD], rax
    mov qword [rbx + FQ_NEXT], 0
    pushfq
    cli
    lea rdi, [fs_lock]
    call spin_lock
    mov rax, [fs_tail]                  ; last in line
    test rax, rax
    jz .first
    mov [rax + FQ_NEXT], rbx
    jmp .queued
.first:
    mov [fs_list], rbx
.queued:
    mov [fs_tail], rbx
    lea rdi, [fs_lock]
    call spin_unlock
    popfq
    mov rdi, [main_thread]
    call thread_unpark
.wait:
    cmp dword [rbx + FQ_DONE], 0
    jne .done
    call thread_park
    jmp .wait
.done:
    ret

; fs_give(EDI = memory, RSI = where in it): FQ_LEN bytes of FQ_BUF there,
; and the buffer freed -> RAX = E_* if they did not fit, else FQ_RESULT
fs_give:
    mov rcx, [rbx + FQ_LEN]
    mov rdx, [rbx + FQ_BUF]
    test rcx, rcx
    jz .given
    call h_mem_write
    cmp rax, E_ANY
    jae .free
.given:
    mov rax, [rbx + FQ_RESULT]
.free:
    push rax
    mov rdi, [rbx + FQ_BUF]
    test rdi, rdi
    jz .freed
    call kfree
.freed:
    pop rax
    ret

; FS_ENTER: the frame of an op: RBX = the request, zeroed
%macro FS_ENTER 0
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, FQ_SIZE
    mov rbx, rsp
    push rax
    push rdi
    push rcx
    mov rdi, rbx
    mov ecx, FQ_SIZE / 8
    xor eax, eax
    rep stosq
    pop rcx
    pop rdi
    pop rax
%endmacro

%macro FS_LEAVE 0
    call op_done
    xor edx, edx
    add rsp, FQ_SIZE
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret
%endmacro

; h_fs_volumes(EDI = files, ESI = memory, RDX = where in it, RCX = room) ->
; RAX = how many volumes it reaches (needs RT_FS_READ): an FV_* record for
; each that fits
h_fs_volumes:
    FS_ENTER
    mov r13d, esi
    mov r15, rdx
    mov [rbx + FQ_ROOM], rcx
    mov edx, RT_FS_READ
    call fs_open
    jc .out
    mov rax, [r12 + FO_VOL]
    mov [rbx + FQ_VOLS], rax
    mov rdi, r12
    call obj_put
    mov rdi, [rbx + FQ_ROOM]
    cmp rdi, MAX_VOL * FV_SIZE
    jbe .room
    mov rdi, MAX_VOL * FV_SIZE
    mov [rbx + FQ_ROOM], rdi
.room:
    test rdi, rdi
    jz .ask
    call kmalloc
    test rax, rax
    jz .nomem
    mov [rbx + FQ_BUF], rax
.ask:
    mov dword [rbx + FQ_OP], FSQ_VOLUMES
    call fs_call
    mov edi, r13d
    mov rsi, r15
    call fs_give
    jmp .out
.nomem:
    mov rax, E_NOMEM
.out:
    FS_LEAVE

; h_fs_list(EDI = files, ESI = memory, RDX = where its path is, RCX = where
; to put what is in it, R8 = room there) -> RAX = how many things the folder
; holds (needs RT_FS_READ): an FE_* record for each that fits
h_fs_list:
    FS_ENTER
    mov r13d, esi
    mov r15, rcx
    mov [rbx + FQ_ROOM], r8
    push rdx
    mov edx, RT_FS_READ
    call fs_open
    pop rsi
    jc .out
    mov edi, r13d
    mov edx, FQ_PATH
    call fs_take
    push rax
    mov rdi, r12
    call obj_put
    pop rax
    jc .out
    mov rdi, [rbx + FQ_ROOM]
    cmp rdi, FS_ROOM_MAX
    jbe .room
    mov rdi, FS_ROOM_MAX
    mov [rbx + FQ_ROOM], rdi
.room:
    test rdi, rdi
    jz .ask
    call kmalloc
    test rax, rax
    jz .nomem
    mov [rbx + FQ_BUF], rax
.ask:
    mov dword [rbx + FQ_OP], FSQ_LIST
    call fs_call
    mov edi, r13d
    mov rsi, r15
    call fs_give
    jmp .out
.nomem:
    mov rax, E_NOMEM
.out:
    FS_LEAVE

; h_fs_read(EDI = files, ESI = memory, RDX = where its path is, RCX = where
; to put the file, R8 = room there) -> RAX = the file's size (needs
; RT_FS_READ): as much of it as fits copied
h_fs_read:
    FS_ENTER
    mov r13d, esi
    mov r15, rcx
    cmp r8, FS_ROOM_MAX
    jbe .room
    mov r8, FS_ROOM_MAX
.room:
    mov [rbx + FQ_ROOM], r8
    push rdx
    mov edx, RT_FS_READ
    call fs_open
    pop rsi
    jc .out
    mov edi, r13d
    mov edx, FQ_PATH
    call fs_take
    push rax
    mov rdi, r12
    call obj_put
    pop rax
    jc .out
    mov dword [rbx + FQ_OP], FSQ_READ   ; (the main thread finds its buffer)
    call fs_call
    mov rax, [rbx + FQ_RESULT]
    cmp rax, E_ANY
    jae .out
    mov edi, r13d
    mov rsi, r15
    call fs_give
.out:
    FS_LEAVE

; h_fs_write(EDI = files, ESI = memory, RDX = where its path is, RCX = where
; the data is, R8 = its bytes) -> RAX = 0 (needs RT_FS_WRITE): the file
; made, or all it held replaced
h_fs_write:
    FS_ENTER
    mov r13d, esi
    mov r15, rcx
    mov [rbx + FQ_LEN], r8
    mov rax, E_ARG
    cmp r8, FS_ROOM_MAX
    ja .out
    push rdx
    mov edx, RT_FS_WRITE
    call fs_open
    pop rsi
    jc .out
    mov edi, r13d
    mov edx, FQ_PATH
    call fs_take
    push rax
    mov rdi, r12
    call obj_put
    pop rax
    jc .out
    mov rdi, [rbx + FQ_LEN]
    test rdi, rdi
    jz .ask
    call kmalloc
    test rax, rax
    jz .nomem
    mov [rbx + FQ_BUF], rax
    mov edi, r13d
    mov rsi, r15
    mov rdx, rax
    mov rcx, [rbx + FQ_LEN]
    call h_mem_read
    cmp rax, E_ANY
    jae .free
.ask:
    mov dword [rbx + FQ_OP], FSQ_WRITE
    call fs_call
    mov rax, [rbx + FQ_RESULT]
.free:
    push rax
    mov rdi, [rbx + FQ_BUF]
    test rdi, rdi
    jz .freed
    call kfree
.freed:
    pop rax
    jmp .out
.nomem:
    mov rax, E_NOMEM
.out:
    FS_LEAVE

; h_fs_mkdir, h_fs_remove(EDI = files, ESI = memory, RDX = where the path
; is) -> RAX = 0 (needs RT_FS_WRITE): a folder made; a file, or an empty
; folder, gone
h_fs_mkdir:
    mov eax, FSQ_MKDIR
    jmp fs_one_path
h_fs_remove:
    mov eax, FSQ_REMOVE
fs_one_path:
    FS_ENTER
    mov [rbx + FQ_OP], eax
    mov r13d, esi
    push rdx
    mov edx, RT_FS_WRITE
    call fs_open
    pop rsi
    jc .out
    mov edi, r13d
    mov edx, FQ_PATH
    call fs_take
    push rax
    mov rdi, r12
    call obj_put
    pop rax
    jc .out
    call fs_call
    mov rax, [rbx + FQ_RESULT]
.out:
    FS_LEAVE

; h_fs_rename(EDI = files, ESI = memory, RDX = where a file's path is, RCX =
; where its new one is) -> RAX = 0 (needs RT_FS_WRITE)
h_fs_rename:
    FS_ENTER
    mov r13d, esi
    mov r15, rcx
    push rdx
    mov edx, RT_FS_WRITE
    call fs_open
    pop rsi
    jc .out
    mov edi, r13d
    mov edx, FQ_PATH
    call fs_take
    jc .put
    mov edi, r13d
    mov rsi, r15
    mov edx, FQ_PATH2
    call fs_take
.put:
    push rax
    pushfq
    mov rdi, r12
    call obj_put
    popfq
    pop rax
    jc .out
    mov dword [rbx + FQ_OP], FSQ_RENAME
    call fs_call
    mov rax, [rbx + FQ_RESULT]
.out:
    FS_LEAVE

; h_fs_sub(EDI = files, ESI = memory, RDX = where a folder's path is, RCX =
; rights, RT_FS_*) -> RAX = a handle that reaches that folder alone, with
; those of the rights this one has
h_fs_sub:
    FS_ENTER
    mov r13d, esi
    mov r15, rcx
    push rdx
    push rdi
    mov edx, RT_FS_READ
    call fs_open
    pop rdi
    pop rsi
    jc .out
    push rsi
    call handle_info                    ; EDX = its rights
    pop rsi
    and r15d, edx
    and r15d, RT_FS_READ | RT_FS_WRITE
    or r15d, RT_DUP | RT_GIVE | RT_INFO
    mov edi, r13d
    mov edx, FQ_PATH
    call fs_take
    push rax
    pushfq
    mov rdi, r12
    call obj_put
    popfq
    pop rax
    jc .out
    mov dword [rbx + FQ_OP], FSQ_FOLDER
    call fs_call
    mov rax, [rbx + FQ_RESULT]
    cmp rax, E_ANY
    jae .out
    mov edi, OT_FILES
    mov esi, FO_SIZE
    lea rdx, [str_ot_files]
    call obj_new
    test rax, rax
    jz .nomem
    mov rdi, rax
    mov rcx, [rbx + FQ_VOL]
    movzx ecx, byte [rcx + VO_INDEX]
    mov [rdi + FO_VOL], rcx
    lea rsi, [rbx + FQ_PATH]            ; its folder; the root as ""
    cmp word [rsi], '/'
    jne .root
    inc rsi
.root:
    push rdi
    lea rdi, [rdi + FO_ROOT]
    mov ecx, FS_PATH
    rep movsb
    pop rdi
    mov esi, r15d
    call handle_new
    jmp .out
.nomem:
    mov rax, E_NOMEM
.out:
    FS_LEAVE

; -----------------------------------------------------------------------------
;  The main thread's side
; -----------------------------------------------------------------------------

; fs_service: from the main loop, what programs asked of their files, done
fs_service:
    push rbx
    push r12
    push r14
.next:
    cmp qword [fs_list], 0
    je .out
    pushfq
    cli
    lea rdi, [fs_lock]
    call spin_lock
    mov rbx, [fs_list]
    test rbx, rbx
    jz .unlock
    mov rax, [rbx + FQ_NEXT]
    mov [fs_list], rax
    test rax, rax
    jnz .unlock
    mov [fs_tail], rax
.unlock:
    lea rdi, [fs_lock]
    call spin_unlock
    popfq
    test rbx, rbx
    jz .out
    call fs_run
    mov r12, [rbx + FQ_THREAD]          ; the request is gone once it is done
    mov rdi, r12
    call obj_get
    mov dword [rbx + FQ_DONE], 1
    call thread_unpark
    call obj_put
    jmp .next
.out:
    pop r14
    pop r12
    pop rbx
    ret

; fs_run(RBX = a request): done, FQ_RESULT its result. The main thread's.
fs_run:
    push r14
    mov byte [fat_hush], 1              ; what is missing is said by E_*
    mov byte [fat_ioerr], 0
    mov r14, [rbx + FQ_VOL]
    call home_ensure
    call fs_do
    mov [rbx + FQ_RESULT], rax
    mov rax, [home_lifted]              ; written in /Home: read-only again
    test rax, rax
    jz .kept
    mov byte [rax + VO_WRITABLE], 0
    mov qword [home_lifted], 0
.kept:
    mov byte [fat_hush], 0
    mov byte [fat_writing], 0
    pop r14
    ret

; fs_do(RBX = a request, R14 = its volume) -> RAX = its result
fs_do:
    mov eax, [rbx + FQ_OP]
    cmp eax, FSQ_FOLDER
    ja .bad
    lea rcx, [fs_ops]
    jmp [rcx + rax * 8]
.bad:
    mov rax, E_ARG
    ret

; fs_failed -> RAX = E_IO if the drive failed, else E_NOFILE
fs_failed:
    mov rax, E_NOFILE
    cmp byte [fat_ioerr], 0
    je .out
    mov rax, E_IO
.out:
    ret

; fs_writable(RBX = a request, R14 = its volume) -> CF and RAX = E_READONLY
; if it is not to be written. On a volume not made writable, what is in the
; boot stick's /Home is: for this request only (fs_run puts it back).
fs_writable:
    cmp byte [r14 + VO_WRITABLE], 0
    je .home
.yes:
    mov byte [fat_writing], 1
    clc
    ret
.home:
    call fs_home
    jc .no
    mov byte [r14 + VO_WRITABLE], 1
    mov [home_lifted], r14
    jmp .yes
.no:
    mov rax, E_READONLY
    stc
    ret

; fs_home(RBX = a request, R14 = its volume) -> CF unless the volume is the
; boot stick and what it writes is in its /Home (each path, for a rename).
; Preserves all but RAX.
fs_home:
    push rcx
    push rsi
    push r14
    mov rcx, r14
    call log_volume                     ; (removable, and the one booted from)
    jc .not
    cmp rcx, r14
    jne .not
    lea rsi, [rbx + FQ_PATH]
    call home_inside
    jc .not
    cmp dword [rbx + FQ_OP], FSQ_RENAME
    jne .yes
    lea rsi, [rbx + FQ_PATH2]
    call home_inside
    jc .not
.yes:
    clc
    jmp .out
.not:
    stc
.out:
    pop r14
    pop rsi
    pop rcx
    ret

; home_inside(RSI = a path from the root, as fs_path made it: no "." or
; "..") -> CF unless it is something in /Home, in any case as FAT matches
; names. Preserves all but RAX.
home_inside:
    push rcx
    push rdx
    lea rdx, [str_home_in]
    xor ecx, ecx
.each:
    mov al, [rdx + rcx]
    test al, al
    jz .rest
    mov ah, [rsi + rcx]
    cmp ah, 'A'
    jb .same
    cmp ah, 'Z'
    ja .same
    or ah, 0x20
.same:
    cmp ah, al
    jne .not
    inc ecx
    jmp .each
.rest:
    cmp byte [rsi + rcx], 0             ; something in it, not it
    je .not
    clc
    jmp .out
.not:
    stc
.out:
    pop rdx
    pop rcx
    ret

; home_ensure(R14 = a volume): if it is the boot stick, its /Home made, once
; a boot. The main thread's. Preserves all but RAX.
home_ensure:
    cmp byte [home_made], 0
    jne .quick
    push rcx
    push rsi
    push r14
    mov rcx, r14
    call log_volume
    jc .out
    cmp rcx, r14
    jne .out
    lea rsi, [str_home]
    call fat_resolve
    jc .make
    test byte [fat_ent + 11], 0x10
    jz .out                             ; a file of that name: left alone
    jmp .made
.make:
    cmp byte [fat_ioerr], 0
    jne .out
    mov cl, [r14 + VO_WRITABLE]
    mov byte [r14 + VO_WRITABLE], 1
    call fat_mkdir
    mov [r14 + VO_WRITABLE], cl
    jc .out
    movzx eax, byte [r14 + VO_INDEX]
    KLOG "files: made vol%u:/Home, where programs may write", rax
.made:
    mov byte [home_made], 1
.out:
    mov byte [fat_ioerr], 0
    pop r14
    pop rsi
    pop rcx
.quick:
    ret

fsq_volumes:
    push r12
    push r13
    push r15
    push r14
    xor r15d, r15d                      ; R15: the boot stick, if one is
    call log_volume
    jc .no_stick
    mov r15, r14
.no_stick:
    pop r14
    xor r12d, r12d                      ; R12: how many
    xor r13d, r13d                      ; R13: bytes written
    xor ecx, ecx
.each:
    cmp ecx, [vol_count]
    jae .done
    imul rsi, rcx, VO_SIZE
    lea rax, [volumes]
    add rsi, rax
    cmp byte [rsi + VO_GONE], 0
    jne .next
    cmp byte [rsi + VF_MOUNTED], 0
    je .next
    mov rax, [rbx + FQ_VOLS]
    cmp rax, -1
    je .reached
    cmp rax, rcx
    jne .next
.reached:
    inc r12
    lea rax, [r13 + FV_SIZE]
    cmp rax, [rbx + FQ_ROOM]
    ja .next
    mov rdi, [rbx + FQ_BUF]
    add rdi, r13
    mov r13, rax
    mov [rdi + FV_INDEX], ecx
    xor eax, eax
    cmp byte [rsi + VO_WRITABLE], 0
    je .ro
    or eax, FVF_WRITABLE
.ro:
    mov rdx, [rsi + VO_DISK]
    test dword [rdx + DK_FLAGS], DKF_REMOVABLE
    jz .fixed
    or eax, FVF_REMOVABLE
.fixed:
    cmp rsi, r15
    jne .not_boot
    or eax, FVF_BOOT
.not_boot:
    mov [rdi + FV_FLAGS], eax
    push rcx
    mov rax, [rsi + VO_COUNT]
    mov ecx, [rdx + DK_SHIFT]
    shl rax, cl
    mov [rdi + FV_BYTES], rax
    push rsi
    push rdi
    add rsi, VO_LABEL                   ; its label: 40 bytes at most, the
    add rdi, FV_LABEL                   ; rest zeroes
    mov ecx, FV_SIZE - FV_LABEL
    mov edx, 40
.label:
    xor eax, eax
    test edx, edx
    jz .put
    lodsb
    dec edx
    test al, al
    jnz .put
    xor edx, edx
.put:
    stosb
    dec ecx
    jnz .label
    pop rdi
    pop rsi
    pop rcx
.next:
    inc ecx
    jmp .each
.done:
    mov [rbx + FQ_LEN], r13
    mov rax, r12
    pop r15
    pop r13
    pop r12
    ret

fsq_list:
    push r12
    push r13
    push r15
    lea rsi, [rbx + FQ_PATH]
    call fat_resolve
    jnc .found
    call fs_failed
    jmp .out
.found:
    test byte [fat_ent + 11], 0x10
    jnz .folder
    mov rax, E_ARG
    jmp .out
.folder:
    mov edi, eax
    call dir_open
    xor r12d, r12d                      ; R12: how many
    xor r13d, r13d                      ; R13: bytes written
.each:
    call dir_next
    jc .done
    call fx_skip
    je .each
    test byte [fat_ent + 11], 0x08      ; the volume's label
    jnz .each
    inc r12
    lea rdi, [fat_name]                 ; its record: 24 bytes and the name
    call strlen
    lea r15, [rax + FE_NAME + 1 + 7]
    and r15, ~7
    lea rax, [r13 + r15]
    cmp rax, [rbx + FQ_ROOM]
    ja .each
    mov rdi, [rbx + FQ_BUF]
    add rdi, r13
    mov r13, rax
    mov [rdi + FE_LEN], r15d
    movzx eax, byte [fat_ent + 11]
    xor ecx, ecx
    test al, 0x10
    jz .file
    or ecx, FEA_DIR
.file:
    test al, 0x01
    jz .rw
    or ecx, FEA_RO
.rw:
    test al, 0x02
    jz .shown
    or ecx, FEA_HIDDEN
.shown:
    test al, 0x04
    jz .user
    or ecx, FEA_SYSTEM
.user:
    mov [rdi + FE_ATTR], ecx
    mov eax, [fat_ent + 28]
    test ecx, FEA_DIR
    jz .sized
    xor eax, eax
.sized:
    mov [rdi + FE_SIZE], rax
    movzx eax, word [fat_ent + 24]      ; written: the date
    mov ecx, eax
    shr ecx, 9
    test eax, eax
    jz .undated
    add ecx, 1980
.undated:
    mov [rdi + FE_YEAR], cx
    mov ecx, eax
    shr ecx, 5
    and ecx, 15
    mov [rdi + FE_MONTH], cl
    and eax, 31
    mov [rdi + FE_DAY], al
    movzx eax, word [fat_ent + 22]      ; and the time
    mov ecx, eax
    shr ecx, 11
    mov [rdi + FE_HOUR], cl
    mov ecx, eax
    shr ecx, 5
    and ecx, 63
    mov [rdi + FE_MIN], cl
    and eax, 31
    add eax, eax
    mov [rdi + FE_SEC], al
    mov byte [rdi + FE_SEC + 1], 0
    lea rsi, [fat_name]
    add rdi, FE_NAME
    lea rcx, [r15 - FE_NAME]
    push rcx
    push rdi
    xor eax, eax
    rep stosb
    pop rdi
    pop rcx
.name:
    lodsb
    test al, al
    jz .each
    stosb
    jmp .name
.done:
    cmp byte [fat_ioerr], 0
    je .listed
    mov rax, E_IO
    jmp .out
.listed:
    mov [rbx + FQ_LEN], r13
    mov rax, r12
.out:
    pop r15
    pop r13
    pop r12
    ret

fsq_read:
    lea rsi, [rbx + FQ_PATH]
    call fat_resolve
    jnc .found
    jmp fs_failed
.found:
    test byte [fat_ent + 11], 0x10
    jz .file
    mov rax, E_ARG
    ret
.file:
    mov eax, [fat_ent + 28]
    mov [rbx + FQ_RESULT], rax
    mov rcx, [rbx + FQ_ROOM]
    cmp rax, rcx
    cmova rax, rcx
    mov [rbx + FQ_LEN], rax
    test rax, rax
    jz .done
    mov rdi, rax
    call kmalloc
    test rax, rax
    jz .nomem
    mov [rbx + FQ_BUF], rax
    lea rsi, [rbx + FQ_PATH]
    mov rdi, rax
    mov rcx, [rbx + FQ_LEN]
    call fat_read_file
    jc .io
    mov [rbx + FQ_LEN], rax
.done:
    mov rax, [rbx + FQ_RESULT]
    ret
.io:
    mov rdi, [rbx + FQ_BUF]
    call kfree
    mov qword [rbx + FQ_BUF], 0
    mov qword [rbx + FQ_LEN], 0
    mov rax, E_IO
    ret
.nomem:
    mov qword [rbx + FQ_LEN], 0
    mov rax, E_NOMEM
    ret

; fs_parent: FQ_PATH's folder is there -> CF and RAX = E_* if not
fs_parent:
    lea rsi, [rbx + FQ_PATH]
    call fat_parent
    jnc .out
    call fs_failed
    stc
.out:
    ret

fsq_write:
    call fs_writable
    jc .out
    call fs_parent
    jc .out
    lea rsi, [rbx + FQ_PATH]
    mov rdi, [rbx + FQ_BUF]
    mov rcx, [rbx + FQ_LEN]
    call fat_write_file
    jc .failed
    xor eax, eax
    ret
.failed:
    mov rax, E_ARG                      ; a folder, or not a name it takes
    cmp byte [fat_ioerr], 0
    je .out
    mov rax, E_IO
.out:
    ret

fsq_mkdir:
    call fs_writable
    jc .out
    lea rsi, [rbx + FQ_PATH]
    call fat_resolve
    jc .free
    mov rax, E_EXISTS
    ret
.free:
    mov byte [fat_ioerr], 0
    call fs_parent
    jc .out
    lea rsi, [rbx + FQ_PATH]
    call fat_mkdir
    jc fsq_write.failed
    xor eax, eax
.out:
    ret

fsq_remove:
    call fs_writable
    jc .out
    lea rsi, [rbx + FQ_PATH]
    call fat_resolve
    jnc .there
    jmp fs_failed
.there:
    lea rsi, [rbx + FQ_PATH]
    call fat_remove
    jc fsq_write.failed                 ; a folder with things in it, the root
    xor eax, eax
.out:
    ret

; a file or a folder renamed, or moved to another folder of its volume
fsq_rename:
    call fs_writable
    jc .out
    mov byte [fat_ioerr], 0
    lea rsi, [rbx + FQ_PATH]
    lea rdi, [rbx + FQ_PATH2]
    call fat_rename
.out:
    ret

fsq_folder:
    lea rsi, [rbx + FQ_PATH]
    call fat_resolve
    jnc .there
    jmp fs_failed
.there:
    mov rax, E_ARG
    test byte [fat_ent + 11], 0x10
    jz .out
    xor eax, eax
.out:
    ret

section .rodata
align 8
fs_ops:         dq fsq_volumes, fsq_list, fsq_read, fsq_write, fsq_mkdir
                dq fsq_remove, fsq_rename, fsq_folder
str_ot_files:   db 'files', 0
str_home:       db '/Home', 0
str_home_in:    db '/home/', 0          ; (lower case: home_inside folds to it)

section .bss
alignb 8
fs_list:        resq 1                  ; requests, first come first
fs_tail:        resq 1
home_lifted:    resq 1                  ; the stick, writable for one request in /Home
fs_lock:        resd 1
home_made:      resb 1                  ; the stick's /Home is there
