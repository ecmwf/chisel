#ifdef FIXTURE_DP
typedef double real_t;
#define CONST(x) x
#else
typedef float real_t;
#define CONST(x) x##f
#endif

typedef struct t_pair {
	int n;
	float x;
} t_pair;

static const t_pair p = {6, 0.1f}; /* src: source.F90:12 = T_PAIR(6, 0.1_WP) */
