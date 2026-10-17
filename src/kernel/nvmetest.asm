; =============================================================================
;  nvmetest.asm - 'nvme': each controller and its queues. 'nvme test': a
;  thread on every CPU reading at random at once, each read checked against
;  one read of the first MiB made before; then, on QEMU's drive (serial
;  AXIOMTEST) and no other, each thread writing a region of its own, reading
;  it back and flushing; then a read through the disk layer into a buffer
;  at an odd address.
; =============================================================================

NT_REF          equ 1024 * 1024         ; bytes read first, to check the rest against
NT_READS        equ 200                 ; reads per thread
NT_WBYTES       equ 128 * 1024          ; bytes each thread writes
NT_WORKERS      equ 32
NT_MAGIC        equ 0x5354414D50000000  ; block b of a stamped drive starts with NT_MAGIC | b
NT_WMAGIC       equ 0x5752495445000000  ; a written qword at byte P is NT_WMAGIC ^ P
NT_LAYER        equ 300                 ; blocks read through the disk layer
NT_LAYER_AT     equ 7                   ; from this block

; a thread of the test
NW_TH           equ 0
NW_INDEX        equ 8                   ; and its CPU
NW_READS        equ 16
NW_BYTES        equ 24
NW_BAD          equ 32                  ; reads not as the first read said
NW_FAILED       equ 40                  ; commands that failed
NW_WRITTEN      equ 48                  ; bytes written and read back
NW_WBAD         equ 56                  ; qwords read back wrong
NW_SIZE         equ 64

section .text

cmd_nvme:
    mov rsi, [sh_args]
    cmp byte [rsi], 0
    je nvme_list
    call arg_split
    lea rdi, [str_ob_test]
    call streq
    test eax, eax
    jnz nvme_test
    KLOG "usage: nvme [test]"
    ret

; -----------------------------------------------------------------------------
;  nvme: each controller, then each of its queues
; -----------------------------------------------------------------------------
nvme_list:
    push rbx
    push r12
    push r13
    push r15
    cmp dword [nvme_count], 0
    jne .some
    KLOG "nvme: no controllers"
    jmp .out
.some:
    lea r15, [nvme_ctrl]
    xor r12d, r12d
.ctrl:
    cmp r12d, [nvme_count]
    jae .out
    lea rax, [r15 + NV_MODEL]
    lea rcx, [r15 + NV_SERIAL]
    mov edx, [r15 + NV_NQ]
    lea rsi, [str_nv_polled]
    cmp dword [r15 + NV_MSIX], 0
    je .say
    lea rsi, [str_nv_msix]
.say:
    mov edi, [r15 + NV_MAXXFER]
    shr edi, 10
    KLOG "nvme%u: %s, serial %s; %u I/O queues, %s; %u KiB a command", r12, rax, rcx, rdx, rsi, rdi
    KLOG "  queue  CPU  entries  out  commands  interrupts  polls  errors"
    xor r13d, r13d
.queue:
    cmp r13d, [r15 + NV_NQ]
    jae .next
    mov rbx, [r15 + r13 * 8 + NV_QUEUES]
    mov eax, [rbx + NQ_ID]
    movsxd rcx, dword [rbx + NQ_CPU]
    mov edx, [rbx + NQ_ENTRIES]
    mov esi, [rbx + NQ_BUSY]
    KLOG "  %5u  %3d  %7u  %3u  %8u  %10u  %5u  %6u", rax, rcx, rdx, rsi, qword [rbx + NQ_COMPLETED], qword [rbx + NQ_IRQS], qword [rbx + NQ_POLLS], qword [rbx + NQ_ERRORS]
    inc r13d
    jmp .queue
.next:
    add r15, NV_SIZE
    inc r12d
    jmp .ctrl
.out:
    pop r15
    pop r13
    pop r12
    pop rbx
    ret

; -----------------------------------------------------------------------------
;  nvme test, on the first controller
; -----------------------------------------------------------------------------
nvme_test:
    push rbx
    push rbp
    push r12
    push r13
    push r14
    push r15
    mov byte [nt_fails], 0
    mov qword [nt_ref], 0
    cmp dword [nvme_count], 0
    jne .have
    KLOG "nvme test: no NVMe controller"
    call nt_fail
    jmp .verdict
