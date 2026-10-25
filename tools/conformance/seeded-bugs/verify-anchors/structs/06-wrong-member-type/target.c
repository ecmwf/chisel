#ifdef FIXTURE_DP
typedef double real_t;
#define CONST(x) x
#else
typedef float real_t;
#define CONST(x) x##f
#endif

typedef struct t_pair {
	int n;
	int x;
} t_pair;

static const t_pair p = {6, 2}; /* src: source.F90:12 = T_PAIR(6, 2.0_WP) */
