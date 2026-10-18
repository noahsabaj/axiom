; =============================================================================
;  bench.asm - 'bench': what things cost, measured, as records
;
;  Each action times something many times over and gives a row for it: the
;  area, the bench, how many times, the time each took (in ns, a decimal)
;  and a rate (operations or megabytes a second). `bench` alone runs them
;  all but the slow ones; `bench boot` gives the boot's stages from the
;  marks boot.asm leaves (BOOTMARK). Everything runs on the main thread,
;  as the shell does; the drawing benches leave the screen to be composed
;  again.
; =============================================================================

BN_PINGS        equ 20000               ; handovers between two threads
BN_THREADS      equ 500                 ; threads started and joined
BN_JOBS         equ 2000                ; every CPU woken, and back
BN_ALLOCS       equ 20000               ; allocations, and frees
BN_VMS          equ 200                 ; vm mappings made and freed
BN_CAPS         equ 20000               ; handle operations
BN_RING         equ 2000                ; ring batches
BN_CHAN         equ 20000               ; channel messages
BN_FILLS        equ 20                  ; whole screens filled
BN_GLYPHS       equ 20000
BN_COLORS       equ 2000
BN_COMPOSE      equ 20                  ; whole screens composed

; boot stages: BOOTMARK n stores the TSC when stage n ended
BM_ENTRY        equ 0                   ; kernel_main's first instruction
BM_CPU          equ 1
BM_MEMORY       equ 2
BM_DISPLAY      equ 3
BM_STACKS       equ 4
BM_ACPI         equ 5
BM_SMBIOS       equ 6
BM_FIRMWARE     equ 7                   ; boot services memory reclaimed
BM_SCHED        equ 8
BM_SMP          equ 9
BM_PCI          equ 10
BM_IOMMU        equ 11
BM_USB          equ 12
BM_DISKS        equ 13
BM_CRYPTO       equ 14
BM_NET          equ 15
BM_SHELL        equ 16
BM_STORE        equ 17
BM_COUNT        equ 18

%macro BOOTMARK 1
    push rax
    push rdx
    rdtsc
    shl rdx, 32
    or rax, rdx
    mov [boot_marks + %1 * 8], rax
    pop rdx
    pop rax
%endmacro

; BN_T0: R13 = now
%macro BN_T0 0
    RDTSC64
    mov r13, rax
%endmacro

; BN_ROW 'area', 'bench', count, bytes each: a row for what took since R13.
; Clobbers caller-saved registers.
%macro BN_ROW 4
    [section .rodata]
    %%area: db %1, 0
    %%name: db %2, 0
    __SECT__
    RDTSC64
    sub rax, r13
    mov rcx, rax
    lea rdi, [%%area]
    lea rsi, [%%name]
    mov rdx, %3
    mov r8, %4
    call bn_row
%endmacro

section .text

; -----------------------------------------------------------------------------
;  bench_cols: the table's columns
; -----------------------------------------------------------------------------
bench_cols:
    COLUMN 'area', FT_TEXT
    COLUMN 'bench', FT_TEXT
    COLUMN 'count', FT_INT
    COLUMN 'each', FT_INT, 1, 'ns'
    COLUMN 'rate', FT_INT
    COLUMN 'unit', FT_TEXT
    ret

; bn_row(RDI = area, RSI = bench, RDX = count, RCX = TSC ticks, R8 = bytes
; each, 0 for operations): a row. Preserves RBX, RBP, R12-R15.
bn_row:
    push rbx
    push r12
    push r14
    push r15
    mov r12, rdi
    mov r14, rsi
    mov r15, rdx
    mov rbx, rcx
    test rbx, rbx
    jg .ticks
    mov ebx, 1                          ; none (or marks out of order): 1
.ticks:
    test r15, r15
    jnz .count
    inc r15d
.count:
    push r8
    call rec_row
    xor edi, edi
    mov rsi, r12
    call rec_set
    mov edi, 1
    mov rsi, r14
    call rec_set
    mov edi, 2
    mov rsi, r15
    call rec_set
    mov rax, rbx                        ; tenths of a ns each
    mov rcx, 10000000000
    mul rcx
    div qword [tsc_hz]
    xor edx, edx
    div r15
    mov edi, 3
    mov rsi, rax
    call rec_set
    pop r8
    test r8, r8
    jz .ops
    mov rax, r8                         ; MB/s
    mul r15
    mul qword [tsc_hz]
    div rbx
    xor edx, edx
    mov ecx, 1000000
    div rcx
    lea rsi, [str_bn_mbs]
    jmp .rate