.have:
    lea r15, [nvme_ctrl]
    mov [nt_ctrl], r15
    mov eax, [cpus_online]
    cmp eax, NT_WORKERS
    jbe .count
    mov eax, NT_WORKERS
.count:
    mov [nt_count], eax
    mov ecx, [r15 + NV_NQ]
    lea rdx, [str_nv_polled]
    cmp dword [r15 + NV_MSIX], 0
    je .say
    lea rdx, [str_nv_msix]
.say:
    lea rsi, [r15 + NV_MODEL]
    KLOG "nvme test: %s, %u I/O queues, %s; %u CPUs", rsi, rcx, rdx, qword [cpus_online]

    mov ecx, [r15 + NV_SHIFT]           ; the first MiB, read once
    mov eax, NT_REF
    shr eax, cl
    cmp rax, [r15 + NV_BLOCKS]
    jbe .refsize
    mov rax, [r15 + NV_BLOCKS]
.refsize:
    mov [nt_ref_blocks], rax
    mov edi, NT_REF
    call vm_alloc
    test rax, rax
    jz .oom
    mov [nt_ref], rax
    mov rdi, rax
    xor esi, esi
    mov rdx, [nt_ref_blocks]
    call nt_read
    jnc .stamps
    KLOG "nvme test: the first read failed"
    call nt_fail
    jmp .free
.stamps:
    mov rsi, [nt_ref]
    mov rax, NT_MAGIC
    cmp [rsi], rax
    je .stamped
    KLOG "nvme test: the first MiB is not stamped; reads are checked against one read of it"
    jmp .writes
.stamped:
    xor edx, edx                        ; block
    xor r8d, r8d                        ; wrong
    mov ecx, [r15 + NV_SHIFT]
.stamp:
    cmp rdx, [nt_ref_blocks]
    jae .counted
    mov rdi, rdx
    shl rdi, cl
    mov rax, NT_MAGIC
    or rax, rdx
    cmp [rsi + rdi], rax
    je .right
    inc r8
.right:
    inc rdx
    jmp .stamp
.counted:
    KLOG "nvme test: %u blocks stamped, %u of them wrongly", rdx, r8
    test r8, r8
    jz .writes
    call nt_fail

.writes:
    mov byte [nt_writes], 0             ; QEMU's drive alone, and room after the MiB
    lea rdi, [r15 + NV_SERIAL]
    lea rsi, [str_nt_serial]
    call streq
    test eax, eax
    jz .before
    mov eax, [nt_count]
    imul eax, eax, NT_WBYTES
    mov ecx, [r15 + NV_SHIFT]
    shr eax, cl
    add rax, [nt_ref_blocks]
    cmp rax, [r15 + NV_BLOCKS]
    ja .before
    mov byte [nt_writes], 1
.before:
    xor ecx, ecx                        ; what each queue had done
.queue_before:
    cmp ecx, [r15 + NV_NQ]
    jae .start
    mov rbx, [r15 + rcx * 8 + NV_QUEUES]
    mov rax, [rbx + NQ_COMPLETED]
    lea rdx, [nt_before]
    mov [rdx + rcx * 8], rax
    mov rax, [rbx + NQ_IRQS]
    lea rdx, [nt_before_irq]
    mov [rdx + rcx * 8], rax
    mov rax, [rbx + NQ_POLLS]
    lea rdx, [nt_before_poll]
    mov [rdx + rcx * 8], rax
    inc ecx
    jmp .queue_before

.start:
    lea rdi, [nt_workers]
    xor eax, eax
    mov ecx, NT_WORKERS * NW_SIZE / 8
    rep stosq
    RDTSC64
    mov r14, rax
    xor r12d, r12d
.spawn:
    cmp r12d, [nt_count]
    jae .spawned
    imul rbx, r12, NW_SIZE
    lea rax, [nt_workers]
    add rbx, rax
    mov [rbx + NW_INDEX], r12
    lea rdi, [nt_worker]
    mov rsi, rbx
    lea rdx, [str_nt_worker]
    call thread_new
    test rax, rax
    jz .no_thread
    mov [rbx + NW_TH], rax
    mov [rax + TH_PIN], r12             ; thread i on CPU i
    mov rdi, rax
    call thread_start
    inc r12d
    jmp .spawn
