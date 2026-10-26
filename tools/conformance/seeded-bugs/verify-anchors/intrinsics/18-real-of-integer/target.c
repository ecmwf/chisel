#ifdef FIXTURE_DP
typedef double real_t;
#define CONST(x) x
#else
typedef float real_t;
#define CONST(x) x##f
#endif

static const real_t r = (real_t)7 / CONST(2.0); /* src: source.F90:8 = REAL(7, WP)/2._WP */
