/*
 * sys_pocket.c -- PocketQuake system driver
 * Bare-metal VexRiscv on Analogue Pocket
 *
 * PAK file is read on demand from SD card via APF dataslot_read().
 * The PAK directory is cached in memory at init time; file data is
 * fetched on each Sys_FileRead call.
 */

#include "quakedef.h"
#include <stdarg.h>
#include "../dataslot.h"

/* Not a dedicated server */
qboolean isDedicated = false;
volatile unsigned int pq_dbg_stage = 0;
volatile unsigned int pq_dbg_info = 0;

/* Hardware registers (SYS_CYCLE_LO/HI already defined in libc.h) */
#define CPU_FREQ         100000000  /* clk_cpu currently runs at 100 MHz */

/* On-demand PAK reading via APF dataslot */
#define PAK_SLOT_ID      0      /* data.json slot id for pak0.pak */
#define PAK_MAX_SIZE     (48 * 1024 * 1024)  /* 48MB max */
/* DMA_BUFFER and DMA_CHUNK_SIZE defined in dataslot.h */

/* PAK file structure */
#define PAK_HEADER_MAGIC  (('P') | ('A' << 8) | ('C' << 16) | ('K' << 24))

typedef struct {
    int ident;
    int dirofs;
    int dirlen;
} pakheader_t;

typedef struct {
    char name[56];
    int filepos;
    int filelen;
} pakfile_t;

#define MAX_PAK_FILES 2048

static pakfile_t pak_dir_cache[MAX_PAK_FILES];  /* cached PAK directory (BSS/SDRAM) */
static pakfile_t *pak_dir = pak_dir_cache;
static int pak_numfiles;
static int pak_total_size;  /* dirofs + dirlen, returned by Sys_FileOpenRead */
static int pak_initialized = 0;

/* (DMA buffer at fixed SDRAM address DMA_BUFFER, read via SDRAM_UNCACHED) */

/* Terminal printf for error reporting */
extern void term_printf(const char *fmt, ...);

/* Volatile-safe copy from uncached SDRAM DMA buffer to dest.
 * Ensures each word is actually read from hardware (not optimized by LTO). */
static void dma_copy(void *dest, int count);

static void Pak_Init(void)
{
    pakheader_t hdr;
    int rc;

    if (pak_initialized)
        return;

    /* DMA PAK header into SDRAM, then read via uncacheable alias to
     * bypass D-cache (bridge DMA writes bypass cache). */
    {
        /* Write sentinels via UNCACHED alias to avoid creating dirty D-cache
         * lines that could be evicted over DMA'd data. */
        volatile unsigned int *buf = (volatile unsigned int *)SDRAM_UNCACHED(DMA_BUFFER);
        for (int i = 0; i < 16; i++)
            buf[i] = 0xBAAD0000 | i;

        /* Verify sentinels via uncached alias */
        volatile unsigned int *uc = (volatile unsigned int *)SDRAM_UNCACHED(DMA_BUFFER);
        term_printf("Pre: %x %x %x %x\n", uc[0], uc[1], uc[2], uc[3]);

        /* DMA 64 bytes (not just 12) to check full word writes */
        rc = dataslot_read(PAK_SLOT_ID, 0, (void *)DMA_BUFFER, 64);
        term_printf("DMA rc=%d\n", rc);

        /* Read back all 16 words via uncached alias */
        term_printf("UC: %x %x %x %x\n", uc[0], uc[1], uc[2], uc[3]);
        term_printf("    %x %x %x %x\n", uc[4], uc[5], uc[6], uc[7]);

        /* Second DMA to verify consistency */
        rc = dataslot_read(PAK_SLOT_ID, 0, (void *)DMA_BUFFER, 64);
        term_printf("DMA2 rc=%d\n", rc);
        term_printf("UC2: %x %x %x %x\n", uc[0], uc[1], uc[2], uc[3]);

        if (rc != 0) {
            term_printf("Pak_Init: dataslot_read header failed (%d)\n", rc);
            pak_numfiles = 0;
            pak_initialized = 1;
            return;
        }
        hdr.ident = uc[0];
        hdr.dirofs = uc[1];
        hdr.dirlen = uc[2];
        term_printf("Pak_Init: magic=%x dirofs=%x dirlen=%x\n",
                     hdr.ident, hdr.dirofs, hdr.dirlen);
    }

    if (hdr.ident != PAK_HEADER_MAGIC) {
        term_printf("Pak_Init: bad magic 0x%x\n", hdr.ident);
        pak_numfiles = 0;
        pak_initialized = 1;
        return;
    }

    pak_total_size = hdr.dirofs + hdr.dirlen;
    pak_numfiles = hdr.dirlen / sizeof(pakfile_t);
    if (pak_numfiles > MAX_PAK_FILES)
        pak_numfiles = MAX_PAK_FILES;

    /* Read PAK directory: DMA to SDRAM, volatile copy from uncacheable alias to BSS. */
    {
        int dir_bytes = pak_numfiles * sizeof(pakfile_t);
        int done = 0;
        while (done < dir_bytes) {
            int chunk = dir_bytes - done;
            if (chunk > DMA_CHUNK_SIZE)
                chunk = DMA_CHUNK_SIZE;
            rc = dataslot_read(PAK_SLOT_ID, hdr.dirofs + done,
                               (void *)DMA_BUFFER, chunk);
            if (rc != 0)
                break;
            dma_copy((byte *)pak_dir_cache + done, chunk);
            done += chunk;
        }
    }
    if (rc != 0) {
        term_printf("Pak_Init: dataslot_read dir failed (%d)\n", rc);
        pak_numfiles = 0;
        pak_initialized = 1;
        return;
    }

    term_printf("Pak_Init: %d files, total %d bytes\n", pak_numfiles, pak_total_size);
    pak_initialized = 1;
}

