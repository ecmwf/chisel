#ifdef FIXTURE_DP
typedef double real_t;
#define CONST(x) x
#else
typedef float real_t;
#define CONST(x) x##f
#endif

static const double b = CONST(0.1); /* src: source.F90:4 = 0.1_DP */
