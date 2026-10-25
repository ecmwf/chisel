#ifdef FIXTURE_DP
typedef double real_t;
#define CONST(x) x
#else
typedef float real_t;
#define CONST(x) x##f
#endif

static const real_t a = CONST(0.5); /* src: source.F90:8 = 0.5_WP */
static const real_t c_r = (CONST(1.0) - a) / (CONST(1.0) + a); /* src: source.F90:9 = 1._WP */
static const real_t c_r2 = c_r * c_r; /* src: source.F90:9 = 1._WP */
static const real_t c = c_r2 * c_r2; /* src: source.F90:9 = ((1._WP+A)/(1._WP-A))**4 */
