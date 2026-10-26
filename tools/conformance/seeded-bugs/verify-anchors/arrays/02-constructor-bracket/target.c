#ifdef FIXTURE_DP
typedef double real_t;
#define CONST(x) x
#else
typedef float real_t;
#define CONST(x) x##f
#endif

static const real_t arr[3] = {CONST(0.1), CONST(0.2), CONST(0.3)}; /* src: source.F90:8 = [ 0.1_WP, 0.2_WP, 0.3_WP ] */
