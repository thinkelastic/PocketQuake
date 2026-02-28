/*
 * cd_pocket.c -- CD audio streaming for PocketQuake
 *
 * Streams raw CD-ROM audio tracks (.bin) from SD card via APF data slots.
 * Format: 44100 Hz, 16-bit signed little-endian, stereo (Red Book CD audio).
 * Resampled to 48000 Hz and mixed into I2S output in SNDDMA_Submit.
 *
 * Data slot IDs 10-19 map to Quake CD tracks 2-11.
 * If the .bin files are not present, music is silently disabled.
 *
 * Non-blocking: uses async dataslot_read_start/poll to avoid stalling
 * the CPU during rendering.  At most one DMA completion per frame.
 */

#include "quakedef.h"
#include "../dataslot.h"

/* Data slot ID for a given CD track number (tracks 2-11 -> slots 10-19) */
#define TRACK_SLOT_ID(track) ((track) + 8)
#define TRACK_MIN  2
#define TRACK_MAX  11

/* Ring buffer: 128KB = 32768 stereo frames (L+R = 4 bytes each) = ~0.74s at 44100 Hz.
 * Large enough to survive level load transitions (~0.5s at 1-2fps).
 * Placed in BSS (SDRAM). Must be power-of-two for masking. */
#define MUSIC_BUF_FRAMES   32768
#define MUSIC_BUF_MASK     (MUSIC_BUF_FRAMES - 1)
static short music_buffer[MUSIC_BUF_FRAMES * 2];  /* interleaved L, R */

/* Streaming state */
static int  cd_playing;
static int  cd_paused;
static int  cd_looping;
static byte cd_track;
static int  cd_slot_id;
static unsigned int cd_file_offset;  /* Current byte offset into raw PCM */

/* Ring buffer positions (in stereo frames) */
static unsigned int music_write_pos;
static unsigned int music_read_pos;

/* Resampling state: 44100 -> 48000 with linear interpolation */
#define RESAMPLE_ONE    32768
#define RESAMPLE_STEP   ((44100 * RESAMPLE_ONE + 24000) / 48000)  /* = 30106 */
static int resample_frac;

/* DMA refill: read 16KB chunks from SD card.
 * Must keep up with 176KB/sec consumption (44100 Hz stereo).
 * At 15fps: 15 * 16KB = 240KB/sec — sufficient headroom. */
#define MUSIC_DMA_CHUNK  (16 * 1024)

/* Volume (0-256, 256 = full volume) */
static int cd_volume = 256;

static int cd_available;

/* Async DMA state */
static int  cd_dma_pending;
static unsigned int cd_dma_frames;

/* Forward declarations for static helpers */
static void CDAudio_CopyChunk(unsigned int frames);
static int  CDAudio_StartChunk(void);

/*
 * Yield the dataslot for a blocking read by another caller (e.g., pak file I/O).
 * If an async CD DMA is in flight, wait for it to complete first.
 */