.ops:
    mov rax, r15                        ; operations a second
    mul qword [tsc_hz]
    div rbx
    lea rsi, [str_bn_ops]
.rate:
    mov edi, 5
    call rec_set
    mov edi, 4
    mov rsi, rax
    call rec_set
    pop r15
    pop r14
    pop r12
    pop rbx
    ret

; -----------------------------------------------------------------------------
;  bench [all | boot | sched | mem | caps | gfx | fat [path]]
; -----------------------------------------------------------------------------

; bench_quick: every quick area
bench_quick:
    test edi, edi
    jnz bench_usage
    call bench_cols
    call bn_boot
    call bn_sched
    call bn_mem
    call bn_caps
    call bn_gfx
    clc
    ret

bench_usage:
    KLOG "usage: bench [boot | sched | mem | caps | gfx | fat [path] | store | mandel]"
    stc
    ret

bench_boot:
    test edi, edi
    jnz bench_usage
    call bench_cols
    call bn_boot
    clc
    ret

bench_sched:
    test edi, edi
    jnz bench_usage
    call bench_cols
    call bn_sched
    clc
    ret

bench_mem:
    test edi, edi
    jnz bench_usage
    call bench_cols
    call bn_mem
    clc
    ret

bench_caps:
    test edi, edi
    jnz bench_usage
    call bench_cols
    call bn_caps
    clc
    ret

bench_gfx:
    test edi, edi
    jnz bench_usage
    call bench_cols
    call bn_gfx
    clc
    ret

bench_fat:
    cmp edi, 1
    ja bench_usage
    lea rax, [str_bn_fat_default]
    jb .path
    mov rax, [rsi]
.path:
    push rax
    call bench_cols
    pop rdi
    call bn_fat
    ret

bench_store:
    test edi, edi
    jnz bench_usage
    cmp qword [st_disk], 0
    jne .some
    KLOG "bench store: no store ('store format' makes one on QEMU's test drive)"
    stc
    ret
.some:
    call bench_cols
    call bn_storebench
    ret

bench_mandel:
    test edi, edi
    jnz bench_usage
    call cmd_bench
    clc
    ret

; -----------------------------------------------------------------------------
;  boot: the stages, from the marks
; -----------------------------------------------------------------------------
bn_boot:
    push rbx
    push r12
    push r13
    mov rax, [boot_info]                ; the firmware, to the loader
    mov r13, 0
    mov rcx, [rax + BI_TSC_ENTRY]
    lea rdi, [str_bn_boot]
    lea rsi, [str_bn_bs_fw]
    mov edx, 1
    xor r8d, r8d
    call bn_row
    xor ebx, ebx                        ; the loader's steps
.loader:
    mov rax, [boot_info]
    lea rdx, [bn_loader_marks]
    mov ecx, [rdx + rbx * 8]            ; (later, earlier) pairs
    mov rcx, [rax + rcx]
    mov r8d, [rdx + rbx * 8 + 4]
    sub rcx, [rax + r8]
    lea rdi, [str_bn_boot]
    lea rax, [bn_loader_names]
    mov rsi, [rax + rbx * 8]
    mov edx, 1
    xor r8d, r8d
    call bn_row
    inc ebx
    cmp ebx, 4
    jb .loader
    mov rax, [boot_info]                ; ExitBootServices to the kernel
    mov rcx, [boot_marks + BM_ENTRY * 8]
    sub rcx, [rax + BI_TSC_EXIT]
    lea rdi, [str_bn_boot]
    lea rsi, [str_bn_bs_exit]
    mov edx, 1
    xor r8d, r8d
    call bn_row
    mov ebx, 1                          ; each stage of kernel_main
.stage:
    cmp ebx, BM_COUNT
    jae .total
    mov rcx, [boot_marks + rbx * 8]
    test rcx, rcx
    jz .next
    mov r12, rbx                        ; the mark before it
.before:
    dec r12
    cmp qword [boot_marks + r12 * 8], 0
    je .before
    sub rcx, [boot_marks + r12 * 8]
    lea rdi, [str_bn_boot]
    lea rax, [bn_stage_names]
    mov rsi, [rax + rbx * 8]
    mov edx, 1
    xor r8d, r8d
    call bn_row
.next:
    inc ebx
    jmp .stage
.total:
    mov ebx, BM_COUNT - 1               ; power-on to the last mark