/* Find a file in the PAK */
static int Pak_FindFile(const char *path, int *offset, int *length)
{
    int i;
    Pak_Init();

    for (i = 0; i < pak_numfiles; i++) {
        if (Q_strcasecmp(pak_dir[i].name, path) == 0) {
            *offset = pak_dir[i].filepos;
            *length = pak_dir[i].filelen;
            return 1;
        }
    }
    return 0;
}

/*
===============================================================================
FILE IO
===============================================================================
*/

#define MAX_HANDLES 10

typedef struct {
    int used;
    unsigned char *data;  /* NULL = on-demand PAK via dataslot_read */
    int length;
    int position;
} syshandle_t;

static syshandle_t sys_handles[MAX_HANDLES];

static int findhandle(void)
{
    int i;
    for (i = 1; i < MAX_HANDLES; i++)
        if (!sys_handles[i].used)
            return i;
    Sys_Error("out of handles");
    return -1;
}

int filelength(FILE *f)
{
    int pos, end;
    pos = ftell(f);
    fseek(f, 0, SEEK_END);
    end = ftell(f);
    fseek(f, pos, SEEK_SET);
    return end;
}

int Sys_FileOpenRead(char *path, int *hndl)
{
    int i;

    i = findhandle();

    /* Intercept requests for pak0.pak itself — return an on-demand handle */
    {
        const char *p = path;
        int found = 0;
        while (*p) {
            if (p[0]=='p'&&p[1]=='a'&&p[2]=='k'&&p[3]=='0'&&
                p[4]=='.'&&p[5]=='p'&&p[6]=='a'&&p[7]=='k') {
                found = 1; break;
            }
            p++;
        }
        if (found) {
            /* Do not depend on Pak_Init() here. COM_LoadPackFile will parse the
             * header/directory via Sys_FileRead from this handle. */
            sys_handles[i].used = 1;
            sys_handles[i].data = NULL;  /* on-demand: no memory-mapped data */
            sys_handles[i].length = PAK_MAX_SIZE;
            sys_handles[i].position = 0;
            *hndl = i;
            return PAK_MAX_SIZE;
        }
    }

    /* File not found — Quake's COM_FindFile handles PAK contents by
       opening pak0.pak (intercepted above) and seeking to offsets. */
    *hndl = -1;
    return -1;
}

int Sys_FileOpenWrite(char *path)
{
    /* Write not supported on bare metal */
    (void)path;
    return -1;
}

void Sys_FileClose(int handle)
{
    if (handle >= 0 && handle < MAX_HANDLES)
        sys_handles[handle].used = 0;
}

void Sys_FileSeek(int handle, int position)
{
    if (handle >= 0 && handle < MAX_HANDLES && sys_handles[handle].used) {
        sys_handles[handle].position = position;
    }
}

/* DMA transfer statistics for debugging */
static int dma_total_calls = 0;
static int dma_total_errors = 0;
static int dma_stale_hits = 0;

/* Volatile-safe copy from uncached SDRAM alias.
 * Q_memcpy's src parameter is void* (non-volatile), so LTO can optimize
 * reads from the uncached alias into cached/reordered reads. This function
 * ensures each word is actually read from hardware via volatile. */
