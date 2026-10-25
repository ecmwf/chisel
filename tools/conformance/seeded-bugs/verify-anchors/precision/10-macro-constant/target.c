#ifdef FIXTURE_DP
typedef double real_t;
#define CONST(x) x
#else
typedef float real_t;
#define CONST(x) x##f
#endif

#define A_C CONST(0.1) /* src: source.F90:8 = 0.1_WP */
