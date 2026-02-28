/*
 * File I/O emulation for VexRiscv
 * Uses data slots for loading files into SDRAM
 */

#include "libc.h"
#include "../dataslot.h"

/* Standard file descriptors (unused but defined for compatibility) */
static FILE stdin_file = {0, 0, 0, 0, NULL};
static FILE stdout_file = {0, 0, 0, 0, NULL};
static FILE stderr_file = {0, 0, 0, 0, NULL};

FILE *stdin = &stdin_file;
FILE *stdout = &stdout_file;
FILE *stderr = &stderr_file;

/* File table for open files */
#define MAX_OPEN_FILES 4
static FILE file_table[MAX_OPEN_FILES];
static int file_table_used[MAX_OPEN_FILES] = {0};

/* Find a free file slot */
static FILE *alloc_file(void) {
    for (int i = 0; i < MAX_OPEN_FILES; i++) {
        if (!file_table_used[i]) {
            file_table_used[i] = 1;
            memset(&file_table[i], 0, sizeof(FILE));
            return &file_table[i];
        }
    }
    return NULL;
}

/* Free a file slot */
static void free_file(FILE *f) {
    for (int i = 0; i < MAX_OPEN_FILES; i++) {
        if (&file_table[i] == f) {
            file_table_used[i] = 0;
            return;
        }
    }
}

/* PAK data slot IDs (matches data.json) */
#define PAK0_SLOT_ID     1
#define PAK1_SLOT_ID     2
#define PAK_MAX_SIZE     (48 * 1024 * 1024)  /* 48MB max */

/* Savegame/config write support via direct SDRAM access.
 * Each save slot and config has its own APF data slot (nonvolatile).
 * Bridge auto-loads each file into its own SDRAM region at boot.
 * On save, we write to SDRAM + explicitly persist via dataslot_write at offset 0. */
#define FILE_FLAG_WRITE  1
#define SAV_BUF_SIZE     (256 * 1024)

static char sav_buf[SAV_BUF_SIZE] __attribute__((section(".bss.sav")));

/* Per-file save slots (data.json):
 *   Slots 20-31 = s0.sav through s11.sav (nonvolatile, 128KB each)
 *   Slot  32    = config.cfg (nonvolatile, 128KB)
 * SDRAM region: bridge 0x03C00000 = CPU 0x13C00000, 128KB per slot. */
#define SAV_REGION_BASE  0x13C00000
#define SAV_SLOT_BASE    20     /* data slot ID for s0.sav */
#define SAV_CFG_SLOT     32     /* data slot ID for config.cfg */
#define SAV_SLOT_SIZE    (128 * 1024)
#define SAV_MAX_SLOTS    12
#define SAV_HEADER_SIZE  4

/* Which save/config slot is currently open for writing (-1 = none) */
static int sav_write_slot_num = -1;  /* 0-11 = save, 12 = config */

/* Extract Quake save slot number from filename (e.g. "s0.sav" → 0, "s11.sav" → 11).
 * Returns -1 if not a valid save slot filename. */
static int sav_slot_from_name(const char *basename) {
    if (basename[0] != 's') return -1;
    int n = 0;
    const char *p = basename + 1;
    if (!isdigit(*p)) return -1;
    while (isdigit(*p)) {
        n = n * 10 + (*p - '0');
        p++;
    }
    if (strcmp(p, ".sav") != 0 && strcmp(p, ".SAV") != 0) return -1;
    if (n < 0 || n >= SAV_MAX_SLOTS) return -1;
    return n;
}

/* Check if string ends with suffix */
static int str_ends_with(const char *str, const char *suffix) {
    int str_len = strlen(str);
    int suf_len = strlen(suffix);
    if (suf_len > str_len) return 0;
    return strcmp(str + str_len - suf_len, suffix) == 0;
}

/* Check if path is a .sav file */
static int is_sav_file(const char *pathname) {
    return str_ends_with(pathname, ".sav") || str_ends_with(pathname, ".SAV");
}

