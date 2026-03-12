#ifndef SPAN_ACCEL_H
#define SPAN_ACCEL_H

/*
 * Hardware Span Rasterizer
 * - Textured span mode: offloads D_DrawSpans8 inner pixel loop.
 * - Z-span mode: offloads D_DrawZSpans short writes.
 */

/* Enable textured span offload on SDRAM-backed framebuffer path. */
#define HW_SPAN_ACCEL 1
#define HW_ZSPAN_ACCEL 1  /* Z-buffer in external SRAM, HW z-span writes */
#define HW_TURB_ACCEL 1
#define HW_SURFBLOCK_ACCEL 1
#define HW_PERSP_ACCEL 1  /* HW perspective correction in span rasterizer */
#define HW_COMBINED_Z 1   /* Combined texture + z-buffer write mode */
#define HW_ALIAS_ACCEL 1  /* HW alias polygon span rendering */
#define HW_SPRITE_ACCEL 1 /* HW sprite span rendering (persp + z-test + transparency) */

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

/* Perspective correction registers (slots 26-35) */
#define SPAN_PERSP_SDIVZ      (*(volatile unsigned int *)(SPAN_BASE + 0x68))
#define SPAN_PERSP_TDIVZ      (*(volatile unsigned int *)(SPAN_BASE + 0x6C))
#define SPAN_PERSP_ZI         (*(volatile unsigned int *)(SPAN_BASE + 0x70))
#define SPAN_PERSP_SDIVZ_STEP (*(volatile unsigned int *)(SPAN_BASE + 0x74))
#define SPAN_PERSP_TDIVZ_STEP (*(volatile unsigned int *)(SPAN_BASE + 0x78))
#define SPAN_PERSP_ZI_STEP    (*(volatile unsigned int *)(SPAN_BASE + 0x7C))
#define SPAN_PERSP_SADJUST    (*(volatile unsigned int *)(SPAN_BASE + 0x80))
#define SPAN_PERSP_TADJUST    (*(volatile unsigned int *)(SPAN_BASE + 0x84))
#define SPAN_PERSP_BBEXTENTS  (*(volatile unsigned int *)(SPAN_BASE + 0x88))
#define SPAN_PERSP_BBEXTENTT  (*(volatile unsigned int *)(SPAN_BASE + 0x8C))

/* Alias mode registers (slots 36-39) */
#define SPAN_ALIAS_PTEX   (*(volatile unsigned int *)(SPAN_BASE + 0x90))
#define SPAN_ALIAS_STSTEP (*(volatile unsigned int *)(SPAN_BASE + 0x94))
#define SPAN_ALIAS_SFRAC  (*(volatile unsigned int *)(SPAN_BASE + 0x98))
#define SPAN_ALIAS_TFRAC  (*(volatile unsigned int *)(SPAN_BASE + 0x9C))

/* UV MAD origin/step registers (slots 40-49, sticky per-surface) */
#define SPAN_PERSP_SDIVZ_ORIGIN  (*(volatile unsigned int *)(SPAN_BASE + 0xA0))
#define SPAN_PERSP_TDIVZ_ORIGIN  (*(volatile unsigned int *)(SPAN_BASE + 0xA4))
#define SPAN_PERSP_ZI_ORIGIN     (*(volatile unsigned int *)(SPAN_BASE + 0xA8))
#define SPAN_PERSP_SDIVZ_STEPV   (*(volatile unsigned int *)(SPAN_BASE + 0xAC))
#define SPAN_PERSP_TDIVZ_STEPV   (*(volatile unsigned int *)(SPAN_BASE + 0xB0))
#define SPAN_PERSP_ZI_STEPV      (*(volatile unsigned int *)(SPAN_BASE + 0xB4))
#define SPAN_PERSP_SDIVZ_STEPU   (*(volatile unsigned int *)(SPAN_BASE + 0xB8))
#define SPAN_PERSP_TDIVZ_STEPU   (*(volatile unsigned int *)(SPAN_BASE + 0xBC))
#define SPAN_PERSP_ZI_STEPU      (*(volatile unsigned int *)(SPAN_BASE + 0xC0))
#define SPAN_UV                  (*(volatile unsigned int *)(SPAN_BASE + 0xC4))

