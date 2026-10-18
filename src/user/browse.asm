; =============================================================================
;  browse.asm - a web browser, in a window of its own
;
;    run browse [url]
;
;  B1: pages over HTTP and HTTPS (fetch.inc), HTML (html.inc) or plain
;  text, laid out (layout.inc) and drawn (draw.inc) in a 1400 by 1000
;  window: a toolbar (back, forward, reload, the address), the page, its
;  scrollbar, a status line. No CSS, images or scripts yet.
;    ctrl+L, or a click there: the address, all of it chosen; Enter goes
;      there, Esc leaves it
;    the wheel, up and down, space: scroll; Backspace: back; ctrl+R:
;      reload; ctrl+W or the close button: the end
;    a click on a link follows it; "#name" scrolls to its anchor
;  Redirects are followed, 8 at most. The charset is the Content-Type's,
;  else the page's <meta>, else UTF-8 if the bytes are, else Windows-1252.
;  A page that cannot be had is an error page; with no URL, a start page.
;  Each load says, on the console:
;    browse: <url>: <status>, <bytes> bytes, <elements> elements, <links> links
;  and the window is titled "<title> · browse".
; =============================================================================

%include "axe.inc"

CHUNK           equ 4096                ; through the io page
WAIT_US         equ 15000000            ; how long anything may take

%include "sock.inc"
%include "web/util.inc"
%include "web/url.inc"
%include "web/fetch.inc"
%include "web/html.inc"
%include "web/draw.inc"
%include "web/layout.inc"

WIN_W           equ 1400
WIN_H           equ 1000
TB_H            equ 56                  ; the toolbar
SB_H            equ 32                  ; the status line
BAR_W           equ 14                  ; the scrollbar
VIEW_Y          equ TB_H
VIEW_W          equ WIN_W - BAR_W
VIEW_H          equ WIN_H - TB_H - SB_H
BTN_Y           equ 8
BTN_W           equ 44
BTN_H           equ 40
BACK_X          equ 8
FWD_X           equ 56
RELOAD_X        equ 104
ADDR_X          equ 160
ADDR_Y          equ 8
ADDR_W          equ WIN_W - ADDR_X - 8
ADDR_H          equ 40
ADDR_PAD        equ 10
ADDR_MAX        equ 2048
THUMB_MIN       equ 32
LINE_PX         equ 48                  ; an arrow's scroll
WHEEL_PX        equ 72                  ; a notch's
ARENA_BYTES     equ 64 << 20
REDIRECTS_MAX   equ 8
HIST_MAX        equ 64
HE_TEXT         equ 0                   ; a history entry: the URL, with its
HE_SCROLL       equ U_TEXT_MAX + 256    ; fragment, and where it was scrolled
HE_SIZE         equ HE_SCROLL + 8
GEN_MAX         equ 65536
TITLE_KEEP      equ 140                 ; of the page's title, at most

FONT_UI         equ WF_SANS * WF_SIZES + WF_PX20
FONT_STATUS     equ WF_SANS * WF_SIZES + WF_PX16
BC_PAGE        equ 0xFFFFFF
BC_CHROME      equ 0xECEFF3
BC_EDGE        equ 0xC9CED6
BC_BUTTON      equ 0xDCE1E8
BC_INK         equ 0x202124
BC_FAINT         equ 0xA0A6AE
BC_FIELD_EDGE  equ 0x9AA3AE
BC_FOCUS       equ 0x3B78E7
BC_CHOSEN      equ 0xC8DCFA
BC_TRACK       equ 0xF1F3F4
BC_THUMB       equ 0xBDC1C6
BC_STATUS      equ 0x3C4043

GO_NEW          equ 0                   ; go's ways: a new page in the history,
GO_HIST         equ 1                   ; one from it, the same again
GO_RELOAD       equ 2

KEY_UP          equ 0x11                ; kbd.asm's
KEY_DOWN        equ 0x12
KEY_LEFT        equ 0x13
KEY_RIGHT       equ 0x14
KEY_BS          equ 8
KEY_ENTER       equ 10
KEY_ESC         equ 27
KEY_CTRL_L      equ 12
KEY_CTRL_R      equ 18
KEY_CTRL_W      equ 23

main:
    push rbx
    push r12
    push r13
    push r14
    push r15
    lea rsi, [rdi + SB_ARGS]            ; the URL, if any
    mov ecx, [rdi + SB_ARGS_LEN]
    cmp ecx, ADDR_MAX - 1
    jbe .args
    mov ecx, ADDR_MAX - 1
.args:
    lea rdi, [arg_buf]
    rep movsb
    mov byte [rdi], 0
    cmp dword [ax_desk], 0
    je .no_desk
    mov edi, RESP_MAX
    call mem_new
    test rax, rax
    js .refused
    mov [resp_buf], rax
    mov edi, ARENA_BYTES
    call ar_init
    test rax, rax
    js .refused
    mov edi, DL_BYTES
    call mem_new
    test rax, rax
    js .refused
    mov [dl_base], rax
    mov [dl_top], rax
    add rax, DL_BYTES
    mov [dl_end], rax
    lea rsi, [s_home_url]               ; a URL to be on, for now
    lea rdi, [cur_url]
    call url_parse

    mov eax, SYS_CHANNEL_NEW            ; what the window says comes over this
    syscall
    test rax, rax
    js .refused
    mov [ev_end], edx
    mov edi, [ax_desk]
    mov esi, WIN_W
    mov edx, WIN_H
    mov r10d, eax
    mov eax, SYS_WINDOW_NEW
    syscall
    test rax, rax
    js .refused
    mov [win], eax
    mov edi, edx
    mov eax, SYS_MAP
    syscall
    test rax, rax
    js .refused
    mov [px_base], rax
    mov dword [px_stride], WIN_W
    lea rsi, [s_open]
    call ax_puts

    lea rsi, [arg_buf]
    mov edx, GO_NEW
    call go

.event:
    mov edi, [ev_end]
    lea rsi, [ev]
    mov edx, WE_SIZE
    xor ecx, ecx
    call ax_recv
    test rax, rax
    js .done                            ; the window is gone
    mov eax, [ev + WE_KIND]
    cmp eax, WE_KEY
    je .key
    cmp eax, WE_PRESS
    je .press
    cmp eax, WE_MOVE
    je .move
    cmp eax, WE_RELEASE
    je .release
    cmp eax, WE_WHEEL
    je .wheel
    cmp eax, WE_CLOSE
    je .done
    jmp .event
.key:
    mov eax, [ev + WE_CODE]
    call on_key
    jc .done
    jmp .event
.press:
    cmp dword [ev + WE_CODE], 1
    jne .event
    mov edi, [ev + WE_X]
    mov esi, [ev + WE_Y]
    call on_press
    jmp .event