.last:
    mov rcx, [boot_marks + rbx * 8]
    test rcx, rcx
    jnz .have
    dec ebx
    jnz .last
.have:
    lea rdi, [str_bn_boot]
    lea rsi, [str_bn_bs_total]
    mov edx, 1
    xor r8d, r8d
    call bn_row
    pop r13
    pop r12
    pop rbx
    ret

; -----------------------------------------------------------------------------
;  sched: switches, wake-ups, IPIs, threads
; -----------------------------------------------------------------------------
bn_sched:
    push rbx
    push r12
    push r13
    mov ebx, 1                          ; CPUs other than the BSP's, if any
    mov r12d, 2
    cmp dword [cpus_online], 3
    jae .cpus
    xor ebx, ebx
    mov r12d, 1
    cmp dword [cpus_online], 2
    jae .cpus
    xor r12d, r12d
.cpus:
    mov edi, ebx                        ; two threads on one CPU
    mov esi, ebx
    call bn_pingpong
    mov rcx, rax
    lea rdi, [str_bn_sched]
    lea rsi, [str_bn_switch]
    mov edx, BN_PINGS * 2
    xor r8d, r8d
    call bn_row
    mov edi, ebx                        ; on two CPUs
    mov esi, r12d
    call bn_pingpong
    mov rcx, rax
    lea rdi, [str_bn_sched]
    lea rsi, [str_bn_wake]
    mov edx, BN_PINGS * 2
    xor r8d, r8d
    call bn_row
    BN_T0                               ; a yield with nothing else to run
    mov ebx, BN_ALLOCS
.yield:
    call thread_yield
    dec ebx
    jnz .yield
    BN_ROW 'sched', 'yield alone', BN_ALLOCS, 0
    BN_T0                               ; every CPU woken by an IPI, and back
    mov ebx, BN_JOBS
.job:
    lea rdi, [bn_nothing]
    xor esi, esi
    call job_run_each
    dec ebx
    jnz .job
    BN_ROW 'sched', 'job on every cpu', BN_JOBS, 0
    BN_T0                               ; a thread started and joined
    mov ebx, BN_THREADS
.thread:
    lea rdi, [bn_nothing]
    xor esi, esi
    lea rdx, [str_bn_thread]
    call thread_new
    test rax, rax
    jz .threads_done
    mov r12, rax
    mov rdi, rax
    call thread_start
    mov rdi, r12
    call thread_join
    dec ebx
    jnz .thread
.threads_done:
    BN_ROW 'sched', 'thread start+join', BN_THREADS, 0
    pop r13
    pop r12
    pop rbx
    ret

bn_nothing:
    xor eax, eax
    ret

; bn_pingpong(EDI = A's CPU, ESI = B's CPU) -> RAX = TSC ticks for
; BN_PINGS * 2 handovers between A and B, pinned there
bn_pingpong:
    push rbx
    push r12
    push r13
    mov r12d, edi
    mov r13d, esi
    mov dword [bp_turn], 0
    lea rdi, [bn_pong]
    mov esi, BN_PINGS
    lea rdx, [str_bn_pong]
    call thread_new
    test rax, rax
    jz .oom
    mov [bp_b], rax
    mov [rax + TH_PIN], r13
    lea rdi, [bn_ping]
    mov esi, BN_PINGS
    lea rdx, [str_bn_ping]
    call thread_new
    test rax, rax
    jz .oom
    mov [bp_a], rax
    mov [rax + TH_PIN], r12
    RDTSC64
    mov rbx, rax
    mov rdi, [bp_b]
    call thread_start
    mov rdi, [bp_a]
    call thread_start
    mov rdi, [bp_a]
    call thread_join
    mov rdi, [bp_b]
    call thread_join
    RDTSC64
    sub rax, rbx
    jmp .out
.oom:
    xor eax, eax
.out:
    pop r13
    pop r12
    pop rbx
    ret

bn_ping:                                ; RDI = rounds
    push rbx
    mov rbx, rdi
.round:
    mov dword [bp_turn], 1
    mov rdi, [bp_b]
    call thread_unpark
.wait:
    cmp dword [bp_turn], 0
    je .next
    call thread_park
    jmp .wait
.next:
    dec rbx
    jnz .round
    xor eax, eax
    pop rbx
    ret

bn_pong:
    push rbx
    mov rbx, rdi
.wait:
    cmp dword [bp_turn], 1
    je .turn
    call thread_park
    jmp .wait
