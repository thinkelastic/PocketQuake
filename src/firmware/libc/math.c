/*
 * Software floating-point math library for VexRiscv
 * Uses software float emulation for IEEE 754 operations
 *
 * These implementations prioritize correctness over speed.
 * For better performance, consider lookup tables or CORDIC.
 */

#include "libc.h"

/* Constants */
#define M_PI        3.14159265358979323846f
#define M_PI_2      1.57079632679489661923f
#define M_E         2.71828182845904523536f
#define M_LN2       0.693147180559945309417f
#define M_LN10      2.302585092994045684017f

/* Floating point bit manipulation helpers */
typedef union {
    float f;
    uint32_t u;
    int32_t i;
} float_bits;

typedef union {
    double d;
    uint64_t u;
    int64_t i;
} double_bits;

/* ============================================
 * Basic math functions
 * ============================================ */

float fabsf(float x) {
    float_bits fb;
    fb.f = x;
    fb.u &= 0x7FFFFFFF;  /* Clear sign bit */
    return fb.f;
}

double fabs(double x) {
    return (double)fabsf((float)x);
}

/* ============================================
 * Square root - Newton-Raphson method
 * ============================================ */

float sqrtf(float x) {
    if (x < 0.0f) {
        return 0.0f / 0.0f;  /* NaN */
    }
    if (x == 0.0f || x == 1.0f) {
        return x;
    }

    /* Initial guess using bit manipulation (fast inverse square root trick) */
    float_bits fb;
    fb.f = x;
    fb.u = 0x5f3759df - (fb.u >> 1);  /* Magic number for 1/sqrt(x) */
    float y = fb.f;

    /* Newton-Raphson iterations for 1/sqrt(x) */
    y = y * (1.5f - 0.5f * x * y * y);
    y = y * (1.5f - 0.5f * x * y * y);
    y = y * (1.5f - 0.5f * x * y * y);

    /* Return sqrt(x) = x * (1/sqrt(x)) */
    return x * y;
}

double sqrt(double x) {
    return (double)sqrtf((float)x);
}

/* ============================================
 * Exponential function - Taylor series
 * exp(x) = 1 + x + x^2/2! + x^3/3! + ...
 * ============================================ */

float expf(float x) {
    /* Handle special cases */
    if (x == 0.0f) return 1.0f;
    if (x > 88.0f) return 1.0f / 0.0f;   /* Overflow to +inf */
    if (x < -88.0f) return 0.0f;          /* Underflow to 0 */

    /* Range reduction: exp(x) = exp(k*ln2 + r) = 2^k * exp(r)
     * where |r| <= ln2/2 */
    int k = (int)(x / M_LN2 + (x >= 0 ? 0.5f : -0.5f));
    float r = x - k * (float)M_LN2;

    /* Taylor series for exp(r) where |r| <= ln2/2 */
    float sum = 1.0f;
    float term = r;
    sum += term;

    term *= r / 2.0f;
    sum += term;

    term *= r / 3.0f;
    sum += term;

    term *= r / 4.0f;
    sum += term;

    term *= r / 5.0f;
    sum += term;

    term *= r / 6.0f;
    sum += term;

    term *= r / 7.0f;
    sum += term;

    term *= r / 8.0f;
    sum += term;

    /* Multiply by 2^k using bit manipulation */
    if (k != 0) {
        float_bits fb;
        fb.f = sum;
        fb.u += (uint32_t)k << 23;  /* Add k to exponent */
        return fb.f;
    }

    return sum;
}

double exp(double x) {
    return (double)expf((float)x);
}

/* ============================================
 * Natural logarithm - Taylor series
 * ln(x) = ln((1+y)/(1-y)) = 2(y + y^3/3 + y^5/5 + ...)
 * where y = (x-1)/(x+1)
 * ============================================ */

float logf(float x) {
    if (x <= 0.0f) {
        if (x == 0.0f) return -1.0f / 0.0f;  /* -inf */
        return 0.0f / 0.0f;  /* NaN */
    }
    if (x == 1.0f) return 0.0f;

    /* Range reduction: x = m * 2^e where 1 <= m < 2
     * ln(x) = ln(m) + e*ln(2) */
    float_bits fb;
    fb.f = x;
    int e = ((fb.u >> 23) & 0xFF) - 127;
    fb.u = (fb.u & 0x007FFFFF) | 0x3F800000;  /* Set exponent to 0 (m in [1,2)) */
    float m = fb.f;

    /* Adjust if m is close to 2 for better convergence */
    if (m > 1.41421356f) {  /* sqrt(2) */
        m *= 0.5f;
        e++;
    }

    /* y = (m-1)/(m+1), using Taylor series for ln((1+y)/(1-y)) */
    float y = (m - 1.0f) / (m + 1.0f);
    float y2 = y * y;

    /* ln((1+y)/(1-y)) = 2(y + y^3/3 + y^5/5 + y^7/7 + ...) */
    float sum = y;
    float term = y * y2;
    sum += term / 3.0f;

    term *= y2;
    sum += term / 5.0f;

    term *= y2;
    sum += term / 7.0f;

    term *= y2;
    sum += term / 9.0f;

    term *= y2;
    sum += term / 11.0f;

    sum *= 2.0f;

    return sum + e * (float)M_LN2;
}