.move:
    cmp byte [dragging], 0
    je .event
    mov edi, [ev + WE_Y]
    call bar_to
    jmp .event
.release:
    mov byte [dragging], 0
    jmp .event
.wheel:
    mov edi, [ev + WE_CODE]
    imul edi, edi, -WHEEL_PX
    call scroll_by
    jmp .event
.done:
    lea rsi, [s_bye]
    call ax_puts
    xor eax, eax
    jmp .out
.no_desk:
    lea rsi, [s_no_desk]
    call ax_puts
    mov eax, 2
    jmp .out
.refused:
    mov rbx, rax
    lea rsi, [s_refused]
    call ax_add
    mov rdi, rbx
    call ax_addd
    call ax_flush
    mov eax, 3
.out:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; -----------------------------------------------------------------------------
;  Input
; -----------------------------------------------------------------------------

; on_key(EAX = a key) -> CF to end
on_key:
    cmp byte [addr_focus], 0
    jne addr_key
    cmp eax, KEY_CTRL_L
    je .address
    cmp eax, KEY_DOWN
    je .down
    cmp eax, KEY_UP
    je .up
    cmp eax, ' '
    je .page
    cmp eax, KEY_BS
    je .back
    cmp eax, KEY_CTRL_R
    je .reload
    cmp eax, KEY_CTRL_W
    je .end
    clc
    ret
.address:
    call addr_take
    clc
    ret
.down:
    mov edi, LINE_PX
    call scroll_by
    clc
    ret
.up:
    mov edi, -LINE_PX
    call scroll_by
    clc
    ret
.page:
    mov edi, VIEW_H - LINE_PX
    call scroll_by
    clc
    ret
.back:
    call go_back
    clc
    ret
.reload:
    call reload
    clc
    ret
.end:
    stc
    ret

; addr_take: the address field has the keys, all of it chosen
addr_take:
    mov byte [addr_focus], 1
    mov byte [addr_all], 1
    mov eax, [addr_len]
    mov [addr_caret], eax
    jmp paint_toolbar

; addr_leave: it has them no more, and shows the page's URL again
addr_leave:
    mov byte [addr_focus], 0
    mov byte [addr_all], 0
    call addr_from_page
    jmp paint_toolbar

; addr_key(EAX = a key), while the address field has the keys -> CF clear
addr_key:
    cmp eax, KEY_ENTER
    je .enter
    cmp eax, 13
    je .enter
    cmp eax, KEY_ESC
    je .escape
    cmp eax, KEY_CTRL_L
    je .all
    cmp eax, KEY_BS
    je .backspace
    cmp eax, KEY_LEFT
    je .left
    cmp eax, KEY_RIGHT
    je .right
    cmp eax, ' '
    jb .done
    cmp eax, 0x7E
    ja .done
    cmp byte [addr_all], 0              ; a character: in place of what was
    je .insert                          ; chosen, or at the caret
    mov dword [addr_len], 0
    mov dword [addr_caret], 0
    mov byte [addr_all], 0
.insert:
    mov ecx, [addr_len]
    cmp ecx, ADDR_MAX - 1
    jae .done
    mov edx, [addr_caret]
.shift:
    cmp ecx, edx
    jbe .put
    mov r8b, [addr_buf + rcx - 1]
    mov [addr_buf + rcx], r8b
    dec ecx
    jmp .shift
.put:
    mov [addr_buf + rdx], al
    inc dword [addr_len]
    inc dword [addr_caret]
    mov ecx, [addr_len]
    mov byte [addr_buf + rcx], 0
    jmp .done
.backspace:
    cmp byte [addr_all], 0
    je .delete
    mov dword [addr_len], 0
    mov dword [addr_caret], 0
    mov byte [addr_buf], 0
    mov byte [addr_all], 0
    jmp .done
.delete:
    mov edx, [addr_caret]
    test edx, edx
    jz .done
    dec dword [addr_caret]
    dec dword [addr_len]
    mov ecx, [addr_len]
.pull:
    cmp edx, ecx
    ja .pulled
    mov r8b, [addr_buf + rdx]
    mov [addr_buf + rdx - 1], r8b
    inc edx
    jmp .pull
.pulled:
    mov ecx, [addr_len]
    mov byte [addr_buf + rcx], 0
    jmp .done
.left:
    mov byte [addr_all], 0
    cmp dword [addr_caret], 0
    je .done
    dec dword [addr_caret]
    jmp .done
.right:
    mov byte [addr_all], 0
    mov eax, [addr_caret]
    cmp eax, [addr_len]
    jae .done
    inc dword [addr_caret]
    jmp .done
.all:
    mov byte [addr_all], 1
    mov eax, [addr_len]
    mov [addr_caret], eax
    jmp .done
.escape:
    call addr_leave
    clc
    ret
.enter:
    mov byte [addr_focus], 0
    mov byte [addr_all], 0
    lea rsi, [addr_buf]
    mov edx, GO_NEW
    call go
    clc
    ret
.done:
    call paint_toolbar
    clc
    ret

; on_press(EDI = x, ESI = y): the left button, there
on_press:
    push rbx
    push r12
    mov ebx, edi
    mov r12d, esi
    cmp r12d, TB_H
    jge .below
    cmp r12d, BTN_Y                     ; the toolbar
    jl .out
    cmp r12d, BTN_Y + BTN_H
    jge .out
    mov eax, ebx
    sub eax, BACK_X
    cmp eax, BTN_W
    jb .back
    mov eax, ebx
    sub eax, FWD_X
    cmp eax, BTN_W
    jb .forward
    mov eax, ebx
    sub eax, RELOAD_X
    cmp eax, BTN_W
    jb .reload
    mov eax, ebx
    sub eax, ADDR_X
    cmp eax, ADDR_W
    jae .out
    call addr_take
    jmp .out
.back:
    call go_back
    jmp .out
.forward:
    call go_forward
    jmp .out
.reload:
    call reload
    jmp .out
.below:
    cmp byte [addr_focus], 0
    je .page
    call addr_leave
.page:
    cmp r12d, VIEW_Y + VIEW_H
    jge .out
    cmp ebx, VIEW_W
    jl .link
    mov byte [dragging], 1              ; the scrollbar
    mov edi, r12d
    call bar_to
    jmp .out
.link:
    mov edi, ebx
    mov esi, r12d
    sub esi, VIEW_Y
    add esi, [scroll]
    call hit
    test eax, eax
    jz .out
    lea edi, [rax - 1]
    call follow
.out:
    pop r12
    pop rbx
    ret

; hit(EDI = x, ESI = y, in the document) -> EAX = the link there + 1, or 0
hit:
    push rbx
    mov rbx, [dl_base]
