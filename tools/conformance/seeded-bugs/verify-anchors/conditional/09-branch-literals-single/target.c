#include <stdbool.h>

#ifdef FIXTURE_DP
typedef double real_t;
#define CONST(x) x
#else
typedef float real_t;
#define CONST(x) x##f
#endif

static const bool lf = true; /* src: source.F90:8 = .TRUE. */
static const real_t q = lf ? 0.1f : 0.2f; /* src: source.F90:9 = MERGE(0.1_WP, 0.2_WP, LF) */