/* HW address generation registers (slots 50-53, sticky per-frame) */
#define SPAN_FB_BASE             (*(volatile unsigned int *)(SPAN_BASE + 0xC8))
#define SPAN_FB_STRIDE           (*(volatile unsigned int *)(SPAN_BASE + 0xCC))
#define SPAN_Z_BASE              (*(volatile unsigned int *)(SPAN_BASE + 0xD0))
#define SPAN_Z_STRIDE            (*(volatile unsigned int *)(SPAN_BASE + 0xD4))

/* DMA span list registers (slots 54-56) */
#define SPAN_DMA_BASE            (*(volatile unsigned int *)(SPAN_BASE + 0xD8))
#define SPAN_DMA_KICK            (*(volatile unsigned int *)(SPAN_BASE + 0xDC))
#define SPAN_DMA_STATUS          (*(volatile unsigned int *)(SPAN_BASE + 0xDC))
#define SPAN_DMA_CTRL            (*(volatile unsigned int *)(SPAN_BASE + 0xE0))

/* Pack a span descriptor: {count[29:20], v[19:10], u[9:0]} */
#define SPAN_DESC_PACK(u, v, count) \
    (((unsigned int)((count) & 0x3FF) << 20) | \
     ((unsigned int)((v) & 0x3FF) << 10) | \
     ((unsigned int)((u) & 0x3FF)))

#define SPAN_CTL_CMAP   0x10000   /* bit 16: colormap enable */
#define SPAN_CTL_TURB   0x20000   /* bit 17: turbulence enable */
#define SPAN_CTL_PERSP  0x40000   /* bit 18: perspective enable */
#define SPAN_CTL_COMBZ  0x80000   /* bit 19: combined z-write */
#define SPAN_CTL_ALIAS  0x100000  /* bit 20: alias texture stepping */
#define SPAN_CTL_NOZ    0x200000  /* bit 21: skip all z-test/z-write */
#define SPAN_CTL_SPRITE 0x400000  /* bit 22: sprite mode (transparency + z-test) */
#define SPAN_CTL_UV     0x800000  /* bit 23: UV mode (HW computes sdivz/tdivz/zi from u,v) */

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

/* Service audio during hardware wait loops.
 * Fill the BRAM ring buffer so the timer ISR can drain it to the FIFO.
 * When timer ISR is inactive, also drain directly to the FIFO. */
extern void SNDDMA_FillRing(void);
extern void SNDDMA_Submit(void);
extern int audio_timer_active;
static inline void span_pump_audio(void)
{
    if (audio_timer_active)
        SNDDMA_FillRing();
    else
        SNDDMA_Submit();
}

/* Block until span completes, servicing audio in the meantime */
static inline void span_wait(void)
{
    while (SPAN_STATUS & SPAN_STATUS_BUSY)
        span_pump_audio();
}

/* Start a textured span draw (non-blocking).
 * fb_addr/tex_addr are CPU byte addresses (0x10xxxxxx or 0x50xxxxxx SDRAM alias).
 * s, t, sstep, tstep are 16.16 fixed-point.
 * tex_width/tex_height are texture dimensions in pixels (hardware clamps s/t). */
static inline void span_draw(unsigned int fb_addr, unsigned int tex_addr,
                              int tex_width, int tex_height, int s, int t,
                              int sstep, int tstep, int count)
{
    span_wait();
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
    span_wait();
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
    span_wait();
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
    span_wait();
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
    span_wait();
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
    span_wait();
    SPAN_FB_ADDR = fb_addr;
    SPAN_S       = (unsigned int)s;
    SPAN_T       = (unsigned int)t;
    SPAN_SSTEP   = (unsigned int)sstep;
    SPAN_TSTEP   = (unsigned int)tstep;
    SPAN_CONTROL = (unsigned int)count | 0x20000;  /* bit 17 = turb enable */
}

/* Start a turbulent span with combined z-buffer write (non-blocking).
 * Texture must already be set via SPAN_TEX_ADDR/SPAN_TEX_WIDTH.
 * SPAN_ZISTEP must be set per-surface before the span loop.
 * z_addr is byte address of short z-buffer, izi is starting fixed-point izi. */
