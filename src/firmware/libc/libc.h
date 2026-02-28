/*
 * Minimal libc for VexRiscv on Analogue Pocket
 * Provides essential functions for PocketQuake
 */

#ifndef LIBC_H
#define LIBC_H

#include <stdint.h>
#include <stddef.h>
#include <stdarg.h>

/* Memory map constants */
#define SDRAM_BASE      0x10000000
#define SDRAM_SIZE      0x04000000  /* 64MB */
#define SYSREG_BASE     0x40000000

/* System registers */
#define SYS_STATUS      (*(volatile uint32_t*)(SYSREG_BASE + 0x00))
#define SYS_CYCLE_LO    (*(volatile uint32_t*)(SYSREG_BASE + 0x04))
#define SYS_CYCLE_HI    (*(volatile uint32_t*)(SYSREG_BASE + 0x08))

/* Hardware performance counters (sysreg) */
#define SYS_PERF_SPAN       (*(volatile uint32_t*)(SYSREG_BASE + 0x70))
#define SYS_PERF_DMA        (*(volatile uint32_t*)(SYSREG_BASE + 0x74))
#define SYS_PERF_SRAMFILL   (*(volatile uint32_t*)(SYSREG_BASE + 0x78))
#define SYS_PERF_SRAM_BUSY  (*(volatile uint32_t*)(SYSREG_BASE + 0x7C))
#define SYS_PERF_SDRAM      (*(volatile uint32_t*)(SYSREG_BASE + 0x80))
#define SYS_PERF_SDRAM_SPAN (*(volatile uint32_t*)(SYSREG_BASE + 0x84))
#define SYS_PERF_SDRAM_DMA  (*(volatile uint32_t*)(SYSREG_BASE + 0x88))
#define SYS_PERF_SDRAM_CPU  (*(volatile uint32_t*)(SYSREG_BASE + 0x8C))

/* Span rasterizer performance counters (write-clear via SPAN_PERF_CACHE_HITS) */
#define SPAN_PERF_CACHE_HITS   (*(volatile uint32_t*)0x4800005C)
#define SPAN_PERF_CACHE_MISSES (*(volatile uint32_t*)0x48000060)
#define SPAN_PERF_PIXELS       (*(volatile uint32_t*)0x48000064)

/* Status bits */
#define SYS_STATUS_SDRAM_READY          0x01
#define SYS_STATUS_DATASLOT_COMPLETE    0x02

/* ============================================
 * Standard type definitions
 * ============================================ */

typedef long ssize_t;
typedef long off_t;
typedef long time_t;

/* ============================================
 * Memory functions (memory.c)
 * ============================================ */

/* Heap initialization - call once at startup */
void heap_init(void *start, size_t size);

/* Standard allocation functions */
void *malloc(size_t size);
void *calloc(size_t nmemb, size_t size);
void *realloc(void *ptr, size_t size);
void free(void *ptr);

/* Memory operations */
void *memcpy(void *dest, const void *src, size_t n);
void *memset(void *s, int c, size_t n);
void *memmove(void *dest, const void *src, size_t n);
int memcmp(const void *s1, const void *s2, size_t n);

/* ============================================
 * String functions (string.c)
 * ============================================ */

size_t strlen(const char *s);
char *strcpy(char *dest, const char *src);
char *strncpy(char *dest, const char *src, size_t n);
char *strcat(char *dest, const char *src);
char *strncat(char *dest, const char *src, size_t n);
int strcmp(const char *s1, const char *s2);
int strncmp(const char *s1, const char *s2, size_t n);
char *strchr(const char *s, int c);
char *strrchr(const char *s, int c);
char *strstr(const char *haystack, const char *needle);
char *strtok(char *str, const char *delim);
char *strdup(const char *s);
int strcasecmp(const char *s1, const char *s2);
int strncasecmp(const char *s1, const char *s2, size_t n);

/* ============================================
 * Character functions (ctype.c)
 * ============================================ */

int isprint(int c);
int isspace(int c);
int isdigit(int c);
int isalpha(int c);
int isalnum(int c);
int isupper(int c);
int islower(int c);
int tolower(int c);
int toupper(int c);

/* ============================================
 * Stdlib functions (stdlib.c)
 * ============================================ */

int abs(int j);
long labs(long j);
int atoi(const char *nptr);
long atol(const char *nptr);
double atof(const char *nptr);
long strtol(const char *nptr, char **endptr, int base);
unsigned long strtoul(const char *nptr, char **endptr, int base);

void exit(int status) __attribute__((noreturn));
void abort(void) __attribute__((noreturn));

/* ============================================
 * Sorting functions (qsort.c)
 * ============================================ */

void qsort(void *base, size_t nmemb, size_t size,
           int (*compar)(const void *, const void *));

