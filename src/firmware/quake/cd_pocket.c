/*
 * cd_pocket.c -- CD audio streaming for PocketQuake (HW resampler)
 *
 * Bridge DMA loads CD audio into SDRAM, CPU reads via uncached alias
 * (zero D-cache pollution) and pushes raw samples to HW resampler FIFO.
 * Timer ISR feeds the FIFO at 200 Hz for glitch-free playback at any FPS.
 *
 * The HW resampler handles 44100→48000 Hz resampling, volume, and mixing.
 *
 * Data slot IDs 10-19 map to Quake CD tracks 2-11.
 */

#include "quakedef.h"
#include "../dataslot.h"

#define TRACK_SLOT_ID(track) ((track) + 8)
#define TRACK_MIN  2
#define TRACK_MAX  11

/* Ring buffer in SDRAM — accessed ONLY through uncached alias.
 * 16384 stereo frames = 64KB, power-of-two. */
#define MUSIC_BUF_FRAMES   16384
#define MUSIC_BUF_MASK     (MUSIC_BUF_FRAMES - 1)
#define MUSIC_BUF_ADDR     0x13F00000
#define MUSIC_BUF_UC       ((volatile unsigned int *)SDRAM_UNCACHED(MUSIC_BUF_ADDR))

#define MUSIC_DMA_CHUNK    (16 * 1024)

/* HW resampler MMIO */
#define MUSIC_CTRL       (*(volatile unsigned int *)0x4C000008)
#define MUSIC_VOLUME     (*(volatile unsigned int *)0x4C00000C)
#define MUSIC_FIFO_LEVEL (*(volatile unsigned int *)0x4C000014)
#define MUSIC_DATA       (*(volatile unsigned int *)0x4C00001C)

#define MUSIC_CTRL_ENABLE  (1 << 0)
#define MUSIC_CTRL_PAUSE   (1 << 1)
#define HW_FIFO_DEPTH      512

static int  cd_playing;
static int  cd_looping;
static byte cd_track;
static int  cd_slot_id;
static unsigned int cd_file_offset;

/* Ring buffer positions (monotonically increasing frame counts) */
static volatile unsigned int music_write_pos;
static volatile unsigned int music_read_pos;

static int cd_available;
static int cd_dma_pending;
static unsigned int cd_dma_frames;

static int CDAudio_StartChunk(void);

void CDAudio_DataslotYield(void)
{
    if (!cd_dma_pending)
        return;

    int rc;
    while ((rc = dataslot_read_poll()) == 0)
        ;

    cd_dma_pending = 0;

    if (rc > 0) {
        volatile unsigned int *src = (volatile unsigned int *)SDRAM_UNCACHED(DMA_BUFFER);
        unsigned int wp = music_write_pos;
        for (unsigned int i = 0; i < cd_dma_frames; i++)
            MUSIC_BUF_UC[(wp + i) & MUSIC_BUF_MASK] = src[i];
        music_write_pos = wp + cd_dma_frames;
        cd_file_offset += cd_dma_frames * 4;
    } else if (rc < 0) {
        if (cd_looping)
            cd_file_offset = 0;
        else
            cd_playing = 0;
    }
}

static int CDAudio_Probe(void)
{
    int rc = dataslot_read(TRACK_SLOT_ID(2), 0, (void *)(uintptr_t)DMA_BUFFER, 4);
    return (rc >= 0) ? 1 : 0;
}

/*
 * Push frames from uncached SDRAM ring to HW resampler FIFO.
 * Called from timer ISR (200 Hz) and SNDDMA_FillRing.
 * Uncached SDRAM reads: zero D-cache pollution, ~0.26% bus time.
 */
void CDAudio_CopyToHW(void)
{
    if (!cd_playing)
        return;

    unsigned int avail = music_write_pos - music_read_pos;
    unsigned int hw_space = HW_FIFO_DEPTH - (MUSIC_FIFO_LEVEL & 0x3FF);

    unsigned int count = avail < hw_space ? avail : hw_space;
    if (count > 128)
        count = 128;

    unsigned int rp = music_read_pos;
    for (unsigned int i = 0; i < count; i++)
        MUSIC_DATA = MUSIC_BUF_UC[(rp + i) & MUSIC_BUF_MASK];
    music_read_pos = rp + count;
}

