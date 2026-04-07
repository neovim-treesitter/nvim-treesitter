; inherits: cpp

; Override the inherited (preproc_arg) self-injection from c/injections.scm with an
; explicit language so the injected tree is tagged as "cuda" rather than relying on
; injection.self resolving through the inheritance chain.
((preproc_arg) @injection.content
  (#set! injection.language "cuda"))
