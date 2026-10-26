#include <stdbool.h>

#ifdef FIXTURE_DP
typedef double real_t;
#define CONST(x) x
#else
typedef float real_t;
#define CONST(x) x##f
#endif

typedef struct t_a {
	int n;
	real_t x;
	bool l;
	int k;
	int m;
} t_a;

#define T_A_INIT \
	{ \
		.k = 0, /* src: source.F90:12 = 0 */ \
		.l = true, /* src: source.F90:11 = .TRUE. */ \
		.x = CONST(1.5), /* src: source.F90:10 = 1.5_WP */ \
		.n = 6 /* src: source.F90:9 = 6 */ \
	}
