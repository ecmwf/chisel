! Fixture SOURCE (GOOD): a free subroutine that USEs grid_mod (proven) and shares the
! /state/ common block with the solver (a hidden coupling no call graph shows -> suspected).
subroutine apply_bc(u)
  use grid_mod, only: nx, ny
  implicit none
  real, intent(inout) :: u(nx, ny)
  real :: twall
  common /state/ twall
  u(1, :) = twall
  u(nx, :) = twall
end subroutine apply_bc
