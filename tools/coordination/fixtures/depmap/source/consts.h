! Fixture SOURCE (GOOD): a header #include'd by >=2 units - proves the INCLUDE-edge class the same
! way grid_mod proves the USE/module class: a shared surface pulled in by >=2 units becomes an
! owned surface (guarded, out of the self-serve pool), proven by a RESOLVED #include rather than a
! resolved USE.
real, parameter :: fixture_eps = 1.0e-6
