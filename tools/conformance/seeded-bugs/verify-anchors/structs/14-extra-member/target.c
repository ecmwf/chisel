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
	int y;
} t_pair;

static const t_pair p = {6, CONST(1.5), 0}; /* src: source.F90:12 = T_PAIR(6, 1.5_WP) */
