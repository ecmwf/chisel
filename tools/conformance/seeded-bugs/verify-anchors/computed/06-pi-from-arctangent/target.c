#ifdef FIXTURE_DP
typedef double real_t;
#define CONST(x) x
#else
typedef float real_t;
#define CONST(x) x##f
#endif

static const real_t pi = CONST(3.14159265358979323846); /* src: source.F90:8 = 4*ATAN(1._WP) */
