! Fixture SOURCE (GOOD): USEs grid_mod (proven edge), CALLs apply_bc defined in-tree (proven
! edge), CALLs ext_unknown with no in-tree definition (unresolved -> NO edge; not guessed at),
! and shares the /state/ common block with apply_bc (a STRUCTURAL shared surface -> guarded).
subroutine solver_step(u)
  use grid_mod, only: nx, ny, cell_center
  implicit none
  real, intent(inout) :: u(nx, ny)
  real :: twall
  common /state/ twall
  call apply_bc(u)
  call ext_unknown(u)
  twall = cell_center(1)
end subroutine solver_step
