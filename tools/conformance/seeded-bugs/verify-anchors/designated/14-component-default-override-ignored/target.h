#include <stdbool.h>

#ifdef FIXTURE_DP
typedef double real_t;
#define CONST(x) x
#else
typedef float real_t;
#define CONST(x) x##f
#endif

typedef struct t_in {
	int a;
	real_t b;
} t_in;

typedef struct t_out {
	t_in in;
	bool l;
} t_out;

#define T_OUT_INIT \
	{ \
		.in = {.a = 1, .b = CONST(2.5)}, /* src: source.F90:13 = T_IN(3, 4.5_WP) */ \
		.l = false /* src: source.F90:14 = .FALSE. */ \
	}
