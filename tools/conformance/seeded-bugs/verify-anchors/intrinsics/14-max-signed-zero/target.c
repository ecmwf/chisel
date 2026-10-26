#ifdef FIXTURE_DP
typedef double real_t;
#define CONST(x) x
#else
typedef float real_t;
#define CONST(x) x##f
#endif

static const real_t mz = CONST(0.0); /* src: source.F90:8 = MAX(-0.0_WP, 0.0_WP) */
