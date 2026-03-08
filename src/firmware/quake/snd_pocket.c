/*
 * snd_pocket.c -- Analogue Pocket sound driver for PocketQuake
 *
 * Implements SNDDMA_* interface for the FPGA audio FIFO.
 * Mixes at 11025 Hz, upsamples to 48 kHz via Bresenham with linear
 * interpolation, mixes in CD music, and deposits ready-to-push stereo
 * frames into a BRAM ring buffer.
 *
 * The timer ISR (audio_timer.c) drains the BRAM ring into the FPGA FIFO.
 * Because the ISR only touches BRAM reads + MMIO writes (both local bus),
 * it avoids SDRAM arbiter contention with the span rasterizer that caused
 * hangs when the ISR accessed uncached SDRAM directly.
 *
 * Audio mix buffer is in uncached SDRAM (0x50xxxxxx alias) so the main-loop
 * mixer doesn't need D-cache flushes.  The BRAM ring buffer bridges the
 * two clock domains (main loop vs ISR) safely.
 */

#include "quakedef.h"

// Stereo music sample from cd_pocket.c (writes L/R, returns 0 if silent)
extern int CDAudio_ReadSampleStereo(int *out_l, int *out_r);

// ============================================
// Audio MMIO registers (FPGA audio_output module)
// ============================================
#define AUDIO_SAMPLE    (*(volatile unsigned int *)0x4C000000)  // Write: push {L16, R16}
#define AUDIO_STATUS    (*(volatile unsigned int *)0x4C000004)  // Read: [10:0]=fifo level, [11]=full

#define AUDIO_FIFO_SIZE 2048
#define SND_RATE        11025

// DMA buffer: 8192 interleaved stereo samples (4096 frames, ~372ms at 11025 Hz)
#define SND_BUFFER_SIZE 8192

// Audio mix buffer in regular cached SDRAM.  The timer ISR no longer reads
// from this buffer (it drains the BRAM ring instead), so D-cache coherency
// is not an issue — all access is from the main loop.
static short snd_buffer[SND_BUFFER_SIZE] __attribute__((aligned(4)));

// Upsampling state (11025 -> 48000) with linear interpolation.
// 4.35:1 ratio with 16-bit source data.
#define UPSAMPLE_ONE   32768
#define UPSAMPLE_STEP  ((SND_RATE * UPSAMPLE_ONE + 24000) / 48000)  /* = 7526 */

// ============================================
// BRAM output ring buffer (48 kHz stereo, packed {L16, R16})
// The main loop fills this; the timer ISR drains it to the FIFO.
// 1024 frames at 48 kHz = ~21ms of buffering.
// ============================================
#define OUT_RING_SIZE  1024
#define OUT_RING_MASK  (OUT_RING_SIZE - 1)

static unsigned int out_ring[OUT_RING_SIZE] __attribute__((section(".fastdata"), aligned(4)));
static unsigned int out_ring_wpos __attribute__((section(".fastdata")));
static unsigned int out_ring_rpos __attribute__((section(".fastdata")));

// Upsampling/mixing state — in BRAM for shared access
static int upsample_frac __attribute__((section(".fastdata")));
static int submit_src_pos __attribute__((section(".fastdata")));

// ============================================
// SNDDMA_Init
// ============================================
qboolean SNDDMA_Init(void)
{
    shm = &sn;

    shm->channels = 2;
    shm->samplebits = 16;
    shm->speed = SND_RATE;
    shm->samples = SND_BUFFER_SIZE;            // Total samples (L+R interleaved)
    shm->submission_chunk = 1;
    shm->samplepos = 0;
    shm->buffer = (unsigned char *)snd_buffer;
    shm->soundalive = true;
    shm->gamealive = true;
    shm->splitbuffer = false;

    paintedtime = 0;
    submit_src_pos = 0;
    upsample_frac = 0;
    out_ring_wpos = 0;
    out_ring_rpos = 0;

    // Zero the sound buffer
    for (int i = 0; i < SND_BUFFER_SIZE; i++)
        snd_buffer[i] = 0;

    return true;
}

