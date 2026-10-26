#ifdef FIXTURE_DP
typedef double real_t;
#define CONST(x) x
#else
typedef float real_t;
#define CONST(x) x##f
#endif

static const real_t s2 = CONST(2.0) * CONST(0.1); /* src: source.F90:8 = 2._WP*0.1 */
