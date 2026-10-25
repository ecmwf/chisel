#ifdef FIXTURE_DP
typedef double real_t;
#define CONST(x) x
#else
typedef float real_t;
#define CONST(x) x##f
#endif

static const real_t x = CONST(1.5); /* src: source.F90:8 = 1.5_WP */
static const real_t p5 = (x * x * x) * (x * x); /* src: source.F90:9 = X**5 */
