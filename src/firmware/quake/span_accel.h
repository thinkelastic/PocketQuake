#ifndef SPAN_ACCEL_H
#define SPAN_ACCEL_H

/*
 * Hardware Span Rasterizer
 * - Textured span mode: offloads D_DrawSpans8 inner pixel loop.
 * - Z-span mode: offloads D_DrawZSpans short writes.
 */

/* Enable textured span offload on SDRAM-backed framebuffer path. */
#define HW_SPAN_ACCEL 1
#define HW_ZSPAN_ACCEL 0  /* Disabled: z-buffer now in cacheable SDRAM, not SRAM */
#define HW_TURB_ACCEL 1
#define HW_SURFBLOCK_ACCEL 1

#define SPAN_BASE       0x48000000
#define SPAN_FB_ADDR    (*(volatile unsigned int *)(SPAN_BASE + 0x00))
#define SPAN_TEX_ADDR   (*(volatile unsigned int *)(SPAN_BASE + 0x04))
#define SPAN_TEX_WIDTH  (*(volatile unsigned int *)(SPAN_BASE + 0x08))
#define SPAN_S          (*(volatile unsigned int *)(SPAN_BASE + 0x0C))
#define SPAN_T          (*(volatile unsigned int *)(SPAN_BASE + 0x10))
#define SPAN_SSTEP      (*(volatile unsigned int *)(SPAN_BASE + 0x14))
#define SPAN_TSTEP      (*(volatile unsigned int *)(SPAN_BASE + 0x18))
#define SPAN_CONTROL    (*(volatile unsigned int *)(SPAN_BASE + 0x1C))
#define SPAN_STATUS     (*(volatile unsigned int *)(SPAN_BASE + 0x20))
#define SPAN_Z_ADDR     (*(volatile unsigned int *)(SPAN_BASE + 0x24))
#define SPAN_ZI         (*(volatile unsigned int *)(SPAN_BASE + 0x28))
#define SPAN_ZISTEP     (*(volatile unsigned int *)(SPAN_BASE + 0x2C))
#define SPAN_ZCONTROL   (*(volatile unsigned int *)(SPAN_BASE + 0x30))
#define SPAN_LIGHT      (*(volatile unsigned int *)(SPAN_BASE + 0x34))
#define SPAN_LIGHTSTEP  (*(volatile unsigned int *)(SPAN_BASE + 0x38))
#define SPAN_TURB_PHASE (*(volatile unsigned int *)(SPAN_BASE + 0x3C))

/* Surface block registers */
#define SURF_LIGHT_TL   (*(volatile unsigned int *)(SPAN_BASE + 0x40))
#define SURF_LIGHT_TR   (*(volatile unsigned int *)(SPAN_BASE + 0x44))
#define SURF_LIGHT_BL   (*(volatile unsigned int *)(SPAN_BASE + 0x48))
#define SURF_LIGHT_BR   (*(volatile unsigned int *)(SPAN_BASE + 0x4C))
#define SURF_TEX_STEP   (*(volatile unsigned int *)(SPAN_BASE + 0x50))
#define SURF_DEST_STEP  (*(volatile unsigned int *)(SPAN_BASE + 0x54))
#define SURF_CONTROL    (*(volatile unsigned int *)(SPAN_BASE + 0x58))

#define SPAN_STATUS_BUSY        0x01
#define SPAN_STATUS_QUEUE_FULL  0x02
#define SPAN_STATUS_CAN_ACCEPT  0x04
#define SPAN_STATUS_OVERFLOW    0x08

/* Start a textured span draw (non-blocking).
 * fb_addr/tex_addr are CPU byte addresses (0x10xxxxxx or 0x50xxxxxx SDRAM alias).
 * s, t, sstep, tstep are 16.16 fixed-point.
 * tex_width/tex_height are texture dimensions in pixels (hardware clamps s/t). */
static inline void span_draw(unsigned int fb_addr, unsigned int tex_addr,
                              int tex_width, int tex_height, int s, int t,
                              int sstep, int tstep, int count)
{
    SPAN_FB_ADDR   = fb_addr;
    SPAN_TEX_ADDR  = tex_addr;
    SPAN_TEX_WIDTH = (unsigned int)tex_width | ((unsigned int)tex_height << 16);
    SPAN_S         = (unsigned int)s;
    SPAN_T         = (unsigned int)t;
    SPAN_SSTEP     = (unsigned int)sstep;
    SPAN_TSTEP     = (unsigned int)tstep;
    SPAN_CONTROL   = (unsigned int)count;  /* triggers start */
}

/* Program texture source for subsequent textured span commands.
 * tex_width/tex_height are texture dimensions in pixels (hardware clamps s/t). */
static inline void span_set_texture(unsigned int tex_addr, int tex_width, int tex_height)
{
    SPAN_TEX_ADDR  = tex_addr;
    SPAN_TEX_WIDTH = (unsigned int)tex_width | ((unsigned int)tex_height << 16);
}

/* Start a textured span draw using already programmed texture source. */
static inline void span_draw_tex(unsigned int fb_addr, int s, int t,
                                 int sstep, int tstep, int count)
{
    SPAN_FB_ADDR   = fb_addr;
    SPAN_S         = (unsigned int)s;
    SPAN_T         = (unsigned int)t;
    SPAN_SSTEP     = (unsigned int)sstep;
    SPAN_TSTEP     = (unsigned int)tstep;
    SPAN_CONTROL   = (unsigned int)count;
}

/* Start a textured span with hardware colormap/lighting lookup.
 * light is the pre-shifted light level (light & 0xFF00).
 * tex_width/tex_height are texture dimensions in pixels (hardware clamps s/t). */
