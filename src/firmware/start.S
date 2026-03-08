/*
 * VexRiscv startup code
 * Sets up stack pointer and jumps to main
 * Includes trap handler for misaligned access emulation and crash debugging
 *
 * Trap architecture:
 *   Reset vector = 0 (_start), mtvec set to _trap_vector during boot.
 *   _trap_vector saves t0 to a fixed BRAM scratch word before reading
 *   mcause, so ALL registers (including t0) survive interrupt return.
 *   Timer interrupt (mcause 0x80000007) uses a fast path that only saves
 *   caller-saved registers.  All other traps use the full save path.
 *
 * BRAM scratch layout (0x0000F000):
 *   0x0000F000: boot magic / t0 save slot (shared; boot magic only read once)
 *   0x0000F004: (available)
 */

.section .text.start
.global _start

_start:
    /* Cold boot entry point (reset vector = 0).
     * mtvec is changed to _trap_vector below, so this code only runs once. */

    /* Set up stack pointer */
    lui sp, %hi(_stack_top)
    addi sp, sp, %lo(_stack_top)

    /* Enable FPU: set mstatus.FS = 11 (Dirty) — bits [14:13] */
    li t0, (3 << 13)
    csrs mstatus, t0

    /* Set mtvec to dedicated trap handler (NOT _start) */
    la t0, _trap_vector
    csrw mtvec, t0

    /* Mark that we've booted (store magic value at fixed BRAM address) */
    lui t0, 0x0000F     /* Use top of BRAM area 0x0000F000 as scratch */
    li t1, 0xDEAD0001
    sw t1, 0(t0)

    /* Clear BSS section */
    lui a0, %hi(_bss_start)
    addi a0, a0, %lo(_bss_start)
    lui a1, %hi(_bss_end)
    addi a1, a1, %lo(_bss_end)
clear_bss:
    bge a0, a1, done_bss
    sw zero, 0(a0)
    addi a0, a0, 4
    j clear_bss
done_bss:

    /* Jump to main */
    jal ra, main

    /* If main returns, loop forever */
halt:
    j halt


/* ========================================
 * Trap vector entry point.
 *
 * Saves t0 to a fixed BRAM scratch word BEFORE reading mcause,
 * so the original t0 is never lost.  Uses mscratch for original sp.
 *
 * Register contract at entry:
 *   mscratch = undefined (will be set to original sp)
 *   All GPRs = interrupted context values
 * ======================================== */
.align 4
_trap_vector:
    /* Step 1: Save original sp to mscratch */
    csrw mscratch, sp

    /* Step 2: Save original t0 to fixed BRAM scratch (0x0000F000).
     * We use sp as a temp (original sp is safe in mscratch). */
    lui sp, 0xF                 /* sp = 0x0000F000 */
    sw t0, 0(sp)                /* BRAM[0xF000] = original t0 */

    /* Step 3: Read mcause into t0 (safe — original t0 is saved) */
    csrr t0, mcause

    /* Step 4: Fast-path check for timer interrupt (mcause == 0x80000007).
     * Interrupts have bit 31 set; code 7 = machine timer. */
    bgez t0, _full_trap_path    /* Bit 31 clear → synchronous exception */
    andi t0, t0, 0x7F           /* Mask off interrupt bit */
    addi t0, t0, -7             /* t0 = 0 if timer interrupt */
    bnez t0, _full_trap_path    /* Not timer → full save */

    /* ================================================
     * Timer interrupt fast path
     * Save only caller-saved regs (~18 words = 72 bytes + overhead)
     * ================================================ */
    lui sp, %hi(_timer_stack_top)
    addi sp, sp, %lo(_timer_stack_top)
    addi sp, sp, -96

    /* Save original sp (from mscratch) */
    csrr t0, mscratch
    sw t0,  0(sp)               /* frame[0] = original sp */

    /* Save ra */
    sw ra,  4(sp)

    /* Save original t0 (from BRAM scratch at 0x0000F000) */
    lui t0, 0xF
    lw t0, 0(t0)
    sw t0,  8(sp)               /* frame[2] = original t0 (x5) */

    /* Save remaining caller-saved registers */
    sw a0, 12(sp)
    sw a1, 16(sp)
    sw a2, 20(sp)
    sw a3, 24(sp)
    sw a4, 28(sp)
    sw a5, 32(sp)
    sw a6, 36(sp)
    sw a7, 40(sp)
    sw t1, 44(sp)
    sw t2, 48(sp)
    sw t3, 52(sp)
    sw t4, 56(sp)
    sw t5, 60(sp)
    sw t6, 64(sp)
    csrr t0, mepc
    sw t0, 68(sp)               /* frame[17] = mepc */

    /* Call audio ISR (integer-only, no FP save needed) */
    jal ra, audio_timer_isr

    /* Restore mepc */
    lw t0, 68(sp)
    csrw mepc, t0

    /* Restore all caller-saved registers */
    lw ra,  4(sp)
    lw a0, 12(sp)
    lw a1, 16(sp)
    lw a2, 20(sp)
    lw a3, 24(sp)
    lw a4, 28(sp)
    lw a5, 32(sp)
    lw a6, 36(sp)
    lw a7, 40(sp)
    lw t1, 44(sp)
    lw t2, 48(sp)
    lw t3, 52(sp)
    lw t4, 56(sp)
    lw t5, 60(sp)
    lw t6, 64(sp)

    /* Restore t0 (must be after all other uses of t0) */
    lw t0,  8(sp)

    /* Restore original sp and return */
    lw sp,  0(sp)
    mret


