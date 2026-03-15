/*
 * Hardware CalcGradients Accelerator
 * Replaces D_CalcGradients() with FPGA FP32 computation engine.
 * Reuses the scanline_engine address space at 0x60000000.
 */

#ifndef SCANLINE_ACCEL_H
#define SCANLINE_ACCEL_H

#define HW_SCANLINE_ACCEL 0
#define HW_CALCGRAD_ACCEL 1

#define CALCGRAD_BASE         0x60000000u

/* Helper to write a float as raw bits to MMIO */
static inline void calcgrad_write_float(unsigned int offset, float f)
{
    union { float f; unsigned int u; } conv;
    conv.f = f;
    *(volatile unsigned int *)(CALCGRAD_BASE + offset) = conv.u;
}

/* Helper to read raw MMIO bits as float */
static inline float calcgrad_read_float(unsigned int offset)
{
    union { float f; unsigned int u; } conv;
    conv.u = *(volatile unsigned int *)(CALCGRAD_BASE + offset);
    return conv.f;
}

static inline int calcgrad_read_int(unsigned int offset)
{
    return *(volatile int *)(CALCGRAD_BASE + offset);
}

static inline void calcgrad_write_int(unsigned int offset, unsigned int val)
{
    *(volatile unsigned int *)(CALCGRAD_BASE + offset) = val;
}

/* Frame constants (write once per frame, or when view matrix changes) */
#define CG_VRIGHT0    0x00
#define CG_VRIGHT1    0x04
#define CG_VRIGHT2    0x08
#define CG_VUP0       0x0C
#define CG_VUP1       0x10
#define CG_VUP2       0x14
#define CG_VPN0       0x18
#define CG_VPN1       0x1C
#define CG_VPN2       0x20
#define CG_XSCALEINV  0x24
#define CG_YSCALEINV  0x28
#define CG_XCENTER    0x2C
#define CG_YCENTER    0x30
#define CG_MODELORG0  0x34
#define CG_MODELORG1  0x38
#define CG_MODELORG2  0x3C

/* Per-surface inputs */
#define CG_SVEC0      0x40
#define CG_SVEC1      0x44
#define CG_SVEC2      0x48
#define CG_SVEC3      0x4C
#define CG_TVEC0      0x50
#define CG_TVEC1      0x54
#define CG_TVEC2      0x58
#define CG_TVEC3      0x5C
#define CG_MIPLEVEL   0x60
#define CG_TEXMINS    0x64  /* {texmins_t[31:16], texmins_s[15:0]} */
#define CG_EXTENTS    0x68  /* {extents_t[31:16], extents_s[15:0]} */
#define CG_KICK       0x6C  /* Write any value to start */

/* Results (read after busy clears) */
#define CG_SDIVZSTEPU   0x80
#define CG_TDIVZSTEPU   0x84
#define CG_SDIVZSTEPV   0x88
#define CG_TDIVZSTEPV   0x8C
#define CG_SDIVZORIGIN  0x90
#define CG_TDIVZORIGIN  0x94
#define CG_SADJUST      0x98
#define CG_TADJUST      0x9C
#define CG_BBEXTENTS    0xA0
#define CG_BBEXTENTT    0xA4
#define CG_STATUS       0xA8  /* bit0 = busy */

static inline void calcgrad_wait(void)
{
    while (*(volatile unsigned int *)(CALCGRAD_BASE + CG_STATUS) & 1)
        ;
}

#endif /* SCANLINE_ACCEL_H */
