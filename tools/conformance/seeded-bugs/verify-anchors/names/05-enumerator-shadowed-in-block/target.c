enum { NPTS = 4 }; /* src: source.F90:3 = 4 */

int mod_a_sub_a(void)
{
	enum { NPTS = 5 }; /* src: source.F90:7 = 5 */
	static const int n2 = NPTS * 2; /* src: source.F90:4 = NPTS*2 */
	return n2 + NPTS;
}