.turn:
    mov dword [bp_turn], 0
    mov rdi, [bp_a]
    call thread_unpark
    dec rbx
    jnz .wait
    xor eax, eax
    pop rbx
    ret

; -----------------------------------------------------------------------------
;  mem: the heap, pages, the vm region
; -----------------------------------------------------------------------------
bn_mem:
    push rbx
    push r12
    push r13
    BN_T0
    mov ebx, BN_ALLOCS
.small:
    mov edi, 64
    call kmalloc
    mov rdi, rax
    call kfree
    dec ebx
    jnz .small
    BN_ROW 'mem', 'kmalloc+kfree 64', BN_ALLOCS, 0
    BN_T0
    mov ebx, BN_ALLOCS
.kib:
    mov edi, 1024
    call kmalloc
    mov rdi, rax
    call kfree
    dec ebx
    jnz .kib
    BN_ROW 'mem', 'kmalloc+kfree 1K', BN_ALLOCS, 0
    BN_T0
    mov ebx, BN_VMS
.large:
    mov edi, 16384
    call kmalloc
    mov rdi, rax
    call kfree
    dec ebx
    jnz .large
    BN_ROW 'mem', 'kmalloc+kfree 16K', BN_VMS, 0
    BN_T0
    mov ebx, BN_ALLOCS
.page:
    mov edi, 1
    call pmm_alloc
    mov rdi, rax
    mov esi, 1
    call pmm_free
    dec ebx
    jnz .page
    BN_ROW 'mem', 'pmm page', BN_ALLOCS, 0
    BN_T0
    mov ebx, BN_VMS
.vm:
    mov edi, 65536
    call vm_alloc
    mov rdi, rax
    call vm_free
    dec ebx
    jnz .vm
    BN_ROW 'mem', 'vm_alloc+free 64K', BN_VMS, 0
    pop r13
    pop r12
    pop rbx
    ret

; -----------------------------------------------------------------------------
;  caps: handles, rings and channels, from the kernel's task
; -----------------------------------------------------------------------------
bn_caps:
    push rbx
    push r12
    push r13
    push r14
    push r15
    lea rdi, [str_bn_thread]            ; an event signalled by handle
    call h_event_new
    cmp rax, E_ANY
    jae .no_event
    mov r12, rax
    BN_T0
    mov ebx, BN_CAPS
.signal:
    mov edi, r12d
    call h_event_signal
    dec ebx
    jnz .signal
    BN_ROW 'caps', 'event signal', BN_CAPS, 0
    BN_T0
    mov ebx, BN_CAPS
.dup:
    mov edi, r12d
    mov esi, RT_ALL
    xor edx, edx
    call handle_dup
    mov edi, eax
    call handle_close
    dec ebx
    jnz .dup
    BN_ROW 'caps', 'handle dup+close', BN_CAPS, 0
    mov edi, r12d
    call handle_close
.no_event:
    lea r15, [bn_ring]                  ; a ring: nops, 32 at a time
    mov edi, 32
    call rc_open
    test rax, rax
    jnz .no_ring
    SQE RO_NOP, 0, 0
    BN_T0
    mov r12d, BN_RING
.batch:
    mov ebx, 32
.nops:
    call rc_push
    dec ebx
    jnz .nops
    mov esi, 32
    mov edx, 32
    xor ecx, ecx
    call rc_enter
    call rt_drain
    dec r12d
    jnz .batch
    BN_ROW 'caps', 'ring nop (32 a call)', BN_RING * 32, 0
    BN_T0
    mov r12d, BN_RING * 4
.one:
    call rc_push
    mov esi, 1
    mov edx, 1
    xor ecx, ecx
    call rc_enter
    call rt_drain
    dec r12d
    jnz .one
    BN_ROW 'caps', 'ring nop (1 a call)', BN_RING * 4, 0
    call rc_close
.no_ring:
    call h_channel_new                  ; a channel: 64 bytes there and back
    cmp rax, E_ANY
    jae .no_chan
    mov r12, rax
    mov r14, rdx
    mov edi, 4096
    lea rsi, [str_bn_thread]
    call h_mem_new
    cmp rax, E_ANY
    jae .no_mem
    mov r15, rax
    BN_T0
    mov ebx, BN_CHAN
