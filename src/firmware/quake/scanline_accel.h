/*
 * Scanline Engine Accelerator - Hardware GenSpan
 * Replaces R_GenerateSpans_Array with FPGA surface stack engine.
 */

#ifndef SCANLINE_ACCEL_H
#define SCANLINE_ACCEL_H

#define HW_SCANLINE_ACCEL 1

#define SCANLINE_BASE         0x60000000u

#define SCAN_EDGE_HEAD_U      (*(volatile unsigned int *)(SCANLINE_BASE + 0x00))
#define SCAN_EDGE_TAIL_U      (*(volatile unsigned int *)(SCANLINE_BASE + 0x04))
#define SCAN_SCANLINE_V       (*(volatile unsigned int *)(SCANLINE_BASE + 0x08))
#define SCAN_EDGE_COUNT       (*(volatile unsigned int *)(SCANLINE_BASE + 0x0C))
#define SCAN_EDGE_DATA        (*(volatile unsigned int *)(SCANLINE_BASE + 0x10))
#define SCAN_SURFACE_KEY      (*(volatile unsigned int *)(SCANLINE_BASE + 0x14))
#define SCAN_CONTROL          (*(volatile unsigned int *)(SCANLINE_BASE + 0x18))
#define SCAN_STATUS           (*(volatile unsigned int *)(SCANLINE_BASE + 0x1C))
#define SCAN_SPAN_COUNT       (*(volatile unsigned int *)(SCANLINE_BASE + 0x20))
#define SCAN_SPAN_DATA        (*(volatile unsigned int *)(SCANLINE_BASE + 0x24))
#define SCAN_FRAME_INIT       (*(volatile unsigned int *)(SCANLINE_BASE + 0x28))

/* Debug registers (read-only) */
#define SCAN_DBG_FIRST_EDGE   (*(volatile unsigned int *)(SCANLINE_BASE + 0x2C))
#define SCAN_DBG_STATE        (*(volatile unsigned int *)(SCANLINE_BASE + 0x30))
#define SCAN_DBG_EDGES        (*(volatile unsigned int *)(SCANLINE_BASE + 0x34))

static inline void scanline_wait(void)
{
    while (SCAN_STATUS & 1)
        ;
}

static inline void scanline_load_surface(int idx, int key, int insubmodel)
{
    SCAN_SURFACE_KEY = ((unsigned int)idx << 16) |
                       ((insubmodel & 1) << 15) |
                       (key & 0x7FFF);
}

#endif /* SCANLINE_ACCEL_H */
