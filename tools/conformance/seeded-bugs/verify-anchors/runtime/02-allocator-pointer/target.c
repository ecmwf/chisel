#include <stdlib.h>

enum { NPTS = 8 }; /* src: source.F90:4 = 8 */

double *mod_a_alloc_a(void)
{
	double *const p = calloc(NPTS, sizeof(double)); /* src: source.F90:8 = NPTS */
	return p;
}
