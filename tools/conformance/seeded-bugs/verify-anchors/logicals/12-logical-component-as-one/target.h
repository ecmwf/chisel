#include <stdbool.h>

typedef struct t_l {
	int n;
	bool l;
} t_l;

#define T_L_INIT \
	{ \
		.n = 6, /* src: source.F90:4 = 6 */ \
		.l = 1 /* src: source.F90:5 = .TRUE. */ \
	}
