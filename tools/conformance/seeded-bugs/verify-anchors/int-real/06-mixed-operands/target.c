#ifdef FIXTURE_DP
typedef double real_t;
#define CONST(x) x
#else
typedef float real_t;
#define CONST(x) x##f
#endif

static const real_t m = CONST(1.0) + 3 / 2; /* src: source.F90:8 = 1._WP + 3/2 */
