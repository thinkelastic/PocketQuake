/*
 * Time functions for VexRiscv
 * Uses hardware cycle counter for timing
 */

#include "libc.h"

/* CPU clock frequency in Hz (100 MHz) */
#define CPU_FREQ_HZ     100000000

/* Get 64-bit cycle counter */
static uint64_t get_cycles(void) {
    uint32_t lo, hi, hi2;

    /* Read high, low, high again to handle rollover */
    do {
        hi = SYS_CYCLE_HI;
        lo = SYS_CYCLE_LO;
        hi2 = SYS_CYCLE_HI;
    } while (hi != hi2);

    return ((uint64_t)hi << 32) | lo;
}

time_t time(time_t *tloc) {
    uint64_t cycles = get_cycles();
    time_t seconds = cycles / CPU_FREQ_HZ;

    if (tloc != NULL) {
        *tloc = seconds;
    }

    return seconds;
}

int clock_gettime(int clk_id, struct timespec *tp) {
    (void)clk_id;  /* Treat all clocks the same */

    if (tp == NULL) {
        return -1;
    }

    uint64_t cycles = get_cycles();

    /* Calculate seconds and nanoseconds */
    tp->tv_sec = cycles / CPU_FREQ_HZ;

    uint64_t remaining_cycles = cycles % CPU_FREQ_HZ;
    /* Convert remaining cycles to nanoseconds */
    /* remaining_cycles * 1000000000 / CPU_FREQ_HZ */
    /* To avoid overflow: (remaining_cycles * 1000) / (CPU_FREQ_HZ / 1000000) */
    tp->tv_nsec = (remaining_cycles * 1000000000ULL) / CPU_FREQ_HZ;

    return 0;
}
