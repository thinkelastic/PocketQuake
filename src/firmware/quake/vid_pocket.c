/*
 * vid_pocket.c -- PocketQuake video driver
 * Quake renders 8-bit indexed pixels directly to SDRAM framebuffer.
 * Hardware video scanout reads 8-bit indices and does palette lookup in FPGA.
 */

#include "quakedef.h"
#include "d_local.h"
#include "surface_accel.h"

extern viddef_t vid;

#define BASEWIDTH   320
#define BASEHEIGHT  240

/* System register MMIO (implemented by cpu_system.v) */
#define SYS_DISPLAY_MODE    (*(volatile unsigned int *)0x4000000C)
#define SYS_FB_DISPLAY      (*(volatile unsigned int *)0x40000010)
#define SYS_FB_DRAW         (*(volatile unsigned int *)0x40000014)
#define SYS_FB_SWAP         (*(volatile unsigned int *)0x40000018)
#define SYS_PAL_INDEX       (*(volatile unsigned int *)0x40000040)
#define SYS_PAL_DATA        (*(volatile unsigned int *)0x40000044)
#define SDRAM_UC_BASE       0x50000000u

#define VID_PIXELS          (BASEWIDTH * BASEHEIGHT)
#define SURFCACHE_SIZE      (2 * 1024 * 1024)

/* Surface cache and z-buffer in BSS (cacheable SDRAM) */
static byte surfcache_storage[SURFCACHE_SIZE];
static short zbuffer_storage[BASEWIDTH * BASEHEIGHT];

unsigned short d_8to16table[256];
unsigned d_8to24table[256];

/* Get CPU byte address of the current draw framebuffer */
static byte *fb_draw_buffer(void)
{
    unsigned int draw_word_addr = SYS_FB_DRAW & 0x01FFFFFFu;
    return (byte *)(SDRAM_UC_BASE + (draw_word_addr << 1));
}

void VID_SetPalette(unsigned char *palette)
{
    int i;
    unsigned char *p = palette;

    /* Write to hardware palette (auto-incrementing index) */
    SYS_PAL_INDEX = 0;

    for (i = 0; i < 256; i++) {
        unsigned int r = *p++;
        unsigned int g = *p++;
        unsigned int b = *p++;

        /* Write to hardware palette in FPGA.
         * Empirically, the output looks blue-shifted, so swap R/B to test. */
        SYS_PAL_DATA = b | (g << 8) | (r << 16);

        /* Keep software lookup tables for other Quake code */
        d_8to16table[i] = (unsigned short)(((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3));
        d_8to24table[i] = (unsigned)((r) | (g << 8) | (b << 16));
    }
}

void VID_ShiftPalette(unsigned char *palette)
{
    VID_SetPalette(palette);
}

void VID_Init(unsigned char *palette)
{
    Sys_Printf("VID_Init: start\n");
    vid.maxwarpwidth = vid.width = vid.conwidth = BASEWIDTH;
    vid.maxwarpheight = vid.height = vid.conheight = BASEHEIGHT;
    vid.aspect = ((float)BASEHEIGHT / (float)BASEWIDTH) * (320.0f / 240.0f);
    vid.numpages = 2;
    vid.colormap = host_colormap;
    vid.fullbright = 256 - LittleLong(*((int *)vid.colormap + 2048));
    Sys_Printf("VID_Init: fullbright=%d\n", vid.fullbright);

    /* Point vid.buffer at the SDRAM draw framebuffer */
    vid.buffer = vid.conbuffer = fb_draw_buffer();
    vid.rowbytes = vid.conrowbytes = BASEWIDTH;

    Sys_Printf("VID_Init: buffer=%x\n", (unsigned)vid.buffer);

    /* Z-buffer in cacheable SDRAM (BSS) for fast D-cache access */
    d_pzbuffer = zbuffer_storage;
    D_InitCaches(surfcache_storage, SURFCACHE_SIZE);

    VID_SetPalette(palette);

#if HW_CMAP_BRAM
    /* Upload colormap to FPGA BRAM for fast lookup */
    Sys_Printf("VID_Init: uploading colormap to BRAM\n");
    cmap_upload(host_colormap);

    /* Readback verification: word reads and byte reads */
    {
        volatile unsigned int *cmap_w = (volatile unsigned int *)CMAP_BRAM_BASE;
        const unsigned int *src_w = (const unsigned int *)host_colormap;
        int errs = 0, i;

        /* Test word readback at a few spots */
        for (i = 0; i < 4096; i += 511) {
            unsigned int got = cmap_w[i];
            unsigned int exp = src_w[i];
            if (got != exp) {
                Sys_Printf("CMAP word[%d]: got %x exp %x\n", i, got, exp);
                errs++;
            }
        }

        /* Test byte readback (the actual access pattern used in rendering) */
        for (i = 0; i < 64; i++) {
            unsigned char got = CMAP_BRAM_PTR[i];
            unsigned char exp = host_colormap[i];
            if (got != exp) {
                Sys_Printf("CMAP byte[%d]: got %x exp %x\n", i, got, exp);
                errs++;
            }
        }

        /* Test a colormap-style access: light level 32 (0x2000), pix=0..3 */
        for (i = 0; i < 4; i++) {
            unsigned char got = CMAP_BRAM_PTR[0x2000 + i];
            unsigned char exp = host_colormap[0x2000 + i];
            if (got != exp) {
                Sys_Printf("CMAP hi[%x]: got %x exp %x\n", 0x2000+i, got, exp);
                errs++;
            }
        }

        Sys_Printf("VID_Init: BRAM verify %s (%d errors)\n",
                    errs ? "FAIL" : "OK", errs);
    }
#endif

    SYS_DISPLAY_MODE = 1;  /* 1 = framebuffer only */
    Sys_Printf("VID_Init: done\n");
}

void VID_Shutdown(void)
{
    SYS_DISPLAY_MODE = 0;  /* back to terminal overlay */
}

void VID_Update(vrect_t *rects)
{
    (void)rects;

    /* Request buffer flip (will happen on next vblank) */
    SYS_FB_SWAP = 1;

    /* Wait for swap to complete (vsync) */
    while (SYS_FB_SWAP) ;

    /* Update vid.buffer to point at the new draw buffer */
    vid.buffer = vid.conbuffer = fb_draw_buffer();
}

/*
================
D_BeginDirectRect
================
*/
void D_BeginDirectRect(int x, int y, byte *pbitmap, int width, int height)
{
    (void)x; (void)y; (void)pbitmap; (void)width; (void)height;
}

/*
================
D_EndDirectRect
================
*/
void D_EndDirectRect(int x, int y, int width, int height)
{
    (void)x; (void)y; (void)width; (void)height;
}
