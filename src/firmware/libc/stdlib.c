/*
 * Standard library functions for VexRiscv
 */

#include "libc.h"

int errno = 0;

/* Simple LCG random number generator */
static unsigned int _rand_seed = 1;

int rand(void) {
    _rand_seed = _rand_seed * 1103515245 + 12345;
    return (_rand_seed >> 16) & 0x7FFF;
}

void srand(unsigned int seed) {
    _rand_seed = seed;
}

#define RAND_MAX 0x7FFF

char *strerror(int errnum) {
    switch (errnum) {
        case 0: return "Success";
        case ENOENT: return "No such file or directory";
        case EINVAL: return "Invalid argument";
        case ERANGE: return "Result too large";
        default: return "Unknown error";
    }
}

int abs(int j) {
    return (j < 0) ? -j : j;
}

long labs(long j) {
    return (j < 0) ? -j : j;
}

int atoi(const char *nptr) {
    return (int)atol(nptr);
}

long atol(const char *nptr) {
    long result = 0;
    int sign = 1;

    /* Skip whitespace */
    while (isspace(*nptr)) {
        nptr++;
    }

    /* Handle sign */
    if (*nptr == '-') {
        sign = -1;
        nptr++;
    } else if (*nptr == '+') {
        nptr++;
    }

    /* Convert digits */
    while (isdigit(*nptr)) {
        result = result * 10 + (*nptr - '0');
        nptr++;
    }

    return result * sign;
}

long strtol(const char *nptr, char **endptr, int base) {
    long result = 0;
    int sign = 1;
    const char *start = nptr;

    /* Skip whitespace */
    while (isspace(*nptr)) {
        nptr++;
    }

    /* Handle sign */
    if (*nptr == '-') {
        sign = -1;
        nptr++;
    } else if (*nptr == '+') {
        nptr++;
    }

    /* Handle base prefix */
    if (base == 0) {
        if (*nptr == '0') {
            nptr++;
            if (*nptr == 'x' || *nptr == 'X') {
                base = 16;
                nptr++;
            } else {
                base = 8;
            }
        } else {
            base = 10;
        }
    } else if (base == 16) {
        if (*nptr == '0' && (*(nptr + 1) == 'x' || *(nptr + 1) == 'X')) {
            nptr += 2;
        }
    }

    /* Convert digits */
    while (*nptr) {
        int digit;

        if (isdigit(*nptr)) {
            digit = *nptr - '0';
        } else if (*nptr >= 'a' && *nptr <= 'z') {
            digit = *nptr - 'a' + 10;
        } else if (*nptr >= 'A' && *nptr <= 'Z') {
            digit = *nptr - 'A' + 10;
        } else {
            break;
        }

        if (digit >= base) {
            break;
        }

        result = result * base + digit;
        nptr++;
    }

    if (endptr) {
        *endptr = (char *)nptr;
    }

    return result * sign;
}

unsigned long strtoul(const char *nptr, char **endptr, int base) {
    return (unsigned long)strtol(nptr, endptr, base);
}

/* Software floating-point atof implementation */
double atof(const char *nptr) {
    float result = 0.0f;
    float fraction = 0.0f;
    float divisor = 1.0f;
    int sign = 1;
    int exp_sign = 1;
    int exponent = 0;
    int in_fraction = 0;
    int in_exponent = 0;

    /* Skip whitespace */
    while (isspace(*nptr)) {
        nptr++;
    }

    /* Handle sign */
    if (*nptr == '-') {
        sign = -1;
        nptr++;
    } else if (*nptr == '+') {
        nptr++;
    }

    /* Parse mantissa */
    while (*nptr) {
        if (isdigit(*nptr)) {
            if (in_exponent) {
                exponent = exponent * 10 + (*nptr - '0');
            } else if (in_fraction) {
                divisor *= 10.0f;
                fraction += (*nptr - '0') / divisor;
            } else {
                result = result * 10.0f + (*nptr - '0');
            }
        } else if (*nptr == '.' && !in_fraction && !in_exponent) {
            in_fraction = 1;
        } else if ((*nptr == 'e' || *nptr == 'E') && !in_exponent) {
            in_exponent = 1;
            nptr++;
            if (*nptr == '-') {
                exp_sign = -1;
                nptr++;
            } else if (*nptr == '+') {
                nptr++;
            }
            continue;
        } else {
            break;
        }
        nptr++;
    }

    result = (result + fraction) * sign;

    /* Apply exponent */
    if (exponent != 0) {
        float exp_mult = 1.0f;
        while (exponent > 0) {
            exp_mult *= 10.0f;
            exponent--;
        }
        if (exp_sign < 0) {
            result /= exp_mult;
        } else {
            result *= exp_mult;
        }
    }

    return (double)result;
}

void exit(int status) {
    (void)status;
    /* Infinite loop - no OS to return to */
    while (1) {
        /* Could add a soft reset here if desired */
    }
}

void abort(void) {
    exit(EXIT_FAILURE);
}
