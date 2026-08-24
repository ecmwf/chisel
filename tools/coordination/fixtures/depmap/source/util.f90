! Fixture SOURCE (GOOD): a leaf - no use, no call, no common, no module/proc dependency; only
! #includes consts.h (shared with grid_mod.f90 -> an INCLUDE-class owned surface).
pure subroutine util_clamp(x, lo, hi)
  implicit none
#include "consts.h"
  real, intent(inout) :: x
  real, intent(in) :: lo, hi
  x = max(lo, min(hi, x))
end subroutine util_clamp
