#include <tgmath.h>

#ifdef FIXTURE_DP
typedef double real_t;
#define CONST(x) x
#else
typedef float real_t;
#define CONST(x) x##f
#endif

#define ANG atan2(CONST(2.0), CONST(1.0)) /* src: source.F90:8 = ATAN2(1._WP, 2._WP) */