.message:
    mov edi, r12d
    mov esi, r15d
    xor edx, edx
    mov ecx, 64
    call h_ch_send
    mov edi, r14d
    mov esi, r15d
    xor edx, edx
    mov ecx, 64
    call h_ch_recv
    dec ebx
    jnz .message
    BN_ROW 'caps', 'channel send+recv 64', BN_CHAN, 64
    mov edi, r15d
    call handle_close
.no_mem:
    mov edi, r12d
    call handle_close
    mov edi, r14d
    call handle_close
.no_chan:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; -----------------------------------------------------------------------------
;  gfx: fills, blits, glyphs, composing, a terminal drawn
; -----------------------------------------------------------------------------
bn_gfx:
    cmp byte [gfx_ready], 0
    jne .ready
    ret
.ready:
    push rbx
    push r12
    push r13
    push r14
    call gfx_target_back
    call bn_gfx_check
    BN_T0                               ; the whole back buffer filled
    mov ebx, BN_FILLS
.fill:
    xor edi, edi
    xor esi, esi
    mov rdx, [scr_w]
    mov rcx, [scr_h]
    mov r8d, ebx
    imul r8d, r8d, 0x010203
    call gfx_fill
    dec ebx
    jnz .fill
    mov rax, [scr_w]
    imul rax, [scr_h]
    shl rax, 2
    mov r14, rax                        ; R14 = a screen's bytes
    BN_ROW 'gfx', 'fill screen', BN_FILLS, r14
    BN_T0                               ; a cell's worth, filled
    mov ebx, BN_GLYPHS
.cell:
    mov edi, ebx
    and edi, 127
    imul edi, edi, 15
    mov esi, ebx
    shr esi, 7
    and esi, 31
    imul esi, esi, 30
    mov rdx, [font_cw]
    mov rcx, [font_ch]
    mov r8d, 0x203040
    call gfx_fill
    dec ebx
    jnz .cell
    mov rax, [font_cw]
    imul rax, [font_ch]
    shl rax, 2
    mov r12, rax
    BN_ROW 'gfx', 'fill cell', BN_GLYPHS, r12
    BN_T0                               ; the back buffer to the screen
    mov ebx, BN_FILLS
.blit:
    call gfx_blit_all
    dec ebx
    jnz .blit
    BN_ROW 'gfx', 'blit screen', BN_FILLS, r14
    mov edi, 0xE0E0E0                   ; glyphs on a background
    mov esi, 0x202020
    call gfx_color
    BN_T0
    mov ebx, BN_GLYPHS
.opaque:
    mov edi, ebx
    and edi, 127
    imul rdi, [font_cw]
    mov esi, ebx
    shr esi, 7
    and esi, 31
    imul rsi, [font_ch]
    mov edx, ebx
    and edx, 63
    add edx, 33
    call gfx_glyph
    dec ebx
    jnz .opaque
    BN_ROW 'gfx', 'glyph opaque', BN_GLYPHS, r12
    mov edi, 0xFFC040                   ; glyphs over what is there
    mov esi, GFX_CLEAR
    call gfx_color
    BN_T0
    mov ebx, BN_GLYPHS
.blend:
    mov edi, ebx
    and edi, 127
    imul rdi, [font_cw]
    mov esi, ebx
    shr esi, 7
    and esi, 31
    imul rsi, [font_ch]
    mov edx, ebx
    and edx, 63
    add edx, 33
    call gfx_glyph
    dec ebx
    jnz .blend
    BN_ROW 'gfx', 'glyph blended', BN_GLYPHS, r12
    BN_T0                               ; the text colours changed
    mov ebx, BN_COLORS
.color:
    mov edi, ebx
    and edi, 1
    imul edi, edi, 0x405060
    add edi, 0x808080
    mov esi, 0x202020
    call gfx_color
    dec ebx
    jnz .color
    BN_ROW 'gfx', 'text colour change', BN_COLORS, 0
    BN_T0                               ; the whole desktop composed and shown
    mov ebx, BN_COMPOSE
.compose:
    xor edi, edi
    xor esi, esi
    mov rdx, [scr_w]
    mov rcx, [scr_h]
    call desk_compose
    dec ebx
    jnz .compose
    BN_ROW 'gfx', 'compose screen', BN_COMPOSE, r14
    call con_target                     ; this shell, drawn whole
    test rax, rax
    jz .no_term
    mov r12, rax
    BN_T0
    mov ebx, BN_COMPOSE
.term:
    mov qword [r12 + TW_SHOWN], -1
    mov rdi, r12
    call term_draw
    dec ebx
    jnz .term
    BN_ROW 'gfx', 'terminal redraw', BN_COMPOSE, 0
