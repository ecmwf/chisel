#ifdef FIXTURE_DP
typedef double real_t;
#define CONST(x) x
#else
typedef float real_t;
#define CONST(x) x##f
#endif

static const real_t x = CONST(1.1); /* src: source.F90:8 = 1.1_WP */
static const real_t p0 = CONST(1.0); /* src: source.F90:9 = X**0 */