static int CDAudio_StartChunk(void)
{
    if (music_write_pos - music_read_pos >= MUSIC_BUF_FRAMES - MUSIC_DMA_CHUNK / 4)
        return -1;

    cd_dma_frames = MUSIC_DMA_CHUNK / 4;
    dataslot_read_start(cd_slot_id, cd_file_offset,
                        (void *)(uintptr_t)DMA_BUFFER, MUSIC_DMA_CHUNK);
    cd_dma_pending = 1;
    return 0;
}

static void CDAudio_Refill(void)
{
    if (!cd_playing)
        return;

    if (cd_dma_pending) {
        int rc = dataslot_read_poll();
        if (rc == 0)
            return;

        cd_dma_pending = 0;

        if (rc < 0) {
            if (cd_looping)
                cd_file_offset = 0;
            else {
                cd_playing = 0;
                return;
            }
        } else {
            volatile unsigned int *src = (volatile unsigned int *)SDRAM_UNCACHED(DMA_BUFFER);
            unsigned int wp = music_write_pos;
            for (unsigned int i = 0; i < cd_dma_frames; i++)
                MUSIC_BUF_UC[(wp + i) & MUSIC_BUF_MASK] = src[i];
            music_write_pos = wp + cd_dma_frames;
            cd_file_offset += cd_dma_frames * 4;
        }
    }

    if (!cd_dma_pending)
        CDAudio_StartChunk();
}

void CDAudio_Play(byte track, qboolean looping)
{
    if (!cd_available)
        return;
    if (track < TRACK_MIN || track > TRACK_MAX)
        return;

    CDAudio_Stop();

    cd_track = track;
    cd_slot_id = TRACK_SLOT_ID(track);
    cd_file_offset = 0;
    cd_looping = looping;
    cd_playing = 1;
    music_write_pos = 0;
    music_read_pos = 0;

    for (int i = 0; i < 4; i++) {
        int rc = dataslot_read(cd_slot_id, cd_file_offset,
                               (void *)(uintptr_t)DMA_BUFFER, MUSIC_DMA_CHUNK);
        if (rc < 0) {
            if (i == 0) {
                Con_Printf("CD Audio: track %d not found\n", track);
                cd_playing = 0;
                return;
            }
            break;
        }
        volatile unsigned int *src = (volatile unsigned int *)SDRAM_UNCACHED(DMA_BUFFER);
        unsigned int wp = music_write_pos;
        for (unsigned int j = 0; j < MUSIC_DMA_CHUNK / 4; j++)
            MUSIC_BUF_UC[(wp + j) & MUSIC_BUF_MASK] = src[j];
        music_write_pos = wp + MUSIC_DMA_CHUNK / 4;
        cd_file_offset += MUSIC_DMA_CHUNK;
    }
    cd_dma_pending = 0;

    CDAudio_CopyToHW();

    extern cvar_t bgmvolume;
    int vol = (int)(bgmvolume.value * 256);
    if (vol < 0) vol = 0;
    if (vol > 256) vol = 256;
    MUSIC_VOLUME = vol;
    MUSIC_CTRL = MUSIC_CTRL_ENABLE;
}

void CDAudio_Stop(void)
{
    MUSIC_CTRL = 0;
    cd_playing = 0;
    cd_dma_pending = 0;
    music_write_pos = 0;
    music_read_pos = 0;
}

void CDAudio_Pause(void)
{
    if (cd_playing)
        MUSIC_CTRL = MUSIC_CTRL_ENABLE | MUSIC_CTRL_PAUSE;
}

void CDAudio_Resume(void)
{
    if (cd_playing)
        MUSIC_CTRL = MUSIC_CTRL_ENABLE;
}

void CDAudio_Update(void)
{
    if (!cd_available)
        return;

    extern cvar_t bgmvolume;
    int vol = (int)(bgmvolume.value * 256);
    if (vol < 0) vol = 0;
    if (vol > 256) vol = 256;
    MUSIC_VOLUME = vol;

    if (!cd_playing)
        return;

    CDAudio_Refill();
}

int CDAudio_Init(void)
{
    cd_playing = 0;
    cd_available = 0;
    cd_dma_pending = 0;
    MUSIC_CTRL = 0;

    cd_available = CDAudio_Probe();
    dataslot_yield_hook = CDAudio_DataslotYield;

    if (cd_available)
        Con_Printf("CD Audio: HW resampler ready\n");
    else
        Con_Printf("CD Audio: no CD tracks (optional)\n");

    return 0;
}

void CDAudio_Shutdown(void)
{
    CDAudio_Stop();
}