.no_term:
    call gfx_target_back
    xor edi, edi                        ; all of it shown again as it was
    xor esi, esi
    mov rdx, [scr_w]
    mov rcx, [scr_h]
    call desk_damage
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; -----------------------------------------------------------------------------
;  fat: a file read whole from the current volume, three times
; -----------------------------------------------------------------------------
bn_fat:                                 ; RDI = path -> CF
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov r12, rdi
    call fat_vol
    jc .out
    mov edi, BN_FAT_MAX
    call vm_alloc
    test rax, rax
    jz .oom
    mov r15, rax
    mov ebx, 3
.read:
    mov rax, [disk_ops]
    mov [bn_ops0], rax
    BN_T0
    mov rsi, r12
    mov rdi, r15
    mov ecx, BN_FAT_MAX
    call fat_read_file
    jc .failed
    mov r8, rax
    RDTSC64
    sub rax, r13
    push rax
    push r8
    mov rcx, rax
    lea rdi, [str_bn_fat]
    lea rsi, [str_bn_fat_read]
    mov edx, 1
    call bn_row
    pop r8                              ; and each read asked of the driver
    pop rcx
    mov rax, r8
    mov rdx, [disk_ops]
    sub rdx, [bn_ops0]
    xor r8d, r8d
    test rdx, rdx
    jz .counted
    push rdx
    xor edx, edx
    div qword [rsp]
    mov r8, rax                         ; bytes each
    pop rdx
.counted:
    lea rdi, [str_bn_fat]
    lea rsi, [str_bn_fat_ops]
    call bn_row
    dec ebx
    jnz .read
    mov rdi, r15
    call vm_free
    clc
    jmp .out
.failed:
    mov rdi, r15
    call vm_free
    stc
    jmp .out
.oom:
    KLOG "bench: out of memory"
    stc
.out:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

BN_FAT_MAX      equ 16 * 1024 * 1024

; -----------------------------------------------------------------------------
;  store: commits (each to the drive, flushed) and reads, under bench/
; -----------------------------------------------------------------------------
BN_COMMITS      equ 100
BN_GETS         equ 2000
BN_BIG          equ 64 * 1024
BN_BIGS         equ 20

bn_storebench:                               ; -> CF (said why)
    push rbx
    push r12
    push r13
    BN_T0                               ; a small change, committed
    mov ebx, BN_COMMITS
.small:
    mov edi, 64
    mov esi, ebx
    call bn_st_commit
    jc .out
    dec ebx
    jnz .small
    BN_ROW 'store', 'put 64 B + commit', BN_COMMITS, 64
    BN_T0                               ; read back
    mov ebx, BN_GETS
.get:
    xor edi, edi
    lea rsi, [str_bn_st_name]
    call store_get
    cmp rax, -4096                      ; E_* (a pointer is negative too)
    jae .refused
    mov rdi, rax
    call st_free
    dec ebx
    jnz .get
    BN_ROW 'store', 'get 64 B', BN_GETS, 64
    BN_T0                               ; a big change, committed
    mov ebx, BN_BIGS
.big:
    mov edi, BN_BIG
    mov esi, ebx
    call bn_st_commit
    jc .out
    dec ebx
    jnz .big
    BN_ROW 'store', 'put 64 KiB + commit', BN_BIGS, BN_BIG
    BN_T0                               ; the drive's flush alone (a commit
    mov ebx, BN_BIGS                    ; waits for two)
.flush:
    call st_flush
    dec ebx
    jnz .flush
    BN_ROW 'store', 'drive flush', BN_BIGS, 0
    xor edi, edi                        ; and gone again
    lea rsi, [str_bn_st_name]
    call store_del
    xor edi, edi
    lea rsi, [str_bn_st_why]
    mov ecx, RT_ALL
    call store_commit
    clc
    jmp .out
.refused:
    KLOG "bench store: refused (%d)", rax
    stc
.out:
    pop r13
    pop r12
    pop rbx
    ret

; bn_st_commit(EDI = bytes, ESI = what they start with) -> CF (said why):
; bench/value set to them, committed
bn_st_commit:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    mov ebx, edi
    call kmalloc                        ; (the store owns it once put)
    test rax, rax
    jz .nomem
    mov [rax], esi
    xor edi, edi
    lea rsi, [str_bn_st_name]
    mov rdx, rax
    mov ecx, ebx
    call store_put
    test rax, rax
    jnz .refused
    xor edi, edi
    lea rsi, [str_bn_st_why]
    mov ecx, RT_ALL
    call store_commit
    test rax, rax
    js .refused
    clc
    jmp .out