/* ================================================
 * Full trap path — exceptions and non-timer interrupts
 *
 * Restores t0 from BRAM scratch, restores sp from mscratch,
 * then saves ALL registers to a full trap frame.
 *
 * Trap frame layout:
 *   x0-x31  (32 words) at sp+0   .. sp+124
 *   mepc    (1 word)   at sp+128
 *   mcause  (1 word)   at sp+132
 *   mtval   (1 word)   at sp+136
 *   f0-f31  (32 words) at sp+140 .. sp+264
 * Total: 67 words = 268 bytes (round to 272 for 8-byte alignment)
 * ================================================ */
_full_trap_path:
    /* Recover original t0 from BRAM scratch.
     * sp is still 0x0000F000 from the lui above. */
    lw t0, 0(sp)               /* t0 = original t0 */

    /* Switch to trap stack in BRAM */
    lui sp, %hi(_stack_top)
    addi sp, sp, %lo(_stack_top)

    /* Allocate trap frame: 272 bytes */
    addi sp, sp, -272

    /* Save original t0 (x5) FIRST — it was recovered from scratch */
    sw t0,  20(sp)

    /* Now use t0 as temp to save original sp from mscratch */
    csrr t0, mscratch
    sw t0,   8(sp)             /* x2 = original sp */

    /* Save remaining x1, x3-x31 */
    sw x1,   4(sp)
    sw x3,  12(sp)
    sw x4,  16(sp)
    /* x5 already saved above */
    sw x6,  24(sp)
    sw x7,  28(sp)
    sw x8,  32(sp)
    sw x9,  36(sp)
    sw x10, 40(sp)
    sw x11, 44(sp)
    sw x12, 48(sp)
    sw x13, 52(sp)
    sw x14, 56(sp)
    sw x15, 60(sp)
    sw x16, 64(sp)
    sw x17, 68(sp)
    sw x18, 72(sp)
    sw x19, 76(sp)
    sw x20, 80(sp)
    sw x21, 84(sp)
    sw x22, 88(sp)
    sw x23, 92(sp)
    sw x24, 96(sp)
    sw x25, 100(sp)
    sw x26, 104(sp)
    sw x27, 108(sp)
    sw x28, 112(sp)
    sw x29, 116(sp)
    sw x30, 120(sp)
    sw x31, 124(sp)

    /* Save CSRs: mepc, mcause, mtval */
    csrr t0, mepc
    sw t0, 128(sp)
    csrr t0, mcause
    sw t0, 132(sp)
    csrr t0, mtval
    sw t0, 136(sp)

    /* Store 0 at x0 position (for completeness) */
    sw zero, 0(sp)

    /* Save f0-f31 (floating-point registers) */
    fsw f0,  140(sp)
    fsw f1,  144(sp)
    fsw f2,  148(sp)
    fsw f3,  152(sp)
    fsw f4,  156(sp)
    fsw f5,  160(sp)
    fsw f6,  164(sp)
    fsw f7,  168(sp)
    fsw f8,  172(sp)
    fsw f9,  176(sp)
    fsw f10, 180(sp)
    fsw f11, 184(sp)
    fsw f12, 188(sp)
    fsw f13, 192(sp)
    fsw f14, 196(sp)
    fsw f15, 200(sp)
    fsw f16, 204(sp)
    fsw f17, 208(sp)
    fsw f18, 212(sp)
    fsw f19, 216(sp)
    fsw f20, 220(sp)
    fsw f21, 224(sp)
    fsw f22, 228(sp)
    fsw f23, 232(sp)
    fsw f24, 236(sp)
    fsw f25, 240(sp)
    fsw f26, 244(sp)
    fsw f27, 248(sp)
    fsw f28, 252(sp)
    fsw f29, 256(sp)
    fsw f30, 260(sp)
    fsw f31, 264(sp)

    /* Call C handler: handle_misaligned(trap_frame_t *frame)
     * Returns 1 if handled (should return), 0 if fatal */
    mv a0, sp
    jal ra, handle_misaligned

    /* Check return value */
    beqz a0, _fatal_trap

    /* Handled - restore mepc (may have been modified) */
    lw t0, 128(sp)
    csrw mepc, t0

    /* Restore f0-f31 (may have been modified by FLW emulation) */
    flw f0,  140(sp)
    flw f1,  144(sp)
    flw f2,  148(sp)
    flw f3,  152(sp)
    flw f4,  156(sp)
    flw f5,  160(sp)
    flw f6,  164(sp)
    flw f7,  168(sp)
    flw f8,  172(sp)
    flw f9,  176(sp)
    flw f10, 180(sp)
    flw f11, 184(sp)
    flw f12, 188(sp)
    flw f13, 192(sp)
    flw f14, 196(sp)
    flw f15, 200(sp)
    flw f16, 204(sp)
    flw f17, 208(sp)
    flw f18, 212(sp)
    flw f19, 216(sp)
    flw f20, 220(sp)
    flw f21, 224(sp)
    flw f22, 228(sp)
    flw f23, 232(sp)
    flw f24, 236(sp)
    flw f25, 240(sp)
    flw f26, 244(sp)
    flw f27, 248(sp)
    flw f28, 252(sp)
    flw f29, 256(sp)
    flw f30, 260(sp)
    flw f31, 264(sp)

    /* Restore integer registers */
    lw x1,   4(sp)
    /* Restore original sp to mscratch temporarily */
    lw t0,   8(sp)
    csrw mscratch, t0
    lw x3,  12(sp)
    lw x4,  16(sp)
    lw x5,  20(sp)
    lw x6,  24(sp)
    lw x7,  28(sp)
    lw x8,  32(sp)
    lw x9,  36(sp)
    lw x10, 40(sp)
    lw x11, 44(sp)
    lw x12, 48(sp)
    lw x13, 52(sp)
    lw x14, 56(sp)
    lw x15, 60(sp)
    lw x16, 64(sp)
    lw x17, 68(sp)
    lw x18, 72(sp)
    lw x19, 76(sp)
    lw x20, 80(sp)
    lw x21, 84(sp)
    lw x22, 88(sp)
    lw x23, 92(sp)
    lw x24, 96(sp)
    lw x25, 100(sp)
    lw x26, 104(sp)
    lw x27, 108(sp)
    lw x28, 112(sp)
    lw x29, 116(sp)
    lw x30, 120(sp)
    lw x31, 124(sp)

    /* Restore original sp from mscratch */
    csrr sp, mscratch

    /* Return from trap */
    mret

