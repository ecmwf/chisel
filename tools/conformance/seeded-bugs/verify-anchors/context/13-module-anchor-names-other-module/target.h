#include <stdbool.h>
#include <stddef.h>

#ifdef FIXTURE_DP
typedef double real_t;
#define CONST(x) x
#else
typedef float real_t;
#define CONST(x) x##f
#endif

typedef struct mod_a_ctx {
	real_t *buf;
	real_t *p;
} mod_a_ctx;

#define MOD_A_CTX_INIT {0} /* src: source.F90:1 (module MOD_B) */