/* Check if path is a .cfg file */
static int is_cfg_file(const char *pathname) {
    return str_ends_with(pathname, ".cfg") || str_ends_with(pathname, ".CFG");
}

/* Return pointer to basename (after last '/') */
static const char *path_basename(const char *pathname) {
    const char *p = pathname;
    const char *last = pathname;
    while (*p) {
        if (*p == '/')
            last = p + 1;
        p++;
    }
    return last;
}

/* Map filename to data slot ID for on-demand PAK reading.
 * Returns slot ID >= 0 for known pak files, -1 for unknown. */
static int filename_to_slot(const char *pathname) {
    if (str_ends_with(pathname, "pak0.pak") || str_ends_with(pathname, "PAK0.PAK"))
        return PAK0_SLOT_ID;
    if (str_ends_with(pathname, "pak1.pak") || str_ends_with(pathname, "PAK1.PAK"))
        return PAK1_SLOT_ID;
    return -1;
}

/* ============================================
 * High-level file operations
 * ============================================ */

/* Helper: read save/config data from bridge auto-loaded SDRAM into sav_buf.
 * slot_num: 0-11 for saves, 12 for config.
 * Returns saved_size on success, 0 on empty/corrupt. */
static uint32_t sav_read_from_sdram(int slot_num) {
    uint32_t slot_addr = SAV_REGION_BASE + slot_num * SAV_SLOT_SIZE;
    volatile uint32_t *uc = (volatile uint32_t *)SDRAM_UNCACHED(slot_addr);
    uint32_t saved_size = uc[0];  /* size header */
    if (saved_size == 0 || saved_size > (SAV_SLOT_SIZE - SAV_HEADER_SIZE))
        return 0;

    memset(sav_buf, 0, SAV_BUF_SIZE);
    volatile uint32_t *wsrc = (volatile uint32_t *)SDRAM_UNCACHED(slot_addr + SAV_HEADER_SIZE);
    uint32_t *wdst = (uint32_t *)sav_buf;
    uint32_t words = saved_size >> 2;
    for (uint32_t i = 0; i < words; i++)
        wdst[i] = wsrc[i];
    uint32_t tail = saved_size & 3;
    if (tail) {
        uint32_t last_word = wsrc[words];
        uint8_t *bdst = (uint8_t *)sav_buf + (words << 2);
        for (uint32_t i = 0; i < tail; i++)
            bdst[i] = (uint8_t)(last_word >> (i * 8));
    }
    return saved_size;
}