.no_thread:
    KLOG "nvme test: out of memory starting threads"
    call nt_fail
.spawned:
    xor r13d, r13d
.join:
    cmp r13d, r12d
    jae .joined
    imul rbx, r13, NW_SIZE
    lea rax, [nt_workers]
    add rbx, rax
    mov rdi, [rbx + NW_TH]
    call thread_join
    inc r13d
    jmp .join
.joined:
    RDTSC64
    sub rax, r14
    xor edx, edx
    div qword [tsc_per_us]
    mov r14, rax                        ; R14 = us
    xor r8d, r8d                        ; reads
    xor r9d, r9d                        ; bytes
    xor r10d, r10d                      ; wrong
    xor r11d, r11d                      ; failed
    xor ebp, ebp                        ; written
    xor esi, esi                        ; written wrong
    xor r13d, r13d
.sum:
    cmp r13d, r12d
    jae .summed
    imul rbx, r13, NW_SIZE
    lea rax, [nt_workers]
    add rbx, rax
    add r8, [rbx + NW_READS]
    add r9, [rbx + NW_BYTES]
    add r10, [rbx + NW_BAD]
    add r11, [rbx + NW_FAILED]
    add rbp, [rbx + NW_WRITTEN]
    add rsi, [rbx + NW_WBAD]
    inc r13d
    jmp .sum
.summed:
    mov rcx, r14
    test rcx, rcx
    jnz .rate
    inc rcx
.rate:
    mov rax, r9                         ; MiB/s
    imul rax, rax, 1000000
    xor edx, edx
    div rcx
    shr rax, 20
    mov rdi, rax
    mov rax, r14                        ; ms
    xor edx, edx
    mov ecx, 1000
    div rcx
    mov rcx, rax
    mov edx, [r15 + NV_MAXXFER]
    push rcx
    mov ecx, [r15 + NV_SHIFT]
    shr edx, cl
    pop rcx
    KLOG "nvme test: %u reads of 1 to %u blocks by %u threads, one on each CPU: %b in %u ms, %u MiB/s; %u wrong, %u failed", r8, rdx, r12, r9, rcx, rdi, r10, r11
    imul rax, r12, NT_READS
    cmp r8, rax
    jne .reads_bad
    mov rax, r10
    or rax, r11
    jz .queues
.reads_bad:
    call nt_fail

.queues:
    xor r13d, r13d
.queue:
    cmp r13d, [r15 + NV_NQ]
    jae .wrote
    mov rbx, [r15 + r13 * 8 + NV_QUEUES]
    lea rax, [nt_before]
    mov rcx, [rbx + NQ_COMPLETED]
    sub rcx, [rax + r13 * 8]
    lea rax, [nt_before_irq]
    mov rdx, [rbx + NQ_IRQS]
    sub rdx, [rax + r13 * 8]
    lea rax, [nt_before_poll]
    mov rdi, [rbx + NQ_POLLS]
    sub rdi, [rax + r13 * 8]
    mov eax, [rbx + NQ_ID]
    movsxd r8, dword [rbx + NQ_CPU]
    KLOG "nvme test: queue %u, interrupting CPU %d: %u commands, %u interrupts, %u polls", rax, r8, rcx, rdx, rdi
    test rcx, rcx
    jz .unused
    cmp dword [r15 + NV_MSIX], 0
    je .queue_next
    test rdx, rdx
    jnz .queue_next
    KLOG "nvme test: queue %u was never interrupted", rax
    call nt_fail
    jmp .queue_next
.unused:
    KLOG "nvme test: queue %u was not used", rax
    call nt_fail
.queue_next:
    inc r13d
    jmp .queue

.wrote:
    cmp byte [nt_writes], 0
    jne .written
    KLOG "nvme test: no writes: only QEMU's drive (serial AXIOMTEST) is written to"
    jmp .layer
.written:
    KLOG "nvme test: %u threads each wrote 128 KiB of its own, read it back and flushed: %b written, %u qwords wrong", r12, rbp, rsi
    imul rax, r12, NT_WBYTES
    cmp rbp, rax
    jne .writes_bad
    test rsi, rsi
    jz .layer
.writes_bad:
    call nt_fail

.layer:
    xor ecx, ecx                        ; the disk this controller is