static void dma_copy(void *dest, int count)
{
    volatile unsigned int *src =
        (volatile unsigned int *)SDRAM_UNCACHED(DMA_BUFFER);
    unsigned int *dst = (unsigned int *)dest;
    int words = count >> 2;
    int i;
    for (i = 0; i < words; i++)
        dst[i] = src[i];
    /* Handle trailing bytes */
    int tail = count & 3;
    if (tail) {
        volatile unsigned char *sb =
            (volatile unsigned char *)SDRAM_UNCACHED(DMA_BUFFER);
        unsigned char *db = (unsigned char *)dest;
        for (i = words * 4; i < count; i++)
            db[i] = sb[i];
    }
}

#define DMA_SENTINEL  0xBAADF00D

int Sys_FileRead(int handle, void *dest, int count)
{
    syshandle_t *h;
    int remaining;

    if (handle < 0 || handle >= MAX_HANDLES)
        return 0;
    h = &sys_handles[handle];
    if (!h->used)
        return 0;

    remaining = h->length - h->position;
    if (count > remaining)
        count = remaining;
    if (count <= 0)
        return 0;

    if (h->data == NULL) {
        /* On-demand PAK read: DMA to SDRAM, copy from uncacheable alias. */
        {
            int done = 0;
            while (done < count) {
                int chunk = count - done;
                if (chunk > DMA_CHUNK_SIZE)
                    chunk = DMA_CHUNK_SIZE;

                dma_total_calls++;

                /* Plant sentinel via UNCACHED alias to avoid creating dirty
                 * D-cache lines that could be evicted over DMA'd data. */
                volatile unsigned int *buf = (volatile unsigned int *)SDRAM_UNCACHED(DMA_BUFFER);
                buf[0] = DMA_SENTINEL;

                int rc = dataslot_read(PAK_SLOT_ID, h->position + done,
                                       (void *)DMA_BUFFER, chunk);
                if (rc != 0) {
                    dma_total_errors++;
                    term_printf("DMA ERR: rc=%d off=%x len=%x #%d\n",
                                rc, h->position + done, chunk, dma_total_calls);
                    return done;
                }

                /* Check sentinel survived → DMA didn't write (false DONE) */
                volatile unsigned int *uc =
                    (volatile unsigned int *)SDRAM_UNCACHED(DMA_BUFFER);
                if (uc[0] == DMA_SENTINEL) {
                    dma_stale_hits++;
                    if (dma_stale_hits <= 8)
                        term_printf("STALE! off=%x #%d\n",
                                    h->position + done, dma_total_calls);
                    /* Retry */
                    rc = dataslot_read(PAK_SLOT_ID, h->position + done,
                                       (void *)DMA_BUFFER, chunk);
                    if (rc != 0 || uc[0] == DMA_SENTINEL)
                        return done;
                }

                /* Volatile copy: ensures each word is actually read from
                 * uncached SDRAM, preventing LTO from caching/reordering. */
                dma_copy((byte *)dest + done, chunk);
                done += chunk;
            }
        }
    } else {
        /* Memory-mapped data (not currently used, kept for safety) */
        Q_memcpy(dest, h->data + h->position, count);
    }

    h->position += count;
    return count;
}

/* Print DMA stats — call from Host_Init or similar */
void Sys_PrintDmaStats(void)
{
    term_printf("DMA: %d calls, %d errs, %d stale\n",
                dma_total_calls, dma_total_errors, dma_stale_hits);
}

int Sys_FileWrite(int handle, void *data, int count)
{
    (void)handle;
    (void)data;
    (void)count;
    return 0;
}

int Sys_FileTime(char *path)
{
    int offset, length;
    if (Pak_FindFile(path, &offset, &length))
        return 1;
    return -1;
}

void Sys_mkdir(char *path)
{
    (void)path;
}

/*
===============================================================================
SYSTEM IO
===============================================================================
*/

void Sys_MakeCodeWriteable(unsigned long startaddr, unsigned long length)
{
    (void)startaddr;
    (void)length;
    /* All memory is RWX on bare metal */
}

/* Terminal printf (defined in terminal.c) */
extern void term_printf(const char *fmt, ...);
extern void term_puts(const char *s);
extern void term_putchar(char c);

#define SYS_PRINTF_ENABLE 1

void Sys_Error(char *error, ...)
{
    va_list argptr;
    char buf[256];

    va_start(argptr, error);
    vsprintf(buf, error, argptr);
    va_end(argptr);

    /* Ensure terminal is visible for fatal diagnostics. */
    (*(volatile unsigned int *)0x4000000C) = 0;
    term_printf("Sys_Error: %s\n", buf);

    /* Halt */
    while (1) {}
}

