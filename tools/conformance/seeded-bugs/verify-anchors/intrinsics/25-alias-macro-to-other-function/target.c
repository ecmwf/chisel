#include <tgmath.h>

#ifdef FIXTURE_DP
typedef double real_t;
#define CONST(x) x
#else
typedef float real_t;
#define CONST(x) x##f
#endif

#define LOG(x) sqrt(x)
#define LN2 LOG(CONST(2.0)) /* src: source.F90:8 = LOG(2._WP) */