.disk:
    cmp ecx, [disk_count]
    jae .no_disk
    imul rbx, rcx, DK_SIZE
    lea rax, [disks]
    add rbx, rax
    cmp [rbx + DK_CTX], r15
    je .disk_found
    inc ecx
    jmp .disk
.no_disk:
    KLOG "nvme test: no disk is this controller's"
    call nt_fail
    jmp .free
.disk_found:
    mov r13d, NT_LAYER
    mov rax, [nt_ref_blocks]
    sub rax, NT_LAYER_AT
    cmp r13, rax
    jbe .layer_size
    mov r13, rax
.layer_size:
    mov ecx, [r15 + NV_SHIFT]
    mov rdi, r13
    shl rdi, cl
    add rdi, 16
    call kmalloc
    test rax, rax
    jz .oom
    mov rbp, rax
    lea rdi, [rax + 1]                  ; an odd address
    mov esi, NT_LAYER_AT
    mov edx, r13d
    call disk_read
    jc .layer_failed
    mov ecx, [r15 + NV_SHIFT]
    mov rsi, NT_LAYER_AT
    shl rsi, cl
    add rsi, [nt_ref]
    mov rax, r13
    shl rax, cl
    mov rcx, rax
    lea rdi, [rbp + 1]
    repe cmpsb
    jne .layer_wrong
    KLOG "nvme test: %u blocks through the disk layer into a buffer at an odd address, as read before", r13
    jmp .layer_free
.layer_failed:
    KLOG "nvme test: a read through the disk layer failed"
    call nt_fail
    jmp .layer_free
.layer_wrong:
    KLOG "nvme test: a read through the disk layer into a buffer at an odd address differs"
    call nt_fail
.layer_free:
    mov rdi, rbp
    call kfree
    jmp .free
.oom:
    KLOG "nvme test: out of memory"
    call nt_fail
.free:
    mov rdi, [nt_ref]
    test rdi, rdi
    jz .verdict
    call vm_free
.verdict:
    cmp byte [nt_fails], 0
    jne .failed
    KLOG "nvme test: passed"
    jmp .out
.failed:
    KLOG "nvme test: FAILED"
.out:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret

nt_fail:
    mov byte [nt_fails], 1
    ret

; nt_read(R15, RSI = first block, RDX = blocks, RDI = buffer) -> CF: in
; commands of NV_MAXXFER at most
nt_read:
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    mov r9, rdx
    mov r8, rdi
.chunk:
    test r9, r9
    jz .ok
    mov ecx, [r15 + NV_SHIFT]
    mov eax, [r15 + NV_MAXXFER]
    shr eax, cl
    mov rdx, r9
    cmp rdx, rax
    jbe .size
    mov rdx, rax
.size:
    mov edi, 0x02
    call nvme_io
    jc .out
    sub r9, rdx
    add rsi, rdx
    mov rax, rdx
    shl rax, cl
    add r8, rax
    jmp .chunk
.ok:
    clc
.out:
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    ret

; nt_rand(R13 = state) -> RAX, R13 moved on (xorshift). Preserves others.
nt_rand:
    mov rax, r13
    shl rax, 13
    xor r13, rax
    mov rax, r13
    shr rax, 7
    xor r13, rax
    mov rax, r13
    shl rax, 17
    xor r13, rax
    mov rax, r13
    ret

; nt_worker(RDI = its NW_*): pinned to CPU NW_INDEX
nt_worker:
    push rbx
    push rbp
    push r12
    push r13
    push r14
    push r15
    mov rbx, rdi
    mov r15, [nt_ctrl]
    mov edi, NV_XFER + 4096             ; room to start anywhere in a page
    call vm_alloc
    test rax, rax
    jz .nomem
    mov r14, rax
    mov r13, [rbx + NW_INDEX]           ; a seed of its own
    inc r13
    mov rax, 0x9E3779B97F4A7C15
    imul r13, rax
    RDTSC64
    xor r13, rax
    or r13, 1
    mov r12d, NT_READS
