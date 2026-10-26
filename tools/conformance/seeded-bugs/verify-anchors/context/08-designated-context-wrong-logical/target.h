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
	real_t xrate;
	bool lflag;
	int ntick;
} mod_a_ctx;

#define MOD_A_CTX_INIT /* src: source.F90:1 (module MOD_A) */ \
	{ \
		.ichan = 6, /* src: source.F90:8 = 6 */ \
		.xrate = CONST(1.0), /* src: source.F90:9 = 1.0_WP */ \
		.lflag = false /* src: source.F90:10 = .TRUE. */ \
	}