FILE *fopen(const char *pathname, const char *mode) {
    /* Savegame write mode — buffer in sav_buf, written to slot on fclose */
    if (mode[0] == 'w' && is_sav_file(pathname)) {
        const char *base = path_basename(pathname);
        int slot_num = sav_slot_from_name(base);
        if (slot_num < 0) return NULL;
        FILE *f = alloc_file();
        if (!f) return NULL;
        sav_write_slot_num = slot_num;
        memset(sav_buf, 0, SAV_BUF_SIZE);
        f->slot_id = SAV_SLOT_BASE + slot_num;
        f->offset = 0;
        f->size = SAV_SLOT_SIZE - SAV_HEADER_SIZE;
        f->flags = FILE_FLAG_WRITE;
        f->data = sav_buf;
        return f;
    }

    /* Config file write mode */
    if (mode[0] == 'w' && is_cfg_file(pathname)) {
        FILE *f = alloc_file();
        if (!f) return NULL;
        sav_write_slot_num = SAV_MAX_SLOTS;  /* 12 = config */
        memset(sav_buf, 0, SAV_BUF_SIZE);
        f->slot_id = SAV_CFG_SLOT;
        f->offset = 0;
        f->size = SAV_SLOT_SIZE - SAV_HEADER_SIZE;
        f->flags = FILE_FLAG_WRITE;
        f->data = sav_buf;
        return f;
    }

    /* All other writes not supported */
    if (mode[0] == 'w') return NULL;

    /* Savegame read mode — from bridge auto-loaded SDRAM */
    if (is_sav_file(pathname)) {
        const char *base = path_basename(pathname);
        int slot_num = sav_slot_from_name(base);
        if (slot_num < 0) return NULL;

        uint32_t saved_size = sav_read_from_sdram(slot_num);
        if (saved_size == 0) return NULL;

        FILE *f = alloc_file();
        if (!f) return NULL;
        f->slot_id = SAV_SLOT_BASE + slot_num;
        f->offset = 0;
        f->size = saved_size;
        f->flags = 0;
        f->data = sav_buf;
        return f;
    }

    /* Config file read mode — from bridge auto-loaded SDRAM */
    if (is_cfg_file(pathname)) {
        uint32_t saved_size = sav_read_from_sdram(SAV_MAX_SLOTS);
        if (saved_size == 0)
            return NULL;  /* no saved config — use default from Assets */

        FILE *f = alloc_file();
        if (!f) return NULL;
        f->slot_id = SAV_CFG_SLOT;
        f->offset = 0;
        f->size = saved_size;
        f->flags = 0;
        f->data = sav_buf;
        return f;
    }

    /* PAK file read mode */
    int slot_id = filename_to_slot(pathname);
    if (slot_id == -1) {
        return NULL;  /* Unknown file */
    }

    FILE *f = alloc_file();
    if (f == NULL) {
        return NULL;
    }

    f->slot_id = slot_id;
    f->offset = 0;
    f->flags = 0;
    f->data = NULL;
    f->size = PAK_MAX_SIZE;

    return f;
}

int fclose(FILE *stream) {
    if (stream == NULL) {
        return -1;
    }

    /* Savegame/config write-back: write to SDRAM via uncached alias,
     * then explicitly persist to SD card via dataslot_write() at offset 0.
     * Each save/config has its own data slot — no offset math needed. */
    if ((stream->flags & FILE_FLAG_WRITE) && stream->offset > 0 && sav_write_slot_num >= 0) {
        uint32_t actual_size = stream->offset;
        uint32_t slot_addr = SAV_REGION_BASE + (uint32_t)sav_write_slot_num * SAV_SLOT_SIZE;
        int ds_slot_id = (sav_write_slot_num < SAV_MAX_SLOTS)
                         ? SAV_SLOT_BASE + sav_write_slot_num
                         : SAV_CFG_SLOT;

        /* Write size header + data to SDRAM via uncached alias */
        *(volatile uint32_t *)SDRAM_UNCACHED(slot_addr) = actual_size;
        {
            volatile uint32_t *wdst = (volatile uint32_t *)SDRAM_UNCACHED(slot_addr + SAV_HEADER_SIZE);
            uint32_t *wsrc = (uint32_t *)sav_buf;
            uint32_t words = actual_size >> 2;
            for (uint32_t i = 0; i < words; i++)
                wdst[i] = wsrc[i];
            uint32_t tail = actual_size & 3;
            if (tail) {
                uint32_t last = 0;
                for (uint32_t i = 0; i < tail; i++)
                    last |= (uint32_t)((uint8_t *)sav_buf)[(words << 2) + i] << (i * 8);
                wdst[words] = last;
            }
        }

        __asm__ volatile("fence");

        /* Persist to SD card — single write at offset 0.
         * No chunking needed: data is already contiguous in SDRAM,
         * and DMA_CHUNK_SIZE only limits reads (bounce buffer). */
        uint32_t wr_total = SAV_HEADER_SIZE + actual_size;
        dataslot_write(ds_slot_id, 0, (void *)slot_addr, wr_total);

        sav_write_slot_num = -1;
    }

    /* Don't free SDRAM data here - mmap/munmap handles that */
    free_file(stream);
    return 0;
}

