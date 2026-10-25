#ifdef FIXTURE_DP
typedef double real_t;
#define CONST(x) x
#else
typedef float real_t;
#define CONST(x) x##f
#endif

struct mod_a_ctx {
	real_t yr;
	real_t xr;
};

static struct mod_a_ctx mod_a = { CONST(0.5), CONST(0.25) }; /* src: source.F90:8 = 0.5_WP */ /* src: source.F90:9 = 0.25_WP */
