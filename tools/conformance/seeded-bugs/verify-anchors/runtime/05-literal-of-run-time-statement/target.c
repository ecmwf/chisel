#include <tgmath.h>

#ifdef FIXTURE_DP
typedef double real_t;
#define CONST(x) x
#else
typedef float real_t;
#define CONST(x) x##f
#endif

real_t mod_a_half_root(real_t x)
{
	const real_t half_root = CONST(0.5) * sqrt(x); /* src: source.F90:11 = 0.5_WP */
	return half_root;
}
