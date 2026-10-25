#ifdef FIXTURE_DP
typedef double real_t;
#define CONST(x) x
#else
typedef float real_t;
#define CONST(x) x##f
#endif

static const real_t s = CONST(0.7) * CONST(0.7); /* src: source.F90:8 = 0.7_WP*0.7_WP */