.item:
    cmp rbx, [dl_top]
    jae .none
    cmp byte [rbx + DI_KIND], DK_TEXT
    jne .next
    mov eax, [rbx + DI_LINK]
    test eax, eax
    jz .next
    movzx edx, byte [rbx + DI_FONT]
    call font_entry
    mov eax, [rbx + DI_Y]
    sub eax, [r11 + WFT_ASCENT]
    cmp esi, eax
    jl .next
    mov eax, [rbx + DI_Y]
    add eax, [r11 + WFT_DESCENT]
    cmp esi, eax
    jge .next
    mov eax, edi
    sub eax, [rbx + DI_X]
    jl .next
    mov ecx, [rbx + DI_W]
    add ecx, 63
    shr ecx, 6
    cmp eax, ecx
    jge .next
    mov eax, [rbx + DI_LINK]
    jmp .out
.next:
    add rbx, DI_SIZE
    jmp .item
.none:
    xor eax, eax
.out:
    pop rbx
    ret

; follow(EDI = a link): to where it goes, from this page
follow:
    push rbx
    shl edi, 4
    lea rbx, [lk_table + rdi]           ; RBX: the link
    mov rsi, [rbx + LK_HREF]
    mov ecx, [rbx + LK_LEN]
    lea rdx, [cur_url]
    lea rdi, [link_buf]
    call url_resolve
    jc .cannot
    pop rbx
    lea rsi, [link_buf]
    mov edx, GO_NEW
    jmp go
.cannot:                                ; mailto:, javascript:, ...: said so
    mov rsi, [rbx + LK_HREF]
    mov ecx, [rbx + LK_LEN]
    cmp ecx, 200
    jbe .short
    mov ecx, 200
.short:
    lea rdi, [link_buf]
    rep movsb
    mov byte [rdi], 0
    lea rsi, [link_buf]
    lea rdi, [s_cannot]
    call status_set
    pop rbx
    ret

; -----------------------------------------------------------------------------
;  Scrolling
; -----------------------------------------------------------------------------

; max_scroll -> EAX = the furthest the page scrolls
max_scroll:
    mov eax, [doc_height]
    sub eax, VIEW_H
    jge .out
    xor eax, eax
.out:
    ret

; scroll_by(EDI = pixels, down positive); scroll_to(EDI = where)
scroll_by:
    add edi, [scroll]
scroll_to:
    call max_scroll
    cmp edi, eax
    cmovg edi, eax
    xor eax, eax
    cmp edi, eax
    cmovl edi, eax
    cmp edi, [scroll]
    je .out
    mov [scroll], edi
    jmp paint_view
.out:
    ret

; thumb -> EAX = the thumb's height, EDX = its top in the view; ZF if there
; is no thumb (the page fits)
thumb:
    call max_scroll
    test eax, eax
    jz .out
    mov ecx, eax                        ; ECX: the furthest
    mov eax, VIEW_H * VIEW_H
    xor edx, edx
    div dword [doc_height]
    cmp eax, THUMB_MIN
    jge .tall
    mov eax, THUMB_MIN
.tall:
    push rax
    mov edx, VIEW_H
    sub edx, eax
    mov eax, [scroll]
    imul eax, edx
    xor edx, edx
    div ecx
    mov edx, eax
    pop rax
    test eax, eax                       ; ZF clear
.out:
    ret

; bar_to(EDI = y in the window): the thumb's middle there
bar_to:
    push rbx
    mov ebx, edi
    call thumb
    jz .out
    sub ebx, VIEW_Y
    mov ecx, eax
    shr ecx, 1
    sub ebx, ecx                        ; EBX: the thumb's top, wanted
    mov ecx, VIEW_H
    sub ecx, eax                        ; ECX: how far it moves
    jle .out
    call max_scroll
    imul eax, ebx
    cdq
    idiv ecx
    mov edi, eax
    call scroll_to
.out:
    pop rbx
    ret

; scroll_frag: to the anchor that cur_url's fragment names, or the top
scroll_frag:
    push rbx
    push r12
    xor edi, edi
    cmp byte [cur_url + U_FRAG], 0
    je .to
    lea rsi, [cur_url + U_FRAG]         ; its length
    xor ecx, ecx
.len:
    cmp byte [rsi + rcx], 0
    je .counted
    inc ecx
    jmp .len
.counted:
    lea rbx, [an_table]
    mov r12d, [an_count]
.anchor:
    test r12d, r12d
    jz .to
    cmp [rbx + AN_LEN], ecx
    jne .next
    push rcx
    push rsi
    mov rdi, [rbx + AN_NAME]
    repe cmpsb
    pop rsi
    pop rcx
    je .found
.next:
    add rbx, AN_SIZE
    dec r12d
    jmp .anchor
.found:
    mov edi, [rbx + AN_Y]
.to:
    mov dword [scroll], -1              ; (so it is drawn whatever)
    call scroll_to
    pop r12
    pop rbx
    ret

; -----------------------------------------------------------------------------
;  Going places
; -----------------------------------------------------------------------------

; go(RSI = NUL-ended text, EDX = GO_*): there
go:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov r13d, edx                       ; R13D: GO_*
    lea rdi, [go_text]                  ; a copy, trimmed
.blank:
    cmp byte [rsi], ' '
    jne .copy
    inc rsi
    jmp .blank
.copy:
    mov ecx, U_TEXT_MAX + 255
    call str_copy
.trim:
    lea rax, [go_text]
    cmp rdi, rax
    je .trimmed
    cmp byte [rdi - 1], ' '
    jne .trimmed
    dec rdi
    mov byte [rdi], 0
    jmp .trim
.trimmed:
    cmp r13d, GO_NEW                    ; where the page being left was
    jne .saved
    call hist_keep
.saved:
    cmp byte [go_text], 0
    je .start
    lea rsi, [go_text]
    lea rdi, [s_about_start]
    call ci_starts
    je .start
    lea rsi, [go_text]
    lea rdi, [new_url]
    call url_parse
    jc .bad_url
    cmp r13d, GO_RELOAD                 ; this page, another anchor on it
    je .fetch_first
    cmp byte [page_about], 0
    jne .fetch_first
    cmp byte [new_url + U_FRAG], 0
    je .fetch_first
    lea rsi, [new_url + U_TEXT]
    lea rdi, [cur_url + U_TEXT]
.same:
    mov al, [rsi]
    cmp al, [rdi]
    jne .fetch_first
    inc rsi
    inc rdi
    test al, al
    jnz .same
    lea rsi, [new_url]
    lea rdi, [cur_url]
    call url_copy
    call addr_from_page
    cmp r13d, GO_NEW
    jne .anchored
    call hist_add
