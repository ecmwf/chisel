#ifdef FIXTURE_DP
typedef double real_t;
#define CONST(x) x
#else
typedef float real_t;
#define CONST(x) x##f
#endif

struct mod_a_ctx {
	real_t xr;
	real_t yr;
};

static struct mod_a_ctx mod_a = {
	.xr = CONST(0.5), /* src: source.F90:8 = 0.5_WP */
	.yr = CONST(0.25), /* src: source.F90:9 = 0.25_WP */
};