// ============================================
// SNDDMA_GetDMAPos
// ============================================
int SNDDMA_GetDMAPos(void)
{
    shm->samplepos = (submit_src_pos * 2) & (shm->samples - 1);
    return shm->samplepos;
}

// ============================================
// SNDDMA_FillRing - upsample/mix into BRAM ring (main loop)
//
// Called from S_Update, S_ExtraUpdate, and span_pump_audio.
// Reads from uncached SDRAM mix buffer + CD music, writes to BRAM ring.
// ============================================
PQ_FASTTEXT void SNDDMA_FillRing(void)
{
    short *buf = snd_buffer;
    int fmask = (SND_BUFFER_SIZE / 2) - 1;

    // Fill ring until full or no more mixed data
    while ((out_ring_wpos - out_ring_rpos) < OUT_RING_SIZE &&
           submit_src_pos + 1 < paintedtime) {
        int i0 = (submit_src_pos & fmask) * 2;
        int i1 = ((submit_src_pos + 1) & fmask) * 2;

        // Linear interpolation between adjacent stereo frames
        int f = upsample_frac;
        int sfx_l = buf[i0]     + (((buf[i1]     - buf[i0])     * f) >> 15);
        int sfx_r = buf[i0 + 1] + (((buf[i1 + 1] - buf[i0 + 1]) * f) >> 15);

        // Mix in stereo music (resampled to 48 kHz in cd_pocket.c)
        int music_l, music_r;
        CDAudio_ReadSampleStereo(&music_l, &music_r);

        int left  = sfx_l + music_l;
        int right = sfx_r + music_r;

        // Clamp to 16-bit range
        if (left > 32767) left = 32767;
        else if (left < -32768) left = -32768;
        if (right > 32767) right = 32767;
        else if (right < -32768) right = -32768;

        unsigned short out_l = (unsigned short)(short)left;
        unsigned short out_r = (unsigned short)(short)right;
        out_ring[out_ring_wpos & OUT_RING_MASK] = ((unsigned int)out_l << 16) | out_r;
        out_ring_wpos++;

        // Advance fractional position: step = 11025/48000 in fixed-point
        upsample_frac += UPSAMPLE_STEP;
        if (upsample_frac >= UPSAMPLE_ONE) {
            upsample_frac -= UPSAMPLE_ONE;
            submit_src_pos++;
        }
    }
}

// ============================================
// SNDDMA_DrainRing - push BRAM ring to FPGA FIFO (timer ISR)
//
// Only accesses BRAM (out_ring) and MMIO (AUDIO_SAMPLE/STATUS).
// Both go through the local bus path — no SDRAM arbiter contention.
// ============================================
PQ_FASTTEXT void SNDDMA_DrainRing(void)
{
    int fifo_level = AUDIO_STATUS & 0x7FF;
    int fifo_space = AUDIO_FIFO_SIZE - fifo_level - 16;
    if (fifo_space <= 0)
        return;

    // Cap per-call work to keep ISR bounded (~5ms × 48kHz = 240 samples)
    if (fifo_space > 480)
        fifo_space = 480;

    unsigned int rp = out_ring_rpos;
    unsigned int wp = out_ring_wpos;
    int count = 0;

    while (count < fifo_space && rp != wp) {
        AUDIO_SAMPLE = out_ring[rp & OUT_RING_MASK];
        rp++;
        count++;
    }

    out_ring_rpos = rp;
}

// ============================================
// SNDDMA_Submit - legacy entry point
//
// When timer ISR is active, this is not called.
// When polling (no timer), fills ring then immediately drains to FIFO.
// ============================================
void SNDDMA_Submit(void)
{
    SNDDMA_FillRing();
    SNDDMA_DrainRing();
}

// ============================================
// SNDDMA_Shutdown
// ============================================
void SNDDMA_Shutdown(void)
{
}