.anchored:
    call scroll_frag
    call paint_toolbar
    jmp .out

.fetch_first:
    xor r14d, r14d                      ; R14D: redirects so far
.fetch:
    lea rsi, [new_url + U_TEXT]
    lea rdi, [s_loading]
    call status_set
    lea rdi, [new_url]
    call fetch
    test rax, rax
    js .failed
    mov r15, rax                        ; R15: the status
    cmp r15, 301
    je .redirect
    cmp r15, 302
    je .redirect
    cmp r15, 303
    je .redirect
    cmp r15, 307
    je .redirect
    cmp r15, 308
    jne .page
.redirect:
    cmp qword [resp_loc_len], 0
    je .page
    lea rsi, [s_log]                    ; "browse: <url>: 302, to <there>"
    call ax_add
    lea rsi, [new_url + U_TEXT]
    call ax_add
    lea rsi, [s_colon_sp]
    call ax_add
    mov rdi, r15
    call ax_addu
    lea rsi, [s_redirected]
    call ax_add
    mov rsi, [resp_loc]
    mov rcx, [resp_loc_len]
    call ax_addn
    call ax_flush
    inc r14d
    cmp r14d, REDIRECTS_MAX
    ja .too_many
    lea rsi, [new_url + U_FRAG]         ; its fragment, unless it says another
    lea rdi, [frag_keep]
    mov ecx, 256
    call str_copy
    mov rsi, [resp_loc]
    mov rcx, [resp_loc_len]
    lea rdx, [new_url]
    lea rdi, [link_buf]
    call url_resolve
    jc .bad_redirect
    lea rsi, [link_buf]
    lea rdi, [new_url]
    call url_parse
    jc .bad_redirect
    cmp byte [new_url + U_FRAG], 0
    jne .fetch
    lea rsi, [frag_keep]
    lea rdi, [new_url + U_FRAG]
    mov ecx, 256
    call str_copy
    jmp .fetch

.page:
    mov ebx, [scroll]                   ; EBX: where it was, for a reload
    lea rsi, [new_url]
    lea rdi, [cur_url]
    call url_copy
    mov rdi, r15
    call show_response
    call addr_from_page
    cmp r13d, GO_NEW
    jne .placed
    call hist_add
.placed:
    cmp r13d, GO_RELOAD
    jne .frag
    mov dword [scroll], -1
    mov edi, ebx
    call scroll_to
    jmp .shown
.frag:
    call scroll_frag
.shown:
    call paint_all
    jmp .out

.start:
    call show_start
    jmp .made
.bad_url:
    lea rsi, [s_why_url]
    jmp .error
.too_many:
    lea rsi, [s_why_redirects]
    jmp .error
.bad_redirect:
    lea rsi, [s_why_redirect]
    jmp .error
.failed:
    lea rsi, [fetch_why]
.error:
    call show_error
.made:
    lea rsi, [go_text]                  ; the address as it was asked for
    lea rdi, [addr_buf]
    mov ecx, ADDR_MAX
    call str_copy
    lea rax, [addr_buf]
    sub rdi, rax
    mov [addr_len], edi
    mov [addr_caret], edi
    lea rsi, [go_text]
    lea rdi, [page_text]
    mov ecx, U_TEXT_MAX + 256
    call str_copy
    cmp r13d, GO_NEW
    jne .made_placed
    call hist_add
.made_placed:
    mov dword [scroll], -1
    xor edi, edi
    call scroll_to
    call paint_all
.out:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; go_back, go_forward: a step through the history; reload: this again
go_back:
    mov eax, [hist_i]
    test eax, eax
    jz .out
    call hist_keep
    dec dword [hist_i]
    jmp hist_go
.out:
    ret

go_forward:
    mov eax, [hist_i]
    inc eax
    cmp eax, [hist_n]
    jae .out
    call hist_keep
    inc dword [hist_i]
    jmp hist_go
.out:
    ret

; hist_go: to the history's entry hist_i, scrolled as it was
hist_go:
    push rbx
    mov eax, [hist_i]
    imul eax, eax, HE_SIZE
    lea rbx, [history + rax]
    lea rsi, [rbx + HE_TEXT]
    mov edx, GO_HIST
    call go
    mov edi, [rbx + HE_SCROLL]
    call scroll_to
    call paint_toolbar
    pop rbx
    ret

reload:
    cmp dword [hist_n], 0
    je .out
    lea rsi, [page_text]
    mov edx, GO_RELOAD
    jmp go
.out:
    ret

; hist_keep: where the page shown is scrolled, kept in its entry
hist_keep:
    cmp dword [hist_n], 0
    je .out
    mov eax, [hist_i]
    imul eax, eax, HE_SIZE
    lea rcx, [history + rax]
    mov eax, [scroll]
    mov [rcx + HE_SCROLL], eax
.out:
    ret

; hist_add: page_text, a new entry after this one (those after it gone)
hist_add:
    mov eax, [hist_i]
    inc eax
    cmp dword [hist_n], 0
    jne .after
    xor eax, eax
.after:
    cmp eax, HIST_MAX
    jb .room
    lea rdi, [history]                  ; full: the oldest goes
    lea rsi, [history + HE_SIZE]
    mov ecx, (HIST_MAX - 1) * HE_SIZE
    rep movsb
    mov eax, HIST_MAX - 1
.room:
    mov [hist_i], eax
    inc eax
    mov [hist_n], eax
    dec eax
    imul eax, eax, HE_SIZE
    lea rdi, [history + rax + HE_TEXT]
    lea rsi, [page_text]
    mov ecx, U_TEXT_MAX + 256
    call str_copy
    mov eax, [hist_i]
    imul eax, eax, HE_SIZE
    lea rcx, [history + rax]
    mov dword [rcx + HE_SCROLL], 0
    ret

; addr_from_page: the address field, and page_text, cur_url with its fragment
addr_from_page:
    cmp byte [page_about], 0
    jne .about
    lea rax, [page_text]
    mov [out_ptr], rax
    add rax, U_TEXT_MAX + 255
    mov [out_end], rax
    lea rsi, [cur_url + U_TEXT]
    call put_str
    cmp byte [cur_url + U_FRAG], 0
    je .about
    lea rsi, [s_hash]
    call put_str
    lea rsi, [cur_url + U_FRAG]
    call put_str
