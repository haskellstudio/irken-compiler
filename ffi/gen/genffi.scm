;; -*- Mode: Irken -*-

;; basis, but with stdio replacing io
(include "lib/core.scm")
(include "lib/pair.scm")
(include "lib/string.scm")
(include "lib/symbol.scm")
(include "lib/queue.scm")
(include "lib/set.scm")
(include "lib/alist.scm")
(include "lib/ctype.scm") ;; needed by os & io.
(include "lib/lisp_reader.scm") ;; needed by ctype
(include "lib/stdio.scm")
(include "lib/frb.scm")
(include "lib/getopt.scm")
(include "lib/map.scm")
(include "lib/cmap.scm")

(require-ffi 'libc)

(include "ffi/gen/cparse.scm")

;; scan for typedefs, structs, and function declarations in
;;   preprocessed C output.

;; Currently, we rely on offsetof & sizeof from a generated C program,
;;  but theoretically we could calculate this from the raw data given
;;  a set of alignment rules and sizes.  I don't know how much these
;;  vary from platform to platform - LLVM should be a source of clues.

;; we can't use the one from lib/ctype.scm, it isn't
;;  expressive enough (yet).

;; C types consist of two morally different building blocks - types and
;; 'declarators'.  A declarator is simply a type with a name attached.
;; declarators are used in typedefs, struct/union elements, and
;; function parameters.

(datatype ctype2
  (:name symbol)   ;; void, thing_t, etc...
  (:int cint bool) ;; kind/size, signed?
  (:float bool bool) ;; long? double?
  (:array int ctype2)
  (:pointer ctype2)
  ;; XXX seriously consider collapsing this into a single alt
  ;;   with a boolean to indicate which kind.  would avoid much
  ;;   code duplication.
  (:struct symbol (maybe (list declarator)))
  (:union  symbol (maybe (list declarator)))
  (:function ctype2 (list declarator))
  )

;; a ctype in s-expression form.
(define ctype2-repr
  (ctype2:name 'void)   -> "void"
  (ctype2:name name)    -> (format "(type " (symbol->string name) ")")
  (ctype2:int cint s?)  -> (cint-repr cint s?)
  (ctype2:float l? d?)  -> (format (if l? "long" "") (if d? "double" "float"))
  (ctype2:array size t) -> (format "(array " (int size) " " (ctype2-repr t) ")")
  (ctype2:pointer t)    -> (format "(* " (ctype2-repr t) ")")
  (ctype2:struct name (maybe:no))        -> (format "(struct " (sym name) ")")
  (ctype2:struct name (maybe:yes slots)) -> (format "(struct " (sym name) " (" (join declarator-repr " " slots) "))")
  (ctype2:union name (maybe:no))         -> (format "(union " (sym name) ")")
  (ctype2:union name (maybe:yes slots))  -> (format "(union " (sym name) " (" (join declarator-repr " " slots) "))")
  (ctype2:function type args)            -> (format "(fun " (join declarator-repr " " args) " -> " (ctype2-repr type) ")")
  )

;; a 'declarator' is a combination of name and type.  sometimes the
;; name is not present (e.g. parameters in function declarations)
(datatype declarator
  (:t ctype2 (maybe symbol))
  )

(define declarator-repr
  (declarator:t type (maybe:no))
  -> (format (ctype2-repr type))
  (declarator:t type (maybe:yes name))
  -> (format "(named " (sym name) " " (ctype2-repr type) ")")
  )

;; ...and back into C

(define cint->c
  (cint:char)     -> "char"
  (cint:short)    -> "short"
  (cint:int)      -> "int"
  (cint:long)     -> "long"
  (cint:longlong) -> "long long"
  (cint:width w)  -> (format "int" (int (* w 8)) "_t")
  )

(define declarator->c
  ;; arrays and function pointers: special cases.
  (declarator:t (ctype2:array size t) (maybe:yes name))
  -> (format (ctype2->c t) " " (sym name) "[" (int size) "]")
  (declarator:t (ctype2:pointer (ctype2:function rtype args)) (maybe:yes name))
  -> (format (ctype2->c rtype) "(*" (sym name) ")(" (join declarator->c ", " args) ")")
  (declarator:t type (maybe:yes name))
  -> (format (ctype2->c type) " " (sym name))
  (declarator:t type (maybe:no))
  -> (ctype2->c type)
  )

(define ctype2->c
  (ctype2:name name)              -> (format (sym name))
  (ctype2:int cint s?)            -> (format (if s? "" "unsigned ") (cint->c cint))
  (ctype2:float l? d?)            -> (format (if l? "long " "") (if d? "double" "float"))
  (ctype2:array size t)           -> (format (ctype2->c t) (if (> size 0) (format "[" (int size) "]") "[]"))
  (ctype2:pointer t)              -> (format (ctype2->c t) "*")
  (ctype2:struct name (maybe:no)) -> (format "struct " (sym name))
  (ctype2:union name (maybe:no))  -> (format "union " (sym name))
  (ctype2:struct name (maybe:yes slots))
  -> (format "struct " (sym name) " {\n  " (join declarator->c ";\n  " slots) ";\n}")
  (ctype2:union name (maybe:yes slots))
  -> (format "union " (sym name) " {\n  " (join declarator->c ";\n  " slots) ";\n}")
  (ctype2:function rtype args) ;; unnamed function pointer.
  -> (format (ctype2->c rtype) "(*)(" (join declarator->c ", " args) ")")
  )

;; imperative walker: call <p> on all subtypes of <type>
;; note: walks from outside-in.
(define (walk-type p type)
  (define (W type)
    (p type)
    (match type with
      (ctype2:pointer sub)                -> (W sub)
      (ctype2:array _ sub)                -> (W sub)
      (ctype2:struct _ (maybe:yes slots)) -> (WD slots)
      (ctype2:union _ (maybe:yes slots))  -> (WD slots)
      (ctype2:function rtype args)        -> (begin (W rtype) (WD args))
      _ -> #u))
  (define (WD decls)
    (for-list decl decls
      (match decl with
        (declarator:t type name)
        -> (W type))))
  (W type)
  )

;; functional walker: run all subtypes through <p>
(define (map-type p type)
  (define (M type)
    (p (match type with
         (ctype2:pointer sub)                   -> (ctype2:pointer (M sub))
         (ctype2:array n sub)                   -> (ctype2:array n (M sub))
         (ctype2:struct name (maybe:yes slots)) -> (ctype2:struct name (maybe:yes (MD slots)))
         (ctype2:union name (maybe:yes slots))  -> (ctype2:union name (maybe:yes (MD slots)))
         (ctype2:function rtype args)           -> (ctype2:function (M rtype) (MD args))
         _                                      -> type)))
  (define (MD decls)
    (map (lambda (decl)
           (match decl with
             (declarator:t type name)
             -> (declarator:t (M type) name)))
         decls))
  (M type)
  )

;; given a name -> type map for all typedefs,
;;  walk a ctype replacing all typedefs.
(define (substitute-typedefs type map)
  (define (sub t)
    (match t with
      (ctype2:name name)
      -> (match (tree/member map symbol-index-cmp name) with
           (maybe:yes next) -> (map-type sub next)
           (maybe:no) -> t)
      _ -> t))
  (map-type sub type)
  )

;; remove struct definitions - this is useful after typedef
;;  substitution on function arguments.
(define (remove-struct-defns type)
  (define M
    (ctype2:struct name _) -> (ctype2:struct name (maybe:no))
    (ctype2:union name _)  -> (ctype2:union name (maybe:no))
    t -> t)
  (map-type M type))

;; remove names from arguments in function decls.
(define remove-declname
  (declarator:t type _) -> (declarator:t type (maybe:no)))
(define remove-argnames
  (ctype2:function rtype args) -> (ctype2:function rtype (map remove-declname args))
  t -> t
  )
(define remove-voidargs
  (ctype2:function rtype ((declarator:t (ctype2:name 'void) _)))
  -> (ctype2:function rtype '())
  t -> t
  )
(define (sanitize-sig t)
  (remove-voidargs (remove-argnames (remove-struct-defns t)))
  )

;; functional walker: run all subtypes through <p>,
;;  which takes two arguments:
;;  1) the path of declarator names (list symbol)
;;  2) the type object.
;;
;; this is an instance of an interesting functional-programming
;;  pattern: most jobs can be done with 'downward' pattern matching,
;;  but sometimes you need pattern matching on the *parents* of an
;;  object as well.  in this case, we match on the declarator parent
;;  path.

(define (map-type-path p path type)
  (define (M path type)
    (p path
       (match type with
         (ctype2:pointer sub)                   -> (ctype2:pointer (M path sub))
         (ctype2:array n sub)                   -> (ctype2:array n (M path sub))
         (ctype2:struct name (maybe:yes slots)) -> (ctype2:struct name (maybe:yes (MD path slots)))
         (ctype2:union name (maybe:yes slots))  -> (ctype2:union name (maybe:yes (MD path slots)))
         (ctype2:function rtype args)           -> (ctype2:function (M path rtype) (MD path args))
         _                                      -> type)))
  ;; whenever we descend through a declarator, push that name onto the path.
  (define (MD path0 decls)
    (map (lambda (decl)
           (match decl with
             (declarator:t type (maybe:yes name))
             -> (declarator:t (M (list:cons name path) type) (maybe:yes name))
             (declarator:t type (maybe:no))
             -> (declarator:t (M path type) (maybe:no))
             ))
         decls))
  (M path type)
  )

;; some subtleties with C typedefs/structs/unions:
;; 1) the namespace of structs and unions is separate.
;; 2) there are several combinations of name/embedded/anonymous:
;;   a) typedef struct name {...} name_t;
;;   b) typedef struct {...} name_t;
;;   c) struct { ... struct/union name {...}; ...};
;;   d) struct { ... struct/union {...}; ...};
;;
;; we wish to 'flatten' everything so that there are no embedded
;;   or anonymous structs/unions.
;; to do this we must 1) name all anonymous structs/unions and
;;   2) pull them into global scope.
;;
;; this necessarily makes these new definitions incompatible
;; (syntactically, but not structurally) with the 'real' ones.