void CDAudio_DataslotYield(void)
{
    if (!cd_dma_pending)
        return;

    /* Busy-wait for the in-flight DMA to finish */
    int rc;
    while ((rc = dataslot_read_poll()) == 0)
        ;

    cd_dma_pending = 0;

    if (rc > 0) {
        CDAudio_CopyChunk(cd_dma_frames);
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
    int rc = dataslot_read(TRACK_SLOT_ID(2), 0, (void *)DMA_BUFFER, 4);
    return (rc >= 0) ? 1 : 0;
}

static void CDAudio_CopyChunk(unsigned int frames)
{
    volatile short *src = (volatile short *)SDRAM_UNCACHED(DMA_BUFFER);
    unsigned int wp = music_write_pos;

    for (unsigned int i = 0; i < frames; i++) {
        unsigned int idx = (wp & MUSIC_BUF_MASK) * 2;
        music_buffer[idx]     = src[i * 2];
        music_buffer[idx + 1] = src[i * 2 + 1];
        wp++;
    }

    music_write_pos = wp;
}

static int CDAudio_StartChunk(void)
{
    if (music_write_pos - music_read_pos >= MUSIC_BUF_FRAMES - MUSIC_DMA_CHUNK / 4)
        return -1;

    cd_dma_frames = MUSIC_DMA_CHUNK / 4;
    dataslot_read_start(cd_slot_id, cd_file_offset, (void *)DMA_BUFFER, MUSIC_DMA_CHUNK);
    cd_dma_pending = 1;
    return 0;
}

/*
 * Non-blocking refill: poll for DMA completion, copy data, start next.
 * Called from CDAudio_Update() once per frame.
 */
static void CDAudio_Refill(void)
{
    if (!cd_playing || cd_paused)
        return;

    if (cd_dma_pending) {
        int rc = dataslot_read_poll();
        if (rc == 0)
            return;  /* Still in flight */

        cd_dma_pending = 0;

        if (rc < 0) {
            /* EOF or error */
            if (cd_looping) {
                cd_file_offset = 0;
                CDAudio_StartChunk();
            } else {
                cd_playing = 0;
            }
            return;
        }

        /* DMA complete — copy to ring buffer */
        CDAudio_CopyChunk(cd_dma_frames);
        cd_file_offset += cd_dma_frames * 4;
    }

    /* Start next chunk if buffer needs more */
    if (!cd_dma_pending)
        CDAudio_StartChunk();
}

int CDAudio_ReadSampleStereo(int *out_l, int *out_r)
{
    *out_l = 0;
    *out_r = 0;

    if (!cd_playing || cd_paused)
        return 0;

    if (music_write_pos - music_read_pos < 2)
        return 0;

    unsigned int idx0 = (music_read_pos & MUSIC_BUF_MASK) * 2;
    unsigned int idx1 = ((music_read_pos + 1) & MUSIC_BUF_MASK) * 2;

    int l0 = music_buffer[idx0];
    int r0 = music_buffer[idx0 + 1];
    int l1 = music_buffer[idx1];
    int r1 = music_buffer[idx1 + 1];

    int f = resample_frac;
    int sl = l0 + (((l1 - l0) * f) >> 15);
    int sr = r0 + (((r1 - r0) * f) >> 15);

    *out_l = (sl * cd_volume) >> 8;
    *out_r = (sr * cd_volume) >> 8;

    resample_frac += RESAMPLE_STEP;
    if (resample_frac >= RESAMPLE_ONE) {
        resample_frac -= RESAMPLE_ONE;
        music_read_pos++;
    }

    return 1;
}

void CDAudio_Play(byte track, qboolean looping)
{
    if (!cd_available)
        return;

    if (track < TRACK_MIN || track > TRACK_MAX)
        return;

    CDAudio_Stop();

    int slot = TRACK_SLOT_ID(track);

    cd_track = track;
    cd_slot_id = slot;
    cd_file_offset = 0;
    cd_looping = looping;
    cd_paused = 0;

    music_write_pos = 0;
    music_read_pos = 0;
    resample_frac = 0;

    cd_playing = 1;

    /* Pre-fill the buffer (blocking — only at track start, 8 × 16KB = 128KB) */
    for (int i = 0; i < 8; i++) {
        int rc = dataslot_read(cd_slot_id, cd_file_offset, (void *)DMA_BUFFER, MUSIC_DMA_CHUNK);
        if (rc < 0) break;
        CDAudio_CopyChunk(MUSIC_DMA_CHUNK / 4);
        cd_file_offset += MUSIC_DMA_CHUNK;
    }
    cd_dma_pending = 0;
}

void CDAudio_Stop(void)
{
    cd_playing = 0;
    cd_paused = 0;
    cd_dma_pending = 0;
    music_write_pos = 0;
    music_read_pos = 0;
    resample_frac = 0;
}

void CDAudio_Pause(void)
{
    if (cd_playing)
        cd_paused = 1;
}

void CDAudio_Resume(void)
{
    if (cd_playing)
        cd_paused = 0;
}

void CDAudio_Update(void)
{
    if (!cd_available)
        return;

    extern cvar_t bgmvolume;
    cd_volume = (int)(bgmvolume.value * 256);
    if (cd_volume < 0) cd_volume = 0;
    if (cd_volume > 256) cd_volume = 256;

    if (!cd_playing || cd_paused)
        return;

    CDAudio_Refill();
}

int CDAudio_Init(void)
{
    cd_playing = 0;
    cd_paused = 0;
    cd_available = 0;
    cd_volume = 256;
    cd_dma_pending = 0;

    cd_available = CDAudio_Probe();

    /* Register yield hook so blocking dataslot_read/write() calls
     * automatically complete any in-flight async CD DMA first.
     * CDAudio_Refill() restarts async streaming once per frame. */
    dataslot_yield_hook = CDAudio_DataslotYield;

    if (cd_available)
        Con_Printf("CD Audio: raw CD tracks found\n");
    else
        Con_Printf("CD Audio: no CD tracks (optional)\n");

    return 0;
}

void CDAudio_Shutdown(void)
{
    CDAudio_Stop();
}
