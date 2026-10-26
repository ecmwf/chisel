#include <stddef.h>

#ifdef FIXTURE_DP
typedef double real_t;
#define CONST(x) x
#else
typedef float real_t;
#define CONST(x) x##f
#endif

typedef struct t_p {
	int n;
	real_t *p;
} t_p;

#define T_P_INIT \
	{ \
		.n = 6, /* src: source.F90:9 = 6 */ \
		.p = NULL /* src: source.F90:10 = NULL() */ \
	}
