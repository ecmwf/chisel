#include <tgmath.h>

#ifdef FIXTURE_DP
typedef double real_t;
#define CONST(x) x
#else
typedef float real_t;
#define CONST(x) x##f
#endif

#define T5 tanh(CONST(0.5)) /* src: source.F90:8 = TANH(0.5_WP) */
