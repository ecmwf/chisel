! Fixture SOURCE (GOOD): a foundation module used by many units (high fan-in -> owned).
module grid_mod
  implicit none
  integer, parameter :: nx = 64, ny = 64
  real, parameter :: dx = 1.0 / nx
contains
  pure real function cell_center(i) result(x)
    integer, intent(in) :: i
    x = (real(i) - 0.5) * dx
  end function cell_center
end module grid_mod
