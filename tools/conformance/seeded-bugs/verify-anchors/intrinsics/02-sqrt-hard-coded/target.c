#ifdef FIXTURE_DP
typedef double real_t;
#define CONST(x) x
#else
typedef float real_t;
#define CONST(x) x##f
#endif

static const real_t sq2 = CONST(1.4142135623730951); /* src: source.F90:8 = SQRT(2._WP) */
