#include <stddef.h>

#ifdef FIXTURE_DP
typedef double real_t;
#define CONST(x) x
#else
typedef float real_t;
#define CONST(x) x##f
#endif

static real_t *q = NULL; /* src: source.F90:8 = NULL() */