size_t fread(void *ptr, size_t size, size_t nmemb, FILE *stream) {
    if (stream == NULL || ptr == NULL || size == 0 || nmemb == 0) {
        return 0;
    }

    size_t total_bytes = size * nmemb;
    size_t available = stream->size - stream->offset;

    if (total_bytes > available) {
        total_bytes = available;
        nmemb = total_bytes / size;
        total_bytes = nmemb * size;  /* Round down to whole elements */
    }

    if (total_bytes == 0) {
        return 0;
    }

    /* If data is loaded in memory (via mmap), copy directly from it */
    if (stream->data != NULL) {
        memcpy(ptr, (uint8_t *)stream->data + stream->offset, total_bytes);
        stream->offset += total_bytes;
        return nmemb;
    }

    /* DMA to bounce buffer, then copy via uncacheable alias to avoid
     * stale D-cache lines at the destination address. */
    uint8_t *dest = (uint8_t *)ptr;
    size_t remaining = total_bytes;
    while (remaining > 0) {
        size_t chunk = remaining > DMA_CHUNK_SIZE ? DMA_CHUNK_SIZE : remaining;
        if (dataslot_read(stream->slot_id, stream->offset, (void *)DMA_BUFFER, chunk) != 0) {
            return 0;
        }
        memcpy(dest, SDRAM_UNCACHED(DMA_BUFFER), chunk);
        dest += chunk;
        stream->offset += chunk;
        remaining -= chunk;
    }
    return nmemb;
}

size_t fwrite(const void *ptr, size_t size, size_t nmemb, FILE *stream) {
    if (stream && (stream->flags & FILE_FLAG_WRITE)) {
        size_t total = size * nmemb;
        size_t remaining = stream->size - stream->offset;
        if (total > remaining) total = remaining;
        if (total > 0) {
            memcpy((char *)stream->data + stream->offset, ptr, total);
            stream->offset += total;
        }
        return total / size;
    }
    return 0;
}

int fseek(FILE *stream, long offset, int whence) {
    if (stream == NULL) {
        return -1;
    }

    long new_offset;

    switch (whence) {
        case SEEK_SET:
            new_offset = offset;
            break;
        case SEEK_CUR:
            new_offset = (long)stream->offset + offset;
            break;
        case SEEK_END:
            new_offset = (long)stream->size + offset;
            break;
        default:
            return -1;
    }

    if (new_offset < 0 || (size_t)new_offset > stream->size) {
        return -1;
    }

    stream->offset = (uint32_t)new_offset;
    return 0;
}

long ftell(FILE *stream) {
    if (stream == NULL) {
        return -1;
    }
    return (long)stream->offset;
}

void rewind(FILE *stream) {
    if (stream != NULL) {
        stream->offset = 0;
    }
}

int fflush(FILE *stream) {
    (void)stream;
    return 0;  /* Nothing to flush for read-only files */
}

int feof(FILE *stream) {
    if (stream == NULL) {
        return 1;
    }
    return stream->offset >= stream->size;
}

int ferror(FILE *stream) {
    (void)stream;
    return 0;  /* No error tracking implemented */
}

/* ============================================
 * Formatted I/O (minimal implementation)
 * ============================================ */

/* Forward declaration from terminal */
extern void term_printf(const char *fmt, ...);

int fprintf(FILE *stream, const char *format, ...) {
    va_list args;
    va_start(args, format);

    if (stream && (stream->flags & FILE_FLAG_WRITE)) {
        /* Format into write buffer at current offset */
        int remaining = (int)(stream->size - stream->offset);
        if (remaining > 1) {
            int n = vsnprintf((char *)stream->data + stream->offset, remaining, format, args);
            if (n > 0) {
                stream->offset += (n < remaining) ? n : remaining - 1;
            }
        }
        va_end(args);
        return 0;
    }

    /* Fallback: format and print to terminal */
    char buf[256];
    vsnprintf(buf, sizeof(buf), format, args);
    extern void term_puts(const char *s);
    term_puts(buf);
    va_end(args);
    return 0;
}