void *bsearch(const void *key, const void *base, size_t nmemb, size_t size,
              int (*compar)(const void *, const void *));

/* ============================================
 * Time functions (time.c)
 * ============================================ */

struct timespec {
    time_t tv_sec;
    long tv_nsec;
};

#define CLOCK_REALTIME  0
#define CLOCK_MONOTONIC 1

time_t time(time_t *tloc);
int clock_gettime(int clk_id, struct timespec *tp);

/* ============================================
 * Math functions (math.c)
 * ============================================ */

/* Basic math */
float fabsf(float x);
double fabs(double x);

/* Square root */
float sqrtf(float x);
double sqrt(double x);

/* Exponential and logarithm */
float expf(float x);
double exp(double x);
float logf(float x);
double log(double x);

/* Power */
float powf(float x, float y);
double pow(double x, double y);

/* Trigonometric */
float sinf(float x);
float cosf(float x);
float tanf(float x);
double sin(double x);
double cos(double x);
double tan(double x);

/* Floor/ceiling */
float floorf(float x);
float ceilf(float x);
double floor(double x);
double ceil(double x);

/* Round */
float roundf(float x);
double round(double x);

/* Additional math (needed by Quake) */
float fmodf(float x, float y);
double fmod(double x, double y);
float atan2f(float y, float x);
double atan2(double y, double x);
float atanf(float x);
double atan(double x);
float asinf(float x);
double asin(double x);
float acosf(float x);
double acos(double x);
float log2f(float x);
float log10f(float x);
float frexpf(float x, int *exp);
float ldexpf(float x, int exp);

/* ============================================
 * File I/O emulation (file.c)
 * ============================================ */

/* FILE structure - simplified for data slot backend */
typedef struct {
    uint16_t slot_id;
    uint32_t offset;
    uint32_t size;
    uint32_t flags;
    void *data;         /* Pointer to loaded data in SDRAM */
} FILE;

extern FILE *stdin;
extern FILE *stdout;
extern FILE *stderr;

#define EOF (-1)
#define SEEK_SET 0
#define SEEK_CUR 1
#define SEEK_END 2

/* File operations */
FILE *fopen(const char *pathname, const char *mode);
int fclose(FILE *stream);
size_t fread(void *ptr, size_t size, size_t nmemb, FILE *stream);
size_t fwrite(const void *ptr, size_t size, size_t nmemb, FILE *stream);
int fseek(FILE *stream, long offset, int whence);
long ftell(FILE *stream);
void rewind(FILE *stream);
int fflush(FILE *stream);
int feof(FILE *stream);
int ferror(FILE *stream);

/* Formatted I/O */
int fprintf(FILE *stream, const char *format, ...);
int sprintf(char *str, const char *format, ...);
int snprintf(char *str, size_t size, const char *format, ...);
int vsnprintf(char *str, size_t size, const char *format, va_list args);
int vsprintf(char *str, const char *format, va_list args);
int sscanf(const char *str, const char *format, ...);
int fscanf(FILE *stream, const char *format, ...);
int fgetc(FILE *stream);
int getc(FILE *stream);
int unlink(const char *pathname);
ssize_t write(int fd, const void *buf, size_t count);
int rand(void);
void srand(unsigned int seed);
#define RAND_MAX 0x7FFF

/* POSIX-style file operations */
#define O_RDONLY 0

int open(const char *pathname, int flags, ...);
int close(int fd);
ssize_t read(int fd, void *buf, size_t count);
off_t lseek(int fd, off_t offset, int whence);

/* mmap emulation */
#define PROT_READ   0x1
#define MAP_PRIVATE 0x02
#define MAP_FAILED  ((void *)-1)

void *mmap(void *addr, size_t length, int prot, int flags, int fd, off_t offset);
int munmap(void *addr, size_t length);

/* ============================================
 * Compatibility macros
 * ============================================ */

/* ============================================
 * setjmp/longjmp
 * ============================================ */

typedef int jmp_buf[26];  /* ra, sp, s0-s11, fs0-fs11 */

int setjmp(jmp_buf env);
void longjmp(jmp_buf env, int val) __attribute__((noreturn));

/* ============================================
 * errno emulation
 * ============================================ */

extern int errno;
#define ENOENT  2
#define EINVAL  22
#define ERANGE  34

/* strerror */
char *strerror(int errnum);

/* ============================================
 * Compatibility macros
 * ============================================ */

#ifndef NULL
#define NULL ((void*)0)
#endif
#define EXIT_SUCCESS 0
#define EXIT_FAILURE 1

/* va_copy for compilers that support it */
#ifndef va_copy
#define va_copy(dest, src) ((dest) = (src))
#endif

#endif /* LIBC_H */
