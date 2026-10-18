; =============================================================================
;  notes/panel.inc - sheets: open, save as, and asking before what is
;  changed is lost
;
;  A sheet comes down over the window, the rest dimmed behind it, and has
;  the keys and the mouse until it is answered. Open and Save As browse the
;  files given: the volumes at the left (or the one folder given), the
;  folder's contents in the middle, folders first, each by name; a double
;  click or Enter opens a folder or the file. Save As names the file in a
;  field at the top, and asks before it replaces one. Closing a tab that
;  has changed asks whether to save it.
; =============================================================================

S_OPEN          equ 1
S_SAVE          equ 2
S_CLOSE         equ 3
S_REPLACE       equ 4

PN_MEM          equ 128 * 1024          ; the listing's memory: its path, then
PN_RECS         equ 512                 ; the records it holds
PN_MAX          equ 2048
PN_VOLS         equ 16

H_S_UP          equ 30                  ; what a press in a sheet hits
H_S_NAME        equ 31
H_S_CANCEL      equ 32
H_S_OK          equ 33
H_S_NEWDIR      equ 34
H_S_DONT        equ 35
H_S_VOL         equ 64                  ; + which
H_S_ROW         equ 128                 ; + which row

section .text

; sheet_open(EAX = S_*)
sheet_open:
    push rbx
    push r12
    mov r12d, eax
    call cur_doc
    mov qword [pn_msg], 0
    cmp r12d, S_CLOSE
    jae .shown
    call pn_init
    jc .no_room
    call pn_volumes
    call pn_start
    cmp r12d, S_SAVE
    jne .list
    lea rdi, [name_text]                ; its name, all but its kind chosen
    call doc_name
    cmp dword [rbx + D_NEW], 0
    je .named
    lea rsi, [s_txt]
    call str_cat
.named:
    lea rsi, [name_text]
    mov rcx, rdi
    sub rcx, rsi
    lea r8, [f_name]
    call kit_eset
    mov dword [f_name + KE_ANCHOR], 0
    mov ecx, [f_name + KE_LEN]          ; to its last dot
.dot:
    test ecx, ecx
    jz .list
    dec ecx
    cmp byte [name_text + rcx], '.'
    jne .dot
    test ecx, ecx
    jz .list
    mov [f_name + KE_CARET], ecx
.list:
    mov [sheet], r12d
    call pn_list
    cmp r12d, S_SAVE
    jne .shown
    mov dword [pn_sel], -1
.shown:
    mov [sheet], r12d
    mov dword [need], N_ALL
    pop r12
    pop rbx
    ret
.no_room:
    lea rax, [s_e_nomem]
    mov [said], rax
    or dword [need], N_STATUS
    pop r12
    pop rbx
    ret

sheet_close:
    mov dword [sheet], 0
    mov dword [need], N_ALL
    ret

; pn_init: the listing's memory, the first time -> CF if there is none
pn_init:
    cmp qword [pn_va], 0
    jne .have
    mov edi, PN_MEM
    call kit_alloc
    jc .out
    mov [pn_va], rax
    mov [pn_h], edx
    lea rax, [name_text]
    mov [f_name + KE_BUF], rax
    mov dword [f_name + KE_CAP], 200
.have:
    clc
.out:
    ret

; pn_volumes: the volumes the files reach, for the sidebar
pn_volumes:
    mov dword [pn_nvols], 0
    cmp dword [confined], 0
    jne .out
    cmp dword [ax_files], 0
    je .out
    mov eax, RO_FS_VOLUMES
    mov edi, [ax_io]
    xor esi, esi
    mov edx, 4096
    xor ecx, ecx
    call fsq
    test rax, rax
    jle .out
    cmp eax, PN_VOLS
    jbe .some
    mov eax, PN_VOLS
.some:
    mov [pn_nvols], eax
    imul ecx, eax, FV_SIZE
    mov rsi, [ax_io_va]
    lea rdi, [pn_vols]
    rep movsb
.out:
    ret

; pn_start(RBX): the folder its document is in, else the stick's top
pn_start:
    lea rdi, [pn_dir]
    cmp dword [rbx + D_NEW], 0
    jne .top
    mov ecx, [rbx + D_NAME]
    test ecx, ecx
    jz .copied
    cmp byte [rbx + D_PATH + rcx - 1], '/'
    jne .copy
    dec ecx
.copy:
    lea rsi, [rbx + D_PATH]
    rep movsb
.copied:
    mov byte [rdi], 0
    ret
.top:
    mov byte [rdi], 0
    cmp dword [confined], 0
    jne .out
    mov dword [rdi], 'vol'
    add rdi, 3
    mov eax, [boot_vol]
    call put_dec
    mov word [rdi], ':'
.out:
    ret

; pn_list: what pn_dir holds, sorted, into pn_idx
pn_list:
    push rbx
    push r12
    push r13
    mov dword [pn_n], 0
    mov dword [pn_top], 0
    mov dword [pn_sel], -1
    mov dword [pn_bad], 0
    mov rdi, [pn_va]                    ; the path, first in its memory
    lea rsi, [pn_dir]
    mov ecx, FS_PATH
    rep movsb
    mov eax, RO_FS_LIST
    mov edi, [pn_h]
    xor esi, esi
    mov edx, PN_RECS
    mov ecx, PN_MEM - PN_RECS
    call fsq
    test rax, rax
    jns .listed
    mov dword [pn_bad], 1
    jmp .out
.listed:
    mov r12, [pn_va]                    ; R12: a record
    add r12, PN_RECS
    mov r13, [pn_va]
    add r13, PN_MEM                     ; R13: the end of them
    mov ebx, eax                        ; EBX: how many
.each:
    test ebx, ebx
    jz .sort
    lea rax, [r12 + FE_NAME]
    cmp rax, r13
    jae .sort
    mov eax, [r12 + FE_LEN]
    test eax, eax
    jz .sort
    test dword [r12 + FE_ATTR], FEA_HIDDEN | FEA_SYSTEM
    jnz .next
    mov ecx, [pn_n]
    cmp ecx, PN_MAX
    jae .sort
    mov rax, r12
    sub rax, [pn_va]
    mov [pn_idx + rcx * 4], eax
    inc dword [pn_n]
.next:
    mov eax, [r12 + FE_LEN]
    add r12, rax
    dec ebx
    jmp .each
.sort:
    mov ecx, 1                          ; folders first, then by name
.outer:
    cmp ecx, [pn_n]
    jae .sorted
    mov r12d, [pn_idx + rcx * 4]        ; R12D: what goes in its place
    mov edx, ecx
.inner:
    test edx, edx
    jz .put
    mov eax, r12d
    mov r8d, [pn_idx + rdx * 4 - 4]
    call pn_less
    jae .put
    mov [pn_idx + rdx * 4], r8d
    dec edx
    jmp .inner
.put:
    mov [pn_idx + rdx * 4], r12d
    inc ecx
    jmp .outer
.sorted:
    cmp dword [pn_n], 0
    je .out
    cmp dword [sheet], S_SAVE
    je .out
    mov dword [pn_sel], 0