double log(double x) {
    return (double)logf((float)x);
}

/* ============================================
 * Power function
 * pow(x, y) = exp(y * ln(x))
 * ============================================ */

float powf(float x, float y) {
    if (y == 0.0f) return 1.0f;
    if (x == 0.0f) return 0.0f;
    if (x == 1.0f) return 1.0f;

    /* Handle negative base */
    if (x < 0.0f) {
        /* Only valid for integer exponents */
        int yi = (int)y;
        if ((float)yi != y) {
            return 0.0f / 0.0f;  /* NaN */
        }
        float result = expf(y * logf(-x));
        return (yi & 1) ? -result : result;
    }

    return expf(y * logf(x));
}

double pow(double x, double y) {
    return (double)powf((float)x, (float)y);
}

/* ============================================
 * Trigonometric functions - Taylor series
 * sin(x) = x - x^3/3! + x^5/5! - x^7/7! + ...
 * cos(x) = 1 - x^2/2! + x^4/4! - x^6/6! + ...
 * ============================================ */

/* Reduce angle to [-pi, pi] */
static float reduce_angle(float x) {
    /* Reduce to [-2pi, 2pi] first */
    float two_pi = 2.0f * (float)M_PI;
    int k = (int)(x / two_pi);
    x -= k * two_pi;

    /* Further reduce to [-pi, pi] */
    if (x > (float)M_PI) {
        x -= two_pi;
    } else if (x < -(float)M_PI) {
        x += two_pi;
    }

    return x;
}

float sinf(float x) {
    x = reduce_angle(x);

    /* For |x| > pi/2, mirror into primary interval.
     * sin(x) = sin(pi - x) for x in (pi/2, pi]
     * sin(x) = -sin(pi + x) for x in [-pi, -pi/2) */
    if (fabsf(x) > (float)M_PI_2) {
        if (x > 0) {
            return sinf((float)M_PI - x);
        } else {
            return -sinf((float)M_PI + x);
        }
    }

    /* Taylor series for sin(x) */
    float x2 = x * x;
    float term = x;
    float sum = term;

    term *= -x2 / 6.0f;         /* x^3/3! */
    sum += term;

    term *= -x2 / 20.0f;        /* x^5/5! */
    sum += term;

    term *= -x2 / 42.0f;        /* x^7/7! */
    sum += term;

    term *= -x2 / 72.0f;        /* x^9/9! */
    sum += term;

    term *= -x2 / 110.0f;       /* x^11/11! */
    sum += term;

    return sum;
}

float cosf(float x) {
    x = reduce_angle(x);
    x = fabsf(x);  /* cos(-x) = cos(x) */

    /* For x > pi/4, use identity cos(x) = sin(pi/2 - x) */
    if (x > (float)M_PI_2) {
        return -cosf((float)M_PI - x);
    }

    /* Taylor series for cos(x) */
    float x2 = x * x;
    float term = 1.0f;
    float sum = term;

    term *= -x2 / 2.0f;         /* x^2/2! */
    sum += term;

    term *= -x2 / 12.0f;        /* x^4/4! */
    sum += term;

    term *= -x2 / 30.0f;        /* x^6/6! */
    sum += term;

    term *= -x2 / 56.0f;        /* x^8/8! */
    sum += term;

    term *= -x2 / 90.0f;        /* x^10/10! */
    sum += term;

    return sum;
}

float tanf(float x) {
    float c = cosf(x);
    if (fabsf(c) < 1e-10f) {
        return (x > 0) ? 1.0f / 0.0f : -1.0f / 0.0f;  /* +/-inf */
    }
    return sinf(x) / c;
}

double sin(double x) {
    return (double)sinf((float)x);
}

double cos(double x) {
    return (double)cosf((float)x);
}

double tan(double x) {
    return (double)tanf((float)x);
}

/* ============================================
 * Floor and ceiling functions
 * ============================================ */

