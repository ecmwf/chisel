#ifdef FIXTURE_DP
typedef double real_t;
#define CONST(x) x
#else
typedef float real_t;
#define CONST(x) x##f
#endif

static const float b = 100.0f; /* src: source.F90:8 = 100._WP */
