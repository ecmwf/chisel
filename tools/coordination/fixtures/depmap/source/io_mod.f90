! Fixture SOURCE (GOOD): a module that USEs the grid foundation (a proven edge).
module io_mod
  use grid_mod, only: nx, ny
  implicit none
contains
  subroutine read_input(u)
    real, intent(out) :: u(nx, ny)
    u = 0.0
  end subroutine read_input
end module io_mod
