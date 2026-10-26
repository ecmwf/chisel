#ifdef FIXTURE_DP
typedef double real_t;
#define CONST(x) x
#else
typedef float real_t;
#define CONST(x) x##f
#endif

static const real_t arr[2] = {CONST(0.5), 16777217.000000001}; /* src: source.F90:8 = (/ 0.5_WP, 16777217.000000001_WP /) */