(define (name-anonymous types structs)

  (define (name-it uname sname struct? slots)
    (let ((new-name (string->symbol (format (sym sname) "_" (sym uname))))
          (new-type (if struct?
                        (ctype2:struct new-name slots)
                        (ctype2:union new-name slots)))
          (ref-type (if struct?
                        (ctype2:struct new-name (maybe:no))
                        (ctype2:union new-name (maybe:no)))))
      (tree/insert! types.structs magic-cmp (:tuple new-name struct?) new-type)
      ;; return a referral to our newly named top-level type
      ref-type
      ))

  (define M
    (uname sname . _) (ctype2:struct '%anonymous slots)
    -> (name-it uname sname #t slots)
    (uname sname . _) (ctype2:union '%anonymous slots)
    -> (name-it uname sname #f slots)
    path t -> t
    )

  (for-list struct structs
    (when-maybe type0 (tree/member types.structs magic-cmp (:tuple struct #t))
      (let ((type1 (map-type-path M (LIST struct) type0)))
        ;; replace the entry
        (tree/delete! types.structs magic-cmp (:tuple struct #t))
        (tree/insert! types.structs magic-cmp (:tuple struct #t) type1)
        ))))

(define *verbose-flag* #f)
(defmacro verbose
  (verbose item ...) -> (if *verbose-flag* (begin item ... #u)))

(define (process-cpp-file cppfile)

  (let ((tdgram (sexp->grammar c-grammar))
        (file (stdio/open-read cppfile))
        (gen0 (stdio-char-generator file))
        (gen1 (make-lex-generator dfa-c gen0))
        (gen2 (partition-stream gen1))
        (typedefs (tree/empty))
        (structs (tree/empty))
        (functions (tree/empty)))

    (define (parse-toks toks root)
      (earley tdgram (prod:nt root) (list-generator toks)))

    (define (try-parse toks root parser)
      (try
       (maybe:yes (parser (parse-toks toks root)))
       except (:NoParse tok)
       -> (begin
            (verbose
             (printf (bold "unable to parse " (sym root) " expression:\n"))
             (printf " toks = " (toks->string toks) "\n")
             (printf " at token = " (token-repr tok) "\n"))
            (maybe:no))))

    (define add-typedef!
      (declarator:t type (maybe:yes name))
      -> (begin
           ;; if it's a named struct/union, add it to that table as well.
           (match type with
             (ctype2:struct '%anonymous _) -> #u
             (ctype2:union '%anonymous _)  -> #u
             (ctype2:struct name1 slots)   -> (tree/insert! structs magic-cmp (:tuple name1 #t) type)
             (ctype2:union name1 slots)    -> (tree/insert! structs magic-cmp (:tuple name1 #f) type)
             _                             -> #u
             )
           (tree/insert! typedefs symbol-index-cmp name type))
      _ -> (impossible)
      )

    (define (add-struct! t)
      (match t with
        (ctype2:struct name slots)
        -> (tree/insert! structs magic-cmp (:tuple name #t) t)
        (ctype2:union name slots)
        -> (tree/insert! structs magic-cmp (:tuple name #f) t)
        _ -> (impossible)
        ))

    (define add-function!
      (declarator:t type (maybe:yes name))
      -> (tree/insert! functions symbol-index-cmp name type)
      _ -> (impossible)
      )

    (for toks gen2
      ;;(printf (toks->string toks))
      (match (%%attr (car toks) kind) with
        'eof     -> #u
        'TYPEDEF -> (when-maybe ob (try-parse toks 'typedef parse-typedef) (add-typedef! ob))
        'STRUCT  -> (when-maybe ob (try-parse toks 'struct_definition parse-struct-definition) (add-struct! ob))
        'UNION   -> (when-maybe ob (try-parse toks 'struct_definition parse-struct-definition) (add-struct! ob))
        _        -> (when-maybe ob (try-parse toks 'fun_declaration parse-fundecl) (add-function! ob))
        ))
    (let ((result {typedefs=typedefs structs=structs functions=functions}))
      result
      )))

(define (substitute-all-typedefs types)
  (define (S t)
    (substitute-typedefs t types.typedefs))
  (for-map k v types.typedefs
    (tree/delete! types.typedefs symbol-index-cmp k)
    (tree/insert! types.typedefs symbol-index-cmp k (S v)))
  ;; note: struct keys are a tuple of name and a struct/union bool.
  (for-map k v types.structs
    (tree/delete! types.structs magic-cmp k)
    (tree/insert! types.structs magic-cmp k (S v)))
  (for-map k v types.functions
    (tree/delete! types.functions symbol-index-cmp k)
    (tree/insert! types.functions symbol-index-cmp k (S v)))
  )

(define (dump-types types)
  (printf "\n--------- typedefs -----------\n")
  (for-map k v types.typedefs
    (printf (lpad 30 (sym k)) " " (ctype2-repr v) "\n"))
  (printf "\n--------- structs -----------\n")
  (for-map k v types.structs
    (let (((name struct?) k)
          (mslots
           (match v with
             (ctype2:struct _ mslots) -> mslots
             (ctype2:union _ mslots) -> mslots
             _ -> (impossible))))
      (printf (if struct? "struct" "union") " " (bold (sym name) " (" (sym name)) ") {\n")
      (when-maybe slots mslots
        (for-list slot slots
          (match slot with
            (declarator:t type (maybe:yes name))
            -> (printf (lpad 16 (sym name)) " : " (ctype2-repr type) "\n")
            _ -> (impossible)
            )))
      (printf "}\n")
      ))
  (printf "\n--------- functions -----------\n")
  (for-map fname ftype types.functions
    (printf
     (lpad 30 (sym fname)) " "
     (ctype2-repr (sanitize-sig ftype))
     "\n")
    )
  )

;; parse an FFI spec file.
(define (parse-ffi exp)
  (define sexp->string
    (sexp:string s) -> s
    exp -> (raise (:GenFFI/Error "expected string" exp))
    )
  (define sexp->symbol
    (sexp:symbol s) -> s
    exp -> (raise (:GenFFI/Error "expected symbol" exp))
    )
  (define sexp-starting-with
    sym0 (sexp:list ((sexp:symbol sym1) . subs))
    -> (if (eq? sym0 sym1)
           (maybe:yes subs) ;; subs := (list sexp)
           (maybe:no))
    _ _ -> (maybe:no)
    )
  (match exp with
    (sexp:list ((sexp:symbol iface) . lists)) ;; lists := (list sexp)
    -> (let ((includes '())
             (structs '())
             (constants '())
             (sigs '()))
         (for-list list lists ;; list := sexp
           (when-maybe obs (sexp-starting-with 'structs list)
             (append! structs (map sexp->symbol obs)))
           (when-maybe obs (sexp-starting-with 'constants list)
             (append! constants (map sexp->symbol obs)))
           (when-maybe obs (sexp-starting-with 'sigs list)
             (append! sigs (map sexp->symbol obs)))
           (when-maybe obs (sexp-starting-with 'includes list)
             (append! includes (map sexp->string obs)))
           )
         {iface=iface
          includes=includes
          structs=structs
          sigs=sigs
          constants=constants}
         )
    _ -> (raise (:GenFFI/BadFFI exp))
    ))

;; from os.scm
(define (getenv name)
  (let ((val* (libc/getenv (%string->cref #f (zero-terminate name)))))
    (if (cref-null? val*)
        ""
        (%cref->string #f val* (libc/strlen val*))
        )))

(define (getenv-or var default)
  (let ((val (getenv var)))
    (if (= 0 (string-length val))
        default
        val)))

(define *CC* (getenv-or "CC" "clang"))

(define (system cmd)
  (libc/system (%string->cref #f (zero-terminate cmd))))

(define (compile args)
  (let ((cmd (format *CC* " " (join " " args))))
    (printf "CC: " cmd "\n")
    (let ((rcode (system cmd)))
      (if (not (= rcode 0))
          (raise (:GenFFI/CompileFailed "failed to invoke CC" cmd))
          #u))
    ))

(define (write-includes iface ofile)
  (stdio/write ofile (format "// interface includes\n"))
  (for-list include iface.includes
    (stdio/write ofile (format "#include <" include ">\n"))))

(define (genc1 ffi-path)
  (printf "genc1... FFI = " (string ffi-path) "\n")
  (let ((ffi-file (stdio/open-read ffi-path))
        (exp (car (reader ffi-path (lambda () (stdio/read-char ffi-file)))))
        (iface (parse-ffi exp))
        (base (first (string-split ffi-path #\.)))
        (opath (format base "_iface1.c"))
        (ofile (stdio/open-write opath))
        )
    (stdio/write
     ofile
     (format "// generated by " sys.argv[0] "\n\n"
             "#include <stdio.h>\n"
             "#include <stdint.h>\n"
             "#include <stddef.h>\n"
             "#include <inttypes.h>\n"
             ))
    (write-includes iface ofile)
    ;; write code to emit constants (this will be appended to the xxx_ffi.scm file)
    (stdio/write ofile (format "\nint main (int argc, char * argv[]) {\n"))
    (for-list constant iface.constants
      (stdio/write
       ofile
       (format "  fprintf (stdout, \"(con " (sym constant)
               " %\" PRIdPTR \")\\n\", (intptr_t)" (sym constant) ");\n")))
    (stdio/write ofile "}\n")
    (stdio/close ofile)
    (let ((cpp-path (format base "_iface1.cpp")))
      (compile (LIST "-E" opath ">" cpp-path))
      (genc2 iface base cpp-path))
    (%exit #f 0)
    ))

(define (find-dependencies types structs)
  ;; find all the dependent structs/unions.  for example,
  ;; if we ask for 'struct x' that in turn contains a pointer
  ;; to 'struct y', we need to add 'struct y' to the set.
  (let ((all (set/empty)))
    (define (collect type)
      (match type with
        (ctype2:struct name _)
        -> (set/add! all magic-cmp (:tuple name #t))
        (ctype2:union name _)
        -> (set/add! all magic-cmp (:tuple name #f))
        _ -> #u
        ))
    (for-list struct structs
      (when-maybe type (tree/member types.structs magic-cmp (:tuple struct #t))
        (walk-type collect (substitute-typedefs type types.typedefs))))
    all
    ))

;; needed for structs/unions that are physically included
;; (rather than via a pointer), forward declarations won't work.

(include "ffi/strong.scm")

(define (toposort all types)

  (define (type->deps t)
    (let ((deps (set/empty)))
      (define W
        (ctype2:struct name _)
        -> (set/add! deps magic-cmp (:tuple name #t))
        (ctype2:union name _)
        -> (set/add! deps magic-cmp (:tuple name #f))
        _ -> #u
        )
      (walk-type W t)
      deps))

  (define (key->type key)
    (match (tree/member types.structs magic-cmp key) with
      (maybe:yes type) -> type
      (maybe:no)       -> (impossible)
      ))

  ;; build a graph for `strongly` with a key type of (:tuple symbol bool)
  (let ((g (tree/empty)))
    (for-set k all
      (tree/insert! g magic-cmp k (type->deps (key->type k))))
    ;; flatten the components back into a list...
    (let ((components (strongly g magic-cmp))
          (result '()))
      (for-list names components
        (for-list name names
          (PUSH result name)))
      (printn result)
      (reverse result)))
  )

(define (gen-sigs iface types W)
  (W (format "  fprintf (stdout, "))
  (for-list sig iface.sigs
    (match (tree/member types.functions symbol-index-cmp sig) with
      (maybe:yes type)
      ;; (sig accept (int (* (struct sockaddr)) (* uint) -> int))
      -> (match (sanitize-sig type) with
           (ctype2:function rtype args)
           -> (W (format "\"(sig " (sym sig) " ("
                         (join declarator-repr " " args)
                         " -> " (ctype2-repr rtype) "))\\n\"\n"))
           _
           -> (W (format "\"(sig " (ctype2-repr type) ")\\n\"\n"))
           )
      (maybe:no)
      -> (raise (:GenFFI/NoSuchFun "gen-sigs: no such function/object" sig))
      ))
  (W (format ");\n"))
  )

(define (genc2 iface base cpp-path)
  (let ((types (process-cpp-file cpp-path))
        (opath (format base "_iface2.c"))
        (ofile (stdio/open-write opath)))

    (define (W s)
      (stdio/write ofile s)
      #u)

    (W (format "// generated by " sys.argv[0] "\n\n"
               "#include <stdio.h>\n"
               "#include <stdint.h>\n"
               "#include <stddef.h>\n"
               "#include <inttypes.h>\n"
               ))
    (verbose (dump-types types))
    (substitute-all-typedefs types)
    (name-anonymous types iface.structs)
    (printn iface.structs)
    (let ((deps (find-dependencies types iface.structs)))
      (W (format "#define OO(s,f) do { fprintf (stdout, \"  (%s %\" PRIdPTR \")\\n\", "
                 "#f, offsetof (struct s, f)); } while (0)\n"))
      ;; emit the struct/union defs in topological order...
      (let ((sorted (toposort deps types)))
        (for-list key sorted
          (when-maybe type (tree/member types.structs magic-cmp key)
            (W (format (ctype2->c type) ";\n"))
            ))
        ;; now emit the program to print out sizes/offsets
        (W "\nint main (int argc, char * argv[]) {\n")
        (for-list key sorted
          (when-maybe type (tree/member types.structs magic-cmp key)
            (let (((kind name1 slots)
                   (match type with
                     (ctype2:struct name (maybe:yes slots)) -> (:tuple 'struct name slots)
                     (ctype2:union name (maybe:yes slots))  -> (:tuple 'union name slots)
                     (ctype2:struct name (maybe:no))        -> (:tuple 'struct name '())
                     (ctype2:union name (maybe:no))         -> (:tuple 'union name '())
                     _ -> (impossible)))
                  (sname (format (sym kind) " " (sym name1)))
                  (empty? (= (length slots) 0)))
              (when (not empty?)
                (W (format "  // offsets for " sname "\n"
                           "  fprintf (stdout, \"(" sname " %\" PRIdPTR  \"\\n\", sizeof (" sname "));\n"))
                (for-list slot slots
                  (match slot with
                    (declarator:t type (maybe:yes name))
                    ;; (4 sin6_flowinfo (int (4 0)))
                    -> (W (format "  fprintf (stdout, \"  (%\" PRIdPTR \" " (sym name) " "
                                  (ctype2-repr (map-type remove-argnames type))
                                  ")\\n\", "
                                  (if (eq? kind 'struct) (format "offsetof(" sname ", " (sym name) ")") "(intptr_t)0")
                                  ");\n"))
                    _ -> (impossible)
                    ))
                (W "  fprintf (stdout, \" )\\n\");\n")
                )
              )))
        ;; emit the signatures...
        (gen-sigs iface types W)
        (W "}\n")
        (stdio/close ofile)
        ;; ok, now (finally!) generate the interface file.
        (let ((iface-path (format base "_ffi.scm"))
              (iface-file (stdio/open-write iface-path))
              (iface1 (format base "_iface1"))
              (iface2 (format base "_iface2")))
          (stdio/write iface-file (format ";; generated by " sys.argv[0] " for " base "\n\n"))
          (stdio/write iface-file "(includes ")
          (for-list include iface.includes
            (stdio/write iface-file (format (string include) " ")))
          (stdio/write iface-file ")\n")
          (stdio/close iface-file)
          ;; compile iface2
          (compile (LIST opath "-o" iface2))
          ;; append to interface
          (system (format iface2 " >> " iface-path))
          ;; compile iface1
          (compile (LIST (format iface1 ".c") "-o" iface1))
          ;; append to interface
          (system (format iface1 " >> " iface-path)))
        ))))

(define program-options
  (makeopt
   (flag 'h)
   (flag 'v)
   (arg 'gen (string ""))
   (arg 'scan (string ""))
   ))

(define (usage)
  (printf "\nGenerate an interface file for Irken.\n\n")
  (printf "Usage: " sys.argv[0] " -gen foo.ffi\n")
  (%exit #f -1)
  )

(define (get-options)
  (if (< sys.argc 2)
      (usage)
      (try
       (process-options program-options (rest (vector->list sys.argv)))
       except (:Getopt/MissingArg _ _)
       -> (usage)
       )))

(define (main)
  (let ((opts (get-options)))
    (when-maybe b (get-bool-opt opts 'h)
      (usage))
    (when-maybe b (get-bool-opt opts 'v)
      (set! *verbose-flag* #t))
    (when-maybe ffipath (get-string-opt opts 'gen)
      (genc1 ffipath)
      #u)
    (when-maybe cpp-path (get-string-opt opts 'scan)
      (dump-types (process-cpp-file cpp-path))
      #u)
    ))

(main)
