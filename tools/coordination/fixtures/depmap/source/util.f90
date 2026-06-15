! Fixture SOURCE (GOOD): a pure leaf - no use, no call, no common; depends on nothing.
pure subroutine util_clamp(x, lo, hi)
  implicit none
  real, intent(inout) :: x
  real, intent(in) :: lo, hi
  x = max(lo, min(hi, x))
end subroutine util_clamp
