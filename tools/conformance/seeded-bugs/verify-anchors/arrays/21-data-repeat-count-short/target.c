#ifdef FIXTURE_DP
typedef double real_t;
#define CONST(x) x
#else
typedef float real_t;
#define CONST(x) x##f
#endif

static real_t arr[] = {CONST(1.5), CONST(1.5), CONST(2.5), CONST(2.5)}; /* src: source.F90:9 = 3*1.5_WP, 2*2.5_WP */