.about:                                 ; (an about page's stays what was asked)
    lea rsi, [page_text]
    lea rdi, [addr_buf]
    mov ecx, ADDR_MAX
    call str_copy
    lea rax, [addr_buf]
    sub rdi, rax
    mov [addr_len], edi
    mov [addr_caret], edi
    ret

; -----------------------------------------------------------------------------
;  Pages
; -----------------------------------------------------------------------------

; show_response(RDI = the status): the answer fetched, as its type says,
; laid out and titled, and said on the console
show_response:
    push rbx
    push r12
    push r13
    push r14
    mov r14, rdi                        ; R14: the status
    mov r12, [resp_body]                ; R12, R13: the body
    mov r13, [resp_len]
    mov byte [page_about], 0
    xor ebx, ebx                        ; EBX: 0 HTML, 1 text, 2 another kind
    mov rsi, [resp_type]
    mov rcx, [resp_type_len]
    test rcx, rcx
    jz .typed
    lea rdi, [s_text_plain]
    call ci_find
    test rax, rax
    jnz .text
    mov rsi, [resp_type]
    mov rcx, [resp_type_len]
    lea rdi, [s_html]
    call ci_find
    test rax, rax
    jnz .typed
    mov rsi, [resp_type]
    mov rcx, [resp_type_len]
    lea rdi, [s_xml]
    call ci_find
    test rax, rax
    jnz .typed
    mov rsi, [resp_type]
    mov rcx, [resp_type_len]
    lea rdi, [s_text_sl]
    call ci_prefix_n
    je .text
    mov ebx, 2
    jmp .typed
.text:
    mov ebx, 1
.typed:
    call ar_reset
    cmp ebx, 2
    je .other
    mov edi, ebx                        ; the charset
    call charset
    mov [latin1], al
    test ebx, ebx
    jnz .plain
    mov rsi, r12
    mov rcx, r13
    call html_parse
    jmp .parsed
.plain:
    mov rsi, r12
    mov rcx, r13
    call plain_doc
    jmp .parsed
.other:                                 ; what it is, and that it is not shown
    call gen_start
    lea rsi, [s_other_1]
    call put_str
    mov rsi, [resp_type]
    mov rcx, [resp_type_len]
    call put_html
    lea rsi, [s_other_2]
    call put_str
    mov rdi, r13
    call put_u
    lea rsi, [s_other_3]
    call put_str
    call gen_parse
.parsed:
    mov [doc], rax
    test rax, rax
    jz .empty
    mov rdi, rax
    mov esi, VIEW_W
    call layout
    jmp .titled
.empty:
    mov rax, [dl_base]
    mov [dl_top], rax
    mov dword [doc_height], 0
    mov dword [lk_count], 0
    mov dword [an_count], 0
.titled:
    lea rsi, [cur_url + U_TEXT]
    call title_set
    lea rsi, [s_log]                    ; the console's line, and the status's
    call ax_add
    lea rsi, [cur_url + U_TEXT]
    call ax_add
    lea rsi, [s_colon_sp]
    call ax_add
    lea rax, [status_buf]
    mov [out_ptr], rax
    add rax, 255
    mov [out_end], rax
    mov rdi, r14
    call put_u
    lea rsi, [s_comma_sp]
    call put_str
    mov rdi, r13
    call put_u
    lea rsi, [s_bytes]
    call put_str
    mov rdi, [html_elements]
    call put_u
    lea rsi, [s_elements]
    call put_str
    mov edi, [lk_count]
    call put_u
    lea rsi, [s_links]
    call put_str
    lea rsi, [status_buf]
    call ax_add
    call ax_flush
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; show_start: the start page
show_start:
    mov byte [latin1], 0
    call ar_reset
    lea rsi, [start_page]
    mov ecx, start_page_end - start_page
    call html_parse
    lea rsi, [s_start_name]
    jmp about_shown

; show_error(RSI = why, NUL-ended): a page saying that go_text could not be
; shown, and why
show_error:
    push rbx
    mov rbx, rsi
    call gen_start
    lea rsi, [s_error_1]
    call put_str
    lea rsi, [go_text]
    mov rcx, rsi
.len:
    cmp byte [rcx], 0
    je .counted
    inc rcx
    jmp .len
.counted:
    sub rcx, rsi
    call put_html
    lea rsi, [s_error_2]
    call put_str
    mov rsi, rbx
    mov rcx, rsi
.why_len:
    cmp byte [rcx], 0
    je .why_counted
    inc rcx
    jmp .why_len
.why_counted:
    sub rcx, rsi
    call put_html
    lea rsi, [s_error_3]
    call put_str
    lea rsi, [s_log]
    call ax_add
    lea rsi, [go_text]
    call ax_add
    lea rsi, [s_colon_sp]
    call ax_add
    mov rsi, rbx
    call ax_add
    call ax_flush
    lea rsi, [status_buf]               ; the status line says it too
    mov rdi, rsi
    mov rsi, rbx
    mov ecx, 256
    call str_copy
    call gen_parse
    pop rbx
    lea rsi, [go_text]
    jmp about_shown_kept

; about_shown(RAX = the document, RSI = the status line's text): a page of
; our own laid out and titled. about_shown_kept: the status line as it is,
; RSI the title's stand-in
about_shown:
    push rsi
    push rax
    lea rdi, [status_buf]
    mov ecx, 256
    call str_copy
    pop rax
    pop rsi
about_shown_kept:
    push rsi
    mov [doc], rax
    mov byte [page_about], 1
    test rax, rax
    jz .none
    mov rdi, rax
    mov esi, VIEW_W
    call layout
.none:
    pop rsi
    jmp title_set

; gen_start: gen_buf, empty, for put_*; gen_parse -> RAX = it parsed, as UTF-8
gen_start:
    lea rax, [gen_buf]
    mov [out_ptr], rax
    add rax, GEN_MAX - 1
    mov [out_end], rax
    ret

gen_parse:
    mov byte [latin1], 0
    call ar_reset
    lea rsi, [gen_buf]
    mov rcx, [out_ptr]
    sub rcx, rsi
    jmp html_parse

; put_html(RSI = bytes, RCX = how many): onto out_ptr, with & < > " escaped
put_html:
    push rbx
    push r12
    mov rbx, rsi
    lea r12, [rsi + rcx]
.char:
    cmp rbx, r12
    jae .out
    movzx eax, byte [rbx]
    inc rbx
    lea rsi, [s_amp]
    cmp eax, '&'
    je .entity
    lea rsi, [s_lt]
    cmp eax, '<'
    je .entity
    lea rsi, [s_gt]
    cmp eax, '>'
    je .entity
    lea rsi, [s_quot]
    cmp eax, '"'
    je .entity
    lea rsi, [rbx - 1]
    mov ecx, 1
    call put_n
    jmp .char
.entity:
    call put_str
    jmp .char
.out:
    pop r12
    pop rbx
    ret

; plain_doc(RSI = text, RCX = bytes) -> RAX = a document of it in a pre
plain_doc:
    push rbx
    push r12
    push r13
    push r14
    mov r12, rsi
    mov r13, rcx
    mov byte [doc_title], 0
    mov qword [html_elements], 0
    mov edi, NT_DOC
    call new_node
    test rax, rax
    jz .out
    mov rbx, rax                        ; RBX: the document
    mov edi, NT_ELEM
    call new_node
    test rax, rax
    jz .done
    mov r14, rax                        ; R14: the pre
    mov byte [r14 + N_TAG], T_pre
    mov rdi, rbx
    mov rsi, r14
    call append
    test r13, r13
    jz .done
    mov rsi, r12
    mov rcx, r13
    xor edx, edx
    call decode
    test rax, rax
    jz .done
    push rax
    push rdx
    mov edi, NT_TEXT
    call new_node
    pop rdx
    pop rcx
    test rax, rax
    jz .done
    mov [rax + N_TEXT], rcx
    mov [rax + N_LEN], edx
    mov rdi, r14
    mov rsi, rax
    call append
.done:
    mov rax, rbx
.out:
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; charset(EDI = 1 if plain text) -> AL = 1 to take the body as Windows-1252
charset:
    push rbx
    mov ebx, edi
    mov rsi, [resp_type]                ; the Content-Type's
    mov rcx, [resp_type_len]
    test rcx, rcx
    jz .meta
    lea rdi, [s_charset]
    call ci_find
    test rax, rax
    jz .meta
    mov rcx, [resp_type]
    add rcx, [resp_type_len]
    jmp .named
.meta:
    test ebx, ebx                       ; a page's own, in its first 1024 bytes
    jnz .sniff
    mov rsi, [resp_body]
    mov rcx, [resp_len]
    cmp rcx, 1024
    jbe .head
    mov ecx, 1024
.head:
    lea rdi, [s_charset]
    call ci_find
    test rax, rax
    jz .sniff
    mov rcx, [resp_body]
    add rcx, [resp_len]
.named:                                 ; RAX: at "charset", RCX: the end
    add rax, 7
.to_value:
    cmp rax, rcx
    jae .sniff
    movzx edx, byte [rax]
    cmp edx, '='
    je .skip
    cmp edx, ' '
    je .skip
    cmp edx, '"'
    je .skip
    cmp edx, "'"
    jne .value
.skip:
    inc rax
    jmp .to_value
.value:
    mov rsi, rax
    sub rcx, rax
    lea rdi, [s_utf8]
    call ci_prefix_n
    je .utf8
    lea rdi, [s_utf8b]
    call ci_prefix_n
    je .utf8
    lea rbx, [latin_names]
.latin:
    cmp byte [rbx], 0
    je .utf8                            ; another we do not know: UTF-8
    mov rdi, rbx
    call ci_prefix_n
    je .one
.latin_next:
    inc rbx
    cmp byte [rbx - 1], 0
    jne .latin_next
    jmp .latin
.sniff:                                 ; none said: UTF-8 if it is
    mov rsi, [resp_body]
    mov rcx, [resp_len]
    call utf8_valid
    jc .one
.utf8:
    xor eax, eax
    jmp .out
.one:
    mov eax, 1
.out:
    pop rbx
    ret

; utf8_valid(RSI = bytes, RCX = how many) -> CF if they are not UTF-8
utf8_valid:
    lea rdx, [rsi + rcx]
.char:
    cmp rsi, rdx
    jae .yes
    movzx eax, byte [rsi]
    inc rsi
    cmp eax, 0x80
    jb .char
    mov ecx, 1
    cmp eax, 0xC2
    jb .no
    cmp eax, 0xE0
    jb .cont
    mov ecx, 2
    cmp eax, 0xF0
    jb .cont
    mov ecx, 3
    cmp eax, 0xF5
    jae .no
.cont:
    cmp rsi, rdx
    jae .yes                            ; cut short at the end: still UTF-8
    movzx eax, byte [rsi]
    and eax, 0xC0
    cmp eax, 0x80
    jne .no
    inc rsi
    dec ecx
    jnz .cont
    jmp .char
.yes:
    clc
    ret
.no:
    stc
    ret

; title_set(RSI = what stands in for a title): "<title> · browse"
title_set:
    push rbx
    mov rbx, rsi
    mov rdi, [ax_io_va]
    lea rsi, [doc_title]
    cmp byte [rsi], 0
    jne .collapse
    mov rsi, rbx
.collapse:                              ; its whitespace one space, TITLE_KEEP
    mov rcx, rdi                        ; bytes at most, cut between characters
    add rcx, TITLE_KEEP
    xor edx, edx                        ; EDX: a space is pending
.char:
    movzx eax, byte [rsi]
    test eax, eax
    jz .end
    inc rsi
    cmp eax, ' '
    je .space
    cmp eax, 9
    jb .keep
    cmp eax, 13
    jbe .space
.keep:
    cmp rdi, rcx
    jb .room
    and eax, 0xC0                       ; out of room: done, at a character's start
    cmp eax, 0x80
    jne .end
    movzx eax, byte [rsi - 1]
.room:
    test edx, edx
    jz .put
    xor edx, edx
    mov rbx, [ax_io_va]
    cmp rdi, rbx
    je .put
    mov byte [rdi], ' '
    inc rdi
.put:
    mov [rdi], al
    inc rdi
    jmp .char
.space:
    mov edx, 1
    jmp .char
.end:
    lea rsi, [s_title_tail]
.tail:
    lodsb
    test al, al
    jz .titled
    stosb
    jmp .tail
.titled:
    sub rdi, [ax_io_va]
    sub rsp, SQ_SIZE
    push rdi
    lea rdi, [rsp + 8]
    xor eax, eax
    mov ecx, SQ_SIZE / 8
    rep stosq
    pop rdi
    mov byte [rsp + SQ_OP], RO_WIN_TITLE
    mov eax, [win]
    mov [rsp + SQ_HANDLE], eax
    mov eax, [ax_io]
    mov [rsp + SQ_HANDLE2], eax
    mov [rsp + SQ_A1], rdi
    mov rdi, rsp
    call ax_do
    add rsp, SQ_SIZE
    pop rbx
    ret

; status_set(RDI = a NUL-ended prefix, RSI = NUL-ended): the status line,
; shown
status_set:
    lea rax, [status_buf]
    mov [out_ptr], rax
    add rax, 255
    mov [out_end], rax
    push rsi
    mov rsi, rdi
    call put_str
    pop rsi
    call put_str
    jmp paint_status

; -----------------------------------------------------------------------------
;  Drawing
; -----------------------------------------------------------------------------

; clip_set(EDI, ESI = top left, EDX, ECX = bottom right, exclusive)
clip_set:
    mov [clip_x0], edi
    mov [clip_y0], esi
    mov [clip_x1], edx
    mov [clip_y1], ecx
    ret

paint_all:
    call paint_toolbar_only
    call paint_view_only
    call paint_status_only
    xor edi, edi
    xor esi, esi
    mov edx, WIN_W
    mov ecx, WIN_H
    jmp show

paint_toolbar:
    call paint_toolbar_only
    xor edi, edi
    xor esi, esi
    mov edx, WIN_W
    mov ecx, TB_H
    jmp show

paint_view:
    call paint_view_only
    xor edi, edi
    mov esi, VIEW_Y
    mov edx, WIN_W
    mov ecx, VIEW_H
    jmp show

paint_status:
    call paint_status_only
    xor edi, edi
    mov esi, WIN_H - SB_H
    mov edx, WIN_W
    mov ecx, SB_H
    jmp show

paint_toolbar_only:
    push rbx
    push r12
    push r13
    xor edi, edi
    xor esi, esi
    mov edx, WIN_W
    mov ecx, TB_H
    call clip_set
    xor edi, edi
    xor esi, esi
    mov edx, WIN_W
    mov ecx, TB_H - 1
    mov r8d, BC_CHROME
    call fill_rect
    xor edi, edi
    mov esi, TB_H - 1
    mov edx, WIN_W
    mov ecx, 1
    mov r8d, BC_EDGE
    call fill_rect
    mov r9d, BC_FAINT                    ; the buttons
    cmp dword [hist_i], 0
    je .back
    mov r9d, BC_INK
.back:
    mov edi, BACK_X
    lea rsi, [s_back]
    call button
    mov r9d, BC_FAINT
    mov eax, [hist_i]
    inc eax
    cmp eax, [hist_n]
    jae .forward
    mov r9d, BC_INK
.forward:
    mov edi, FWD_X
    lea rsi, [s_forward]
    call button
    mov r9d, BC_INK
    mov edi, RELOAD_X
    lea rsi, [s_reload]
    call button
    mov r8d, BC_FIELD_EDGE             ; the address field: its edge,
    mov ebx, 1
    cmp byte [addr_focus], 0
    je .edge
    mov r8d, BC_FOCUS
    mov ebx, 2
.edge:
    mov edi, ADDR_X
    mov esi, ADDR_Y
    mov edx, ADDR_W
    mov ecx, ADDR_H
    call fill_rect
    mov edi, ADDR_X
    add edi, ebx
    mov esi, ADDR_Y
    add esi, ebx
    mov edx, ADDR_W
    sub edx, ebx
    sub edx, ebx
    mov ecx, ADDR_H
    sub ecx, ebx
    sub ecx, ebx
    mov r8d, BC_PAGE
    call fill_rect
    mov edi, ADDR_X + 2                 ; the text, inside it
    mov esi, ADDR_Y + 2
    mov edx, ADDR_X + ADDR_W - 2
    mov ecx, ADDR_Y + ADDR_H - 2
    call clip_set
    lea rsi, [addr_buf]                 ; R12D: where it starts, so the caret
    mov ecx, [addr_caret]               ; shows; R13D: the caret's x
    mov edx, FONT_UI
    call text_w64
    add eax, 63
    shr eax, 6
    mov r13d, eax
    mov r12d, ADDR_X + ADDR_PAD
    cmp byte [addr_focus], 0
    je .start
    mov eax, r13d
    sub eax, ADDR_W - 2 * ADDR_PAD - 4
    jle .start
    sub r12d, eax
.start:
    add r13d, r12d
    cmp byte [addr_all], 0              ; chosen: behind it, a colour
    je .text
    cmp byte [addr_focus], 0
    je .text
    cmp dword [addr_len], 0
    je .text
    lea rsi, [addr_buf]
    mov ecx, [addr_len]
    mov edx, FONT_UI
    call text_w64
    lea edx, [rax + 63]
    shr edx, 6
    mov edi, r12d
    mov esi, ADDR_Y + 7
    mov ecx, ADDR_H - 14
    mov r8d, BC_CHOSEN
    call fill_rect
.text:
    lea rsi, [addr_buf]
    mov ecx, [addr_len]
    mov edi, r12d
    mov edx, ADDR_Y + 28                ; the baseline
    mov r8d, FONT_UI
    mov r9d, BC_INK
    xor r10d, r10d
    call draw_text
    cmp byte [addr_focus], 0
    je .out
    mov edi, r13d                       ; the caret
    mov esi, ADDR_Y + 8
    mov edx, 2
    mov ecx, ADDR_H - 16
    mov r8d, BC_INK
    call fill_rect
.out:
    pop r13
    pop r12
    pop rbx
    ret

; button(EDI = x, RSI = its NUL-ended label, R9D = the label's colour)
button:
    push rbx
    push r12
    push r13
    mov ebx, edi
    mov r12, rsi
    mov r13d, r9d
    mov esi, BTN_Y
    mov edx, BTN_W
    mov ecx, BTN_H
    mov r8d, BC_BUTTON
    call fill_rect
    mov rsi, r12
    xor ecx, ecx
.len:
    cmp byte [rsi + rcx], 0
    je .counted
    inc ecx
    jmp .len
.counted:
    mov edx, FONT_UI
    push rcx
    call text_w64
    pop rcx
    add eax, 63
    shr eax, 6
    mov edi, BTN_W
    sub edi, eax
    sar edi, 1
    add edi, ebx
    mov rsi, r12
    mov edx, BTN_Y + 28
    mov r8d, FONT_UI
    mov r9d, r13d
    xor r10d, r10d
    call draw_text
    pop r13
    pop r12
    pop rbx
    ret

paint_view_only:
    push rbx
    xor edi, edi
    mov esi, VIEW_Y
    mov edx, WIN_W
    mov ecx, VIEW_Y + VIEW_H
    call clip_set
    xor edi, edi
    mov esi, VIEW_Y
    mov edx, VIEW_W
    mov ecx, VIEW_H
    mov r8d, BC_PAGE
    call fill_rect
    mov edx, VIEW_W                     ; the page, inside its part
    mov ecx, VIEW_Y + VIEW_H
    xor edi, edi
    mov esi, VIEW_Y
    call clip_set
    xor edi, edi
    mov esi, VIEW_Y
    sub esi, [scroll]
    call draw_list
    xor edi, edi                        ; the scrollbar
    mov esi, VIEW_Y
    mov edx, WIN_W
    mov ecx, VIEW_Y + VIEW_H
    call clip_set
    mov edi, VIEW_W
    mov esi, VIEW_Y
    mov edx, BAR_W
    mov ecx, VIEW_H
    mov r8d, BC_TRACK
    call fill_rect
    call thumb
    jz .out
    mov ecx, eax
    lea esi, [rdx + VIEW_Y]
    mov edi, VIEW_W + 3
    mov edx, BAR_W - 6
    mov r8d, BC_THUMB
    call fill_rect
.out:
    pop rbx
    ret

paint_status_only:
    xor edi, edi
    mov esi, WIN_H - SB_H
    mov edx, WIN_W
    mov ecx, WIN_H
    call clip_set
    xor edi, edi
    mov esi, WIN_H - SB_H
    mov edx, WIN_W
    mov ecx, 1
    mov r8d, BC_EDGE
    call fill_rect
    xor edi, edi
    mov esi, WIN_H - SB_H + 1
    mov edx, WIN_W
    mov ecx, SB_H - 1
    mov r8d, BC_CHROME
    call fill_rect
    lea rsi, [status_buf]
    xor ecx, ecx
.len:
    cmp byte [rsi + rcx], 0
    je .counted
    inc ecx
    jmp .len
.counted:
    mov edi, 10
    mov edx, WIN_H - 10
    mov r8d, FONT_STATUS
    mov r9d, BC_STATUS
    xor r10d, r10d
    jmp draw_text

; show(EDI = x, ESI = y, EDX = w, ECX = h): that part to the screen
show:
    sub rsp, SQ_SIZE
    push rdi
    push rcx
    lea rdi, [rsp + 16]
    xor eax, eax
    mov ecx, SQ_SIZE / 8
    rep stosq
    pop rcx
    pop rdi
    mov byte [rsp + SQ_OP], RO_WIN_SHOW
    mov eax, [win]
    mov [rsp + SQ_HANDLE], eax
    mov [rsp + SQ_A0], rdi
    mov [rsp + SQ_A1], rsi
    mov eax, edx                        ; w | h << 32
    shl rcx, 32
    or rax, rcx
    mov [rsp + SQ_A2], rax
    mov rdi, rsp
    call ax_do
    add rsp, SQ_SIZE
    ret

section .rodata
s_open:         db 'browse: a window 1400x1000', 10, 0
s_bye:          db 'browse: closed', 10, 0
s_no_desk:      db 'browse: no desktop to open a window on', 10, 0
s_refused:      db 'browse: refused: ', 0
s_home_url:     db 'http://localhost/', 0
s_about_start:  db 'about:start', 0
s_start_name:   db 'start page', 0
s_log:          db 'browse: ', 0
s_colon_sp:     db ': ', 0
s_comma_sp:     db ', ', 0
s_bytes:        db ' bytes, ', 0
s_elements:     db ' elements, ', 0
s_links:        db ' links', 0
s_redirected:   db ', to ', 0
s_loading:      db 'Loading ', 0
s_cannot:       db 'browse cannot open that link: ', 0
s_hash:         db '#', 0
s_title_tail:   db ' ', 0xC2, 0xB7, ' browse', 0
s_back:         db 0xE2, 0x97, 0x80, 0  ; U+25C0, U+25B6, U+21BB
s_forward:      db 0xE2, 0x96, 0xB6, 0
s_reload:       db 0xE2, 0x86, 0xBB, 0
s_why_url:      db 'That is not an address browse can open (http or https).', 0
s_why_redirects: db 'It redirected more than 8 times.', 0
s_why_redirect: db 'It redirected to an address browse cannot open.', 0
s_text_plain:   db 'text/plain', 0
s_html:         db 'html', 0
s_xml:          db 'xml', 0
s_text_sl:      db 'text/', 0
s_charset:      db 'charset', 0
s_utf8:         db 'utf-8', 0
s_utf8b:        db 'utf8', 0
latin_names:    db 'iso-8859', 0, 'iso8859', 0, 'latin', 0, 'windows-125', 0, 'cp125', 0
                db 'us-ascii', 0, 'ascii', 0, 'l1', 0, 0
s_amp:          db '&amp;', 0
s_lt:           db '&lt;', 0
s_gt:           db '&gt;', 0
s_quot:         db '&quot;', 0
s_other_1:      db '<title>A file</title><h1>Not a page</h1><p>The answer is <code>', 0
s_other_2:      db '</code>, ', 0
s_other_3:      db ' bytes of it. browse shows HTML and plain text for now.', 0
s_error_1:      db '<title>Problem loading page</title><h1>This page could not be shown</h1><p><b>', 0
s_error_2:      db '</b><p>', 0
s_error_3:      db '<p>Check the address, or try again with ctrl+R.', 0
start_page:
    db '<title>Start</title>'
    db '<h1>browse</h1>'
    db "<p>Axiom's web browser: HTML and plain text, over HTTP and HTTPS, in a window of its own. "
    db 'Type an address above (<kbd>ctrl+L</kbd>), or try one of these:'
    db '<ul><li><a href="http://example.com/">example.com</a>'
    db '<li><a href="https://en.wikipedia.org/wiki/Special:Random">a random Wikipedia article</a>'
    db '<li><a href="https://news.ycombinator.com/">Hacker News</a>'
    db '<li><a href="https://text.npr.org/">NPR, as text</a></ul>'
    db '<h3>Keys</h3><table>'
    db '<tr><td><kbd>ctrl+L</kbd><td>the address; <kbd>Enter</kbd> goes there, <kbd>Esc</kbd> leaves it'
    db '<tr><td><kbd>', 0xE2, 0x86, 0x91, ' ', 0xE2, 0x86, 0x93, '</kbd>, <kbd>space</kbd>, the wheel<td>scroll'
    db '<tr><td><kbd>Backspace</kbd><td>back'
    db '<tr><td><kbd>ctrl+R</kbd><td>reload'
    db '<tr><td><kbd>ctrl+W</kbd><td>close</table>'
    db '<p><small>B1: no CSS, images or scripts yet.</small>'
start_page_end:

section .bss
alignb 8
doc:            resq 1
win:            resd 1
ev_end:         resd 1
scroll:         resd 1
addr_len:       resd 1
addr_caret:     resd 1
hist_n:         resd 1
hist_i:         resd 1
ev:             resb WE_SIZE
addr_focus:     resb 1
addr_all:       resb 1
page_about:     resb 1
dragging:       resb 1
alignb 8
cur_url:        resb U_SIZE
new_url:        resb U_SIZE
link_buf:       resb U_TEXT_MAX
go_text:        resb U_TEXT_MAX + 256
page_text:      resb U_TEXT_MAX + 256
frag_keep:      resb 256
arg_buf:        resb ADDR_MAX
addr_buf:       resb ADDR_MAX + 1
status_buf:     resb 256
gen_buf:        resb GEN_MAX
alignb 8
history:        resb HIST_MAX * HE_SIZE

AXE_END
