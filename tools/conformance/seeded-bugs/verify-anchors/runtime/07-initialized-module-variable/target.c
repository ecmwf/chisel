#ifdef FIXTURE_DP
typedef double real_t;
#define CONST(x) x
#else
typedef float real_t;
#define CONST(x) x##f
#endif

static real_t mod_a_xr = CONST(0.5); /* src: source.F90:8 = 0.5_WP */

void mod_a_step_a(void)
{
	mod_a_xr = mod_a_xr * CONST(2.0); /* src: source.F90:11 = 2._WP */
}