int sprintf(char *str, const char *format, ...) {
    va_list args;
    va_start(args, format);
    int result = vsprintf(str, format, args);
    va_end(args);
    return result;
}

/* Core formatted print: va_list version with size limit */
int vsnprintf(char *str, size_t size, const char *format, va_list args) {
    char *out = str;
    char *end = str + size - 1;  /* Leave room for null */
    const char *p = format;

    if (size == 0) return 0;

    while (*p && out < end) {
        if (*p == '%') {
            p++;
            /* Parse flags */
            int left_align = 0;
            char pad_char = ' ';
            if (*p == '-') { left_align = 1; p++; }
            if (*p == '0') { pad_char = '0'; p++; }

            /* Parse width */
            int width = 0;
            while (*p >= '0' && *p <= '9') {
                width = width * 10 + (*p - '0');
                p++;
            }

            /* Parse precision */
            int precision = -1;
            if (*p == '.') {
                p++;
                precision = 0;
                while (*p >= '0' && *p <= '9') {
                    precision = precision * 10 + (*p - '0');
                    p++;
                }
            }

            /* Parse length modifier */
            int is_long = 0;
            if (*p == 'l') { is_long = 1; p++; }

            switch (*p) {
                case 'd':
                case 'i': {
                    long val = is_long ? va_arg(args, long) : (long)va_arg(args, int);
                    char buf[20];
                    int i = 0, neg = 0;
                    if (val < 0) { neg = 1; val = -val; }
                    do { buf[i++] = '0' + (val % 10); val /= 10; } while (val > 0);
                    int len = i + neg;
                    if (!left_align) while (len < width && out < end) { *out++ = pad_char; len++; }
                    if (neg && out < end) *out++ = '-';
                    while (i > 0 && out < end) *out++ = buf[--i];
                    if (left_align) while (len < width && out < end) { *out++ = ' '; len++; }
                    break;
                }
                case 'u': {
                    unsigned long val = is_long ? va_arg(args, unsigned long) : (unsigned long)va_arg(args, unsigned int);
                    char buf[20]; int i = 0;
                    do { buf[i++] = '0' + (val % 10); val /= 10; } while (val > 0);
                    int len = i;
                    if (!left_align) while (len < width && out < end) { *out++ = pad_char; len++; }
                    while (i > 0 && out < end) *out++ = buf[--i];
                    if (left_align) while (len < width && out < end) { *out++ = ' '; len++; }
                    break;
                }
                case 'x':
                case 'X': {
                    unsigned long val = is_long ? va_arg(args, unsigned long) : (unsigned long)va_arg(args, unsigned int);
                    const char *hex = (*p == 'x') ? "0123456789abcdef" : "0123456789ABCDEF";
                    char buf[16]; int i = 0;
                    do { buf[i++] = hex[val & 0xF]; val >>= 4; } while (val > 0);
                    int len = i;
                    if (!left_align) while (len < width && out < end) { *out++ = pad_char; len++; }
                    while (i > 0 && out < end) *out++ = buf[--i];
                    if (left_align) while (len < width && out < end) { *out++ = ' '; len++; }
                    break;
                }
                case 'f': {
                    float val = (float)va_arg(args, double);
                    int prec = (precision >= 0) ? precision : 6;
                    if (val < 0) { if (out < end) *out++ = '-'; val = -val; }
                    int ipart = (int)val;
                    float fpart = val - ipart;
                    /* Integer part */
                    char buf[20]; int i = 0;
                    do { buf[i++] = '0' + (ipart % 10); ipart /= 10; } while (ipart > 0);
                    int numlen = i + (prec > 0 ? 1 + prec : 0);
                    if (!left_align) while (numlen < width && out < end) { *out++ = pad_char; numlen++; }
                    while (i > 0 && out < end) *out++ = buf[--i];
                    /* Decimal part */
                    if (prec > 0) {
                        if (out < end) *out++ = '.';
                        for (i = 0; i < prec && out < end; i++) {
                            fpart *= 10.0f;
                            int d = (int)fpart;
                            if (d > 9) d = 9;
                            if (d < 0) d = 0;
                            *out++ = '0' + d;
                            fpart -= d;
                        }
                    }
                    break;
                }
                case 's': {
                    const char *s = va_arg(args, const char *);
                    if (!s) s = "(null)";
                    int len = 0; const char *t = s;
                    while (*t) { t++; len++; }
                    if (!left_align) while (len < width && out < end) { *out++ = ' '; width--; }
                    while (*s && out < end) *out++ = *s++;
                    if (left_align) while (len < width && out < end) { *out++ = ' '; len++; }
                    break;
                }
                case 'c': {
                    char c = (char)va_arg(args, int);
                    if (out < end) *out++ = c;
                    break;
                }
                case 'p': {
                    unsigned long val = (unsigned long)va_arg(args, void *);
                    if (out + 1 < end) { *out++ = '0'; *out++ = 'x'; }
                    char buf[16]; int i = 0;
                    do { buf[i++] = "0123456789abcdef"[val & 0xF]; val >>= 4; } while (val > 0);
                    while (i > 0 && out < end) *out++ = buf[--i];
                    break;
                }
                case '%':
                    if (out < end) *out++ = '%';
                    break;
                default:
                    if (out < end) *out++ = '%';
                    if (out < end) *out++ = *p;
                    break;
            }
        } else {
            *out++ = *p;
        }
        p++;
    }

    *out = '\0';
    return out - str;
}

