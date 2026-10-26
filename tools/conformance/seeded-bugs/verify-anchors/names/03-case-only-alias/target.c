#ifdef FIXTURE_DP
typedef double real_t;
#define CONST(x) x
#else
typedef float real_t;
#define CONST(x) x##f
#endif

#define XI CONST(0.25)
static const real_t xi = CONST(0.5); /* src: source.F90:8 = 0.5_WP */
static const real_t y = XI; /* src: source.F90:9 = XI */
