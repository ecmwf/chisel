#include <stdlib.h>

double *mod_a_alloc_a(void)
{
	double *const p = calloc(8, sizeof(double)); /* src: source.F90:7 = 8 */
	return p;
}
