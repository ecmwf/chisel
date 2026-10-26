#include <tgmath.h>

#ifdef FIXTURE_DP
typedef double real_t;
#define CONST(x) x
#else
typedef float real_t;
#define CONST(x) x##f
#endif

#define AB fabs(CONST(-2.5)) /* src: source.F90:8 = ABS(-2.5_WP) */
