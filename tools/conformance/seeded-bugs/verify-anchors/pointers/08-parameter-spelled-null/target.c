#ifdef FIXTURE_DP
typedef double real_t;
#define CONST(x) x
#else
typedef float real_t;
#define CONST(x) x##f
#endif

static real_t *pick(real_t *NULL)
{
	real_t *const q = NULL; /* src: source.F90:12 = NULL() */
	return q;
}
