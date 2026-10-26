#include <stdbool.h>

#ifdef FIXTURE_DP
typedef double real_t;
#define CONST(x) x
#else
typedef float real_t;
#define CONST(x) x##f
#endif

typedef struct t_c {
	int n;
	real_t x;
} t_c;

#define T_C_INIT \
	{ \
		.n = 2 + 3, /* src: source.F90:9 = 2*3 */ \
		.x = CONST(1.0) / CONST(4.0) /* src: source.F90:10 = 1.0_WP/4.0_WP */ \
	}