float floorf(float x) {
    int i = (int)x;
    return (x < 0.0f && (float)i != x) ? (float)(i - 1) : (float)i;
}

float ceilf(float x) {
    int i = (int)x;
    return (x > 0.0f && (float)i != x) ? (float)(i + 1) : (float)i;
}

double floor(double x) {
    return (double)floorf((float)x);
}

double ceil(double x) {
    return (double)ceilf((float)x);
}

/* ============================================
 * Round function
 * ============================================ */

float roundf(float x) {
    if (x >= 0.0f) {
        return floorf(x + 0.5f);
    } else {
        return ceilf(x - 0.5f);
    }
}

double round(double x) {
    return (double)roundf((float)x);
}

/* ============================================
 * Additional math functions needed by Quake
 * ============================================ */

float fmodf(float x, float y) {
    if (y == 0.0f) return 0.0f / 0.0f;  /* NaN */
    int n = (int)(x / y);
    return x - n * y;
}

double fmod(double x, double y) {
    return (double)fmodf((float)x, (float)y);
}

float atan2f(float y, float x) {
    /* Handle special cases */
    if (x == 0.0f) {
        if (y > 0.0f) return (float)M_PI_2;
        if (y < 0.0f) return -(float)M_PI_2;
        return 0.0f;
    }

    float a = y / x;
    float abs_a = fabsf(a);
    float r;

    /* Polynomial approximation of atan for |a| <= 1 */
    if (abs_a <= 1.0f) {
        /* atan(a) ≈ a - a^3/3 + a^5/5 - a^7/7 + a^9/9 */
        float a2 = a * a;
        r = a;
        float term = a * a2;
        r -= term / 3.0f;
        term *= a2;
        r += term / 5.0f;
        term *= a2;
        r -= term / 7.0f;
        term *= a2;
        r += term / 9.0f;
        term *= a2;
        r -= term / 11.0f;
    } else {
        /* atan(a) = pi/2 - atan(1/a) for |a| > 1 */
        float inv_a = 1.0f / a;
        float inv_a2 = inv_a * inv_a;
        r = inv_a;
        float term = inv_a * inv_a2;
        r -= term / 3.0f;
        term *= inv_a2;
        r += term / 5.0f;
        term *= inv_a2;
        r -= term / 7.0f;
        term *= inv_a2;
        r += term / 9.0f;

        if (a > 0.0f)
            r = (float)M_PI_2 - r;
        else
            r = -(float)M_PI_2 - r;
    }

    /* Adjust for quadrant */
    if (x < 0.0f) {
        if (y >= 0.0f)
            r += (float)M_PI;
        else
            r -= (float)M_PI;
    }

    return r;
}

double atan2(double y, double x) {
    return (double)atan2f((float)y, (float)x);
}

float atanf(float x) {
    return atan2f(x, 1.0f);
}

double atan(double x) {
    return (double)atanf((float)x);
}

float asinf(float x) {
    if (x < -1.0f || x > 1.0f) return 0.0f / 0.0f;  /* NaN */
    if (x == 1.0f) return (float)M_PI_2;
    if (x == -1.0f) return -(float)M_PI_2;
    /* asin(x) = atan2(x, sqrt(1 - x*x)) */
    return atan2f(x, sqrtf(1.0f - x * x));
}

double asin(double x) {
    return (double)asinf((float)x);
}

float acosf(float x) {
    if (x < -1.0f || x > 1.0f) return 0.0f / 0.0f;  /* NaN */
    /* acos(x) = pi/2 - asin(x) */
    return (float)M_PI_2 - asinf(x);
}

double acos(double x) {
    return (double)acosf((float)x);
}

float log2f(float x) {
    return logf(x) / (float)M_LN2;
}

float log10f(float x) {
    return logf(x) / (float)M_LN10;
}

float frexpf(float x, int *exp) {
    if (x == 0.0f) {
        *exp = 0;
        return 0.0f;
    }
    float_bits fb;
    fb.f = x;
    *exp = ((fb.u >> 23) & 0xFF) - 126;
    fb.u = (fb.u & 0x807FFFFF) | 0x3F000000;  /* exponent = -1 (0.5 <= |m| < 1) */
    return fb.f;
}

float ldexpf(float x, int exp) {
    float_bits fb;
    fb.f = x;
    int cur_exp = ((fb.u >> 23) & 0xFF);
    cur_exp += exp;
    if (cur_exp <= 0) return 0.0f;
    if (cur_exp >= 255) return (x > 0) ? (1.0f / 0.0f) : (-1.0f / 0.0f);
    fb.u = (fb.u & 0x807FFFFF) | ((unsigned int)cur_exp << 23);
    return fb.f;
}
