/*
 * snd_pocket.c -- Analogue Pocket sound driver for PocketQuake
 *
 * Implements SNDDMA_* interface for the FPGA audio FIFO.
 * Mixes at 22050 Hz, upsamples to 48 kHz via Bresenham, pushes to FPGA FIFO.
 */

#include "quakedef.h"

// ============================================
// Audio MMIO registers (FPGA audio_output module)
// ============================================
#define AUDIO_SAMPLE    (*(volatile unsigned int *)0x4C000000)  // Write: push {L16, R16}
#define AUDIO_STATUS    (*(volatile unsigned int *)0x4C000004)  // Read: [11:0]=fifo level, [12]=full

#define AUDIO_FIFO_SIZE 4096
#define SND_RATE        22050

// DMA buffer: 16384 mono samples (~743ms at 22050 Hz)
#define SND_BUFFER_SIZE 16384
static short snd_buffer[SND_BUFFER_SIZE];

// Upsampling state (22050 -> 48000)
static int upsample_frac;
static int submit_src_pos;   // Source position in mono samples (paintedtime units)

// ============================================
// SNDDMA_Init
// ============================================
qboolean SNDDMA_Init(void)
{
    shm = &sn;

    shm->channels = 1;
    shm->samplebits = 16;
    shm->speed = SND_RATE;
    shm->samples = SND_BUFFER_SIZE;            // Mono samples in buffer
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
    // Simulate DMA playback position from realtime clock.
    // This tells the mixer how far along the "hardware" has consumed.
    shm->samplepos = ((int)(Sys_FloatTime() * shm->speed) * shm->channels) % shm->samples;
    return shm->samplepos;
}

// ============================================
// SNDDMA_Submit - push mixed audio to FPGA FIFO
// ============================================
void SNDDMA_Submit(void)
{
    int fifo_level;
    int fifo_space;
    int idx;
    int mask = shm->samples - 1;
    unsigned short sample;

    if (!shm->buffer)
        return;

    // Check available FIFO space
    fifo_level = AUDIO_STATUS & 0xFFF;
    fifo_space = AUDIO_FIFO_SIZE - fifo_level - 16; // Leave margin
    if (fifo_space <= 0)
        return;

    // Push upsampled audio to FIFO
    // Bresenham: for each 48 kHz output sample, we repeat the current
    // 22050 Hz source sample. When the fractional accumulator crosses
    // 48000, we advance to the next source sample.
    int count = 0;
    while (count < fifo_space && submit_src_pos < paintedtime) {
        idx = submit_src_pos & mask;
        sample = (unsigned short)((short *)shm->buffer)[idx];

        // Write mono sample to both L/R channels: {sample[15:0], sample[15:0]}
        AUDIO_SAMPLE = ((unsigned int)sample << 16) | sample;
        count++;

        // Advance source position with Bresenham (22050 / 48000)
        upsample_frac += SND_RATE;
        if (upsample_frac >= 48000) {
            upsample_frac -= 48000;
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
