#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2026 European Centre for Medium-Range Weather Forecasts (ECMWF)
#
# SPDX-License-Identifier: Apache-2.0

# Trap T37 (target-conventions references/pairs/fortran-to-c.md) on this machine's toolchain. The
# loop y(i) = exp(x(i)), built -O3 -ffp-contract=off with no fast-math: gfortran calls glibc's vector
# exp; a plain C build calls only the scalar one and differs from the Fortran in some values; the C
# build with the declaration of references/langs/c.md and -fopenmp-simd -fno-math-errno calls the
# same vector versions as gfortran, for the default target and for x86-64-v3, and gives the same bits
# for every value; without -fopenmp-simd the warning floor refuses the declaration. Needs gfortran
# and gcc on x86_64 with glibc; a missing one fails the test, it never skips.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DOC="$ROOT/.opencode/skills/target-conventions/references/langs/c.md"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
failures=0
ok() { printf 'ok - %s\n' "$1"; }
not_ok() { printf 'not ok - %s\n' "$1"; printf '%s\n' "${2:-}" | sed 's/^/    /'; failures=$((failures + 1)); }
for tool in gfortran gcc nm; do
	command -v "$tool" >/dev/null || { not_ok "$tool is installed"; exit 1; }
done
[ "$(uname -m)" = x86_64 ] || { not_ok "the vector exp of glibc is checked on x86_64 (this is $(uname -m))"; exit 1; }

cd "$TMP"
cat >f.f90 <<'EOF'
subroutine f(n, x, y)
  integer, intent(in) :: n
  real(8), intent(in) :: x(n)
  real(8), intent(out) :: y(n)
  integer :: i
  do i = 1, n
    y(i) = exp(x(i))
  end do
end subroutine
EOF
cat >plain.c <<'EOF'
#include <math.h>
void c_plain(int n, const double *x, double *y);
void c_plain(int n, const double *x, double *y) {
  for (int i = 0; i < n; i++) y[i] = exp(x[i]);
}
EOF
# The declaration exactly as langs/c.md writes it: the C block of "Vector math without fast-math"
# that holds the pragma.
python3 - "$DOC" >decl.c <<'PY'
import re, sys
section = open(sys.argv[1], encoding="utf-8").read().split("## Vector math without fast-math", 1)[1].split("\n## ", 1)[0]
blocks = [b for b in re.findall(r"```c\n(.*?)```", section, re.S) if "#pragma omp declare simd" in b]
if len(blocks) != 1:
    sys.exit("langs/c.md: expected one C block with the declaration, found %d" % len(blocks))
print("\n".join(line[2:] if line.startswith("  ") else line for line in blocks[0].splitlines()))
PY
cat >>decl.c <<'EOF'

void c_decl(int n, const double *x, double *y);
void c_decl(int n, const double *x, double *y) {
  for (int i = 0; i < n; i++) y[i] = exp(x[i]);
}
EOF
cat >main.c <<'EOF'
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
void f_(int *n, const double *x, double *y);
void c_plain(int n, const double *x, double *y);
void c_decl(int n, const double *x, double *y);
int main(void) {
  int n = 100003;
  double *x = malloc(n * sizeof *x), *a = malloc(n * sizeof *a), *b = malloc(n * sizeof *b), *c = malloc(n * sizeof *c);
  srand(7);
  for (int i = 0; i < n; i++) x[i] = -700.0 + 1400.0 * rand() / RAND_MAX;
  f_(&n, x, a); c_plain(n, x, b); c_decl(n, x, c);
  long plain = 0, decl = 0;
  for (int i = 0; i < n; i++) { plain += memcmp(a + i, b + i, 8) != 0; decl += memcmp(a + i, c + i, 8) != 0; }
  printf("%ld %ld\n", plain, decl);
  return 0;
}
EOF

FLOOR="-std=c17 -Wall -Wextra -Wconversion -Wshadow -Wdouble-promotion -Werror"
vector_calls() { nm "$1" | grep -o -E '_ZGV[A-Za-z0-9]+_exp\b' | sort -u | tr '\n' ' '; }
for target in "" "-march=x86-64-v3"; do
	label="${target:-the default target}"
	gfortran -O3 -ffp-contract=off $target -c f.f90 -o f.o
	gcc $FLOOR -O3 -ffp-contract=off $target -c plain.c -o plain.o
	gcc $FLOOR -O3 -ffp-contract=off $target -fopenmp-simd -fno-math-errno -c decl.c -o decl.o
	fortran="$(vector_calls f.o)" plain="$(vector_calls plain.o)" decl="$(vector_calls decl.o)"
	if [ -n "$fortran" ]; then ok "gfortran calls the vector exp ($label: $fortran)"; else not_ok "gfortran calls the vector exp ($label)" "$(nm f.o)"; fi
	if [ -z "$plain" ]; then ok "plain C calls only the scalar exp ($label)"; else not_ok "plain C calls only the scalar exp ($label)" "$plain"; fi
	if [ "$decl" = "$fortran" ]; then ok "C with the declaration calls the same vector exp as gfortran ($label)"; else not_ok "C with the declaration calls the same vector exp as gfortran ($label)" "C: $decl, Fortran: $fortran"; fi
done

gfortran -O3 -ffp-contract=off -c f.f90 -o f.o
gcc $FLOOR -O3 -ffp-contract=off -c plain.c -o plain.o
gcc $FLOOR -O3 -ffp-contract=off -fopenmp-simd -fno-math-errno -c decl.c -o decl.o
gcc -O0 main.c f.o plain.o decl.o -lmvec -lm -o compare
read -r plain decl <<<"$(./compare)"
if [ "$plain" -gt 0 ]; then ok "plain C differs from the Fortran in $plain values"; else not_ok "plain C differs from the Fortran in some values" "none differ: T37 no longer holds on this toolchain"; fi
if [ "$decl" -eq 0 ]; then ok "C with the declaration gives the Fortran's bits for every value"; else not_ok "C with the declaration gives the Fortran's bits for every value" "$decl values differ"; fi

if out="$(gcc $FLOOR -O3 -ffp-contract=off -fno-math-errno -c decl.c -o decl.o 2>&1)"; then
	not_ok "without -fopenmp-simd the warning floor refuses the declaration" "it compiled"
elif grep -q 'unknown-pragmas' <<<"$out"; then
	ok "without -fopenmp-simd the warning floor refuses the declaration"
else
	not_ok "without -fopenmp-simd the warning floor refuses the declaration" "$out"
fi

[ "$failures" -eq 0 ] || { echo "# test-vector-math: $failures failure(s)" >&2; exit 1; }
echo "# test-vector-math: all assertions passed"