int vsprintf(char *str, const char *format, va_list args) {
    return vsnprintf(str, 0x7FFFFFFF, format, args);
}

int snprintf(char *str, size_t size, const char *format, ...) {
    va_list args;
    va_start(args, format);
    int result = vsnprintf(str, size, format, args);
    va_end(args);
    return result;
}

int sscanf(const char *str, const char *format, ...) {
    va_list args;
    va_start(args, format);

    int count = 0;
    const char *s = str;
    const char *f = format;

    while (*f && *s) {
        if (*f == '%') {
            f++;
            switch (*f) {
                case 'd':
                case 'i': {
                    int *ptr = va_arg(args, int *);
                    int sign = 1;
                    int val = 0;

                    /* Skip whitespace */
                    while (isspace(*s)) s++;

                    if (*s == '-') {
                        sign = -1;
                        s++;
                    } else if (*s == '+') {
                        s++;
                    }

                    if (!isdigit(*s)) break;

                    while (isdigit(*s)) {
                        val = val * 10 + (*s - '0');
                        s++;
                    }

                    *ptr = val * sign;
                    count++;
                    break;
                }
                case 'f': {
                    float *ptr = va_arg(args, float *);

                    /* Skip whitespace */
                    while (isspace(*s)) s++;

                    /* Parse float using atof logic */
                    const char *start = s;
                    int sign = 1;
                    float val = 0.0f;
                    float frac = 0.0f;
                    float div = 1.0f;
                    int in_frac = 0;

                    if (*s == '-') { sign = -1; s++; }
                    else if (*s == '+') { s++; }

                    while (*s && (isdigit(*s) || *s == '.')) {
                        if (*s == '.') {
                            if (in_frac) break;
                            in_frac = 1;
                        } else if (in_frac) {
                            div *= 10.0f;
                            frac += (*s - '0') / div;
                        } else {
                            val = val * 10.0f + (*s - '0');
                        }
                        s++;
                    }

                    if (s == start) break;

                    *ptr = (val + frac) * sign;
                    count++;
                    break;
                }
                case 'x':
                case 'X': {
                    unsigned int *ptr = va_arg(args, unsigned int *);
                    unsigned int val = 0;

                    while (isspace(*s)) s++;

                    /* Skip 0x prefix if present */
                    if (s[0] == '0' && (s[1] == 'x' || s[1] == 'X')) {
                        s += 2;
                    }

                    while (*s) {
                        if (isdigit(*s)) {
                            val = val * 16 + (*s - '0');
                        } else if (*s >= 'a' && *s <= 'f') {
                            val = val * 16 + (*s - 'a' + 10);
                        } else if (*s >= 'A' && *s <= 'F') {
                            val = val * 16 + (*s - 'A' + 10);
                        } else {
                            break;
                        }
                        s++;
                    }

                    *ptr = val;
                    count++;
                    break;
                }
                default:
                    break;
            }
            f++;
        } else if (isspace(*f)) {
            /* Skip whitespace in both format and input */
            while (isspace(*f)) f++;
            while (isspace(*s)) s++;
        } else {
            /* Literal match */
            if (*f != *s) break;
            f++;
            s++;
        }
    }

    va_end(args);
    return count;
}

