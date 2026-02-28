/*
 * snd_pocket.c -- Analogue Pocket sound driver for PocketQuake
 *
 * Implements SNDDMA_* interface for the FPGA audio FIFO.
 * Mixes at 11025 Hz, upsamples to 48 kHz via Bresenham, pushes to FPGA FIFO.
 * Optionally mixes in CD music from cd_pocket.c at the output stage.
 */

#include "quakedef.h"

// Stereo music sample from cd_pocket.c (writes L/R, returns 0 if silent)
extern int CDAudio_ReadSampleStereo(int *out_l, int *out_r);

// ============================================
// Audio MMIO registers (FPGA audio_output module)
// ============================================
#define AUDIO_SAMPLE    (*(volatile unsigned int *)0x4C000000)  // Write: push {L16, R16}
#define AUDIO_STATUS    (*(volatile unsigned int *)0x4C000004)  // Read: [11:0]=fifo level, [12]=full

#define AUDIO_FIFO_SIZE 4096
#define SND_RATE        11025

// DMA buffer: 8192 interleaved stereo samples (4096 frames, ~372ms at 11025 Hz)
#define SND_BUFFER_SIZE 8192
static short snd_buffer[SND_BUFFER_SIZE];

// Upsampling state (11025 -> 48000) with linear interpolation.
// 4.35:1 ratio with 16-bit source data — linear interpolation is smooth enough
// with full precision samples (the old harshness was from 8-bit quantization).
#define UPSAMPLE_ONE   32768
#define UPSAMPLE_STEP  ((SND_RATE * UPSAMPLE_ONE + 24000) / 48000)  /* = 7526 */
static int upsample_frac;
static int submit_src_pos;   // Source position in stereo frames (paintedtime units)

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

    memset(snd_buffer, 0, sizeof(snd_buffer));

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
// SNDDMA_Submit - push mixed audio to FPGA FIFO
// ============================================
void SNDDMA_Submit(void)
{
    int fifo_level;
    int fifo_space;

    if (!shm->buffer)
        return;

    // Check available FIFO space
    fifo_level = AUDIO_STATUS & 0xFFF;
    fifo_space = AUDIO_FIFO_SIZE - fifo_level - 16; // Leave margin
    if (fifo_space <= 0)
        return;

    // Push upsampled stereo audio to FIFO with linear interpolation
    short *buf = (short *)shm->buffer;
    int frames_mask = (shm->samples / 2) - 1;  // Mask for stereo frames
    int count = 0;
    while (count < fifo_space && submit_src_pos + 1 < paintedtime) {
        int i0 = (submit_src_pos & frames_mask) * 2;
        int i1 = ((submit_src_pos + 1) & frames_mask) * 2;

        // Linear interpolation between adjacent stereo frames
        int f = upsample_frac;  // 0..UPSAMPLE_ONE-1
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
        AUDIO_SAMPLE = ((unsigned int)out_l << 16) | out_r;
        count++;

        // Advance fractional position: step = 11025/48000 in fixed-point
        upsample_frac += UPSAMPLE_STEP;
        if (upsample_frac >= UPSAMPLE_ONE) {
            upsample_frac -= UPSAMPLE_ONE;
            submit_src_pos++;
        }
    }
}

// ============================================
// SNDDMA_Shutdown
// ============================================
void SNDDMA_Shutdown(void)
{
}
