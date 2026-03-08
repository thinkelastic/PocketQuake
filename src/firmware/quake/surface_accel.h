#ifndef SURFACE_ACCEL_H
#define SURFACE_ACCEL_H

/*
 * Colormap BRAM Accelerator
 * 16KB colormap stored in FPGA block RAM for fast CPU reads.
 * Replaces slow SDRAM colormap lookups (~12 cycles) with fast BRAM (~2 cycles).
 * Used by D_PolysetDrawSpans8 (alias models) and R_DrawSurfaceBlock8 (world surfaces).
 */

#ifndef HW_CMAP_BRAM
#define HW_CMAP_BRAM 1
#endif

/* Colormap BRAM base: 16KB at 0x54000000
 * Quake colormap = 64 light levels * 256 palette entries = 16384 bytes */
#define CMAP_BRAM_BASE  0x54000000
/* Read-only access: no volatile needed (BRAM has no side effects on read).
 * Volatile was preventing the compiler from caching lookups in registers. */
#define CMAP_BRAM_PTR   ((const unsigned char *)CMAP_BRAM_BASE)

/* Upload 16KB colormap to BRAM (call once at init and on palette change).
 * src must point to Quake's host_colormap (first 16384 bytes used). */
static inline void cmap_upload(const unsigned char *src)
{
    volatile unsigned int *dst = (volatile unsigned int *)CMAP_BRAM_BASE;
    const unsigned int *s = (const unsigned int *)src;
    int i;
    for (i = 0; i < 16384/4; i++)
        dst[i] = s[i];
}

#endif /* SURFACE_ACCEL_H */
