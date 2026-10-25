enum { N = 5 }; /* src: source.F90:3 = 5 */
enum { M = N > 4 ? 2 : 3 }; /* src: source.F90:4 = MERGE(2, 3, N > 4) */
