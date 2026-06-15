! Fixture SOURCE (GOOD): the driver - USEs grid_mod and io_mod (proven), CALLs read_input,
! solver_step, and util_clamp (all defined in-tree -> proven).
program main
  use grid_mod, only: nx, ny
  use io_mod, only: read_input
  implicit none
  real :: u(nx, ny)
  call read_input(u)
  call solver_step(u)
  call util_clamp(u(1, 1), 0.0, 1.0)
end program main
