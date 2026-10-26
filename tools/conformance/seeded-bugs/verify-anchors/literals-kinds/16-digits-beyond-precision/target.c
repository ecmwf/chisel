#ifdef FIXTURE_DP
typedef double real_t;
#define CONST(x) x
#else
typedef float real_t;
#define CONST(x) x##f
#endif

static const real_t pi = CONST(3.141592653589793); /* src: source.F90:8 = 3.14159265358979323846_WP */
