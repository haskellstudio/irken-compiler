;; -*- Mode: Irken -*-

;; This uses a relatively inexpensive form of an 'occurs check'.
;;   Since apply-subst is used all over the place (including in the
;;   printing of errors), this gets better coverage than an explicit
;;   'occurs check' in the unifier.

;; If you see INFINITE-TYPE in an error message, you have either
;;   inadvertently created one via a bug, or you're trying to do
;;   something not supported but the compiler.

;; XXX can this benefit from memoization?

(define (apply-subst t)
  (define (p t)
    (let ((t (type-find t))
	  (trec (type->trec t)))
      (if trec.pending
	  (pred 'INFINITE-TYPE '())
	  (match t with
	    (type:tvar _ _) -> t
	    (type:pred name subs _)
	    -> (begin
		 (set! trec.pending #t)
		 (let ((r (pred name (map p subs))))
		   (set! trec.pending #f)
		   r))
	    ))))
  (p t))

(define scheme-repr
  (:scheme gens type)
  -> (format "forall(" (join type-repr "," gens) ")." (type-repr type)))

(define (type-program node)

  (define (unify exp t0 t1)

    (define (print-type-error t0 t1)
      (printf (join "\n" (get-node-context node (noderec->id exp) 30)) "\n")
      (printf "node id=" (int (noderec->id exp)) "\n")
      (let ((ut0 (apply-subst t0))
	    (ut1 (apply-subst t1)))
	(printf "\nType Error:\n\t" (type-repr ut0) "\n\t" (type-repr ut1) "\n")))

    (define (type-error t0 t1)
      (print-type-error t0 t1)
      (error "type error"))

    (define (U t0 t1)
      (when the-context.options.debugtyping
	    (printf "    ----U " (type-repr t0) " -- " (type-repr t1) "\n"))
      (let/cc return
	  (let ((u (type-find t0))
		(v (type-find t1)))
	    (when the-context.options.debugtyping
		  (printf "    ----: " (type-repr u) " -- " (type-repr v) "\n"))
	    (if (not (eq? u v))
		(begin
		  (match u v with
		    (type:tvar _ _) _ -> #u
		    _ (type:tvar _ _) -> #u
		    (type:pred pu su _) (type:pred pv sv _)
		    -> (match pu pv with
			 'rlabel _   -> (return (U-row u v))
			 _ 'rlabel   -> (return (U-row v u))
			 'rdefault _ -> (return (U-row u v))
			 _ 'rdefault -> (return (U-row v u))
			 _ _ -> (if (or (not (eq? pu pv))
					(not (= (length su) (length sv))))
				    (type-error t0 t1)
				    #u)))
		  (type-union u v)
		  (match u v with
		    (type:pred _ su _) (type:pred _ sv _) -> (for-each2 U su sv)
		    _ _ -> #u))
		))))

    (define (pred=? sym0 sym1)
      (eq? sym0 sym1))

    (define label=?
      ;; labels are represented with nullary predicates, compare via symbol
      (type:pred na _ _) (type:pred nb _ _) -> (eq? na nb)
      _ _ -> #f)

    ;; note: a remaining difference between the python solver and the this solver:
    ;;   the python solver will emit rlabel (name,abs(), ...) in some cases.
    ;;   doesn't seem to have an impact (yet), but something to watch for:
    ;;
    ;; 7039 L        primapp [11] ('%rextend/x', None) {a=bool b=bool x=int y=char z=char}
    ;; 7037 L          primapp [9] ('%rextend/y', None) {a=bool b=bool x=#f y=char z=char}
    ;; 7035 L            primapp [7] ('%rextend/z', None) {a=bool b=bool y=#f z=char}
    ;; 7033 L              primapp [5] ('%rextend/a', None) {a=bool b=bool z=#f}
    ;; 7031 L                primapp [3] ('%rextend/b', None) {a=#f b=bool}
    ;; 7029 L                  primapp [1] ('%rmake', None) {b=#f}
    ;;
    ;; vs
    ;;
    ;; 2360   11  100       primapp %rextend x : {x=int y=char z=char a=bool b=bool }
    ;; 2358    9  100         primapp %rextend y : {y=char z=char a=bool b=bool }
    ;; 2356    7  100           primapp %rextend z : {z=char a=bool b=bool }
    ;; 2354    5  100             primapp %rextend a : {a=bool b=bool }
    ;; 2352    3  100               primapp %rextend b : {b=bool }
    ;; 2350    1  100                 primapp %rmake #f : {}

    (define (U-row u v)
      (match u v with
        ;; u and v are both rlabel
        (type:pred 'rlabel (l0 t0 d0) _) (type:pred 'rlabel (l1 t1 d1) _)
        -> (cond ((label=? l0 l1)
                  ;; identical labels, unify presence.
                  (U t0 t1)
                  (U d0 d1))
                 (else
                  ;; distinct head labels, C-MUTATE-LL
                  (let ((x (new-tvar)))
                    (U d0 (rlabel l1 t1 x))
                    (U d1 (rlabel l0 t0 x)))))
	;; u is rlabel, v is not
	(type:pred 'rlabel (l0 t0 d0) _) (type:pred p1 s1 _)
	-> (cond ((eq? p1 'rdefault)
		  ;; C-MUTATE-DL
		  (U (car s1) t0)
		  (U v d0))
		 (else
		  ;; some other predicate
		  ;; S-MUTATE-GL
		  (let ((n (length s1))
			(tvars0 (map-range i n (new-tvar)))
			(tvars1 (map-range i n (new-tvar))))
		    (U (pred p1 tvars0) t0)
		    (U (pred p1 tvars1) d0)
		    (for-range i n
			       (U (nth s1 i) (rlabel l0 (nth tvars0 i) (nth tvars1 i)))
			       ))))
	;; both are rdefault
	(type:pred 'rdefault (t0) _) (type:pred 'rdefault (t1) _)
	-> (U t0 t1)
	;; ensure that u is the rdefault/δ
	_ (type:pred 'rdefault (t1) _)
	-> (U-row v u)
	;; u is rdefault, v is some other predicate, S-MUTATE-GD
	(type:pred 'rdefault (t0) _) (type:pred p1 s1 _)
	-> (let ((n (length s1))
		 (tvars (map-range i n (new-tvar))))
	     (U t0 (pred p1 tvars))
	     (for-range i n
			(U (nth s1 i) (rdefault (nth tvars i)))))
	;; anything else is an error
	_ _ -> (type-error u v)
	))

    (U t0 t1)
    )

  (define (instantiate-type-scheme gens type)
    ;; map from gens->fresh
    (when the-context.options.debugtyping
	  (printf "gens= " (join type-repr ", " gens) "\n")
	  (printf "type= " (type-repr type) "\n"))
    (let ((fresh
	   (foldr
	    (lambda (gen al)
	      (match gen with
		(type:tvar id _) -> (alist:entry id (new-tvar) al)
		_ -> (error "instantiate-type-scheme")))
	    (alist:nil)
	    gens
	    )))
      ;; walk the type, replacing each member of <gen> with its fresh tvar.
      (let walk ((t type))
	(match t with
	  (type:pred name args _) -> (pred name (map walk args))
	  (type:tvar id _)        -> (match (alist/lookup fresh id) with
				       (maybe:yes tv) -> tv
				       (maybe:no) -> t)))))

  (define (occurs-in-type tvar type)
    (let/cc return
	(if (eq? tvar type)
	    #t
	    (match type with
	      (type:tvar _ _) -> #f
	      (type:pred _ args _)
	      -> (begin
		   (for-each
		    (lambda (arg)
		      (if (occurs-in-type tvar arg) (return #t) #u))
		    args)
		   #f)))))

  ;; occurs-free and build-type-scheme could obviously
  ;;   be made more efficient - build-type-scheme walks
  ;;   the entire environment repeatedly.
  (define (occurs-free-in-tenv tvar tenv)
    (let/cc return
	(alist/iterate
	 (lambda (name scheme)
	   (match scheme with
	     (:scheme gens type)
	     -> (if (not (member-eq? tvar gens))
		    (if (occurs-in-type tvar type)
			(return #t)))))
	 tenv)
      #f))

  (define (build-type-scheme type tenv)
    (let ((gens (set-maker '())))
      (define (find-generic-tvars t)
	(match t with
	  (type:tvar _ _)      -> (if (not (occurs-free-in-tenv t tenv)) (gens::add t))
	  (type:pred _ args _) -> (for-each find-generic-tvars args)))
      (let ((type (apply-subst type)))
	(find-generic-tvars type)
	(when the-context.options.debugtyping
	      (printf "build-type-scheme type=" (type-repr type) " gens = " (join type-repr "," (gens::get)) "\n"))
	(:scheme (gens::get) type))))

  (define (type-of* exp tenv)
    (match (noderec->t exp) with
      (node:literal lit)	    -> (type-of-literal lit exp tenv)
      (node:cexp gens sig _)	    -> (type-of-cexp gens sig exp tenv)
      (node:ffi gens sig _)	    -> (type-of-cexp gens sig exp tenv)
      (node:if)			    -> (type-of-conditional exp tenv)
      (node:sequence)		    -> (type-of-sequence (noderec->subs exp) tenv)
      (node:function _ formals)	    -> (type-of-function formals (car (noderec->subs exp)) (noderec->type exp) tenv)
      (node:varref name)	    -> (type-of-varref name tenv)
      (node:varset name)	    -> (type-of-varset name exp tenv)
      (node:call)		    -> (type-of-call exp tenv)
      (node:fix names)		    -> (type-of-fix names exp tenv)
      (node:let names)		    -> (type-of-let names exp tenv)
      (node:primapp name parms)	    -> (type-of-primapp name parms (noderec->subs exp) tenv)
      (node:nvcase dt tags arities) -> (type-of-vcase dt tags arities exp tenv)
      (node:subst _ _)              -> (impossible)
      ))

  (define (dump-tenv tenv)
    (printf "tenv {\n")
    (tree/inorder
     (lambda (name scheme)
       (printf "  " (sym name) " = " (scheme-repr scheme) "\n"))
     tenv)
    (printf "}\n"))

  (define (type-of exp tenv)
    (when the-context.options.debugtyping
      (printf "( type-of* " (int (noderec->id exp)) " " (format-node-type (noderec->t exp)) " :\n"))
    (let ((texp0 (noderec->type exp))
          (texp1 (type-of* exp tenv)))
      ;; XXX the intent of this is to unify with user-assigned types,
      ;;  but it is breaking polymorphic types somehow. (try poly-append).
      ;;(when (not (no-type? texp0))
      ;;  (unify exp texp0 texp1))
      (set-node-type! exp texp1)
      (when the-context.options.debugtyping
        (printf "type-of* " (int (noderec->id exp)) " " (type-repr texp1) ")\n"))
      texp1))

  (define (type-of-literal lit exp tenv)
    (match lit with
      (literal:string _)    -> string-type
      (literal:int _)	    -> int-type
      (literal:char _)	    -> char-type
      (literal:undef)	    -> undefined-type
      (literal:symbol _)    -> symbol-type
      (literal:sexp _)      -> sexp-type
      (literal:cons dt v l) -> (let ((dto (alist/get the-context.datatypes dt "no such datatype")))
				 (match (dto.get-alt-scheme v) with
				   (:scheme gens type)
				   -> (match (instantiate-type-scheme gens type) with
					(type:pred 'arrow (result-type . arg-types) _)
					-> (begin
					     (for-range
						 i (length arg-types)
						 (let ((tx (type-of-literal (nth l i) exp tenv)))
						   (unify exp tx (nth arg-types i))))
					     result-type)
					x -> (error1 "strange constructor scheme" x))))
      (literal:vector l)    -> (let ((tv (new-tvar)))
				 (for-each
				  (lambda (x)
				    (let ((tx (type-of-literal x exp tenv)))
				      (unify exp tv tx)))
				  l)
				 (pred 'vector (LIST tv))
				 )
      ))

  ;; HACK: remove a raw predicate if present
  (define unraw
    (type:pred 'raw (arg) _) -> arg
    t -> t)

  (define (type-of-cexp gens sig exp tenv)
    (match (instantiate-type-scheme gens sig) with
      (type:pred 'arrow pargs _)
      -> (if (not (= (- (length pargs) 1) (length (noderec->subs exp))))
             (error1 "wrong number of args to cexp" exp)
             (match pargs with
               () -> (error1 "malformed arrow type" sig)
               (result-type . parg-types)
               -> (let ((arg-types (map (lambda (x) (type-of x tenv)) (noderec->subs exp))))
                    (for-each2 (lambda (a b)
                                 (unify exp (unraw a) b))
                               parg-types arg-types)
                    result-type
                    )))
      type -> type))

  (define (type-of-conditional exp tenv)
    (match (map (lambda (x) (type-of x tenv)) (noderec->subs exp)) with
      (tif tthen telse)
      -> (begin
	   (unify exp tif bool-type)
	   (unify exp tthen telse)
	   telse)
      _ -> (error1 "malformed conditional" exp)
      ))

  (define (type-of-sequence exps tenv)
    (let loop ((l exps))
      (match l with
	()	  -> (error "empty sequence?")
	(one)	  -> (type-of one tenv)
	(hd . tl) -> (begin
		       ;; ignore all but the last
		       (type-of hd tenv)
		       (loop tl)))))

  ;; XXX TODO - handle user-supplied types (on formals?)
  (define (optional-type formal tenv)
    (new-tvar))

  (define (type-of-function formals body sig tenv)
    (let ((arg-types '()))
      (for-list formal formals
        (let ((type (optional-type formal tenv)))
          (PUSH arg-types type)
          (alist/push tenv formal (:scheme '() type))))
      (let ((btype (type-of body tenv))
            (ftype (arrow btype (reverse arg-types))))
        (if (no-type? sig)
            ftype
            (begin (unify body ftype sig) sig)))
      ))

  (define (apply-tenv name tenv)
;;     (print-string "apply-tenv: ") (printn name)
;;     (print-string " tenv= {\n")
;;     (alist/iterate
;;      (lambda (k v)
;;        (printf " " (sym k) " " (scheme-repr v) "\n"))
;;      tenv)
;;     (print-string "}\n")
    (match (alist/lookup tenv name) with
      (maybe:no) -> (error1 "apply-tenv: unbound variable" name)
      (maybe:yes (:scheme gens type))
      -> (instantiate-type-scheme gens type)))

  (define (type-of-varref name tenv)
    (let ((t (apply-tenv name tenv)))
      ;;(printf "varref: " (sym name) " type = " (type-repr t) "\n")
      t))

  (define (type-of-varset name exp tenv)
    ;; XXX implement the no-generalize rule for vars that are assigned.
    ;;     [i.e. the value restriction]
    (let ((val (car (noderec->subs exp)))
	  (t0 (apply-tenv name tenv))
	  (t1 (type-of val tenv)))
      (unify exp t0 t1)
      undefined-type
      ))

  (define (type-of-call exp tenv)
    (match (map (lambda (x) (type-of x tenv)) (noderec->subs exp)) with
      (rator-type . rand-types)
      -> (let ((result-type (new-tvar)))
	   (unify exp rator-type (arrow result-type rand-types))
	   result-type)
      () -> (error "empty call?")
      ))

  (define (type-of-fix names exp tenv)
    ;; reorder fix into dependency order
    (match (reorder-fix names (noderec->subs exp) the-context.scc-graph) with
      (:reordered names0 inits0 body partition)
      -> (let ((n (length names0))
	       (names (list->vector names0))
	       (inits (list->vector inits0))
	       (init-tvars (list->vector (map-range i n (new-tvar))))
	       (init-types (make-vector n no-type))
	       )
	   ;;(print-string "reordered: ") (printn names0)
	   (for-each
	    (lambda (part)
	      ;; build temp tenv for typing the inits
	      (let ((temp-tenv
		     (foldr
		      (lambda (i al)
			(alist:entry names[i] (:scheme '() init-tvars[i]) al))
		      tenv (reverse part))))
		;; type each init in temp-tenv
		(for-each
		 (lambda (i)
		   (let ((ti (type-of inits[i] temp-tenv))
			 (_ (unify inits[i] ti init-tvars[i]))
			 ;;(ti (apply-subst ti)))
			 )
		     (set! init-types[i] ti)))
		 part)
		;; now extend the environment with type schemes instead
		(for-each
		 (lambda (i)
		   (let ((scheme (build-type-scheme init-types[i] tenv)))
		     (alist/push tenv names[i] scheme)))
		 part)))
	    partition)
	   ;; type the body in the new polymorphic environment
	   (type-of body tenv))))

  (define (type-of-let names exp tenv)
    (let ((n (length names))
	  (inits (noderec->subs exp)))
      (for-range
	  i n
	  (let ((init (nth inits i))
		(name (nth names i))
		(ta (type-of init tenv)))
	    ;; XXX user-supplied type
	    ;; extend environment
	    (alist/push tenv name (:scheme '() ta))))
      ;; type body in the new env
      (type-of (nth inits n) tenv)))

  (define (type-of-vcase dt tags arities exp tenv)
    (if (eq? dt 'nil)
	(type-of-pvcase tags arities exp tenv)
	(type-of-nvcase dt tags exp tenv)))

  (define (type-of-nvcase dt tags exp tenv)
    (let ((dt (alist/get the-context.datatypes dt "no such datatype"))
	  (subs (noderec->subs exp))
	  ;; use match for these!?
	  (value (nth subs 0))
	  (else-exp (nth subs 1))
	  (alts (cdr (cdr subs)))
	  (tval (type-of value tenv))
	  (dt-scheme (dt.get-scheme))
	  (tv (new-tvar)))
      (match dt-scheme with
	(:scheme tvars type)
	-> (if (null? tvars)
	       (unify exp tval type)
	       (let ((type0 (instantiate-type-scheme tvars type)))
		 (unify exp tval type0))))
      ;; each alt has the same type
      (for-each (lambda (alt) (unify alt tv (type-of alt tenv))) alts)
      ;; this will work even when else-exp is a dummy %%match-error
      (unify else-exp tv (type-of else-exp tenv))
      tv))

  (define (type-of-pvcase tags arities exp tenv)
    (match (noderec->subs exp) with
      (value else-exp . alts)
      -> (let ((tv-exp (new-tvar))
	       (else? (match (noderec->t else-exp) with
			(node:primapp '%fail _) -> #f
			(node:primapp '%match-error _) -> #f
			_ -> #t))
	       (row (if else? (new-tvar) (rdefault (rabs)))))
	   (for-range
	       i (length tags)
	       (let ((alt (nth alts i))
		     (tag (nth tags i))
		     (arity (nth arities i))
		     (argvars (n-tvars arity)))
		 (set! row (rlabel (make-label tag)
				   (rpre (if (= arity 1)
					     (car argvars)
					     (pred 'product argvars)))
				   row))
		 ;; each alt must have the same type
		 (unify alt tv-exp (type-of alt tenv))))
	   (if else?
	       (unify else-exp tv-exp (type-of else-exp tenv)))
	   ;; the value must have the row type determined
	   ;;   by the set of polyvariant alternatives
	   (unify value (rsum row) (type-of value tenv))
	   ;; this is the type of the entire expression
	   tv-exp
	   )
      _ -> (error1 "malformed pvcase" exp)
      ))

  (define (remember-variant-label label)
    (match (alist/lookup the-context.variant-labels label) with
      (maybe:yes _) -> #u
      (maybe:no) -> (let ((index (alist/length the-context.variant-labels)))
		      (alist/push the-context.variant-labels label index))))

  (define T0 (new-tvar))
  (define T1 (new-tvar))
  (define T2 (new-tvar))

  (define n-tvars
    0 -> '()
    n -> (list:cons (new-tvar) (n-tvars (- n 1))))

  (define (prim-error name)
    (error1 "bad parameters to primop" name))

  ;; this function acts like a lookup table for the type signatures of primitives.
  ;; it is a function because some of the prims have parameters that affect their
  ;;   type signatures in a way that requires them to be generated on the fly -
  ;;   for example accessing a record field requires a row type containing a label
  ;;   for the field.

  (define (lookup-primapp name params)
    (match name with
      '%fatbar	    -> (:scheme (LIST T0) (arrow T0 (LIST T0 T0)))
      '%fail	    -> (:scheme (LIST T0) (arrow T0 '()))
      '%match-error -> (:scheme (LIST T0) (arrow T0 '()))
      '%make-vector -> (:scheme (LIST T0) (arrow (pred 'vector (LIST T0)) (LIST int-type T0)))
      '%array-ref   -> (:scheme (LIST T0) (arrow T0 (LIST (pred 'vector (LIST T0)) int-type)))
      '%array-set   -> (:scheme (LIST T0) (arrow undefined-type (LIST (pred 'vector (LIST T0)) int-type T0)))
      '%rmake       -> (:scheme '() (arrow (rproduct (rdefault (rabs))) '()))
      '%ensure-heap -> (:scheme '() (arrow undefined-type (LIST int-type)))
      '%rextend     -> (match params with
                         (sexp:symbol label)
                         -> (let ((plabel (make-label label)))
                              ;; forall('a,'b).({lab=(abs) 'a} 'b -> {lab=(pre 'b) 'a})
                              (:scheme (LIST T0 T1)
                                       (arrow (rproduct (rlabel plabel (rpre T1) T0))
                                              (LIST
                                               (rproduct (rlabel plabel (rabs) T0))
                                               T1)))
                              )
                         _ -> (prim-error name))
      '%raccess     -> (match params with
			 (sexp:symbol label)
			 -> (:scheme (LIST T0 T1)
				     (arrow T0
					    (LIST (rproduct (rlabel (make-label label)
								    (rpre T0)
								    T1)))))
			 _ -> (prim-error name))
      '%rset        -> (match params with
			 (sexp:symbol label)
			 -> (:scheme (LIST T0 T1)
				     (arrow undefined-type
					    (LIST (rproduct (rlabel (make-label label)
								    (rpre T0)
								    T1))
						  T0)))
			 _ -> (prim-error name))
      '%dtcon       -> (match params with
			 ;; e.g. list := nil | cons X list
			 ;; %dtcon/list/cons := ∀X.(X,list(X)) → list(X)
			 (sexp:cons dtname altname)
			 -> (match (alist/lookup the-context.datatypes dtname) with
			      (maybe:no) -> (error1 "lookup-primapp: no such datatype" dtname)
			      (maybe:yes dt) -> (dt.get-alt-scheme altname))
			 _ -> (prim-error name))
      '%vcon        -> (match params with
			 (sexp:list ((sexp:symbol label) (sexp:int arity)))
			 -> (let ((plabel (make-label label)))
			      (remember-variant-label label)
			      (match arity with
				;; ∀X.() → Σ(l:pre (Π());X)
				0 -> (:scheme (LIST T0) (arrow (rsum (rlabel plabel (rpre (pred 'product '())) T0)) '()))
				;; ∀XY.X → Σ(l:pre X;Y)
				1 -> (:scheme (LIST T0 T1) (arrow (rsum (rlabel plabel (rpre T0) T1)) (LIST T0)))
				;; ∀ABCD.Π(A,B,C) → Σ(l:pre (Π(A,B,C));D)
				_ -> (let ((tdflt (new-tvar))
					   (targs (n-tvars arity)))
				       (:scheme (list:cons tdflt targs)
						(arrow (rsum (rlabel plabel (rpre (pred 'product targs)) tdflt))
						       targs)))))
			 _ -> (prim-error name))
      '%nvget       -> (match params with
			 (sexp:list ((sexp:cons dtname altname) (sexp:int index) (sexp:int arity)))
			 -> (if (eq? dtname 'nil)
				;; polymorphic variant
				(let ((argvars (n-tvars arity))
				      (tdflt (new-tvar))
				      (plabel (make-label altname))
				      (vtype (rsum (rlabel plabel
							   (rpre (if (> arity 1)
								     (pred 'product argvars)
								     (car argvars)))
							   tdflt))))
				  (:scheme (list:cons tdflt argvars)
					   ;; e.g., to pick the second arg:
					   ;; ∀0123. Σ(l:pre (0,1,2);3) → 1
					   (arrow (nth argvars index) (LIST vtype))))
				;; normal variant
				(match (alist/lookup the-context.datatypes dtname) with
				  (maybe:no) -> (error1 "lookup-primapp: no such datatype" dtname)
				  (maybe:yes dt)
				  -> (let ((alt (dt.get altname))
					   (tvars (dt.get-tvars))
					   (dtscheme (pred dtname tvars)))
				       (:scheme tvars (arrow (nth alt.types index) (LIST dtscheme))))))
			 _ -> (prim-error name))
      '%callocate  -> (let ((type (parse-type params)))
			;; int -> (buffer <type>)
			(:scheme '() (arrow (pred 'buffer (LIST type)) (LIST int-type))))
      '%exit       -> (:scheme (LIST T0 T1) (arrow T0 (LIST T1)))
      '%cget       -> (:scheme (LIST T0) (arrow T0 (LIST (pred 'buffer (LIST T0)) int-type)))
      '%cset       -> (:scheme (LIST T0 T1) (arrow undefined-type (LIST (pred 'buffer (LIST T0)) int-type T1)))
      ;; these both can be done with %%cexp, but we need to be able to detect their usage in order to
      ;;   disable inlining of functions that use them.
      '%getcc      -> (:scheme (LIST T0) (arrow (pred 'continuation (LIST T0)) (LIST)))
      '%putcc      -> (:scheme (LIST T0 T1) (arrow T1 (LIST (pred 'continuation (LIST T0)) T0)))
      ;; used in an nvcase else clause when the compiler knows the match is complete
      ;;  [i.e., no else clause is needed]
      '%complete-match -> (:scheme (LIST T0) (arrow T0 '()))
      ;; llvm prims
      '%llarith    -> (:scheme '() (arrow int-type (LIST int-type int-type)))
      '%llicmp     -> (:scheme '() (arrow bool-type (LIST int-type int-type)))
      '%lleq       -> (:scheme (LIST T0) (arrow bool-type (LIST T0 T0)))
      _ -> (error1 "lookup-primapp" name)))

  ;; each exception is stored in a global table along with a tvar
  ;;  that will unify with each use.
  (define (get-exn-type name)
    (match (alist/lookup the-context.exceptions name) with
      (maybe:yes tvar) -> tvar
      (maybe:no)
      -> (let ((tvar (new-tvar)))
	   (alist/push the-context.exceptions name tvar)
	   tvar)))

  ;; given an exception row type for <exp> look up its name in the global
  ;;   table and unify each element of the sum.

  (define (unify-exception-types exp row tenv)
    ;;(printf " ------- " (type-repr row) " -- " (type-repr (apply-subst (type-of exp tenv))) "\n")
    (match row with
      (type:pred 'rlabel ((type:pred exn-name _ _) exn-type _) _)
      -> (let ((global-type (get-exn-type exn-name)))
	   (unify exp global-type exn-type))
      _ -> (error1 "unify-exception-types: bad type" (type-repr row))
      ))

  ;; unify the label from this row with the global table
  (define (type-of-raise val tenv)
    (let ((val-type (apply-subst (type-of val tenv))))
      (match val-type with
	(type:pred 'rsum (row) _)
	-> (begin
	     (unify-exception-types val row tenv)
	     val-type)
	_ -> (begin
	       (printf "bad exception type:\n")
	       (pp-node val) (newline)
	       (error1 "bad exception type:" val)))))

  ;; unify each label from this row with the global table
  (define (type-of-handle exn-val exn-match tenv)
    (let ((match-type (type-of exn-match tenv))
	  (val-type (apply-subst (type-of exn-val tenv))))
      ;;(printf "type-of-handle: " (type-repr (apply-subst val-type)) "\n")
      (match val-type with
	(type:pred 'rsum (row) _)
	-> (begin
	     (unify-exception-types exn-match row tenv)
	     match-type)
	_ -> (error1 "unify-handlers: expected row sum type" (type-repr val-type)))))

  (define (type-of-primapp name params subs tenv)
    ;; special primapps
    (match name with
      ;; we need a map of exception => tvar, then cross-verify with each handle expression.
      '%exn-raise
      -> (match subs with
	   (exn-val)
	   -> (type-of-raise exn-val tenv)
	   _ -> (error1 "%exn-raise: bad arity" subs))
      '%exn-handle
      ;; %exn-handle is wrapped around the match expression of the exception handler
      -> (match subs with
	   (exn-val exn-match)
	   -> (type-of-handle exn-val exn-match tenv)
	   _ -> (error1 "%exn-handle: bad arity" subs))

      ;; normal primapps
      _ -> (match (lookup-primapp name params) with
	     (:scheme gens type)
	     -> (let ((itype (instantiate-type-scheme gens type)))
		  (when the-context.options.debugtyping
		  	(printf "type-of-primapp, name = " (sym name) " params= " (repr params) "\n")
		  	(printf "type-of-primapp, scheme = " (scheme-repr (lookup-primapp name params)) "\n")
		  	(printf "           instantiated = " (type-repr itype) "\n")
		  	)
		  (match itype with
		    ;; very similar to type-of-cexp
		    (type:pred 'arrow (result-type . arg-types) _)
		    -> (begin
			 (when (not (= (length arg-types) (length subs)))
			       (error2 "wrong number of args to primapp" (map type-repr arg-types) subs))
			 (for-range
			     i (length arg-types)
			     (let ((arg (nth subs i))
				   (ta (type-of arg tenv))
				   (arg-type (nth arg-types i)))
			       (unify arg ta arg-type)))
			 result-type)
		    _ -> (error1 "type-of-primapp" name)
		    )))))

  (define (apply-subst-to-program n)
    ;; This one loop is causing heap allocation to triple while compiling,
    ;;   and almost certainly adding a lot to the compile time.
    ;; I think this is because apply-subst is destroying the shared nature
    ;;   of the tree of types - by deep-copying all types.
    (set-node-type! n (apply-subst (noderec->type n)))
    (for-each apply-subst-to-program (noderec->subs n)))

  (let ((t (type-of node (alist/make))))
    ;;(printf "applying subst...") (flush)
    (apply-subst-to-program node)
    ;;(printf "done.\n")
    t))

(define (dump-types n)

  (define (strip-alpha name)
    (let ((name0 (symbol->string name))
          (parts (string-split name0 #\_)))
      (let loop ((parts (reverse parts)))
        (if (all digit? (string->list (car parts)))
            (loop (cdr parts))
            (format (join "_" (reverse parts)))))))

  (let ((funstack (LIST 0)))
    (for (make-node-generator n) (node depth)
      ;; normalize indent
      (match (noderec->t node) with
        (node:function name formals)
        -> (begin
             (if (> depth (car funstack))
                 (PUSH funstack depth)
                 (while (< depth (car funstack))
                   (pop funstack)))
             (printf (rpad 20 (format (repeat (length funstack) "  ") (strip-alpha name)))
                     " : " (type-repr* (noderec->type node) #t) "\n"))
        _ -> #u
        )
      )))


;; (define (test-typing)
;;   (let ((context (make-context))
;; 	(transform (transformer context))
;; 	;;(exp0 (sexp:list (read-string "(%%cexp (int int -> int) \"%0+%1\" 3 #\\a)")))
;; 	;;(exp0 (sexp:list (read-string "(begin #\\A (if #t 3 4))")))
;; 	(exp0 (sexp:list (read-string "((lambda (a b) (%%cexp (int int -> int) \"%0+%1\" a b)) 3 4)")))
;; 	(exp1 (transform exp0))
;; 	(node0 (walk exp1))
;; 	(graph0 (build-dependency-graph node0))
;; 	(ignore (print-graph graph0))
;; 	(strong (strongly graph0))
;; 	(_ (set! context.scc-graph strong))
;; 	(type0 (type-program node0 context))
;; 	)
;;     (pp-node node0)
;;     (newline)
;;     ))

;; uncomment to test
;(include "self/nodes.scm")
;(test-typing)
