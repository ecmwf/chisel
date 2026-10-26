#ifdef FIXTURE_DP
typedef double real_t;
#define CONST(x) x
#else
typedef float real_t;
#define CONST(x) x##f
#endif

static const real_t h2 = CONST(1.0) / CONST(2.0); /* src: source.F90:8 = 1._WP/2._WP */
