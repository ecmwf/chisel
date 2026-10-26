#include <stddef.h>
typedef double real_t;
void real_transform(real_t a, size_t i, size_t j, size_t n)
{
    (void)a; (void)i; (void)j; (void)n;
}
void f(const real_t *a, size_t i, size_t j, size_t n)
{
    real_transform(a[i + j * n], i, j, n);
}
