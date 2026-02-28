/*
Copyright (C) 1996-1997 Id Software, Inc.

This program is free software; you can redistribute it and/or
modify it under the terms of the GNU General Public License
as published by the Free Software Foundation; either version 2
of the License, or (at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.

See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program; if not, write to the Free Software
Foundation, Inc., 59 Temple Place - Suite 330, Boston, MA  02111-1307, USA.

*/
// snd_mem.c -- sound caching and WAV loading for PocketQuake

#include "quakedef.h"

// ====================================================================
// WAV loading
// ====================================================================

typedef struct {
    byte *data;
    byte *end;
} wavstream_t;

static int GetLittleShort(wavstream_t *s)
{
    int val;
    if (s->data + 2 > s->end) return 0;
    val = s->data[0] | (s->data[1] << 8);
    s->data += 2;
    return val;
}

static int GetLittleLong(wavstream_t *s)
{
    int val;
    if (s->data + 4 > s->end) return 0;
    val = s->data[0] | (s->data[1] << 8) | (s->data[2] << 16) | (s->data[3] << 24);
    s->data += 4;
    return val;
}

static void FindChunk(wavstream_t *s, byte *wav_start, byte *wav_end, const char *name)
{
    byte *p = wav_start + 12; // Skip RIFF header

    while (p + 8 <= wav_end) {
        int chunk_len = p[4] | (p[5] << 8) | (p[6] << 16) | (p[7] << 24);
        if (!Q_strncmp((char *)p, name, 4)) {
            s->data = p + 8;
            s->end = p + 8 + chunk_len;
            if (s->end > wav_end) s->end = wav_end;
            return;
        }
        p += 8 + ((chunk_len + 1) & ~1); // Chunks are word-aligned
    }

    s->data = NULL;
    s->end = NULL;
}

wavinfo_t GetWavinfo(char *name, byte *wav, int wavlength)
{
    wavinfo_t info;
    wavstream_t s;
    int format;
    int samples;

    memset(&info, 0, sizeof(info));

    if (!wav)
        return info;

    // Check RIFF header
    if (Q_strncmp((char *)wav, "RIFF", 4) || Q_strncmp((char *)wav + 8, "WAVE", 4)) {
        Con_Printf("Missing RIFF/WAVE chunks in %s\n", name);
        return info;
    }

    // Get format chunk
    FindChunk(&s, wav, wav + wavlength, "fmt ");
    if (!s.data) {
        Con_Printf("Missing fmt chunk in %s\n", name);
        return info;
    }

    format = GetLittleShort(&s);
    if (format != 1) { // PCM
        Con_Printf("Non-PCM format in %s\n", name);
        return info;
    }

    info.channels = GetLittleShort(&s);
    info.rate = GetLittleLong(&s);
    GetLittleLong(&s); // avgbytespersec
    GetLittleShort(&s); // blockalign
    info.width = GetLittleShort(&s) / 8; // bits -> bytes

    // Get cue point for looping
    FindChunk(&s, wav, wav + wavlength, "cue ");
    if (s.data) {
        GetLittleLong(&s); // num cue points
        info.loopstart = GetLittleLong(&s); // skip id
        // Read the sample offset (3rd field after id, position, chunk)
        // Actually in Quake WAVs, loopstart is stored as sample offset
        // The structure is: id(4) + order(4) + chunkid(4) + chunkstart(4) + blockstart(4) + sampleoffset(4)
        info.loopstart = GetLittleLong(&s); // position
        GetLittleLong(&s); GetLittleLong(&s); GetLittleLong(&s);
        // Quake stores loop start in the first cue point's sample offset
        // Simplified: just use the position field
    } else {
        info.loopstart = -1;
    }

    // Get data chunk
    FindChunk(&s, wav, wav + wavlength, "data");
    if (!s.data) {
        Con_Printf("Missing data chunk in %s\n", name);
        return info;
    }

    samples = (int)(s.end - s.data) / info.width;
    info.samples = samples;
    info.dataofs = (int)(s.data - wav);

    return info;
}

// ====================================================================
// Resampling
// ====================================================================

static void ResampleSfx(sfx_t *sfx, int inrate, int inwidth, byte *data, int insamps)
{
    int outcount;
    int i;
    int samplefrac, fracstep;
    sfxcache_t *sc;

    sc = Cache_Check(&sfx->cache);
    if (!sc)
        return;

    short *out = (short *)sc->data;
    outcount = sc->length;
    fracstep = ((long long)inrate << 8) / shm->speed;
    samplefrac = 0;

    for (i = 0; i < outcount; i++) {
        int srcsample = samplefrac >> 8;
        int frac = samplefrac & 0xFF;
        samplefrac += fracstep;

        int s0, s1;
        if (inwidth == 2) {
            s0 = ((short *)data)[srcsample];
            s1 = (srcsample + 1 < insamps) ? ((short *)data)[srcsample + 1] : s0;
        } else {
            s0 = ((int)((unsigned char)data[srcsample]) - 128) << 8;
            s1 = (srcsample + 1 < insamps)
                ? ((int)((unsigned char)data[srcsample + 1]) - 128) << 8 : s0;
        }

        // Linear interpolation, store as 16-bit signed
        out[i] = (short)(s0 + (((s1 - s0) * frac) >> 8));
    }
}

// ====================================================================
// S_LoadSound
// ====================================================================

sfxcache_t *S_LoadSound(sfx_t *s)
{
    char namebuffer[256];
    byte *data;
    wavinfo_t info;
    int len;
    sfxcache_t *sc;

    // See if still in cache
    sc = Cache_Check(&s->cache);
    if (sc)
        return sc;

    // Load it in
    Q_strcpy(namebuffer, "sound/");
    Q_strcat(namebuffer, s->name);

    data = COM_LoadTempFile(namebuffer);
    if (!data) {
        Con_Printf("Couldn't load %s\n", namebuffer);
        return NULL;
    }

    info = GetWavinfo(s->name, data, com_filesize);
    if (info.channels != 1) {
        Con_Printf("%s is a stereo sample\n", s->name);
        return NULL;
    }

    // Calculate output length at target sample rate
    len = (int)((long long)info.samples * shm->speed / info.rate);
    if (len <= 0) {
        Con_Printf("Sound %s has zero length\n", s->name);
        return NULL;
    }

    // Allocate cache entry: header + 16-bit mono samples
    sc = Cache_Alloc(&s->cache, sizeof(sfxcache_t) + len * 2, s->name);
    if (!sc)
        return NULL;

    sc->length = len;
    sc->loopstart = info.loopstart;
    if (sc->loopstart >= 0)
        sc->loopstart = (int)((long long)sc->loopstart * shm->speed / info.rate);
    sc->speed = shm->speed;
    sc->width = 2;
    sc->stereo = 0;

    ResampleSfx(s, info.rate, info.width, data + info.dataofs, info.samples);

    return sc;
}
