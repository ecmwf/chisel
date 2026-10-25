#ifdef FIXTURE_DP
typedef double real_t;
#define CONST(x) x
#else
typedef float real_t;
#define CONST(x) x##f
#endif

real_t mod_a_ratio4(real_t qa)
{
	const real_t r = (CONST(1.0) + qa) / (CONST(1.0) - qa); /* src: source.F90:11 = 1._WP */
	const real_t r2 = r * r; /* src: source.F90:11 = 1._WP */
	const real_t ratio4 = r2 * r2; /* src: source.F90:11 = ((1._WP+QA)/(1._WP-QA))**4 */
	return ratio4;
}
