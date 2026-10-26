#ifdef FIXTURE_DP
typedef double real_t;
#define CONST(x) x
#else
typedef float real_t;
#define CONST(x) x##f
#endif

static const real_t arr[2] = {CONST(0.5), 1.5}; /* src: source.F90:8 = (/ 0.5_WP, 1.5_WP /) */
