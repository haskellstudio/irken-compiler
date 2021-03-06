;; -*- Mode: Irken -*-

;; a simple stack

(define (make-stack)
  (let ((l '()))
    (define (push x)
      (set! l (list:cons x l)))
    (define (pop)
      (match l with
	() -> (error "stack underflow")
	(hd . tl)
	-> (let ((result hd))
	     (set! l tl)
	     result)))
    (define (get) l)
    (define (top)
      (match l with
	() -> (error "stack underflow")
	(hd . _) -> hd))
    (define (stack-length) (length l))
    {push=push pop=pop top=top get=get length=stack-length}
    ))