void Sys_Printf(char *fmt, ...)
{
#if !SYS_PRINTF_ENABLE
    (void)fmt;
    return;
#else
    va_list argptr;
    char buf[256];

    va_start(argptr, fmt);
    vsprintf(buf, fmt, argptr);
    va_end(argptr);

    term_puts(buf);
#endif
}

void Sys_Quit(void)
{
    while (1) {}
}

float Sys_FloatTime(void)
{
    static unsigned int initialized = 0;
    static unsigned int last_lo = 0;
    static float accum_seconds = 0.0f;
    unsigned int lo = SYS_CYCLE_LO;

    if (!initialized) {
        initialized = 1;
        last_lo = lo;
        return 0.0;
    }

    /* 32-bit cycle delta naturally handles wrap-around without 64-bit math. */
    accum_seconds += (float)(lo - last_lo) * (1.0f / (float)CPU_FREQ);
    last_lo = lo;
    return accum_seconds;
}

char *Sys_ConsoleInput(void)
{
    return NULL;
}

void Sys_Sleep(void)
{
}

void Sys_SendKeyEvents(void)
{
    IN_SendKeyEvents();
}

void Sys_HighFPPrecision(void)
{
}

void Sys_LowFPPrecision(void)
{
}

/*
===============================================================================
MAIN
===============================================================================
*/

/* Heap symbols from linker */
extern char _heap_start[];
extern char _heap_end[];

/* Static arguments for Quake */
static char *quake_argv[] = { "quake", NULL };

/* External: called from main.c */
void __attribute__((noinline, aligned(4))) quake_main(void)
{
    static quakeparms_t parms;
    float time, oldtime, newtime;

    /* Debug markers: raw VRAM writes BEFORE any function calls.
     * VRAM at 0x20000000, row 29, cols 5-6. */
    ((volatile char *)0x20000000)[29 * 40 + 5] = 'Q';
    ((volatile char *)0x20000000)[29 * 40 + 6] = '!';

    /* Ultra-early canary: raw SDRAM write (no function calls) */
    *(volatile unsigned int *)0x13E00000 = 0xAA55AA55;

    /* Debug: print to terminal to confirm we reached quake_main */
    term_printf("=== quake_main REACHED ===\n");

    pq_dbg_stage = 0x1000;

    pq_dbg_stage = 0x1001;
    /* Set up parameters */
    parms.basedir = ".";
    parms.cachedir = NULL;
    parms.argc = 1;
    parms.argv = quake_argv;

    pq_dbg_stage = 0x1002;
    /* Set up heap - use the linker-defined heap region */
    parms.membase = (void *)_heap_start;
    parms.memsize = (int)(_heap_end - _heap_start);

    pq_dbg_stage = 0x1020;
    /* Initialize Quake engine */
    Host_Init(&parms);
    pq_dbg_stage = 0x1030;

    /* Main loop */
    oldtime = Sys_FloatTime();
    {
        volatile char *vram = (volatile char *)0x20000000;
        int frame_num = 0;
        while (1) {
            /* VRAM row 27: frame counter (visible even if SDRAM hung) */
            vram[27 * 40 + 0] = 'F';
            vram[27 * 40 + 1] = '0' + ((frame_num / 1000) % 10);
            vram[27 * 40 + 2] = '0' + ((frame_num / 100) % 10);
            vram[27 * 40 + 3] = '0' + ((frame_num / 10) % 10);
            vram[27 * 40 + 4] = '0' + (frame_num % 10);

            newtime = Sys_FloatTime();
            time = newtime - oldtime;

            /* Limit to reasonable frame time */
            if (time < 0.001)
                continue;
            if (time > 0.1)
                time = 0.1;

            vram[27 * 40 + 6] = 'H';  /* about to call Host_Frame */
            {
                int dma_before = dma_total_calls;
                Host_Frame(time);
                int dma_after = dma_total_calls;
                vram[27 * 40 + 6] = 'D';
                /* Show DMA calls this frame */
                int d = dma_after - dma_before;
                vram[27 * 40 + 8] = 'D';
                vram[27 * 40 + 9] = '0' + ((d / 100) % 10);
                vram[27 * 40 + 10] = '0' + ((d / 10) % 10);
                vram[27 * 40 + 11] = '0' + (d % 10);
            }
            frame_num++;
            oldtime = newtime;
        }
    }
}
