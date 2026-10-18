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
BM_FIRMWARE     equ 4
BM_SCHED        equ 5
BM_SMP          equ 6
BM_PCI          equ 7
BM_USB          equ 8
BM_DISKS        equ 9
BM_CRYPTO       equ 10
BM_NET          equ 11
BM_SHELL        equ 12
BM_STORE        equ 13
BM_COUNT        equ 14

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
    jnz .ticks
    inc ebx
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
    KLOG "usage: bench [boot | sched | mem | caps | gfx | fat [path] | mandel]"
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
    mov rax, [boot_info]                ; the loader
    mov rcx, [rax + BI_TSC_EXIT]
    sub rcx, [rax + BI_TSC_ENTRY]
    lea rdi, [str_bn_boot]
    lea rsi, [str_bn_bs_loader]
    mov edx, 1
    xor r8d, r8d
    call bn_row
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
    BN_T0
    mov rsi, r12
    mov rdi, r15
    mov ecx, BN_FAT_MAX
    call fat_read_file
    jc .failed
    mov r8, rax
    RDTSC64
    sub rax, r13
    mov rcx, rax
    lea rdi, [str_bn_fat]
    lea rsi, [str_bn_fat_read]
    mov edx, 1
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

section .rodata
str_bn_mbs:     db 'MB/s', 0
str_bn_ops:     db 'op/s', 0
str_bn_boot:    db 'boot', 0
str_bn_sched:   db 'sched', 0
str_bn_fat:     db 'fat', 0
str_bn_fat_read: db 'read file', 0
str_bn_fat_default: db '/EFI/AXIOM/BROWSE.AXE', 0
str_bn_switch:  db 'switch (one cpu)', 0
str_bn_wake:    db 'wake-up (two cpus)', 0
str_bn_thread:  db 'bench', 0
str_bn_ping:    db 'bench ping', 0
str_bn_pong:    db 'bench pong', 0
str_bn_bs_fw:   db 'firmware', 0
str_bn_bs_loader: db 'loader', 0
str_bn_bs_exit: db 'exit to kernel', 0
str_bn_bs_total: db 'power-on to prompt', 0
str_bn_bs_cpu:  db 'serial, cpu, log', 0
str_bn_bs_mem:  db 'memory', 0
str_bn_bs_disp: db 'display', 0
str_bn_bs_acpi: db 'acpi, smbios', 0
str_bn_bs_sched: db 'apic, scheduler', 0
str_bn_bs_smp:  db 'other cpus', 0
str_bn_bs_pci:  db 'pci, iommu', 0
str_bn_bs_usb:  db 'keyboard, usb', 0
str_bn_bs_disks: db 'disks', 0
str_bn_bs_crypto: db 'crypto self-test', 0
str_bn_bs_net:  db 'network', 0
str_bn_bs_shell: db 'demo, shell', 0
str_bn_bs_store: db 'store', 0
align 8
bn_stage_names: dq 0, str_bn_bs_cpu, str_bn_bs_mem, str_bn_bs_disp
                dq str_bn_bs_acpi, str_bn_bs_sched, str_bn_bs_smp
                dq str_bn_bs_pci, str_bn_bs_usb, str_bn_bs_disks
                dq str_bn_bs_crypto, str_bn_bs_net, str_bn_bs_shell
                dq str_bn_bs_store

section .bss
alignb 8
boot_marks:     resq BM_COUNT
bp_a:           resq 1
bp_b:           resq 1
bp_turn:        resd 1
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
    ACTION  'mandel', bench_mandel, '', 'one core against all of them, on the Mandelbrot', 0
    dq 0, 0, 0, 0, 0