.read:
    call nt_rand                        ; RBP = 1 to a command's worth of blocks
    mov ecx, [r15 + NV_SHIFT]
    mov ebp, [r15 + NV_MAXXFER]
    shr ebp, cl
    xor edx, edx
    div rbp
    lea rbp, [rdx + 1]
    call nt_rand                        ; RSI = from anywhere in the first MiB
    mov rcx, [nt_ref_blocks]
    sub rcx, rbp
    inc rcx
    xor edx, edx
    div rcx
    mov rsi, rdx
    call nt_rand                        ; R8 = anywhere dword-aligned in a page
    and eax, 0x3FC
    lea r8, [r14 + rax]
    mov edi, 0x02
    mov edx, ebp
    call nvme_io
    jc .failed
    mov ecx, [r15 + NV_SHIFT]
    mov rax, rbp
    shl rax, cl                         ; bytes
    add [rbx + NW_BYTES], rax
    push rsi
    shl rsi, cl
    add rsi, [nt_ref]
    mov rdi, r8
    mov rcx, rax
    repe cmpsb
    pop rsi
    je .counted
    inc qword [rbx + NW_BAD]
    jmp .counted
.failed:
    inc qword [rbx + NW_FAILED]
.counted:
    inc qword [rbx + NW_READS]
    dec r12d
    jnz .read

    cmp byte [nt_writes], 0
    je .done
    mov ecx, [r15 + NV_SHIFT]           ; RSI = its region, after the first MiB
    mov eax, NT_WBYTES
    shr eax, cl
    imul rax, [rbx + NW_INDEX]
    add rax, [nt_ref_blocks]
    mov rsi, rax
    mov r12d, NT_WBYTES                 ; bytes left
    mov r9, NT_WMAGIC
.wchunk:
    test r12d, r12d
    jz .flush
    mov ebp, [r15 + NV_MAXXFER]         ; RBP = bytes this time
    cmp ebp, r12d
    jbe .wsize
    mov ebp, r12d
.wsize:
    call nt_rand
    and eax, 0x3FC
    lea r8, [r14 + rax]
    mov ecx, [r15 + NV_SHIFT]           ; each qword says where it is
    mov rdx, rsi
    shl rdx, cl
    mov rdi, r8
    mov ecx, ebp
    shr ecx, 3
.fill:
    mov rax, rdx
    xor rax, r9
    mov [rdi], rax
    add rdi, 8
    add rdx, 8
    dec ecx
    jnz .fill
    mov ecx, [r15 + NV_SHIFT]
    mov edx, ebp
    shr edx, cl
    mov edi, 0x01                       ; write
    call nvme_io
    jc .wfailed
    mov rdi, r8                         ; forget it, then read it back
    mov ecx, ebp
    xor eax, eax
    rep stosb
    mov edi, 0x02
    call nvme_io
    jc .wfailed
    mov ecx, [r15 + NV_SHIFT]
    mov r10, rsi
    shl r10, cl
    mov rdi, r8
    mov ecx, ebp
    shr ecx, 3
.check:
    mov rax, r10
    xor rax, r9
    cmp [rdi], rax
    je .right
    inc qword [rbx + NW_WBAD]
.right:
    add rdi, 8
    add r10, 8
    dec ecx
    jnz .check
    add [rbx + NW_WRITTEN], rbp
    mov eax, ebp
    mov ecx, [r15 + NV_SHIFT]
    shr eax, cl
    add rsi, rax
    sub r12d, ebp
    jmp .wchunk
.wfailed:
    inc qword [rbx + NW_FAILED]
.flush:
    xor edi, edi                        ; Flush
    xor edx, edx
    call nvme_io
    jnc .done
    inc qword [rbx + NW_FAILED]
.done:
    mov rdi, r14
    call vm_free
    jmp .out
.nomem:
    inc qword [rbx + NW_FAILED]
.out:
    xor eax, eax
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret

section .rodata
str_nt_worker:  db 'nvme test', 0
str_nt_serial:  db 'AXIOMTEST', 0

section .bss
alignb 8
nt_ctrl:        resq 1
nt_ref:         resq 1                  ; the first MiB, read once
nt_ref_blocks:  resq 1
nt_count:       resd 1                  ; threads
nt_fails:       resb 1
nt_writes:      resb 1
alignb 8
nt_before:      resq NV_QMAX            ; each queue's completions before
nt_before_irq:  resq NV_QMAX
nt_before_poll: resq NV_QMAX
nt_workers:     resb NT_WORKERS * NW_SIZE
