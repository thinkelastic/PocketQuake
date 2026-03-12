/*
 * audio_timer.c — Timer interrupt-driven audio FIFO pump
 *
 * Uses the machine timer interrupt (mcause 0x80000007) to drain the
 * BRAM output ring buffer into the FPGA audio FIFO at ~200 Hz.
 *
 * The ISR only reads from BRAM and writes to MMIO — both go through the
 * local bus path, avoiding SDRAM arbiter contention with the span
 * rasterizer.  The main loop fills the BRAM ring via SNDDMA_FillRing().
 *
 * MMIO registers (in axi_periph_slave sysreg space):
 *   0x400000A8: MTIMECMP — write to schedule next timer interrupt
 *   0x400000AC: MTIME_LO — current cycle counter (read-only)
 */

#include "quakedef.h"

#define MTIMECMP    (*(volatile unsigned int *)0x400000A8)
#define MTIME_LO    (*(volatile unsigned int *)0x400000AC)

/* ~200 Hz at 105 MHz = 525000 cycles between interrupts (~5ms).
 * 1024-sample FIFO at 48 kHz = ~21ms, so 5ms interval keeps it well-fed. */
#define TIMER_INTERVAL  525000

/* Exported so main-loop callers can adjust behavior when ISR handles audio */
int audio_timer_active = 0;

/* Drain BRAM ring → FIFO (defined in snd_pocket.c) */
extern void SNDDMA_DrainRing(void);

/*
 * Called from the timer interrupt fast path in start.S.
 * Must NOT use floating-point (FP regs are not saved).
 * Must NOT call anything that allocates or touches the heap.
 */
void __attribute__((noinline)) audio_timer_isr(void)
{
    /* Rearm timer first (minimize jitter) */
    unsigned int now = MTIME_LO;
    MTIMECMP = now + TIMER_INTERVAL;

    /* Drain BRAM ring → FPGA FIFO (BRAM reads + MMIO writes only) */
    if (audio_timer_active)
        SNDDMA_DrainRing();
}

/*
 * Enable the timer interrupt. Called after SNDDMA_Init().
 */
void Audio_TimerStart(void)
{
    /* Schedule first interrupt */
    MTIMECMP = MTIME_LO + TIMER_INTERVAL;

    /* Enable machine timer interrupt: mie.MTIE = bit 7 */
    __asm__ volatile("csrs mie, %0" :: "r"(1 << 7));

    /* Enable global machine interrupts: mstatus.MIE = bit 3 */
    __asm__ volatile("csrs mstatus, %0" :: "r"(1 << 3));

    audio_timer_active = 1;
}

/*
 * Disable the timer interrupt.
 */
void Audio_TimerStop(void)
{
    audio_timer_active = 0;

    /* Disable machine timer interrupt: mie.MTIE = bit 7 */
    __asm__ volatile("csrc mie, %0" :: "r"(1 << 7));
}
