#include <tgmath.h>

#ifdef FIXTURE_DP
typedef double real_t;
#define CONST(x) x
#else
typedef float real_t;
#define CONST(x) x##f
#endif

static const real_t a = CONST(0.5); /* src: source.F90:8 = 0.5_WP */
static const real_t b = CONST(0.25); /* src: source.F90:9 = 0.25_WP */
#define EA exp(a) /* src: source.F90:10 = EXP(A) */