.nomem:
    mov rax, E_NOMEM
.refused:
    KLOG "bench store: refused (%d)", rax
    stc
.out:
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; bn_gfx_check: gfx_glyph 8 pixels at a time against one at a time: every
; character, opaque and blended over another glyph, whole and clipped on
; the right, in a few colours; said whether any pixel differs.
bn_gfx_check:
    cmp byte [gfx_avx2], 0
    jne .check
    ret
.check:
    push rbx
    push rbp
    push r12
    push r13
    push r14
    push r15
    mov rdi, [font_cw]
    imul rdi, [font_ch]
    shl rdi, 3                          ; two cells
    call kmalloc
    test rax, rax
    jz .out
    mov r15, rax                        ; R15 = the cell drawn each way
    xor ebp, ebp                        ; RBP = pixels that differ
    xor r12d, r12d                      ; R12 = the case
.case:
    mov ebx, 32                         ; EBX = the character
.char:
    xor r14d, r14d                      ; R14 = 0: 8 at a time, 1: one by one
.way:
    mov byte [gfx_avx2], 0              ; under it, another glyph
    mov edi, 0x80C0FF
    mov esi, 0x402010
    call gfx_color
    call .where
    lea edx, [ebx + 5]
    call gfx_glyph
    xor eax, eax
    test r14d, r14d
    sete al
    mov [gfx_avx2], al
    mov eax, r12d                       ; the colours: case >> 3
    shr eax, 3
    lea rcx, [bn_check_colours]
    mov edi, [rcx + rax * 8]
    mov esi, [rcx + rax * 8 + 4]
    test r12d, 4
    jz .opaque
    mov esi, GFX_CLEAR
.opaque:
    call gfx_color
    call .where
    mov edx, ebx
    call gfx_glyph
    mov rax, [font_cw]                  ; kept: R13 columns of each row
    imul rax, [font_ch]
    shl rax, 2
    imul rax, r14
    lea rdi, [r15 + rax]
    xor esi, esi                        ; (y = 0)
    mov rax, [scr_w]
    sub rax, [font_cw]
    add rax, r10
    shl rax, 2
    add rsi, rax
    add rsi, [bb_ptr]
    mov rdx, [font_ch]
.copy:
    push rsi
    mov rcx, r13
    rep movsd
    pop rsi
    add rsi, [scr_pitch]
    dec rdx
    jnz .copy
    inc r14d
    cmp r14d, 2
    jb .way
    mov rcx, r13                        ; the two compared
    imul rcx, [font_ch]
    mov rsi, r15
    mov rdi, [font_cw]
    imul rdi, [font_ch]
    lea rdi, [r15 + rdi * 4]
.compare:
    mov eax, [rsi]
    cmp eax, [rdi]
    je .same
    inc rbp
.same:
    add rsi, 4
    add rdi, 4
    dec rcx
    jnz .compare
    inc ebx
    cmp ebx, 256
    jb .char
    inc r12d
    cmp r12d, BN_CHECK_COLOURS * 8
    jb .case
    mov byte [gfx_avx2], 1
    mov rdi, r15
    call kfree
    test rbp, rbp
    jnz .differ
    KLOG "bench: glyphs 8 pixels at a time are the same as one at a time"
    jmp .out
.differ:
    KLOG "bench: glyphs 8 pixels at a time differ from one at a time in %u pixels", rbp
.out:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret
; .where -> RDI = x, RSI = 0 for the case's clip (0, 3, 7 or 0 columns off
; the right edge), R10 = those columns, R13 = the columns left
.where:
    mov eax, r12d
    and eax, 3
    lea rcx, [bn_check_clips]
    movzx r10d, byte [rcx + rax]
    mov r13, [font_cw]
    sub r13, r10
    mov rdi, [scr_w]
    sub rdi, [font_cw]
    add rdi, r10
    xor esi, esi
    ret

section .rodata
bn_check_clips: db 0, 3, 7, 1
BN_CHECK_COLOURS equ 4
align 8
bn_check_colours: dd 0xE0E0E0, 0x202020, 0xFF00FF, 0x00FF00, 0x123456, 0xFEDCBA
                dd 0xFFFFFF, 0x000000
