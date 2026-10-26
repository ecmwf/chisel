#ifdef FIXTURE_DP
typedef double real_t;
#define CONST(x) x
#else
typedef float real_t;
#define CONST(x) x##f
#endif

static real_t helper_powi(real_t b, int e)
{
	real_t r = CONST(1.0);
	int n = e < 0 ? -e : e;
	while (n) {
		if (n & 1)
			r *= b;
		b *= b;
		n >>= 1;
	}
	return e < 0 ? CONST(1.0) / r : r;
}

static const real_t x = CONST(1.1); /* src: source.F90:8 = 1.1_WP */
#define P3 helper_powi(x, 3) /* src: source.F90:9 = X**3 */
