(lang dune 3.14)

(dialect
 (name "eliom-server")
 (implementation (extension "eliom"))
 (interface (extension "eliomi")))

(wrapped_executables false)
