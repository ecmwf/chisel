typedef struct t_vec {
	int k[3];
} t_vec;

static const t_vec v = {.k = {1, 2}}; /* src: source.F90:6 = T_VEC((/ 1, 2, 3 /)) */