static inline void span_draw_turb_z(unsigned int fb_addr, int s, int t,
                                     int sstep, int tstep, int count,
                                     unsigned int z_addr, int izi)
{
    SPAN_Z_ADDR  = z_addr;
    SPAN_ZI      = (unsigned int)izi;
    SPAN_FB_ADDR = fb_addr;
    SPAN_S       = (unsigned int)s;
    SPAN_T       = (unsigned int)t;
    SPAN_SSTEP   = (unsigned int)sstep;
    SPAN_TSTEP   = (unsigned int)tstep;
    SPAN_CONTROL = (unsigned int)count | 0xA0000;  /* bits 17+19 = turb + combined z */
}

/* Start a z-span draw (non-blocking).
 * z_addr is CPU byte address of short z-buffer destination.
 * Per pixel value written is (izi >> 16), then izi += izistep. */
static inline void span_z_draw(unsigned int z_addr, int izi, int izistep, int count)
{
    span_wait();
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
    span_wait();
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

/* Check if at least one command slot is available (active + 3-entry FIFO, depth=4). */
static inline int span_can_accept(void)
{
    return SPAN_STATUS & SPAN_STATUS_CAN_ACCEPT;
}

/* Set sticky perspective parameters (call once per surface / D_DrawSpans8 call).
 * Steps are d_*stepu float values; converted to 16.16 fixed-point * 16 internally.
 * Q16.16 gives range ±32768 (vs Q8.24's ±128) to prevent overflow on edge-on surfaces.
 * Hardware CLZ normalization is format-independent: SCALE cancels in sdivz/zi division.
 * sadjust/tadjust and bbextents/bbextentt are 16.16 fixed-point integers. */
static inline void span_set_perspective(float sdivzstepu, float tdivzstepu, float zistepu,
                                         int sadjust_val, int tadjust_val,
                                         int bbextents_val, int bbextentt_val)
{
    SPAN_PERSP_SDIVZ_STEP = (unsigned int)(int)(sdivzstepu * 16.0f * 65536.0f);
    SPAN_PERSP_TDIVZ_STEP = (unsigned int)(int)(tdivzstepu * 16.0f * 65536.0f);
    SPAN_PERSP_ZI_STEP    = (unsigned int)(int)(zistepu * 16.0f * 65536.0f);
    SPAN_PERSP_SADJUST    = (unsigned int)sadjust_val;
    SPAN_PERSP_TADJUST    = (unsigned int)tadjust_val;
    SPAN_PERSP_BBEXTENTS  = (unsigned int)bbextents_val;
    SPAN_PERSP_BBEXTENTT  = (unsigned int)bbextentt_val;
}

/* Dispatch entire span with HW perspective correction (non-blocking).
 * sdivz/tdivz/zi are float values at span origin, converted to Q16.16.
 * Hardware internally subdivides into 16-pixel affine chunks. */
static inline void span_draw_persp(unsigned int fb_addr, float sdivz, float tdivz,
                                    float zi, int count)
{
    SPAN_FB_ADDR     = fb_addr;
    SPAN_PERSP_SDIVZ = (unsigned int)(int)(sdivz * 65536.0f);
    SPAN_PERSP_TDIVZ = (unsigned int)(int)(tdivz * 65536.0f);
    SPAN_PERSP_ZI    = (unsigned int)(int)(zi * 65536.0f);
    SPAN_CONTROL     = (unsigned int)count | 0x40000;  /* bit 18 = perspective enable */
}

/* Dispatch span with HW perspective correction + combined z-buffer write.
 * Writes z-values alongside textured pixels using the SRAM interface.
 * z_addr is byte address of short z-buffer, izi is starting fixed-point izi. */
static inline void span_draw_persp_z(unsigned int fb_addr, float sdivz, float tdivz,
                                      float zi, unsigned int z_addr, int izi, int count)
{
    SPAN_Z_ADDR      = z_addr;
    SPAN_ZI          = (unsigned int)izi;
    SPAN_FB_ADDR     = fb_addr;
    SPAN_PERSP_SDIVZ = (unsigned int)(int)(sdivz * 65536.0f);
    SPAN_PERSP_TDIVZ = (unsigned int)(int)(tdivz * 65536.0f);
    SPAN_PERSP_ZI    = (unsigned int)(int)(zi * 65536.0f);
    SPAN_CONTROL     = (unsigned int)count | 0xC0000;  /* bits 18+19 = persp + combined z */
}

/* Set sticky perspective parameters with UV MAD origins and steps.
 * Called once per surface. Hardware computes sdivz/tdivz/zi per-span
 * from origins + steps * u,v, eliminating all per-span float math.
 * Also sets the per-16px step registers for HW perspective subdivision. */
static inline void span_set_perspective_uv(
    float sdivzstepu, float tdivzstepu, float zistepu,
    float sdivzstepv, float tdivzstepv, float zistepv,
    float sdivzorigin, float tdivzorigin, float ziorigin,
    int sadjust_val, int tadjust_val,
    int bbextents_val, int bbextentt_val)
{
    /* Per-16px step registers (existing, used by HW perspective subdivision) */
    SPAN_PERSP_SDIVZ_STEP = (unsigned int)(int)(sdivzstepu * 16.0f * 65536.0f);
    SPAN_PERSP_TDIVZ_STEP = (unsigned int)(int)(tdivzstepu * 16.0f * 65536.0f);
    SPAN_PERSP_ZI_STEP    = (unsigned int)(int)(zistepu * 16.0f * 65536.0f);
    /* UV MAD origin registers (Q8.24: 24 fractional bits for precision) */
    SPAN_PERSP_SDIVZ_ORIGIN = (unsigned int)(int)(sdivzorigin * 16777216.0f);
    SPAN_PERSP_TDIVZ_ORIGIN = (unsigned int)(int)(tdivzorigin * 16777216.0f);
    SPAN_PERSP_ZI_ORIGIN    = (unsigned int)(int)(ziorigin * 16777216.0f);
    /* UV MAD per-pixel step registers (Q8.24) */
    SPAN_PERSP_SDIVZ_STEPV  = (unsigned int)(int)(sdivzstepv * 16777216.0f);
    SPAN_PERSP_TDIVZ_STEPV  = (unsigned int)(int)(tdivzstepv * 16777216.0f);
    SPAN_PERSP_ZI_STEPV     = (unsigned int)(int)(zistepv * 16777216.0f);
    SPAN_PERSP_SDIVZ_STEPU  = (unsigned int)(int)(sdivzstepu * 16777216.0f);
    SPAN_PERSP_TDIVZ_STEPU  = (unsigned int)(int)(tdivzstepu * 16777216.0f);
    SPAN_PERSP_ZI_STEPU     = (unsigned int)(int)(zistepu * 16777216.0f);
    /* Adjust/clamp registers */
    SPAN_PERSP_SADJUST    = (unsigned int)sadjust_val;
    SPAN_PERSP_TADJUST    = (unsigned int)tadjust_val;
    SPAN_PERSP_BBEXTENTS  = (unsigned int)bbextents_val;
    SPAN_PERSP_BBEXTENTT  = (unsigned int)bbextentt_val;
}

/* Set HW address generation base/stride (call once per surface or frame).
 * Hardware computes fb_addr = fb_base + fb_stride*v + u
 *                   z_addr  = z_base  + z_stride*v + u*2  */
static inline void span_set_framebuffer(unsigned int fb_base, int fb_stride,
    unsigned int z_base, int z_stride_bytes)
{
    SPAN_FB_BASE   = fb_base;
    SPAN_FB_STRIDE = (unsigned int)fb_stride;
    SPAN_Z_BASE    = z_base;
    SPAN_Z_STRIDE  = (unsigned int)z_stride_bytes;
}

/* Dispatch span with UV mode + combined z-buffer write (non-blocking).
 * Hardware computes sdivz/tdivz/zi/izi AND fb_addr/z_addr from u,v.
 * Only 2 MMIO writes per span. */
static inline void span_draw_persp_z_uv(int u, int v, int count)
{
    SPAN_UV      = ((unsigned int)(v & 0xFFFF) << 16) | (u & 0xFFFF);
    SPAN_CONTROL = (unsigned int)count | SPAN_CTL_PERSP | SPAN_CTL_COMBZ | SPAN_CTL_UV;
}

/* Dispatch span with UV mode, no z-write (non-blocking). */
static inline void span_draw_persp_uv(int u, int v, int count)
{
    SPAN_UV      = ((unsigned int)(v & 0xFFFF) << 16) | (u & 0xFFFF);
    SPAN_CONTROL = (unsigned int)count | SPAN_CTL_PERSP | SPAN_CTL_UV;
}

/* Set sticky alias stepping parameters (call once per triangle).
 * ststepxwhole = skinwidth * (r_tstepx >> 16) + (r_sstepx >> 16) (combined whole step).
 * sstepxfrac = r_sstepx & 0xFFFF, tstepxfrac = r_tstepx & 0xFFFF (fractional steps).
 * skinwidth = texture width in pixels (for t carry). */
static inline void span_alias_setup(int ststepxwhole, int sstepxfrac,
                                     int tstepxfrac, int skinwidth)
{
    SPAN_ALIAS_STSTEP = (unsigned int)ststepxwhole;
    SPAN_ALIAS_SFRAC  = ((unsigned int)(skinwidth & 0xFFFF) << 16) | (sstepxfrac & 0xFFFF);
    SPAN_ALIAS_TFRAC  = (unsigned int)(tstepxfrac & 0xFFFF);
}

/* Dispatch alias span with combined z-write (entities).
 * ptex is absolute SDRAM byte address of texture start for this span.
 * sfrac/tfrac are initial fractional s/t values (16-bit).
 * light is pre-shifted light level (light & 0xFF00).
 * z_addr is byte address of short z-buffer, izi is starting fixed-point izi. */
static inline void span_draw_alias_z(unsigned int fb_addr, unsigned int ptex,
                                      int sfrac, int tfrac, int light,
                                      unsigned int z_addr, int izi, int count)
{
    SPAN_ALIAS_PTEX = ptex;
    SPAN_Z_ADDR     = z_addr;
    SPAN_ZI         = (unsigned int)izi;
    SPAN_FB_ADDR    = fb_addr;
    SPAN_S          = (unsigned int)(sfrac & 0xFFFF);
    SPAN_T          = (unsigned int)(tfrac & 0xFFFF);
    SPAN_LIGHT      = (unsigned int)light;
    SPAN_CONTROL    = (unsigned int)count | SPAN_CTL_ALIAS | SPAN_CTL_COMBZ;
}

/* Dispatch alias span without z-write (viewmodel / NoZ).
 * Same as span_draw_alias_z but skips all z-buffer operations. */
static inline void span_draw_alias_noz(unsigned int fb_addr, unsigned int ptex,
                                        int sfrac, int tfrac, int light,
                                        int count)
{
    SPAN_ALIAS_PTEX = ptex;
    SPAN_FB_ADDR    = fb_addr;
    SPAN_S          = (unsigned int)(sfrac & 0xFFFF);
    SPAN_T          = (unsigned int)(tfrac & 0xFFFF);
    SPAN_LIGHT      = (unsigned int)light;
    SPAN_CONTROL    = (unsigned int)count | SPAN_CTL_ALIAS | SPAN_CTL_NOZ;
}

/* Dispatch sprite span with HW perspective + z-test + transparency.
 * Texture source must be set via span_set_texture() before the span loop.
 * Perspective params must be set via span_set_perspective() per surface.
 * SPAN_ZISTEP must be set per surface.
 * z_addr is byte address of short z-buffer, izi is starting fixed-point izi. */
static inline void span_draw_sprite(unsigned int fb_addr, float sdivz, float tdivz,
                                     float zi, unsigned int z_addr, int izi, int count)
{
    SPAN_Z_ADDR      = z_addr;
    SPAN_ZI          = (unsigned int)izi;
    SPAN_FB_ADDR     = fb_addr;
    SPAN_PERSP_SDIVZ = (unsigned int)(int)(sdivz * 65536.0f);
    SPAN_PERSP_TDIVZ = (unsigned int)(int)(tdivz * 65536.0f);
    SPAN_PERSP_ZI    = (unsigned int)(int)(zi * 65536.0f);
    SPAN_CONTROL     = (unsigned int)count | SPAN_CTL_PERSP | SPAN_CTL_COMBZ | SPAN_CTL_SPRITE;
}

#endif /* SPAN_ACCEL_H */
