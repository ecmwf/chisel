#ifdef FIXTURE_DP
typedef double real_t;
#define CONST(x) x
#else
typedef float real_t;
#define CONST(x) x##f
#endif

static const real_t b = CONST(1.0e3); /* src: source.F90:8 = 1.E3_WP */