_fatal_trap:
    /* Call fatal_trap(trap_frame_t *frame) - does not return */
    mv a0, sp
    jal ra, fatal_trap
    j _fatal_trap

/* ========================================
 * Switch to a new runtime stack and jump to entry point.
 * a0 = function pointer, a1 = new stack top
 * Does not return.
 * ======================================== */
.global switch_to_runtime_stack_and_call
switch_to_runtime_stack_and_call:
    mv sp, a1
    /* Debug: write "S" then hex dump a0 to VRAM row 29 starting col 4
     * Format: S XXXXXXXX (address we're about to jump to) */
    lui t0, 0x20000         /* t0 = 0x20000000 (VRAM base) */
    li  t1, 0x53            /* t1 = 'S' */
    sb  t1, 0x48B(t0)       /* VRAM[29*40 + 3] = 'S' */

    /* Hex dump a0 (8 nibbles) to VRAM row 29, cols 5-12 */
    mv  t2, a0              /* t2 = address to dump */
    addi t3, t0, 0x48D      /* t3 = &VRAM[29*40 + 5] */
    li  t4, 8               /* 8 nibbles */
.L_hexloop:
    srli t1, t2, 28         /* top nibble */
    slli t2, t2, 4          /* shift left for next nibble */
    addi t5, t1, 0x30       /* assume '0'-'9' */
    li  t6, 10
    blt t1, t6, .L_hexstore
    addi t5, t1, 0x37       /* 'A'-'F': 10+0x37=0x41='A' */
.L_hexstore:
    sb  t5, 0(t3)
    addi t3, t3, 1
    addi t4, t4, -1
    bnez t4, .L_hexloop

    /* Also load first word from target via D-bus and write to cols 14-21
     * This confirms PSRAM has valid data at the jump target.
     * Word-align the address since RVC may place quake_main at +2 */
    andi t2, a0, -4          /* word-align: 0x3000c2c6 → 0x3000c2c4 */
    lw  t2, 0(t2)            /* safe word-aligned D-bus read */
    addi t3, t0, 0x496      /* t3 = &VRAM[29*40 + 14] */
    li  t4, 8
.L_hexloop2:
    srli t1, t2, 28
    slli t2, t2, 4
    addi t5, t1, 0x30
    li  t6, 10
    blt t1, t6, .L_hexstore2
    addi t5, t1, 0x37
.L_hexstore2:
    sb  t5, 0(t3)
    addi t3, t3, 1
    addi t4, t4, -1
    bnez t4, .L_hexloop2

    jr a0
1:
    j 1b
