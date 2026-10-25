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
	int ichan;
	int ino;
} mod_a_ctx;

#define MOD_A_CTX_INIT /* src: source.F90:1 (module MOD_A) */ \
	{ \
		.ichan = 6, /* src: source.F90:8 = 6 */ \
		.ino = 7 /* src: source.F90:9 = 7 */ \
	}
