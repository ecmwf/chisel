#include <tgmath.h>

#ifdef FIXTURE_DP
typedef double real_t;
#define CONST(x) x
#else
typedef float real_t;
#define CONST(x) x##f
#endif

struct mod_a_ctx {
	real_t xs;
};

void mod_a_init_a(struct mod_a_ctx *ctx, real_t x)
{
	ctx->xs = CONST(2.0) * sqrt(x); /* src: source.F90:12 = 2._WP */
}
