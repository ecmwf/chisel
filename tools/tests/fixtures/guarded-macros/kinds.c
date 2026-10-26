/* Every token kind clang's raw lexer emits for C17: punctuators, digraphs, trigraphs, */
/* prefixed character and string literals, numbers, comments and stray characters. */
[ ] ( ) { } . ... & && &= * *= + ++ += - -> -- -= ~ ! != / /= % %= < << <= <<= <=> > >> >= >>=
^ ^^ ^= | || |= ? : ; = == , ## #@ .* ->* :: @ <<< >>>
<: :> <% %> %:%: ??( ??) ??< ??> ??' ??! ??- ??!??!
x # x %: x ??= x
1 0x1p3 1.0e+5 .5 07 1u 1ULL
'a' L'a' u'a' U'a' u8'a'
"s" L"s" u"s" U"s" u8"s"
u8 L u U R"(r)"
x // line comment
x /* block */ x
` \ $ a$b café caf\u00e9
x 'unterminated
x "unterminated
#ifdef WITH_FEATURE
#endif
