#include <stdbool.h>

#ifdef FIXTURE_DP
typedef double real_t;
#define CONST(x) x
#else
typedef float real_t;
#define CONST(x) x##f
#endif

static const bool lf = true; /* src: source.F90:8 = .TRUE. */
static const real_t q = CONST(1.0); /* src: source.F90:9 = MERGE(1._WP, 0._WP, LF) */
