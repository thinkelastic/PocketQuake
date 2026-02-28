/*
 * setjmp / longjmp for RV32IMAF (ilp32f ABI)
 * jmp_buf layout (26 x 32-bit words):
 *   [0]  ra   (return address)
 *   [1]  sp   (stack pointer)
 *   [2]  s0   (frame pointer)
 *   [3]  s1
 *   [4]  s2
 *   [5]  s3
 *   [6]  s4
 *   [7]  s5
 *   [8]  s6
 *   [9]  s7
 *   [10] s8
 *   [11] s9
 *   [12] s10
 *   [13] s11
 *   [14] fs0
 *   [15] fs1
 *   [16] fs2
 *   [17] fs3
 *   [18] fs4
 *   [19] fs5
 *   [20] fs6
 *   [21] fs7
 *   [22] fs8
 *   [23] fs9
 *   [24] fs10
 *   [25] fs11
 */

.section .text
.global setjmp
.global longjmp

/* int setjmp(jmp_buf env) */
/* a0 = pointer to jmp_buf */
setjmp:
    sw ra,   0(a0)
    sw sp,   4(a0)
    sw s0,   8(a0)
    sw s1,  12(a0)
    sw s2,  16(a0)
    sw s3,  20(a0)
    sw s4,  24(a0)
    sw s5,  28(a0)
    sw s6,  32(a0)
    sw s7,  36(a0)
    sw s8,  40(a0)
    sw s9,  44(a0)
    sw s10, 48(a0)
    sw s11, 52(a0)
    fsw fs0,  56(a0)
    fsw fs1,  60(a0)
    fsw fs2,  64(a0)
    fsw fs3,  68(a0)
    fsw fs4,  72(a0)
    fsw fs5,  76(a0)
    fsw fs6,  80(a0)
    fsw fs7,  84(a0)
    fsw fs8,  88(a0)
    fsw fs9,  92(a0)
    fsw fs10, 96(a0)
    fsw fs11, 100(a0)
    li a0, 0         /* return 0 from setjmp */
    ret

/* void longjmp(jmp_buf env, int val) */
/* a0 = pointer to jmp_buf, a1 = return value */
longjmp:
    lw ra,   0(a0)
    lw sp,   4(a0)
    lw s0,   8(a0)
    lw s1,  12(a0)
    lw s2,  16(a0)
    lw s3,  20(a0)
    lw s4,  24(a0)
    lw s5,  28(a0)
    lw s6,  32(a0)
    lw s7,  36(a0)
    lw s8,  40(a0)
    lw s9,  44(a0)
    lw s10, 48(a0)
    lw s11, 52(a0)
    flw fs0,  56(a0)
    flw fs1,  60(a0)
    flw fs2,  64(a0)
    flw fs3,  68(a0)
    flw fs4,  72(a0)
    flw fs5,  76(a0)
    flw fs6,  80(a0)
    flw fs7,  84(a0)
    flw fs8,  88(a0)
    flw fs9,  92(a0)
    flw fs10, 96(a0)
    flw fs11, 100(a0)
    mv a0, a1        /* return val */
    bnez a0, 1f
    li a0, 1         /* if val == 0, return 1 */
1:
    ret