str_bn_mbs:     db 'MB/s', 0
str_bn_ops:     db 'op/s', 0
str_bn_boot:    db 'boot', 0
str_bn_sched:   db 'sched', 0
str_bn_fat:     db 'fat', 0
str_bn_st_name: db 'bench/value', 0
str_bn_st_why:  db 'bench store', 0
str_bn_fat_read: db 'read file', 0
str_bn_fat_ops: db 'disk reads in it', 0
str_bn_fat_default: db '/EFI/AXIOM/BROWSE.AXE', 0
str_bn_switch:  db 'switch (one cpu)', 0
str_bn_wake:    db 'wake-up (two cpus)', 0
str_bn_thread:  db 'bench', 0
str_bn_ping:    db 'bench ping', 0
str_bn_pong:    db 'bench pong', 0
str_bn_bs_fw:   db 'firmware', 0
str_bn_bs_ldisp: db 'loader: display mode', 0
str_bn_bs_lcalib: db 'loader: volume, tsc', 0
str_bn_bs_lkernel: db 'loader: kernel, tables', 0
str_bn_bs_lexit: db 'loader: exit boot services', 0
str_bn_bs_exit: db 'exit to kernel', 0
str_bn_bs_total: db 'power-on to prompt', 0
str_bn_bs_cpu:  db 'serial, cpu, log', 0
str_bn_bs_mem:  db 'memory', 0
str_bn_bs_disp: db 'display', 0
str_bn_bs_stacks: db 'first frame, stacks', 0
str_bn_bs_acpi: db 'acpi', 0
str_bn_bs_smbios: db 'smbios', 0
str_bn_bs_reclaim: db 'boot memory reclaimed', 0
str_bn_bs_sched: db 'apic, scheduler', 0
str_bn_bs_smp:  db 'other cpus', 0
str_bn_bs_pci:  db 'pci', 0
str_bn_bs_iommu: db 'iommu', 0
str_bn_bs_usb:  db 'keyboard, usb', 0
str_bn_bs_disks: db 'disks', 0
str_bn_bs_crypto: db 'crypto self-test', 0
str_bn_bs_net:  db 'network', 0
str_bn_bs_shell: db 'demo, shell', 0
str_bn_bs_store: db 'store', 0
align 8
bn_loader_names: dq str_bn_bs_ldisp, str_bn_bs_lcalib, str_bn_bs_lkernel, str_bn_bs_lexit
bn_loader_marks: dd BI_TSC_DISPLAY, BI_TSC_ENTRY, BI_TSC_CALIB, BI_TSC_DISPLAY
                dd BI_TSC_TABLES, BI_TSC_CALIB, BI_TSC_EXIT, BI_TSC_TABLES
bn_stage_names: dq 0, str_bn_bs_cpu, str_bn_bs_mem, str_bn_bs_disp
                dq str_bn_bs_stacks, str_bn_bs_acpi, str_bn_bs_smbios
                dq str_bn_bs_reclaim, str_bn_bs_sched, str_bn_bs_smp
                dq str_bn_bs_pci, str_bn_bs_iommu, str_bn_bs_usb
                dq str_bn_bs_disks, str_bn_bs_crypto, str_bn_bs_net
                dq str_bn_bs_shell, str_bn_bs_store

section .bss
alignb 8
boot_marks:     resq BM_COUNT
bp_a:           resq 1
bp_b:           resq 1
bp_turn:        resd 1
alignb 8
bn_ops0:        resq 1
alignb 8
bn_ring:        resb RC_SIZE

section .data
align 8
bench_actions:
    ACTION  '',       bench_quick,  '', 'what things cost: boot, sched, mem, caps and gfx'
    ACTION  'boot',   bench_boot,   '', 'how long each stage of the boot took'
    ACTION  'sched',  bench_sched,  '', 'switches, wake-ups, a job on every CPU, threads started'
    ACTION  'mem',    bench_mem,    '', 'the heap, pages, the vm region'
    ACTION  'caps',   bench_caps,   '', 'handles, rings and channels'
    ACTION  'gfx',    bench_gfx,    '', 'fills, blits, glyphs, composing, a terminal drawn'
    ACTION  'fat',    bench_fat,    '[path]', 'a file read whole from the current volume, three times'
    ACTION  'store',  bench_store,  '', "commits and reads in the store (QEMU's test drive)"
    ACTION  'mandel', bench_mandel, '', 'one core against all of them, on the Mandelbrot', 0
    dq 0, 0, 0, 0, 0
