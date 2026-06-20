! Fixture SOURCE (GOOD): a free subroutine that USEs grid_mod (proven edge) and shares the
! /state/ common block with the solver (a STRUCTURAL shared surface -> guarded, out of the leaf pool).
subroutine apply_bc(u)
  use grid_mod, only: nx, ny
  implicit none
  real, intent(inout) :: u(nx, ny)
  real :: twall
  common /state/ twall
  u(1, :) = twall
  u(nx, :) = twall
end subroutine apply_bc