.out:
    pop r13
    pop r12
    pop rbx
    ret

; pn_less(EAX, R8D = two records) -> CF if the first goes before the
; second. Preserves all but RAX.
pn_less:
    push rcx
    push rdx
    push rsi
    push rdi
    mov rsi, [pn_va]
    lea rdi, [rsi + r8]
    add rsi, rax
    mov eax, [rsi + FE_ATTR]
    mov ecx, [rdi + FE_ATTR]
    and eax, FEA_DIR
    and ecx, FEA_DIR
    cmp eax, ecx
    je .names
    cmp ecx, eax                        ; a folder (1) before a file (0)
    jmp .out
.names:
    add rsi, FE_NAME
    add rdi, FE_NAME
.each:
    mov al, [rsi]
    mov cl, [rdi]
    call fold2
    cmp al, cl
    jne .out
    test al, al
    jz .same
    inc rsi
    inc rdi
    jmp .each
.same:
    clc
.out:
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    ret

; fold2(AL, CL): both in lower case. Preserves flags' meaning for nothing.
fold2:
    cmp al, 'A'
    jb .cl
    cmp al, 'Z'
    ja .cl
    or al, 0x20
.cl:
    cmp cl, 'A'
    jb .out
    cmp cl, 'Z'
    ja .out
    or cl, 0x20
.out:
    ret

; pn_entry(EAX = which) -> RSI = its record
pn_entry:
    mov eax, [pn_idx + rax * 4]
    mov rsi, [pn_va]
    add rsi, rax
    ret

; pn_join(RSI = a name) -> pn_path: pn_dir and it
pn_join:
    lea rdi, [pn_path]
    lea rcx, [pn_path + FS_PATH - 1]
    lea rdx, [pn_dir]
    cmp byte [rdx], 0
    je .name
.dir:
    mov al, [rdx]
    test al, al
    jz .slash
    mov [rdi], al
    inc rdi
    inc rdx
    jmp .dir
.slash:
    mov byte [rdi], '/'
    inc rdi
.name:
    mov al, [rsi]
    test al, al
    jz .done
    cmp rdi, rcx
    jae .done
    mov [rdi], al
    inc rdi
    inc rsi
    jmp .name
.done:
    mov byte [rdi], 0
    ret

