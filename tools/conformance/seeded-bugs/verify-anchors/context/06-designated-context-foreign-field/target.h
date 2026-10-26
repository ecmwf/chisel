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
	int nb;
} mod_a_ctx;

#define MOD_A_CTX_INIT /* src: source.F90:5 (module MOD_A) */ \
	{ \
		.ichan = 6, /* src: source.F90:12 = 6 */ \
		.xrate = CONST(1.0), /* src: source.F90:13 = 1.0_WP */ \
		.lflag = true, /* src: source.F90:14 = .TRUE. */ \
		.nb = 5 /* src: source.F90:3 = 5 */ \
	}
