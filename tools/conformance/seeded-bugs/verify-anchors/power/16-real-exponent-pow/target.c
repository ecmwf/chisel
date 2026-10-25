#include <tgmath.h>

#ifdef FIXTURE_DP
typedef double real_t;
#define CONST(x) x
#else
typedef float real_t;
#define CONST(x) x##f
#endif

static const real_t x = CONST(2.0); /* src: source.F90:8 = 2._WP */
#define PR pow(x, CONST(1.5)) /* src: source.F90:9 = X**1.5_WP */