; pn_enter(RSI = a folder's record): into it
pn_enter:
    add rsi, FE_NAME
    call pn_join
    lea rsi, [pn_path]
    lea rdi, [pn_dir]
    mov ecx, FS_PATH
    rep movsb
    call pn_list
    mov dword [need], N_ALL
    ret

; pn_parent: up to the folder it is in
pn_parent:
    lea rdi, [pn_dir]
    call k_strlen
    mov ecx, eax
.back:
    test ecx, ecx
    jz .top
    dec ecx
    mov al, [pn_dir + rcx]
    cmp al, '/'
    je .cut
    cmp al, ':'
    jne .back
    cmp byte [pn_dir + rcx + 1], 0      ; at a volume's top already
    je .out
    inc ecx                             ; keep the :
.cut:
    mov byte [pn_dir + rcx], 0
    jmp .list
.top:
    cmp byte [pn_dir], 0
    je .out
    mov byte [pn_dir], 0
.list:
    call pn_list
.out:
    mov dword [need], N_ALL
    ret

; pn_named(RSI = a name) -> EAX = the record of that name here, -1 if none
; (any case, as FAT has names)
pn_named:
    push rbx
    push r12
    mov r12, rsi
    xor ebx, ebx
.each:
    cmp ebx, [pn_n]
    jae .none
    mov eax, ebx
    call pn_entry
    add rsi, FE_NAME
    mov rdi, r12
.cmp:
    mov al, [rsi]
    mov cl, [rdi]
    call fold2
    cmp al, cl
    jne .next
    test al, al
    jz .found
    inc rsi
    inc rdi
    jmp .cmp
.next:
    inc ebx
    jmp .each
.found:
    mov eax, ebx
    jmp .out
.none:
    mov eax, -1
.out:
    pop r12
    pop rbx
    ret

; -----------------------------------------------------------------------------
;  Answering it
; -----------------------------------------------------------------------------

sheet_ok:
    mov eax, [sheet]
    cmp eax, S_CLOSE
    je close_save
    cmp eax, S_REPLACE
    je save_as_path
    cmp eax, S_SAVE
    je pn_save
    ; opening: what is chosen

; pn_activate(RBX): what is chosen: a folder gone into; a file opened, or
; saved over
pn_activate:
    cmp dword [pn_sel], 0
    jl .out
    mov eax, [pn_sel]
    call pn_entry
    test dword [rsi + FE_ATTR], FEA_DIR
    jnz pn_enter
    cmp dword [sheet], S_SAVE
    je pn_save
    add rsi, FE_NAME
    call pn_join
    jmp open_path
.out:
    ret

; pn_save(RBX): to the name in the field, here; asked first if it is there
pn_save:
    mov ecx, [f_name + KE_LEN]
    test ecx, ecx
    jz .out
    mov byte [name_text + rcx], 0
    lea rsi, [name_text]
    call pn_named
    mov r8d, eax
    lea rsi, [name_text]
    call pn_join
    test r8d, r8d
    js save_as_path
    mov eax, r8d
    call pn_entry
    test dword [rsi + FE_ATTR], FEA_DIR
    jnz .folder
    mov dword [sheet], S_REPLACE        ; there already: ask
    mov dword [need], N_ALL
    ret
.folder:
    lea rax, [s_is_folder]
    mov [pn_msg], rax
    mov dword [need], N_ALL
.out:
    ret

sheet_cancel:
    cmp dword [sheet], S_REPLACE
    jne .close
    mov dword [sheet], S_SAVE
    mov dword [need], N_ALL
    ret
.close:
    mov dword [quitting], 0
    mov dword [pn_then_close], 0
    jmp sheet_close

sheet_dont:
    cmp dword [sheet], S_CLOSE
    jne .out
    call sheet_close
    jmp tab_gone
.out:
    ret

; close_save(RBX): save it, then close it
close_save:
    cmp dword [rbx + D_NEW], 0
    je .save
    mov dword [pn_then_close], 1
    mov eax, S_SAVE
    jmp sheet_open
.save:
    call sheet_close
    call save_doc
    jc .failed
    jmp tab_gone
.failed:
    mov dword [quitting], 0
    ret

; save_as_path(RBX): saved to pn_path; its old path back if it cannot be
save_as_path:
    lea rdi, [pn_backup]                ; what it was
    mov ecx, D_SIZE - D_LANG
    lea rsi, [rbx + D_LANG]
    rep movsb
    lea rsi, [pn_path]
    call d_path
    call save_doc
    jc .failed
    mov qword [st_doc], 0
    call sheet_close
    call gutter
    mov dword [need], N_ALL
    cmp dword [pn_then_close], 0
    je .out
    mov dword [pn_then_close], 0
    jmp tab_gone
.failed:
    lea rsi, [pn_backup]
    lea rdi, [rbx + D_LANG]
    mov ecx, D_SIZE - D_LANG
    rep movsb
    mov dword [quitting], 0
    mov dword [pn_then_close], 0
    call sheet_close
    or dword [need], N_STATUS
.out:
    ret

; open_path(RBX): pn_path, in a tab: its own if it is open, the empty one
; in front if that is new, else a new one
open_path:
    push r12
    xor ecx, ecx
.open_already:
    cmp ecx, [ndocs]
    jae .not_open
    imul eax, ecx, D_SIZE
    lea rdi, [docs + rax]
    cmp dword [rdi + D_NEW], 0
    jne .next
    add rdi, D_PATH
    lea rsi, [pn_path]
.cmp:
    mov al, [rsi]
    push rcx
    mov cl, [rdi]
    call fold2
    cmp al, cl
    pop rcx
    jne .next
    test al, al
    jz .there
    inc rsi
    inc rdi
    jmp .cmp
.next:
    inc ecx
    jmp .open_already
.there:
    mov [cur], ecx
    jmp .shown
.not_open:
    xor r12d, r12d                      ; R12D: 1 if a tab was made for it
    cmp dword [rbx + D_NEW], 0
    je .new_tab
    cmp dword [rbx + D_LEN], 0
    jne .new_tab
    call d_dirty
    je .load
.new_tab:
    call doc_new
    jc .full
    mov r12d, 1
.load:
    lea rsi, [pn_path]
    call doc_load
    test rax, rax
    jns .shown
    call error_text
    mov [said], rax
    test r12d, r12d
    jz .untitled
    call doc_close
    mov eax, [ndocs]
    dec eax
    cmp eax, [cur]
    jae .shown
    mov [cur], eax
    jmp .shown
.untitled:
    mov dword [rbx + D_NEW], 1          ; the empty one, as it was
    mov byte [rbx + D_PATH], 0
    mov dword [rbx + D_LANG], 0
    mov dword [rbx + D_KIND], 0
    jmp .shown
.full:
    lea rax, [s_tabs_full]
    mov [said], rax
.shown:
    call sheet_close
    call tab_shown
    or dword [need], N_ALL
    pop r12
    ret

; pn_new_dir: a new folder here, chosen
pn_new_dir:
    push r12
    lea rdi, [name2]                    ; "untitled folder", or with a number
    lea rsi, [s_untitled_dir]
    call str_cat
    mov byte [rdi], 0
    mov r12d, 2
.try:
    lea rsi, [name2]
    call pn_named
    test eax, eax
    js .free
    lea rdi, [name2]
    lea rsi, [s_untitled_dir]
    call str_cat
    mov byte [rdi], ' '
    inc rdi
    mov eax, r12d
    call put_dec
    mov byte [rdi], 0
    inc r12d
    cmp r12d, 100
    jb .try
    jmp .out
.free:
    lea rsi, [name2]
    call pn_join
    mov rdi, [pn_va]
    lea rsi, [pn_path]
    mov ecx, FS_PATH
    rep movsb
    mov eax, RO_FS_MKDIR
    mov edi, [pn_h]
    xor esi, esi
    xor edx, edx
    xor ecx, ecx
    call fsq
    test rax, rax
    jz .made
    call error_text
    mov [pn_msg], rax
    jmp .out
.made:
    call pn_list
    lea rsi, [name2]
    call pn_named
    mov [pn_sel], eax
    call pn_reveal
.out:
    mov dword [need], N_ALL
    pop r12
    ret

; pn_reveal: the row chosen in sight
pn_reveal:
    mov eax, [pn_sel]
    test eax, eax
    js .out
    cmp eax, [pn_top]
    jge .below
    mov [pn_top], eax
    ret
.below:
    mov ecx, [pn_top]
    add ecx, [pn_rows]
    cmp eax, ecx
    jl .out
    sub eax, [pn_rows]
    inc eax
    mov [pn_top], eax
.out:
    ret

; pn_pick(EAX = which): chosen; saving, a file's name to the field
pn_pick:
    mov [pn_sel], eax
    call pn_reveal
    mov dword [need], N_ALL
    cmp dword [sheet], S_SAVE
    jne .out
    mov eax, [pn_sel]
    call pn_entry
    test dword [rsi + FE_ATTR], FEA_DIR
    jnz .out
    add rsi, FE_NAME
    call k_slen
    lea r8, [f_name]
    call kit_eset
.out:
    ret

; -----------------------------------------------------------------------------
;  The keys, the mouse
; -----------------------------------------------------------------------------

panel_key:
    push rbx
    push r12
    push r13
    mov r12d, eax
    mov r13d, edx
    call cur_doc
    cmp r12d, K_ESC
    jne .enter
    call sheet_cancel
    jmp .out
.enter:
    cmp r12d, 10
    jne .alert
    call sheet_ok
    jmp .out
.alert:
    cmp dword [sheet], S_CLOSE
    jb .browse
    jne .out
    mov eax, r12d                       ; d, or ctrl+D: don't save
    or eax, 0x20
    cmp eax, 'd'
    je .dont
    cmp r12d, 4
    jne .out
.dont:
    call sheet_dont
    jmp .out
.browse:
    cmp r12d, K_UP
    jne .down
    test r13d, WM_CTRL
    jnz .parent
    mov eax, [pn_sel]
    dec eax
    jns .pick
    xor eax, eax
    jmp .pick
.down:
    cmp r12d, K_DOWN
    jne .open_keys
    mov eax, [pn_sel]
    inc eax
    cmp eax, [pn_n]
    jl .pick
    mov eax, [pn_n]
    dec eax
.pick:
    cmp dword [pn_n], 0
    je .out
    call pn_pick
    jmp .out
.parent:
    call pn_parent
    jmp .out
.open_keys:
    cmp dword [sheet], S_SAVE
    je .name
    cmp r12d, 8                         ; opening: back, left: the folder up
    je .parent
    cmp r12d, K_LEFT
    je .parent
    cmp r12d, K_RIGHT
    jne .letter
    cmp dword [pn_sel], 0
    jl .out
    mov eax, [pn_sel]
    call pn_entry
    test dword [rsi + FE_ATTR], FEA_DIR
    jz .out
    call pn_enter
    jmp .out
.letter:
    cmp r12d, ' '                       ; a letter: the next it begins
    jbe .out
    cmp r12d, 0x7F
    jae .out
    mov ecx, [pn_sel]
    xor edx, edx
.find:
    inc ecx
    cmp ecx, [pn_n]
    jl .wrapped
    xor ecx, ecx
.wrapped:
    inc edx
    cmp edx, [pn_n]
    ja .out
    mov eax, ecx
    call pn_entry
    mov al, [rsi + FE_NAME]
    push rcx
    mov cl, r12b
    call fold2
    cmp al, cl
    pop rcx
    jne .find
    mov eax, ecx
    call pn_pick
    jmp .out
.name:
    lea r8, [f_name]                    ; saving: the name's field
    mov eax, r12d
    mov edx, r13d
    call kit_ekey
    mov dword [need], N_ALL
.out:
    pop r13
    pop r12
    pop rbx
    ret

panel_press:
    push rbx
    call cur_doc
    lea rsi, [sheet_hits]
    mov edi, [kit_ev + WE_X]
    mov edx, [kit_ev + WE_Y]
    call hit_at
    cmp eax, H_S_UP
    je .up
    cmp eax, H_S_NAME
    je .name
    cmp eax, H_S_CANCEL
    je .cancel
    cmp eax, H_S_OK
    je .ok
    cmp eax, H_S_NEWDIR
    je .new_dir
    cmp eax, H_S_DONT
    je .dont
    cmp eax, H_S_ROW
    jae .row
    cmp eax, H_S_VOL
    jae .vol
    jmp .out
.up:
    call pn_parent
    jmp .out
.name:
    lea r8, [f_name]
    mov edi, [kit_ev + WE_X]
    xor esi, esi
    mov r9d, [f_ui]
    call kit_eclick
    mov dword [need], N_ALL
    jmp .out
.cancel:
    call sheet_cancel
    jmp .out
.ok:
    call sheet_ok
    jmp .out
.new_dir:
    call pn_new_dir
    jmp .out
.dont:
    call sheet_dont
    jmp .out
.vol:
    sub eax, H_S_VOL
    imul eax, eax, FV_SIZE
    mov eax, [pn_vols + rax + FV_INDEX]
    lea rdi, [pn_dir]
    mov dword [rdi], 'vol'
    add rdi, 3
    call put_dec
    mov word [rdi], ':'
    call pn_list
    mov dword [need], N_ALL
    jmp .out
.row:
    sub eax, H_S_ROW
    add eax, [pn_top]
    cmp eax, [pn_n]
    jae .out
    push rax
    call pn_pick
    pop rax
    cmp dword [kit_clicks], 2           ; twice: open it
    jb .out
    call pn_activate
.out:
    pop rbx
    ret

panel_wheel:
    cmp dword [sheet], S_CLOSE
    jae .out
    mov eax, [kit_ev + WE_CODE]
    imul eax, eax, -3
    add eax, [pn_top]
    mov ecx, [pn_n]
    sub ecx, [pn_rows]
    cmp eax, ecx
    jle .not_past
    mov eax, ecx
.not_past:
    test eax, eax
    jns .set
    xor eax, eax
.set:
    mov [pn_top], eax
    mov dword [need], N_ALL
.out:
    ret

; -----------------------------------------------------------------------------
;  Drawing it
; -----------------------------------------------------------------------------

paint_sheet:
    push rbx
    push rbp
    push r12
    push r13
    push r14
    push r15
    call cur_doc
    lea rax, [sheet_hits]
    mov [hit_tab], rax
    mov dword [sheet_hits], 0
    xor edi, edi                        ; the window behind, dimmed
    xor esi, esi
    mov edx, [kit_w]
    mov ecx, [kit_h]
    mov r8d, KA(0x38)
    call kit_fill
    PX sp_pad, 20
    PX sp_r, 12
    mov edi, 440                        ; its size
    mov esi, 132
    cmp dword [sheet], S_CLOSE
    jae .sized
    mov edi, 640
    mov esi, 460
.sized:
    push rsi
    call kit_pt
    mov ecx, [kit_w]
    sub ecx, [sp_pad]
    sub ecx, [sp_pad]
    cmp eax, ecx
    jle .w
    mov eax, ecx
.w:
    mov [sp_w], eax
    pop rdi
    call kit_pt
    mov ecx, [kit_h]
    sub ecx, [sp_pad]
    cmp eax, ecx
    jle .h
    mov eax, ecx
.h:
    mov [sp_h], eax
    mov eax, [kit_w]
    sub eax, [sp_w]
    sar eax, 1
    mov [sp_x], eax
    mov edi, 8
    call kit_pt
    mov [sp_y], eax
    mov edi, [sp_x]
    mov esi, [sp_y]
    mov edx, [sp_w]
    mov ecx, [sp_h]
    mov r8d, [sp_r]
    push rdi
    mov edi, 18
    call kit_pt
    mov r9d, eax
    pop rdi
    call kit_shadow
    mov edi, [sp_x]
    mov esi, [sp_y]
    mov edx, [sp_w]
    mov ecx, [sp_h]
    mov r8d, [sp_r]
    mov r9d, [c_panel]
    call kit_round
    mov edi, [sp_x]
    mov esi, [sp_y]
    mov edx, [sp_w]
    mov ecx, [sp_h]
    mov r8d, [sp_r]
    mov r9d, [c_line]
    mov r10d, 1
    call kit_frame
    cmp dword [sheet], S_CLOSE
    jae .alert
    call paint_browser
    jmp .out
.alert:
    call paint_alert
.out:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret

; paint_alert(RBX): what it asks, and its buttons
paint_alert:
    push r12
    push r13
    lea rdi, [alert_buf]                ; the question
    cmp dword [sheet], S_REPLACE
    je .replace
    lea rsi, [s_ask_save1]
    call str_cat
    call doc_name
    lea rsi, [s_ask_save2]
    call str_cat
    mov byte [rdi], 0
    lea r12, [s_ask_save3]
    jmp .ask
.replace:
    lea rsi, [s_quote1]
    call str_cat
    lea rsi, [name_text]
    call str_cat
    lea rsi, [s_ask_replace]
    call str_cat
    mov byte [rdi], 0
    lea r12, [s_ask_replace2]
.ask:
    mov edi, 19                         ; the question, in bold
    call kit_pt
    mov ecx, eax
    mov eax, [sp_y]
    add eax, [sp_pad]
    mov edi, [sp_x]
    add edi, [sp_pad]
    mov edx, [sp_w]
    sub edx, [sp_pad]
    sub edx, [sp_pad]
    lea rsi, [alert_buf]
    mov r8d, [f_bold]
    mov r9d, [c_text]
    call wrap_text
    mov r13d, eax
    mov edi, 6                          ; then what it means, smaller
    call kit_pt
    add r13d, eax
    mov edi, 17
    call kit_pt
    mov ecx, eax
    mov eax, r13d
    mov edi, [sp_x]
    add edi, [sp_pad]
    mov edx, [sp_w]
    sub edx, [sp_pad]
    sub edx, [sp_pad]
    mov rsi, r12
    mov r8d, [f_small]
    mov r9d, [c_text2]
    call wrap_text
    mov eax, [sp_y]                     ; the buttons: at the right, Save last
    add eax, [sp_h]
    sub eax, [sp_pad]
    push rax
    mov edi, 26
    call kit_pt
    mov [sp_bh], eax
    pop rax
    sub eax, [sp_bh]
    mov r13d, eax                       ; R13D: their top
    mov edi, 88
    call kit_pt
    mov r12d, [sp_x]
    add r12d, [sp_w]
    sub r12d, [sp_pad]
    sub r12d, eax                       ; R12D: the last one's x
    lea r8, [s_save]
    cmp dword [sheet], S_REPLACE
    jne .ok
    lea r8, [s_replace_b]
.ok:
    mov edi, r12d
    mov esi, r13d
    mov ecx, H_S_OK
    mov r9d, KB_DEFAULT
    call sheet_button
    mov edi, 98
    call kit_pt
    sub r12d, eax
    mov edi, r12d
    mov esi, r13d
    lea r8, [s_cancel]
    mov ecx, H_S_CANCEL
    xor r9d, r9d
    call sheet_button
    cmp dword [sheet], S_CLOSE
    jne .out
    mov edi, [sp_x]
    add edi, [sp_pad]
    mov esi, r13d
    lea r8, [s_dont_save]
    mov ecx, H_S_DONT
    xor r9d, r9d
    call sheet_button
.out:
    pop r13
    pop r12
    ret

; sheet_button(EDI = x, ESI = y, R8 = label, ECX = what, R9D = KB_*): 88
; points wide, sp_bh high
sheet_button:
    push r12
    push r13
    push r14
    mov r12d, edi
    mov r13d, esi
    mov r14d, ecx
    mov edi, 88
    call kit_pt
    mov edx, eax
    push r8
    push r9
    mov edi, r12d
    mov esi, r13d
    mov ecx, [sp_bh]
    mov r8d, r14d
    call hit_add
    pop r9
    pop r8
    mov edi, r12d
    mov esi, r13d
    mov ecx, [sp_bh]
    call kit_button
    pop r14
    pop r13
    pop r12
    ret

; wrap_text(RSI = NUL-ended text, EDI = x, EAX = the first line's top,
; EDX = width, ECX = a line's height, R8D = font, R9D = colour) -> EAX =
; the top of the line after the last
wrap_text:
    push rbx
    push rbp
    push r12
    push r13
    push r14
    push r15
    sub rsp, 24
    mov rbx, rsi                        ; RBX: the line's start
    mov [rsp], edi
    mov r12d, eax                       ; R12D: its top
    mov [rsp + 4], edx
    mov [rsp + 8], ecx
    mov [rsp + 12], r8d
    mov [rsp + 16], r9d
.line:
    cmp byte [rbx], 0
    je .done
    xor r13d, r13d                      ; R13D: where it may break, 0 if nowhere yet
    mov r14, rbx                        ; R14: past the word
.word:
    mov al, [r14]
    test al, al
    jz .measure
    cmp al, ' '
    je .measure
    inc r14
    jmp .word
.measure:
    mov rsi, rbx
    mov rcx, r14
    sub rcx, rbx
    mov edx, [rsp + 12]
    call kit_text_w
    cmp eax, [rsp + 4]
    jbe .fits
    test r13d, r13d                     ; too long: break before the word
    jnz .break
.fits:
    cmp byte [r14], 0
    je .last
    mov r13, r14
    sub r13, rbx
    inc r14
    jmp .word
.last:
    mov r13, r14
    sub r13, rbx
.break:
    mov edx, [rsp + 12]
    mov esi, r12d
    mov ecx, [rsp + 8]
    call kit_base
    mov edx, eax
    mov rsi, rbx
    mov ecx, r13d
    mov edi, [rsp]
    mov r8d, [rsp + 12]
    mov r9d, [rsp + 16]
    call kit_text
    add r12d, [rsp + 8]
    add rbx, r13
    cmp byte [rbx], ' '
    jne .line
    inc rbx
    jmp .line
.done:
    mov eax, r12d
    add rsp, 24
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret

; paint_browser(RBX): open or save: the name, where, the volumes, the list,
; the buttons
paint_browser:
    push r12
    push r13
    push r14
    push r15
    PX sp_bh, 26
    PX pn_rh, 24
    mov r13d, [sp_y]                    ; R13D: the row's top
    add r13d, [sp_pad]
    mov r12d, [sp_x]
    add r12d, [sp_pad]                  ; R12D: the left
    cmp dword [sheet], S_SAVE
    je .save_row
    mov edx, [f_bold]                   ; Open, in the middle
    lea rsi, [s_open_title]
    call k_slen
    push rcx
    call kit_text_w
    pop rcx
    mov edi, [kit_w]
    sub edi, eax
    sar edi, 1
    push rdi
    push rcx
    mov edx, [f_bold]
    mov esi, r13d
    mov ecx, [sp_bh]
    call kit_base
    mov edx, eax
    pop rcx
    pop rdi
    lea rsi, [s_open_title]
    mov r8d, [f_bold]
    mov r9d, [c_text]
    call kit_text
    jmp .path_row
.save_row:
    mov eax, [caret_on]                 ; Save As: [name]
    mov [kit_caret], eax
    lea rsi, [s_save_as]
    call k_slen
    mov edx, [f_ui]
    push rcx
    call kit_text_w
    pop rcx
    mov r14d, eax                       ; R14D: the label's width
    mov edi, 280
    call kit_pt
    mov r15d, eax                       ; R15D: the field's
    mov edi, 10
    call kit_pt
    mov [sp_gap], eax
    mov edi, [kit_w]                    ; the two, in the middle
    sub edi, r14d
    sub edi, r15d
    sub edi, [sp_gap]
    sar edi, 1
    push rdi
    push rcx
    mov edx, [f_ui]
    mov esi, r13d
    mov ecx, [sp_bh]
    call kit_base
    mov edx, eax
    pop rcx
    pop rdi
    push rdi
    lea rsi, [s_save_as]
    mov r8d, [f_ui]
    mov r9d, [c_text]
    call kit_text
    pop rdi
    add edi, r14d
    add edi, [sp_gap]
    push rdi
    lea r8, [f_name]
    mov esi, r13d
    mov edx, r15d
    mov ecx, [sp_bh]
    mov r9d, [f_ui]
    mov r10d, 1
    call kit_edraw
    pop rdi
    mov esi, r13d
    mov edx, r15d
    mov ecx, [sp_bh]
    mov r8d, H_S_NAME
    call hit_add
    mov dword [kit_caret], 0
.path_row:
    mov eax, [sp_bh]                    ; where: [^] and the path
    add r13d, eax
    mov edi, 12
    call kit_pt
    add r13d, eax
    mov edi, 32
    call kit_pt
    mov r14d, eax
    mov edi, r12d
    mov esi, r13d
    mov edx, r14d
    mov ecx, [sp_bh]
    mov r8d, H_S_UP
    call hit_add
    lea r8, [s_empty]
    xor r9d, r9d
    call kit_button
    mov edi, r14d
    shr edi, 1
    add edi, r12d
    mov esi, [sp_bh]
    shr esi, 1
    add esi, r13d
    call chevron_up
    call pretty_path
    lea rsi, [pretty_buf]
    call k_slen
    lea edi, [r12 + r14]
    push rdi
    mov edi, 10
    call kit_pt
    pop rdi
    add edi, eax
    push rdi
    push rcx
    mov edx, [f_ui]
    mov esi, r13d
    mov ecx, [sp_bh]
    call kit_base
    mov edx, eax
    pop rcx
    pop rdi
    lea rsi, [pretty_buf]
    mov r8d, [f_ui]
    mov r9d, [c_text2]
    call kit_text
    add r13d, [sp_bh]                   ; the body: from here
    mov edi, 12
    call kit_pt
    add r13d, eax
    mov [pn_y0], r13d
    mov eax, [sp_y]                     ; to above the buttons
    add eax, [sp_h]
    sub eax, [sp_pad]
    sub eax, [sp_bh]
    mov [pn_by], eax
    push rax
    mov edi, 14
    call kit_pt
    mov ecx, eax
    pop rax
    sub eax, ecx
    mov [pn_y1], eax
    call paint_sidebar
    call paint_list
    mov edi, 88                         ; the buttons
    call kit_pt
    mov r12d, [sp_x]
    add r12d, [sp_w]
    sub r12d, [sp_pad]
    sub r12d, eax
    mov edi, r12d
    mov esi, [pn_by]
    lea r8, [s_open_b]
    cmp dword [sheet], S_SAVE
    jne .ok
    lea r8, [s_save]
.ok:
    mov ecx, H_S_OK
    mov r9d, KB_DEFAULT
    call sheet_button
    mov edi, 98
    call kit_pt
    sub r12d, eax
    mov edi, r12d
    mov esi, [pn_by]
    lea r8, [s_cancel]
    mov ecx, H_S_CANCEL
    xor r9d, r9d
    call sheet_button
    mov r13d, [sp_x]                    ; R13D: the left's free x
    add r13d, [sp_pad]
    cmp dword [sheet], S_SAVE
    jne .msg
    mov edi, r13d
    mov esi, [pn_by]
    lea r8, [s_new_dir]
    mov ecx, H_S_NEWDIR
    xor r9d, r9d
    call sheet_button
    mov edi, 100
    call kit_pt
    add r13d, eax
.msg:
    mov rsi, [pn_msg]                   ; and what went wrong, if something did
    test rsi, rsi
    jz .out
    call k_slen
    push rcx
    mov edx, [f_small]
    mov esi, [pn_by]
    mov ecx, [sp_bh]
    call kit_base
    mov edx, eax
    pop rcx
    mov rsi, [pn_msg]
    mov edi, r13d
    mov r8d, [f_small]
    mov r9d, [pal_dark + 2 * 4]
    call kit_text
.out:
    pop r15
    pop r14
    pop r13
    pop r12
    ret

; chevron_up(EDI = x, ESI = y, its centre): ^
chevron_up:
    push rbx
    push r12
    push r13
    mov r12d, edi
    mov r13d, esi
    mov edi, 5
    call kit_pt
    shl eax, 4
    mov ebx, eax                        ; EBX: half its width, in 16ths
    shl r12d, 4
    shl r13d, 4
    add r12d, 8
    add r13d, 8
    mov edi, 3
    call kit_pt
    lea r8d, [rax * 8]
    push r8
    mov edi, r12d
    sub edi, ebx
    mov esi, ebx
    shr esi, 1
    add esi, r13d
    mov edx, r12d
    mov ecx, ebx
    shr ecx, 1
    neg ecx
    add ecx, r13d
    mov r9d, [c_text2]
    call kit_stroke
    pop r8
    lea edi, [r12 + rbx]
    mov esi, ebx
    shr esi, 1
    add esi, r13d
    mov edx, r12d
    mov ecx, ebx
    shr ecx, 1
    neg ecx
    add ecx, r13d
    mov r9d, [c_text2]
    call kit_stroke
    pop r13
    pop r12
    pop rbx
    ret

; pretty_path -> pretty_buf: pn_dir as the user reads it: the volume's
; name, then each folder after a ›
pretty_path:
    lea rdi, [pretty_buf]
    lea rsi, [pn_dir]
    cmp dword [confined], 0
    je .volume
    lea rsi, [s_this_folder]
    call str_cat
    lea rsi, [pn_dir]
    cmp byte [rsi], 0
    je .done
    jmp .sep
.volume:
    cmp word [rsi], 'vo'                ; vol<n>: its label
    jne .rest
    cmp byte [rsi + 2], 'l'
    jne .rest
    add rsi, 3
    xor eax, eax
.digit:
    movzx ecx, byte [rsi]
    sub ecx, '0'
    cmp ecx, 9
    ja .number
    imul eax, eax, 10
    add eax, ecx
    inc rsi
    jmp .digit
.number:
    cmp byte [rsi], ':'
    jne .rest
    inc rsi
    push rsi
    call vol_label
    call str_cat
    pop rsi
.rest:
    cmp byte [rsi], '/'
    jne .comp
    inc rsi
.comp:
    cmp byte [rsi], 0
    je .done
.sep:
    push rsi
    lea rsi, [s_sep]
    call str_cat
    pop rsi
.char:
    lodsb
    test al, al
    jz .done
    cmp al, '/'
    je .comp_next
    lea rcx, [pretty_buf + 200]
    cmp rdi, rcx
    jae .char
    stosb
    jmp .char
.comp_next:
    jmp .comp
.done:
    mov byte [rdi], 0
    ret

; vol_label(EAX = a volume) -> RSI = its name, to show
vol_label:
    xor ecx, ecx
.each:
    cmp ecx, [pn_nvols]
    jae .none
    imul edx, ecx, FV_SIZE
    cmp [pn_vols + rdx + FV_INDEX], eax
    je .found
    inc ecx
    jmp .each
.found:
    lea rsi, [pn_vols + rdx + FV_LABEL]
    cmp byte [rsi], 0
    jne .out
.none:
    lea rsi, [vol_name]                 ; "Volume n"
    push rdi
    lea rdi, [vol_name]
    mov dword [rdi], 'Volu'
    mov dword [rdi + 4], 'me '
    add rdi, 7
    call put_dec
    mov byte [rdi], 0
    pop rdi
    lea rsi, [vol_name]
.out:
    ret

; paint_sidebar: Locations, and the volumes in it
paint_sidebar:
    push r12
    push r13
    push r14
    mov r12d, [sp_x]
    add r12d, [sp_pad]
    mov r13d, [pn_y0]
    lea rsi, [s_locations]
    call k_slen
    push rcx
    mov edx, [f_small]
    mov esi, r13d
    mov ecx, [pn_rh]
    call kit_base
    mov edx, eax
    pop rcx
    lea rsi, [s_locations]
    mov edi, r12d
    mov r8d, [f_small]
    mov r9d, [c_text3]
    call kit_text
    add r13d, [pn_rh]
    cmp dword [confined], 0
    je .volumes
    lea rsi, [s_this_folder]            ; one folder given: it alone
    mov eax, 1
    call side_item
    jmp .out
.volumes:
    xor r14d, r14d
.each:
    cmp r14d, [pn_nvols]
    jae .out
    imul eax, r14d, FV_SIZE
    mov eax, [pn_vols + rax + FV_INDEX]
    push rax
    mov edi, 140
    call kit_pt
    mov edx, eax
    mov edi, r12d
    mov esi, r13d
    mov ecx, [pn_rh]
    lea r8d, [r14 + H_S_VOL]
    call hit_add
    pop rax
    call dir_vol                        ; the one pn_dir is on?
    sete cl
    push rcx
    call vol_label
    pop rax
    movzx eax, al
    call side_item
    add r13d, [pn_rh]
    inc r14d
    jmp .each
.out:
    pop r14
    pop r13
    pop r12
    ret

; dir_vol(EAX = a volume) -> ZF if pn_dir is on it. Preserves RSI.
dir_vol:
    push rsi
    push rdi
    push rax
    lea rdi, [vol_name2]
    mov dword [rdi], 'vol'
    add rdi, 3
    call put_dec
    mov byte [rdi], ':'
    inc rdi
    mov byte [rdi], 0
    lea rsi, [vol_name2]
    lea rdi, [pn_dir]
.cmp:
    mov al, [rsi]
    test al, al
    jz .same
    cmp al, [rdi]
    jne .out
    inc rsi
    inc rdi
    jmp .cmp
.same:
    xor eax, eax
.out:
    pop rax
    pop rdi
    pop rsi
    ret

; side_item(RSI = its name, EAX = 1 if it is where the list is; R12D, R13D
; = where)
side_item:
    push rsi
    test eax, eax
    jz .text
    mov edi, 140
    call kit_pt
    mov edx, eax
    mov edi, 6
    call kit_pt
    mov r8d, eax
    mov edi, r12d
    mov esi, r13d
    mov ecx, [pn_rh]
    call kit_accent
    and eax, 0xFFFFFF
    or eax, KA(0x30)
    mov r9d, eax
    call kit_round
.text:
    pop rsi
    call k_slen
    mov edi, 140
    call kit_pt
    lea edx, [rax - 16]
    push rsi
    lea rdi, [side_buf]                 ; fitted
    push rcx
    rep movsb
    pop rcx
    pop rsi
    lea rsi, [side_buf]
    mov r8d, [f_ui]
    call fit_text
    push rcx
    mov edx, [f_ui]
    mov esi, r13d
    mov ecx, [pn_rh]
    call kit_base
    mov edx, eax
    pop rcx
    lea rsi, [side_buf]
    mov edi, 8
    push rdx
    push rcx
    call kit_pt
    pop rcx
    pop rdx
    lea edi, [r12 + rax]
    mov r8d, [f_ui]
    mov r9d, [c_text]
    call kit_text
    ret

; paint_list: what the folder holds
paint_list:
    push rbx
    push rbp
    push r12
    push r13
    push r14
    push r15
    mov edi, 154
    call kit_pt
    mov r12d, [sp_x]
    add r12d, [sp_pad]
    add r12d, eax                       ; R12D: its left
    mov [pn_lx], r12d
    mov r14d, [sp_x]
    add r14d, [sp_w]
    sub r14d, [sp_pad]
    sub r14d, r12d                      ; R14D: its width
    mov [pn_lw], r14d
    mov r13d, [pn_y0]
    mov ebp, [pn_y1]
    sub ebp, r13d                       ; EBP: its height
    mov edi, 8
    call kit_pt
    mov r8d, eax
    mov edi, r12d
    mov esi, r13d
    mov edx, r14d
    mov ecx, ebp
    mov r9d, [c_bg]
    call kit_round
    mov edi, 8
    call kit_pt
    mov r8d, eax
    mov edi, r12d
    mov esi, r13d
    mov edx, r14d
    mov ecx, ebp
    mov r9d, [c_line]
    mov r10d, 1
    call kit_frame
    mov edi, 4                          ; its rows
    call kit_pt
    lea eax, [rbp - 8]
    xor edx, edx
    div dword [pn_rh]
    mov [pn_rows], eax
    mov edi, r12d
    mov esi, r13d
    mov edx, r14d
    mov ecx, ebp
    call kit_clip
    cmp dword [pn_n], 0
    jne .rows
    lea rsi, [s_empty_dir]              ; nothing: say so
    cmp dword [pn_bad], 0
    je .say
    lea rsi, [s_bad_dir]
.say:
    push rsi
    call k_slen
    mov edx, [f_ui]
    call kit_text_w
    pop rsi
    mov edi, r14d
    sub edi, eax
    sar edi, 1
    add edi, r12d
    push rdi
    push rsi
    push rcx
    mov edx, [f_ui]
    mov esi, r13d
    mov ecx, ebp
    call kit_base
    mov edx, eax
    pop rcx
    pop rsi
    pop rdi
    mov r8d, [f_ui]
    mov r9d, [c_text3]
    call kit_text
    jmp .out
.rows:
    xor r15d, r15d                      ; R15D: the row
.each:
    cmp r15d, [pn_rows]
    jae .scroller
    mov eax, [pn_top]
    add eax, r15d
    cmp eax, [pn_n]
    jae .scroller
    mov ebx, eax                        ; EBX: which
    mov edi, 4
    call kit_pt
    mov esi, r15d
    imul esi, [pn_rh]
    add esi, eax
    add esi, r13d
    mov [pn_ry], esi
    lea edi, [r12 + rax]
    mov edx, r14d
    sub edx, eax
    sub edx, eax
    mov ecx, [pn_rh]
    lea r8d, [r15 + H_S_ROW]
    call hit_add
    mov dword [pn_ink], 0               ; chosen: in the accent
    cmp ebx, [pn_sel]
    jne .icon
    push rdi
    push rdx
    mov edi, 6
    call kit_pt
    mov r8d, eax
    pop rdx
    pop rdi
    mov esi, [pn_ry]
    mov ecx, [pn_rh]
    call kit_accent
    and eax, 0xFFFFFF
    mov r9d, eax
    call kit_round
    mov dword [pn_ink], 1
.icon:
    mov eax, ebx
    call pn_entry
    mov rbx, rsi                        ; RBX: its record
    mov edi, 14
    call kit_pt
    lea edi, [r12 + rax]
    mov esi, [pn_ry]
    test dword [rbx + FE_ATTR], FEA_DIR
    jz .file_icon
    call folder_icon
    jmp .name
.file_icon:
    call file_icon
.name:
    lea rsi, [rbx + FE_NAME]
    call k_slen
    cmp ecx, 200
    jbe .short
    mov ecx, 200
.short:
    push rsi
    lea rdi, [row_buf]
    push rcx
    rep movsb
    pop rcx
    pop rsi
    mov edi, 140
    call kit_pt
    mov edx, r14d
    sub edx, eax
    lea rsi, [row_buf]
    mov r8d, [f_ui]
    call fit_text
    push rcx
    mov edx, [f_ui]
    mov esi, [pn_ry]
    mov ecx, [pn_rh]
    call kit_base
    mov [pn_base], eax
    pop rcx
    mov edi, 40
    call kit_pt
    lea edi, [r12 + rax]
    lea rsi, [row_buf]
    mov edx, [pn_base]
    mov r8d, [f_ui]
    mov r9d, [c_text]
    cmp dword [pn_ink], 0
    je .write
    mov r9d, 0xFFFFFF
.write:
    call kit_text
    test dword [rbx + FE_ATTR], FEA_DIR  ; a file's size, at the right
    jnz .next
    lea rdi, [row_buf]
    mov rax, [rbx + FE_SIZE]
    call fmt_size
    mov byte [rdi], 0
    lea rsi, [row_buf]
    call k_slen
    push rcx
    mov edx, [f_small]
    call kit_text_w
    pop rcx
    push rax
    mov edi, 14
    call kit_pt
    pop rdx
    mov edi, r12d
    add edi, r14d
    sub edi, eax
    sub edi, edx
    lea rsi, [row_buf]
    mov edx, [pn_base]
    mov r8d, [f_small]
    mov r9d, [c_text3]
    cmp dword [pn_ink], 0
    je .size
    mov r9d, KA(0xC0) | 0xFFFFFF
.size:
    call kit_text
.next:
    inc r15d
    jmp .each
.scroller:
    call kit_unclip
    mov edi, 9
    call kit_pt
    lea edi, [r12 + r14]
    sub edi, eax
    lea esi, [r13 + 4]
    lea edx, [rbp - 8]
    mov ecx, [pn_n]
    mov r8d, [pn_rows]
    mov r9d, [pn_top]
    call kit_scroller
.out:
    call kit_unclip
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret

; folder_icon(EDI = x, ESI = a row's top): a folder, as Finder draws one
folder_icon:
    push r12
    push r13
    mov r12d, edi
    mov r13d, esi
    mov edi, 5
    call kit_pt
    add r13d, eax                       ; its top
    mov edi, 2
    call kit_pt
    mov r8d, eax                        ; the tab
    mov edi, 8
    call kit_pt
    mov edx, eax
    mov edi, 5
    call kit_pt
    mov ecx, eax
    mov edi, r12d
    mov esi, r13d
    mov r9d, 0x4FA3E8
    call kit_round
    mov edi, 2                          ; the body
    call kit_pt
    mov r8d, eax
    mov edi, 18
    call kit_pt
    mov edx, eax
    mov edi, 12
    call kit_pt
    mov ecx, eax
    mov edi, 2
    call kit_pt
    lea esi, [r13 + rax]
    mov edi, r12d
    mov r9d, 0x6CB6F2
    call kit_round
    pop r13
    pop r12
    ret

; file_icon(EDI = x, ESI = a row's top): a page
file_icon:
    push r12
    push r13
    mov r12d, edi
    mov r13d, esi
    mov edi, 3
    call kit_pt
    add r13d, eax
    add r12d, eax
    mov edi, 2
    call kit_pt
    mov r8d, eax
    mov edi, 13
    call kit_pt
    mov edx, eax
    mov edi, 17
    call kit_pt
    mov ecx, eax
    mov edi, r12d
    mov esi, r13d
    mov r9d, 0xFFFFFF
    call kit_dark
    jne .light
    mov r9d, 0xD8D8DC
.light:
    push rdx
    push rcx
    push r8
    call kit_round
    pop r8
    pop rcx
    pop rdx
    mov edi, r12d
    mov esi, r13d
    mov r9d, [c_text3]
    mov r10d, 1
    call kit_frame
    pop r13
    pop r12
    ret

; fmt_size(RAX = bytes, RDI) -> "12 KB" there, RDI past it
fmt_size:
    cmp rax, 1000
    jae .kb
    call put_dec
    lea rsi, [s_bytes]
    jmp str_cat
.kb:
    cmp rax, 1000000
    jae .mb
    add rax, 500
    xor edx, edx
    mov ecx, 1000
    div rcx
    call put_dec
    lea rsi, [s_kb]
    jmp str_cat
.mb:
    add rax, 50000                      ; tenths
    xor edx, edx
    mov ecx, 100000
    div rcx
    push rax
    xor edx, edx
    mov ecx, 10
    div rcx
    push rdx
    call put_dec
    mov byte [rdi], '.'
    inc rdi
    pop rax
    call put_dec
    pop rax
    lea rsi, [s_mb]
    jmp str_cat

section .rodata
s_txt:          db '.txt', 0
s_untitled_dir: db 'untitled folder', 0
s_is_folder:    db 'A folder has that name.', 0
s_tabs_full:    db 'There are as many tabs as there can be.', 0
s_ask_save1:    db 'Do you want to save the changes you made to ', 0xE2, 0x80, 0x9C, 0
s_ask_save2:    db 0xE2, 0x80, 0x9D, '?', 0
s_ask_save3:    db "Your changes will be lost if you don't save them.", 0
s_quote1:       db 0xE2, 0x80, 0x9C, 0
s_ask_replace:  db 0xE2, 0x80, 0x9D, ' already exists. Do you want to replace it?', 0
s_ask_replace2: db 'A file with the same name already exists in this folder. Replacing it will overwrite what it holds.', 0
s_save:         db 'Save', 0
s_replace_b:    db 'Replace', 0
s_cancel:       db 'Cancel', 0
s_dont_save:    db "Don't Save", 0
s_open_title:   db 'Open', 0
s_open_b:       db 'Open', 0
s_save_as:      db 'Save As:', 0
s_new_dir:      db 'New Folder', 0
s_locations:    db 'Locations', 0
s_this_folder:  db 'This Folder', 0
s_sep:          db '  ', 0xE2, 0x80, 0xBA, '  ', 0
s_empty_dir:    db 'This folder is empty.', 0
s_bad_dir:      db 'This folder could not be read.', 0
s_bytes:        db ' bytes', 0
s_kb:           db ' KB', 0
s_mb:           db ' MB', 0

section .bss
alignb 8
pn_va:          resq 1
pn_msg:         resq 1
f_name:         resb KE_SIZE
sheet:          resd 1                  ; S_*, 0 if none is down
pn_h:           resd 1
pn_n:           resd 1
pn_sel:         resd 1
pn_top:         resd 1
pn_rows:        resd 1
pn_bad:         resd 1
pn_nvols:       resd 1
pn_then_close:  resd 1                  ; saving, then the tab closes
pn_y0:          resd 1
pn_y1:          resd 1
pn_by:          resd 1
pn_lx:          resd 1
pn_lw:          resd 1
pn_rh:          resd 1
pn_ry:          resd 1
pn_ink:         resd 1
pn_base:        resd 1
sp_x:           resd 1
sp_y:           resd 1
sp_w:           resd 1
sp_h:           resd 1
sp_pad:         resd 1
sp_r:           resd 1
sp_bh:          resd 1
sp_gap:         resd 1
pn_idx:         resd PN_MAX
pn_vols:        resb PN_VOLS * FV_SIZE
sheet_hits:     resb 8 + HITS_MAX * HIT_SIZE
pn_dir:         resb FS_PATH
pn_path:        resb FS_PATH
pn_backup:      resb D_SIZE
name_text:      resb 256
name2:          resb 64
alert_buf:      resb FS_PATH + 128
pretty_buf:     resb 256
side_buf:       resb 64
row_buf:        resb 256
vol_name:       resb 24
vol_name2:      resb 16
