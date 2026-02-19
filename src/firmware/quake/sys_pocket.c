/*
 * sys_pocket.c -- PocketQuake system driver
 * Bare-metal VexRiscv on Analogue Pocket
 *
 * PAK file is memory-mapped in SDRAM at a known address (loaded by APF).
 * No filesystem -- all file I/O operates directly on SDRAM-mapped data.
 */

#include "quakedef.h"
#include <stdarg.h>

/* Not a dedicated server */
qboolean isDedicated = false;
volatile unsigned int pq_dbg_stage = 0;
volatile unsigned int pq_dbg_info = 0;

/* Hardware registers (SYS_CYCLE_LO/HI already defined in libc.h) */
#define CPU_FREQ         100000000  /* clk_cpu currently runs at 100 MHz */

/* PAK file location in SDRAM (cached).
 * Using 0x11000000 (cached) for ~4x faster loading via D-cache burst fills
 * (~2.6 cycles/word vs ~11 cycles/word uncached). */
#define PAK_BASE_ADDR    0x11000000
#define PAK_MAX_SIZE     (48 * 1024 * 1024)  /* 48MB max */

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

static unsigned char *pak_data = (unsigned char *)PAK_BASE_ADDR;
static pakheader_t *pak_header;
static pakfile_t *pak_dir;
static int pak_numfiles;
static int pak_initialized = 0;

static void Pak_Init(void)
{
    if (pak_initialized)
        return;

    pak_header = (pakheader_t *)pak_data;
    if (pak_header->ident != PAK_HEADER_MAGIC) {
        /* PAK not loaded or invalid */
        pak_numfiles = 0;
        pak_initialized = 1;
        return;
    }

    pak_dir = (pakfile_t *)(pak_data + pak_header->dirofs);
    pak_numfiles = pak_header->dirlen / sizeof(pakfile_t);
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
    unsigned char *data;  /* pointer into SDRAM */
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

    /* Intercept requests for pak0.pak itself — return the raw PAK blob */
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
            pakheader_t *hdr = (pakheader_t *)PAK_BASE_ADDR;
            if (hdr->ident == PAK_HEADER_MAGIC) {
                int paklen = hdr->dirofs + hdr->dirlen;
                sys_handles[i].used = 1;
                sys_handles[i].data = (unsigned char *)PAK_BASE_ADDR;
                /* Do not clamp reads to directory end.
                 * Quake uses this handle as a raw backing store and seeks to
                 * file offsets from the directory; some builds can hit entries
                 * beyond a conservative dir-end clamp.
                 */
                sys_handles[i].length = PAK_MAX_SIZE;
                sys_handles[i].position = 0;
                *hndl = i;
                Sys_Printf("DBG pak open: dirofs=0x%x dirlen=0x%x dirend=0x%x limit=0x%x\n",
                           hdr->dirofs, hdr->dirlen, paklen, sys_handles[i].length);
                return paklen;
            }
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

int Sys_FileRead(int handle, void *dest, int count)
{
    syshandle_t *h;
    int remaining;
    int req = count;

    if (handle < 0 || handle >= MAX_HANDLES)
        return 0;
    h = &sys_handles[handle];
    if (!h->used)
        return 0;

    remaining = h->length - h->position;
    if (count > remaining)
        count = remaining;
    if (count <= 0)
    {
        Sys_Printf("DBG read EOF/underflow: h=%d pos=0x%x len=0x%x req=0x%x rem=0x%x\n",
                   handle, h->position, h->length, req, remaining);
        return 0;
    }

    Q_memcpy(dest, h->data + h->position, count);
    h->position += count;
    if (count != req) {
        Sys_Printf("DBG short read: h=%d got=0x%x req=0x%x pos=0x%x len=0x%x\n",
                   handle, count, req, h->position, h->length);
    }
    return count;
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

#define SYS_PRINTF_ENABLE 0

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

double Sys_FloatTime(void)
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
    return (double)accum_seconds;
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
void quake_main(void)
{
    static quakeparms_t parms;
    double time, oldtime, newtime;

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

    pq_dbg_stage = 0x1010;
    /* Initialize PAK file system */
    Pak_Init();

    pq_dbg_stage = 0x1020;
    /* Initialize Quake engine */
    Host_Init(&parms);
    pq_dbg_stage = 0x1030;

    /* Main loop */
    oldtime = Sys_FloatTime();
    while (1) {
        pq_dbg_stage = 0x1100;
        newtime = Sys_FloatTime();
        time = newtime - oldtime;

        /* Limit to reasonable frame time */
        if (time < 0.001)
            continue;
        if (time > 0.1)
            time = 0.1;

        pq_dbg_info = (unsigned int)(time * 1000000.0);
        pq_dbg_stage = 0x1110;
        Host_Frame(time);
        pq_dbg_stage = 0x1120;
        oldtime = newtime;
    }
}
