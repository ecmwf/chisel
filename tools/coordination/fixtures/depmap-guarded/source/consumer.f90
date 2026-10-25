! Macro-guarded edge fixture (tools/tests/test-depmap-macro-guard.sh): every reference from CONSUMER
! to PRODUCER_MOD - the USE and the CALL - sits inside a preprocessor conditional keyed to
! DEMO_FEATURE, a macro the test pins explicitly via --macro-state (DEMO_FEATURE names nothing
! real, and the extractor hard-codes no macro). Nothing else in this file names the producer, so
! whether the edges exist at all depends entirely on whether the extractor honours that pin.
      SUBROUTINE CONSUMER
#ifdef DEMO_FEATURE
      USE PRODUCER_MOD, ONLY : PRODUCE
#endif
      IMPLICIT NONE
#ifdef DEMO_FEATURE
      CALL PRODUCE
#endif
      PRINT *, 'consumer'
      END SUBROUTINE CONSUMER
