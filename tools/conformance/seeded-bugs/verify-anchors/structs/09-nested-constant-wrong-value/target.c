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

static const t_out q = {{7, CONST(8.0)}, true}; /* src: source.F90:16 = T_OUT(T_IN(7, 8.5_WP), .TRUE.) */
