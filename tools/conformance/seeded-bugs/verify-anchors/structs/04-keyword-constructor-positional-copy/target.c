#ifdef FIXTURE_DP
typedef double real_t;
#define CONST(x) x
#else
typedef float real_t;
#define CONST(x) x##f
#endif

typedef struct t_pair {
	int n;
	real_t x;
} t_pair;

static const t_pair p = {CONST(1.5), 6}; /* src: source.F90:12 = T_PAIR(X=1.5_WP, N=6) */