/* ============================================
 * POSIX-style file operations
 * ============================================ */

/* Use negative slot IDs as file descriptors */
#define FD_TO_SLOT(fd) (-(fd) - 1)
#define SLOT_TO_FD(slot) (-(slot) - 1)

static uint32_t fd_offset[16] = {0};
static uint32_t fd_size[16] = {0};
static int fd_used[16] = {0};

int open(const char *pathname, int flags, ...) {
    (void)flags;  /* Only O_RDONLY supported */

    int slot_id = filename_to_slot(pathname);
    if (slot_id < 0 || slot_id >= 16) {
        return -1;
    }

    if (fd_used[slot_id]) {
        return -1;  /* Already open */
    }

    /* Get size */
    if (dataslot_get_size(slot_id, &fd_size[slot_id]) != 0) {
        return -1;
    }

    fd_offset[slot_id] = 0;
    fd_used[slot_id] = 1;

    return SLOT_TO_FD(slot_id);
}

int close(int fd) {
    int slot_id = FD_TO_SLOT(fd);
    if (slot_id < 0 || slot_id >= 16 || !fd_used[slot_id]) {
        return -1;
    }

    fd_used[slot_id] = 0;
    return 0;
}

ssize_t read(int fd, void *buf, size_t count) {
    int slot_id = FD_TO_SLOT(fd);
    if (slot_id < 0 || slot_id >= 16 || !fd_used[slot_id]) {
        return -1;
    }

    uint32_t available = fd_size[slot_id] - fd_offset[slot_id];
    if (count > available) {
        count = available;
    }

    if (count == 0) {
        return 0;
    }

    /* DMA to bounce buffer, copy via uncacheable alias */
    uint8_t *dest = (uint8_t *)buf;
    size_t remaining = count;
    uint32_t off = fd_offset[slot_id];
    while (remaining > 0) {
        size_t chunk = remaining > DMA_CHUNK_SIZE ? DMA_CHUNK_SIZE : remaining;
        if (dataslot_read(slot_id, off, (void *)DMA_BUFFER, chunk) != 0) {
            return -1;
        }
        memcpy(dest, SDRAM_UNCACHED(DMA_BUFFER), chunk);
        dest += chunk;
        off += chunk;
        remaining -= chunk;
    }

    fd_offset[slot_id] += count;
    return count;
}

off_t lseek(int fd, off_t offset, int whence) {
    int slot_id = FD_TO_SLOT(fd);
    if (slot_id < 0 || slot_id >= 16 || !fd_used[slot_id]) {
        return -1;
    }

    off_t new_offset;
    switch (whence) {
        case SEEK_SET:
            new_offset = offset;
            break;
        case SEEK_CUR:
            new_offset = fd_offset[slot_id] + offset;
            break;
        case SEEK_END:
            new_offset = fd_size[slot_id] + offset;
            break;
        default:
            return -1;
    }

    if (new_offset < 0) {
        return -1;
    }

    fd_offset[slot_id] = new_offset;
    return new_offset;
}

int fgetc(FILE *stream) {
    unsigned char c;
    if (fread(&c, 1, 1, stream) == 1)
        return c;
    return EOF;
}

int getc(FILE *stream) {
    return fgetc(stream);
}

