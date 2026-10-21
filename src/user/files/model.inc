; =============================================================================
;  files/model.inc - the volumes, the folder shown, what it holds, and the
;  way back
;
;  A folder's things are listed whole (RO_FS_LIST) into one block of memory
;  (its path first, then FE_* records); all_idx has those shown at all (not
;  hidden, not a system file, no name starting with '.'), idx those the
;  search leaves, in order: folders first, then by the key chosen, names
;  compared as people read them ("file 2" before "file 10").
; =============================================================================

LS_MEM          equ 512 * 1024          ; a folder's listing
LS_RECS         equ 4096                ; where its records start
LS_MAX          equ 4096                ; things in a folder, at most
VOLS_MAX        equ 16
HIST_MAX        equ 32                  ; folders to go back to

SORT_NAME         equ 0                   ; what the list is sorted by
SORT_DATE         equ 1
SORT_SIZE         equ 2
SORT_KIND         equ 3

section .text

; fs_init: whether the files given reach every volume or one folder; the
; volumes
fs_init:
    mov dword [confined], 0
    mov rdi, [ax_io_va]                 ; "": a folder's own, if it is one
    mov byte [rdi], 0
    mov eax, RO_FS_LIST
    mov edi, [ax_io]
    xor esi, esi
    mov edx, 512
    xor ecx, ecx
    call fsq
    test rax, rax
    js vols_read
    mov dword [confined], 1
    ; fall through

; vols_read: the volumes, into vols, and which Axiom started from
vols_read:
    mov dword [nvols], 0
    cmp dword [confined], 0
    jne .out
    mov eax, RO_FS_VOLUMES
    mov edi, [ax_io]
    xor esi, esi
    mov edx, 4096
    xor ecx, ecx
    call fsq
    test rax, rax
    jle .out
    cmp eax, VOLS_MAX
    jbe .n
    mov eax, VOLS_MAX
.n:
    mov [nvols], eax
    imul ecx, eax, FV_SIZE
    mov rsi, [ax_io_va]
    lea rdi, [vols]
    rep movsb
    xor ecx, ecx
.each:
    cmp ecx, [nvols]
    jae .out
    imul edx, ecx, FV_SIZE
    test dword [vols + rdx + FV_FLAGS], FVF_BOOT
    jz .next
    mov eax, [vols + rdx + FV_INDEX]
    mov [boot_vol], eax
.next:
    inc ecx
    jmp .each
.out:
    ret

; ls_init -> CF if there is no memory for a listing
ls_init:
    mov edi, LS_MEM
    call kit_alloc
    jc .out
    mov [ls_va], rax
    mov [ls_h], edx
.out:
    ret

; path_in(RSI = a name, NUL-ended, RDI = FS_PATH bytes): the path to it,
; on the volume Axiom started from if it names none (and the files reach
; every one)
path_in:
    push rbx
    mov rbx, rdi
    xor ecx, ecx                        ; does it name its volume?
.scan:
    mov al, [rsi + rcx]
    test al, al
    jz .plain
    cmp al, ':'
    je .named
    inc ecx
    jmp .scan
.plain:
    cmp dword [confined], 0
    jne .confined
    mov rdi, rbx
    mov dword [rdi], 'vol'
    add rdi, 3
    push rsi
    mov eax, [boot_vol]
    call put_dec
    pop rsi
    mov byte [rdi], ':'
    inc rdi
    cmp byte [rsi], '/'
    je .copy
    cmp byte [rsi], 0
    je .copy
    mov byte [rdi], '/'
    inc rdi
    jmp .copy
.confined:
    cmp byte [rsi], '/'                 ; from the folder given
    jne .named
    inc rsi
.named:
    mov rdi, rbx
.copy:
    lea rcx, [rbx + FS_PATH - 1]
.byte:
    mov al, [rsi]
    test al, al
    jz .done
    cmp rdi, rcx
    jae .done
    mov [rdi], al
    inc rdi
    inc rsi
    jmp .byte
.done:
    cmp rdi, rbx                        ; no '/' at its end
    je .ended
    cmp byte [rdi - 1], '/'
    jne .ended
    dec rdi
    jmp .done
