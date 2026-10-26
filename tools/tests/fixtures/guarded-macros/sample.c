/* The guard's macro is WITH_FEATURE. */
#ifdef WITH_FEATURE
int guarded;
#endif
  #if defined(OTHER_FEATURE) && WITH_FEATURE
#endif
/* lead */ #ifndef WITH_FEATURE
#endif
#if defined(OTHER_FEATURE) || \
    defined(WITH_FEATURE)
#endif
#i\
f defined(WITH_FEATURE)
#endif
#if OTHER_FEATURE
#endif
/*	tab, café */
const char *s = "a\tb \"q\" c\\d";
const char *b = "x]\
y";
char q = '\'';