int unlink(const char *pathname) {
    (void)pathname;
    return -1;  /* Not supported */
}

ssize_t write(int fd, const void *buf, size_t count) {
    (void)fd;
    /* Write to terminal for stdout/stderr */
    extern void term_puts(const char *s);
    const char *p = (const char *)buf;
    size_t i;
    for (i = 0; i < count; i++) {
        extern void term_putchar(char c);
        term_putchar(p[i]);
    }
    return count;
}

int fscanf(FILE *stream, const char *format, ...) {
    /* Very limited fscanf - just enough for Quake's savegame loading */
    /* Read a line from the file and then sscanf it */
    char buf[256];
    int i = 0;
    int c;

    while (i < 255) {
        c = fgetc(stream);
        if (c == EOF || c == '\n')
            break;
        buf[i++] = (char)c;
    }
    buf[i] = '\0';

    va_list args;
    va_start(args, format);
    int result = 0;
    /* Basic: just pass to sscanf */
    /* We can't easily forward varargs to sscanf, so handle common patterns */
    /* Quake save files use simple %d and %f patterns */
    const char *s = buf;
    const char *f = format;

    while (*f && *s) {
        if (*f == '%') {
            f++;
            /* Skip optional width specifier (e.g., %79s) */
            while (isdigit(*f)) f++;
            if (*f == 'd' || *f == 'i') {
                int *ptr = va_arg(args, int *);
                int val = 0, sign = 1;
                while (isspace(*s)) s++;
                if (*s == '-') { sign = -1; s++; }
                while (isdigit(*s)) { val = val * 10 + (*s - '0'); s++; }
                *ptr = val * sign;
                result++;
                f++;
            } else if (*f == 'f') {
                float *ptr = va_arg(args, float *);
                *ptr = (float)atof(s);
                while (*s && !isspace(*s)) s++;
                result++;
                f++;
            } else if (*f == 's') {
                char *ptr = va_arg(args, char *);
                while (isspace(*s)) s++;
                while (*s && !isspace(*s)) *ptr++ = *s++;
                *ptr = '\0';
                result++;
                f++;
            } else {
                f++;
            }
        } else if (isspace(*f)) {
            while (isspace(*f)) f++;
            while (isspace(*s)) s++;
        } else {
            if (*f != *s) break;
            f++; s++;
        }
    }

    va_end(args);
    return result;
}

/* ============================================
 * mmap emulation
 * ============================================ */

/* Static buffer for mmap'd data - we allocate from SDRAM heap */
void *mmap(void *addr, size_t length, int prot, int flags, int fd, off_t offset) {
    (void)addr;
    (void)prot;
    (void)flags;

    int slot_id = FD_TO_SLOT(fd);
    if (slot_id < 0 || slot_id >= 16 || !fd_used[slot_id]) {
        return MAP_FAILED;
    }

    /* Allocate memory for the mapped region */
    void *ptr = malloc(length);
    if (ptr == NULL) {
        return MAP_FAILED;
    }

    /* DMA to bounce buffer in chunks, copy via uncacheable alias to
     * avoid stale D-cache lines at the malloc'd destination. */
    uint8_t *dest = (uint8_t *)ptr;
    size_t remaining = length;
    uint32_t slot_off = (uint32_t)offset;
    while (remaining > 0) {
        size_t chunk = remaining > DMA_CHUNK_SIZE ? DMA_CHUNK_SIZE : remaining;
        if (dataslot_read(slot_id, slot_off, (void *)DMA_BUFFER, chunk) != 0) {
            free(ptr);
            return MAP_FAILED;
        }
        memcpy(dest, SDRAM_UNCACHED(DMA_BUFFER), chunk);
        dest += chunk;
        slot_off += chunk;
        remaining -= chunk;
    }

    return ptr;
}

int munmap(void *addr, size_t length) {
    (void)length;
    if (addr != NULL && addr != MAP_FAILED) {
        free(addr);
    }
    return 0;
}
