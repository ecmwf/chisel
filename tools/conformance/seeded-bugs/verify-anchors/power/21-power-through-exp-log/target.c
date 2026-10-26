#include <tgmath.h>

#ifdef FIXTURE_DP
typedef double real_t;
#define CONST(x) x
#else
typedef float real_t;
#define CONST(x) x##f
#endif

static const real_t x = CONST(2.1); /* src: source.F90:8 = 2.1_WP */
#define P3 exp(CONST(3.0) * log(x)) /* src: source.F90:9 = X**3 */