.ended:
    mov byte [rdi], 0
    pop rbx
    ret

; home_path(RDI): where Files starts: the top of the stick Axiom started
; from, or of the folder given
home_path:
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

; go_home: there, with nothing to go back to
go_home:
    lea rdi, [path_buf]
    call home_path
    lea rsi, [path_buf]
    call go_to
    ret

; go_to(RSI = a folder's path) -> CF (said why) if it could not be read,
; and what was shown still is
go_to:
    push rbx
    lea rdi, [prev_dir]
    push rsi
    lea rsi, [dir]
    call str_copy
    pop rsi
    lea rdi, [dir]
    call str_copy
    mov byte [keep_name], 0
    call search_clear
    call list_dir
    cmp dword [bad], 0
    je .read
    mov ebx, [bad]
    lea rsi, [prev_dir]                 ; it could not: back where it was
    lea rdi, [dir]
    call str_copy
    call list_dir
    mov eax, ebx
    cdqe
    call error_text
    mov [said], rax
    stc
    jmp .out
.read:
    mov dword [scroll], 0
    call title_set
    mov dword [need], N_ALL
    clc
.out:
    pop rbx
    ret

; nav_to(RSI = a folder's path): there, and the way back to here kept
nav_to:
    push rsi
    lea rdi, [dir]                      ; there already
    call str_eq
    pop rsi
    je .out
    call go_to
    jc .out
    lea rsi, [prev_dir]
    lea rdi, [back]
    lea rdx, [back_n]
    call hist_push
    mov dword [fwd_n], 0
.out:
    ret

; go_back, go_forward: along the way kept
go_back:
    cmp dword [back_n], 0
    je .out
    dec dword [back_n]
    mov eax, [back_n]
    imul eax, eax, FS_PATH
    lea rsi, [back + rax]
    call go_to
    jc .undo
    lea rsi, [prev_dir]
    lea rdi, [fwd]
    lea rdx, [fwd_n]
    call hist_push
    lea rsi, [prev_dir]                 ; the folder left, chosen
    call keep_last
    ret
.undo:
    inc dword [back_n]
.out:
    ret

go_forward:
    cmp dword [fwd_n], 0
    je .out
    dec dword [fwd_n]
    mov eax, [fwd_n]
    imul eax, eax, FS_PATH
    lea rsi, [fwd + rax]
    call go_to
    jc .undo
    lea rsi, [prev_dir]
    lea rdi, [back]
    lea rdx, [back_n]
    call hist_push
    ret
.undo:
    inc dword [fwd_n]
.out:
    ret

; go_up: the folder above, the one left chosen in it
go_up:
    lea rsi, [dir]
    lea rdi, [path_buf]
    call str_copy
    lea rdi, [path_buf]
    call parent_of
    jc .out
    lea rsi, [path_buf]
    call nav_to
    jc .out
    lea rsi, [prev_dir]
    call keep_last
.out:
    ret

; keep_last(RSI = a path): its last name chosen, if it is here
keep_last:
    call last_name
    lea rdi, [keep_name]
    call str_copy
    call arrange
    call reveal
    mov dword [need], N_ALL
    ret

; hist_push(RSI = a path, RDI = its stack, RDX = how many it holds)
hist_push:
    push rbx
    mov rbx, rdx
    cmp dword [rbx], HIST_MAX           ; full: the oldest goes
    jb .room
    push rsi
    push rdi
    mov rsi, rdi
    add rsi, FS_PATH
    mov ecx, (HIST_MAX - 1) * FS_PATH
    rep movsb
    pop rdi
    pop rsi
    dec dword [rbx]
.room:
    mov eax, [rbx]
    imul eax, eax, FS_PATH
    add rdi, rax
    call str_copy
    inc dword [rbx]
    pop rbx
    ret

; parent_of(RDI = a path): the folder it is in, in place; CF if it is a
; volume's top, or the folder given
parent_of:
    xor ecx, ecx
    mov edx, -1                         ; EDX: its last '/'
    mov r8d, -1                         ; R8D: its ':'
.each:
    mov al, [rdi + rcx]
    test al, al
    jz .end
    cmp al, '/'
    jne .colon
    mov edx, ecx
.colon:
    cmp al, ':'
    jne .next
    mov r8d, ecx
.next:
    inc ecx
    jmp .each
.end:
    test ecx, ecx                       ; "": the folder given
    jz .top
    lea eax, [r8 + 1]                   ; "vol0:": a volume's top
    test r8d, r8d
    js .cut
    cmp eax, ecx
    jae .top
.cut:
    test edx, edx
    js .first
    mov byte [rdi + rdx], 0             ; "vol0:/a/b" -> "vol0:/a", "vol0:/a"
    clc                                 ; -> "vol0:", "a/b" -> "a"
    ret
.first:
    mov byte [rdi], 0                   ; "a" -> "", the folder given
    clc
    ret
.top:
    stc
    ret

; last_name(RSI = a path) -> RSI = its last name (after the last '/' or ':')
last_name:
    mov rax, rsi
.each:
    mov cl, [rsi]
    test cl, cl
    jz .out
    inc rsi
    cmp cl, '/'
    je .mark
    cmp cl, ':'
    jne .each
.mark:
    mov rax, rsi
    jmp .each
.out:
    mov rsi, rax
    ret

; join(RSI = a name) -> path_buf: it, in dir; join_to(RSI, RDI = FS_PATH
; bytes): there. Preserves others but RAX, RCX, RSI, RDI.
join:
    lea rdi, [path_buf]
join_to:
    lea rcx, [rdi + FS_PATH - 1]
    push rsi
    lea rsi, [dir]
    call str_cat
    pop rsi
    cmp byte [dir], 0                   ; the folder given: the name alone
    je .name
    mov byte [rdi], '/'
    inc rdi
.name:
    mov al, [rsi]
    test al, al
    jz .done
    cmp rdi, rcx
    jae .done
    stosb
    inc rsi
    jmp .name
.done:
    mov byte [rdi], 0
    ret

; dir_vol -> EAX = the volume dir is on (its n), -1 if the files reach one
; folder
dir_vol:
    mov eax, -1
    cmp dword [confined], 0
    jne .out
    lea rsi, [dir + 3]                  ; "vol<n>:"
    xor eax, eax
.digit:
    movzx ecx, byte [rsi]
    sub ecx, '0'
    cmp ecx, 9
    ja .out
    imul eax, eax, 10
    add eax, ecx
    inc rsi
    jmp .digit
.out:
    ret

; vol_rec(EAX = a volume's n) -> RSI = its FV_* record; CF if none
vol_rec:
    xor ecx, ecx
.each:
    cmp ecx, [nvols]
    jae .none
    imul edx, ecx, FV_SIZE
    lea rsi, [vols + rdx]
    cmp [rsi + FV_INDEX], eax
    je .out
    inc ecx
    jmp .each
.none:
    stc
    ret
.out:
    clc
    ret

; vol_label(EAX = a volume's n) -> RSI = its name, "Volume n" if it has none
vol_label:
    push rax
    call vol_rec
    pop rax
    jc .none
    add rsi, FV_LABEL
    cmp byte [rsi], 0
    jne .out
.none:
    lea rdi, [vol_name]
    mov dword [rdi], 'Volu'
    mov dword [rdi + 4], 'me '
    add rdi, 7
    call put_dec
    mov byte [rdi], 0
    lea rsi, [vol_name]
.out:
    ret

; dir_writable -> CF (said why, and how) if dir's volume is read-only.
; Confined: not known here, so CF clear (the write says).
dir_writable:
    call dir_vol
    test eax, eax
    js .yes
    push rax
    call vol_rec
    pop rax
    jc .yes
    test dword [rsi + FV_FLAGS], FVF_WRITABLE
    jnz .yes
    call readonly_said
    stc
    ret
.yes:
    clc
    ret

; dir_name -> RSI = what the folder shown is called
dir_name:
    cmp dword [confined], 0
    je .vols
    lea rsi, [dir]
    cmp byte [rsi], 0
    jne last_name
    lea rsi, [s_this_folder]
    ret
.vols:
    lea rsi, [dir]
    call last_name
    cmp byte [rsi], 0
    jne .out
    call dir_vol                        ; a volume's top: its name
    jmp vol_label
.out:
    ret

; list_dir: what dir holds, read again; what keep_name names chosen
list_dir:
    push rbx
    push r12
    push r13
    mov dword [n_all], 0
    mov dword [bad], 0
    mov rdi, [ls_va]
    lea rsi, [dir]
    mov ecx, FS_PATH
    rep movsb
    mov eax, RO_FS_LIST
    mov edi, [ls_h]
    xor esi, esi
    mov edx, LS_RECS
    mov ecx, LS_MEM - LS_RECS
    call fsq
    test rax, rax
    jns .listed
    mov [bad], eax
    jmp .arrange
.listed:
    mov r12, [ls_va]                    ; R12: a record
    add r12, LS_RECS
    mov r13, [ls_va]
    add r13, LS_MEM                     ; R13: their end
    mov ebx, eax                        ; EBX: how many
.each:
    test ebx, ebx
    jz .arrange
    lea rax, [r12 + FE_NAME]
    cmp rax, r13
    jae .arrange
    mov eax, [r12 + FE_LEN]
    test eax, eax
    jz .arrange
    test dword [r12 + FE_ATTR], FEA_HIDDEN | FEA_SYSTEM
    jnz .next
    cmp byte [r12 + FE_NAME], '.'
    je .next
    mov ecx, [n_all]
    cmp ecx, LS_MAX
    jae .arrange
    mov rax, r12
    sub rax, [ls_va]
    mov [all_idx + rcx * 4], eax
    inc dword [n_all]
.next:
    mov eax, [r12 + FE_LEN]
    add r12, rax
    dec ebx
    jmp .each
.arrange:
    call arrange
    pop r13
    pop r12
    pop rbx
    ret

; remember: the name chosen, to choose it again once the list changes
remember:
    mov byte [keep_name], 0
    mov eax, [sel]
    test eax, eax
    js .out
    cmp eax, [n]
    jae .out
    call entry
    add rsi, FE_NAME
    lea rdi, [keep_name]
    call str_copy
.out:
    ret

; arrange: idx, what is shown: what the search leaves, sorted; the one
; remembered chosen (if not, nothing is)
arrange:
    push rbx
    push r12
    mov dword [n], 0
    xor ebx, ebx
.each:
    cmp ebx, [n_all]
    jae .sort
    mov eax, [all_idx + rbx * 4]
    mov rsi, [ls_va]
    lea rsi, [rsi + rax + FE_NAME]
    call matches
    jc .next
    mov ecx, [n]
    mov eax, [all_idx + rbx * 4]
    mov [idx + rcx * 4], eax
    inc dword [n]
.next:
    inc ebx
    jmp .each
.sort:
    mov ecx, 1                          ; one at a time, into its place
.outer:
    cmp ecx, [n]
    jae .sorted
    mov r12d, [idx + rcx * 4]           ; R12D: what goes in its place
    mov edx, ecx
.inner:
    test edx, edx
    jz .put
    mov eax, r12d
    mov r8d, [idx + rdx * 4 - 4]
    call less
    jnc .put
    mov eax, [idx + rdx * 4 - 4]
    mov [idx + rdx * 4], eax
    dec edx
    jmp .inner
.put:
    mov [idx + rdx * 4], r12d
    inc ecx
    jmp .outer
.sorted:
    mov dword [sel], -1
    cmp byte [keep_name], 0
    je .out
    xor ebx, ebx
.find:
    cmp ebx, [n]
    jae .out
    mov eax, ebx
    call entry
    add rsi, FE_NAME
    lea rdi, [keep_name]
    call same_name
    je .found
    inc ebx
    jmp .find
.found:
    mov [sel], ebx
.out:
    pop r12
    pop rbx
    ret

; entry(EAX = which, of idx) -> RSI = its record. Preserves others.
entry:
    mov eax, [idx + rax * 4]
    mov rsi, [ls_va]
    add rsi, rax
    ret

; sel_entry -> RSI = the record chosen; CF if nothing is
sel_entry:
    mov eax, [sel]
    test eax, eax
    js .none
    cmp eax, [n]
    jae .none
    call entry
    clc
    ret
.none:
    stc
    ret

; matches(RSI = a name) -> CF if the search is not in it (but for case).
; Preserves RBX.
matches:
    mov ecx, [f_search + KE_LEN]
    test ecx, ecx
    jz .yes
    mov r8, [f_search + KE_BUF]
.at:
    cmp byte [rsi], 0
    je .no
    xor edx, edx
.cmp:
    cmp edx, ecx
    jae .yes
    mov al, [rsi + rdx]
    test al, al
    jz .no
    mov r9b, [r8 + rdx]
    LOWER al
    LOWER r9b
    cmp al, r9b
    jne .next
    inc edx
    jmp .cmp
.next:
    inc rsi
    jmp .at
.yes:
    clc
    ret
.no:
    stc
    ret

; less(EAX, R8D = two records, from ls_va) -> CF if the first goes before
; the second. Preserves all but RAX, R8.
less:
    push rcx
    push rdx
    push rsi
    push rdi
    push r9
    mov rsi, [ls_va]
    lea rdi, [rsi + r8]
    add rsi, rax
    mov eax, [rsi + FE_ATTR]            ; folders first
    mov ecx, [rdi + FE_ATTR]
    and eax, FEA_DIR
    and ecx, FEA_DIR
    cmp eax, ecx
    je .key
    cmp ecx, eax
    jmp .out
.key:
    mov ecx, [sort_key]
    cmp ecx, SORT_SIZE
    je .size
    cmp ecx, SORT_DATE
    je .date
    cmp ecx, SORT_KIND
    je .kind
    jmp .name
.size:
    mov rax, [rsi + FE_SIZE]
    cmp rax, [rdi + FE_SIZE]
    jmp .signed
.date:
    call when_key
    mov rcx, rax
    xchg rsi, rdi
    call when_key
    xchg rsi, rdi
    cmp rcx, rax
.signed:
    je .name
    sbb eax, eax                        ; -1 if the first is less, else 0
    or eax, 1
    jmp .flip
.kind:
    push rsi
    push rdi
    call kind_of
    mov r9d, eax
    mov rsi, rdi
    call kind_of
    imul eax, eax, KD_SIZE
    lea rdi, [kinds]
    mov rdi, [rdi + rax + KD_NAME]
    imul eax, r9d, KD_SIZE
    lea rsi, [kinds]
    mov rsi, [rsi + rax + KD_NAME]
    call name_cmp
    pop rdi
    pop rsi
    test eax, eax
    jnz .flip
.name:
    add rsi, FE_NAME
    add rdi, FE_NAME
    call name_cmp
    cmp dword [sort_key], SORT_NAME       ; names: the way chosen; else up
    jne .sign
.flip:
    cmp dword [sort_down], 0
    je .sign
    neg eax
.sign:
    cmp eax, 0                          ; CF if less than 0
    jge .after
    stc
    jmp .out
.after:
    clc
.out:
    pop r9
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    ret

; when_key(RSI = a record) -> RAX: when it was written, as a number that
; sorts. Preserves others.
when_key:
    movzx eax, word [rsi + FE_YEAR]
    shl rax, 8
    mov al, [rsi + FE_MONTH]
    shl rax, 8
    mov al, [rsi + FE_DAY]
    shl rax, 8
    mov al, [rsi + FE_HOUR]
    shl rax, 8
    mov al, [rsi + FE_MIN]
    shl rax, 8
    mov al, [rsi + FE_SEC]
    ret

; name_cmp(RSI, RDI = NUL-ended) -> EAX = -1, 0 or 1: as people read
; names, case aside, numbers by their value. Preserves others but RSI,
; RDI, R8.
name_cmp:
    push rcx
    push rdx
.each:
    movzx eax, byte [rsi]
    movzx ecx, byte [rdi]
    lea edx, [rax - '0']
    cmp edx, 9
    ja .chars
    lea edx, [rcx - '0']
    cmp edx, 9
    ja .chars
    call num_cmp
    test eax, eax
    jz .each
    jmp .out
.chars:
    LOWER al
    LOWER cl
    cmp al, cl
    jne .differ
    test al, al
    jz .same
    inc rsi
    inc rdi
    jmp .each
.differ:
    sbb eax, eax
    or eax, 1
    jmp .out
.same:
    xor eax, eax
.out:
    pop rdx
    pop rcx
    ret

; num_cmp(RSI, RDI = at digits) -> EAX = -1, 0 or 1 by their values; RSI
; and RDI past them
num_cmp:
.zero_a:                                ; leading zeros aside
    cmp byte [rsi], '0'
    jne .zero_b
    movzx eax, byte [rsi + 1]
    sub eax, '0'
    cmp eax, 9
    ja .zero_b
    inc rsi
    jmp .zero_a
.zero_b:
    cmp byte [rdi], '0'
    jne .lengths
    movzx eax, byte [rdi + 1]
    sub eax, '0'
    cmp eax, 9
    ja .lengths
    inc rdi
    jmp .zero_b
.lengths:
    xor ecx, ecx
.len_a:
    movzx eax, byte [rsi + rcx]
    sub eax, '0'
    cmp eax, 9
    ja .len_b0
    inc ecx
    jmp .len_a
.len_b0:
    xor edx, edx
.len_b:
    movzx eax, byte [rdi + rdx]
    sub eax, '0'
    cmp eax, 9
    ja .compare
    inc edx
    jmp .len_b
.compare:
    cmp ecx, edx                        ; more digits: larger
    jne .by
    xor r8d, r8d
.digit:
    cmp r8d, ecx
    jae .equal
    mov al, [rsi + r8]
    cmp al, [rdi + r8]
    jne .by
    inc r8d
    jmp .digit
.by:
    sbb eax, eax
    or eax, 1
    jmp .past
.equal:
    xor eax, eax
.past:
    add rsi, rcx
    add rdi, rdx
    ret

; str_eq(RSI, RDI = NUL-ended) -> ZF if the same. Preserves others but RAX.
str_eq:
    push rsi
    push rdi
.each:
    mov al, [rsi]
    cmp al, [rdi]
    jne .out
    test al, al
    jz .out
    inc rsi
    inc rdi
    jmp .each
.out:
    pop rdi
    pop rsi
    ret

; exists(RSI = a name) -> ZF if dir holds something by that name (as FAT
; compares them, case aside). Preserves RSI.
exists:
    push rbx
    xor ebx, ebx
.each:
    cmp ebx, [n_all]
    jae .no
    mov eax, [all_idx + rbx * 4]
    mov rdi, [ls_va]
    lea rdi, [rdi + rax + FE_NAME]
    call same_name
    je .out
    inc ebx
    jmp .each
.no:
    or ebx, 1                           ; ZF clear
.out:
    pop rbx
    ret

section .rodata
s_this_folder:  db 'This Folder', 0

section .bss
alignb 8
ls_va:          resq 1
ls_h:           resd 1
confined:       resd 1                  ; 1: the files reach one folder alone
boot_vol:       resd 1
nvols:          resd 1
n_all:          resd 1                  ; things listed and shown at all
n:              resd 1                  ; and those the search leaves
sel:            resd 1                  ; the one chosen, of idx; -1 none
bad:            resd 1                  ; E_* if the folder could not be read
sort_key:       resd 1                  ; SORT_*
sort_down:      resd 1                  ; 1: the other way
back_n:         resd 1
fwd_n:          resd 1
vols:           resb VOLS_MAX * FV_SIZE
all_idx:        resd LS_MAX
idx:            resd LS_MAX
dir:            resb FS_PATH            ; the folder shown
prev_dir:       resb FS_PATH
path_buf:       resb FS_PATH
path_buf2:      resb FS_PATH
keep_name:      resb FS_PATH
vol_name:       resb 24
back:           resb HIST_MAX * FS_PATH
fwd:            resb HIST_MAX * FS_PATH