static inline void span_draw_lit(unsigned int fb_addr, unsigned int tex_addr,
                                  int tex_width, int tex_height, int s, int t,
                                  int sstep, int tstep, int count,
                                  unsigned int light)
{
    SPAN_FB_ADDR   = fb_addr;
    SPAN_TEX_ADDR  = tex_addr;
    SPAN_TEX_WIDTH = (unsigned int)tex_width | ((unsigned int)tex_height << 16);
    SPAN_S         = (unsigned int)s;
    SPAN_T         = (unsigned int)t;
    SPAN_SSTEP     = (unsigned int)sstep;
    SPAN_TSTEP     = (unsigned int)tstep;
    SPAN_LIGHT     = light;
    SPAN_LIGHTSTEP = 0;
    SPAN_CONTROL   = (unsigned int)count | 0x10000;  /* bit 16 = colormap enable */
}

/* Set light level for subsequent colormap-enabled spans. */
static inline void span_set_light(unsigned int light)
{
    SPAN_LIGHT = light;
    SPAN_LIGHTSTEP = 0;
}

/* Start a lit span using already programmed texture source and light level. */
static inline void span_draw_tex_lit(unsigned int fb_addr, int s, int t,
                                      int sstep, int tstep, int count)
{
    SPAN_FB_ADDR   = fb_addr;
    SPAN_S         = (unsigned int)s;
    SPAN_T         = (unsigned int)t;
    SPAN_SSTEP     = (unsigned int)sstep;
    SPAN_TSTEP     = (unsigned int)tstep;
    SPAN_CONTROL   = (unsigned int)count | 0x10000;
}

/* Set up constant parameters for surface cache building (call once per block).
 * blocksize is the mip block width/height (16, 8, 4, or 2). */
static inline void span_setup_surface(int blocksize)
{
    SPAN_TEX_WIDTH = (unsigned int)blocksize | ((unsigned int)blocksize << 16);
    SPAN_S         = 0;
    SPAN_SSTEP     = (1 << 16);  /* 1 texel per pixel */
    SPAN_T         = 0;
    SPAN_TSTEP     = 0;
}

/* Draw one row of a lit surface cache block (non-blocking).
 * dest/src are CPU byte addresses. light and lightstep are the colormap
 * light level and per-pixel step (both passed as unsigned int, may be signed). */
static inline void span_draw_surface_row(unsigned int dest, unsigned int src,
                                          unsigned int light, unsigned int lightstep,
                                          int count)
{
    SPAN_FB_ADDR   = dest;
    SPAN_TEX_ADDR  = src;
    SPAN_LIGHT     = light;
    SPAN_LIGHTSTEP = lightstep;
    SPAN_CONTROL   = (unsigned int)count | 0x10000;
}

/* Set turbulence phase for the current frame (7-bit, from cl.time * SPEED). */
static inline void span_set_turb_phase(int phase)
{
    SPAN_TURB_PHASE = (unsigned int)(phase & 127);
}

/* Start a turbulent span draw (non-blocking).
 * Texture must already be set via SPAN_TEX_ADDR/SPAN_TEX_WIDTH.
 * Hardware applies sine-wave distortion to s/t before texture fetch. */
static inline void span_draw_turb(unsigned int fb_addr, int s, int t,
                                   int sstep, int tstep, int count)
{
    SPAN_FB_ADDR = fb_addr;
    SPAN_S       = (unsigned int)s;
    SPAN_T       = (unsigned int)t;
    SPAN_SSTEP   = (unsigned int)sstep;
    SPAN_TSTEP   = (unsigned int)tstep;
    SPAN_CONTROL = (unsigned int)count | 0x20000;  /* bit 17 = turb enable */
}

/* Start a z-span draw (non-blocking).
 * z_addr is CPU byte address of short z-buffer destination.
 * Per pixel value written is (izi >> 16), then izi += izistep. */
static inline void span_z_draw(unsigned int z_addr, int izi, int izistep, int count)
{
    SPAN_Z_ADDR    = z_addr;
    SPAN_ZI        = (unsigned int)izi;
    SPAN_ZISTEP    = (unsigned int)izistep;
    SPAN_ZCONTROL  = (unsigned int)count;  /* triggers start */
}

/* Start a surface block draw (non-blocking).
 * Hardware autonomously iterates all rows, interpolating light bilinearly.
 * dest/src are CPU byte addresses. Light corners are 8.8 fixed-point values.
 * tex_step/dest_step are row strides in bytes. blockdivshift is log2(blocksize). */
static inline void span_draw_surface_block(
    unsigned int dest, unsigned int src,
    unsigned int light_tl, unsigned int light_tr,
    unsigned int light_bl, unsigned int light_br,
    unsigned int tex_step, unsigned int dest_step,
    int blockdivshift)
{
    SPAN_FB_ADDR    = dest;
    SPAN_TEX_ADDR   = src;
    SURF_LIGHT_TL   = light_tl;
    SURF_LIGHT_TR   = light_tr;
    SURF_LIGHT_BL   = light_bl;
    SURF_LIGHT_BR   = light_br;
    SURF_TEX_STEP   = tex_step;
    SURF_DEST_STEP  = dest_step;
    SURF_CONTROL    = (unsigned int)blockdivshift;  /* triggers start */
}

/* Check if span rasterizer is still running */
static inline int span_busy(void)
{
    return SPAN_STATUS & SPAN_STATUS_BUSY;
}

/* Check if at least one command slot is available (active + 2-entry FIFO, depth=3). */
static inline int span_can_accept(void)
{
    return SPAN_STATUS & SPAN_STATUS_CAN_ACCEPT;
}

/* Block until span completes */
static inline void span_wait(void)
{
    while (SPAN_STATUS & SPAN_STATUS_BUSY)
        ;
}

#endif /* SPAN_ACCEL_H */
