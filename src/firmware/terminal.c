/*
 * Simple text terminal driver
 * 40x30 character display at 0x20000000
 */

#include "terminal.h"

/* Terminal VRAM address */
#define TERM_VRAM   ((volatile char *)0x20000000)

/* Cursor position — placed in BRAM BSS so clear_qbss() doesn't reset them */
static int cursor_row __attribute__((section(".bss.boot"))) = 0;
static int cursor_col __attribute__((section(".bss.boot"))) = 0;

void term_init(void) {
    cursor_row = 0;
    cursor_col = 0;
    term_clear();
}

void term_clear(void) {
    for (int i = 0; i < TERM_SIZE; i++) {
        TERM_VRAM[i] = ' ';
    }
    cursor_row = 0;
    cursor_col = 0;
}

void term_setpos(int row, int col) {
    if (row >= 0 && row < TERM_ROWS) cursor_row = row;
    if (col >= 0 && col < TERM_COLS) cursor_col = col;
}

int term_getpos(void) {
    return cursor_row * TERM_COLS + cursor_col;
}

static void scroll_up(void) {
    /* Move all lines up by one */
    for (int i = 0; i < (TERM_ROWS - 1) * TERM_COLS; i++) {
        TERM_VRAM[i] = TERM_VRAM[i + TERM_COLS];
    }
    /* Clear the last line */
    for (int i = 0; i < TERM_COLS; i++) {
        TERM_VRAM[(TERM_ROWS - 1) * TERM_COLS + i] = ' ';
    }
}

void term_putchar(char c) {
    if (c == '\n') {
        cursor_col = 0;
        cursor_row++;
    } else if (c == '\r') {
        cursor_col = 0;
    } else if (c == '\b') {
        if (cursor_col > 0) cursor_col--;
    } else {
        TERM_VRAM[cursor_row * TERM_COLS + cursor_col] = c;
        cursor_col++;
        if (cursor_col >= TERM_COLS) {
            cursor_col = 0;
            cursor_row++;
        }
    }

    /* Handle scrolling */
    if (cursor_row >= TERM_ROWS) {
        scroll_up();
        cursor_row = TERM_ROWS - 1;
    }
}

void term_puts(const char *s) {
    while (*s) {
        term_putchar(*s++);
    }
}

void term_println(const char *s) {
    term_puts(s);
    term_putchar('\n');
}

void term_puthex(uint32_t val, int digits) {
    static const char hex[] = "0123456789ABCDEF";
    for (int i = digits - 1; i >= 0; i--) {
        term_putchar(hex[(val >> (i * 4)) & 0xF]);
    }
}

void term_putdec(int32_t val) {
    char buf[12];
    int i = 0;
    int neg = 0;

    if (val < 0) {
        neg = 1;
        val = -val;
    }

    if (val == 0) {
        term_putchar('0');
        return;
    }

    while (val > 0) {
        buf[i++] = '0' + (val % 10);
        val /= 10;
    }

    if (neg) term_putchar('-');

    while (i > 0) {
        term_putchar(buf[--i]);
    }
}

void term_printf(const char *fmt, ...) {
    va_list args;
    va_start(args, fmt);

    while (*fmt) {
        if (*fmt == '%') {
            fmt++;
            int width = 0;
            int zero_pad = 0;

            /* Check for zero padding */
            if (*fmt == '0') {
                zero_pad = 1;
                fmt++;
            }

            /* Parse width */
            while (*fmt >= '0' && *fmt <= '9') {
                width = width * 10 + (*fmt - '0');
                fmt++;
            }

            switch (*fmt) {
                case 'd': {
                    int32_t val = va_arg(args, int32_t);
                    term_putdec(val);
                    break;
                }
                case 'u': {
                    uint32_t val = va_arg(args, uint32_t);
                    char buf[12];
                    int i = 0;
                    if (val == 0) {
                        term_putchar('0');
                    } else {
                        while (val > 0) {
                            buf[i++] = '0' + (val % 10);
                            val /= 10;
                        }
                        while (i > 0) term_putchar(buf[--i]);
                    }
                    break;
                }
                case 'x':
                case 'X': {
                    uint32_t val = va_arg(args, uint32_t);
                    if (width == 0) {
                        /* Default: print all significant digits, minimum 1 */
                        if (val == 0) {
                            width = 1;
                        } else {
                            /* Count digits needed */
                            uint32_t tmp = val;
                            width = 0;
                            while (tmp) {
                                width++;
                                tmp >>= 4;
                            }
                        }
                    }
                    term_puthex(val, width);
                    break;
                }
                case 's': {
                    const char *s = va_arg(args, const char *);
                    if (s) term_puts(s);
                    break;
                }
                case 'c': {
                    char c = (char)va_arg(args, int);
                    term_putchar(c);
                    break;
                }
                case '%':
                    term_putchar('%');
                    break;
                default:
                    term_putchar('%');
                    term_putchar(*fmt);
                    break;
            }
        } else {
            term_putchar(*fmt);
        }
        fmt++;
    }

    va_end(args);
}
