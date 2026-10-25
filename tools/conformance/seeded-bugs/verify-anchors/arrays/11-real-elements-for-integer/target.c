#ifdef FIXTURE_DP
typedef double real_t;
#define CONST(x) x
#else
typedef float real_t;
#define CONST(x) x##f
#endif

static const real_t arr[4] = {1, 2, 3, 4}; /* src: source.F90:3 = (/ 1, 2, 3, 4 /) */
