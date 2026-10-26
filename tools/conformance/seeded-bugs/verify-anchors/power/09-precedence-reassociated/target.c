#ifdef FIXTURE_DP
typedef double real_t;
#define CONST(x) x
#else
typedef float real_t;
#define CONST(x) x##f
#endif

static const real_t a = CONST(0.3); /* src: source.F90:8 = 0.3_WP */
static const real_t b = CONST(2.1); /* src: source.F90:9 = 2.1_WP */
static const real_t c = a * b * b; /* src: source.F90:10 = A*B**2 */
