
(datatype list
  (:nil)
  (:cons 'a (list 'a))
  )

(datatype bool (:true) (:false))

(define (make-stack)
  (let ((l (list:nil)))
    (lambda (e)
      (set! l (list:cons e l)))
    ))

(let ((is (make-stack))
      (bs (make-stack)))
  (is 10)
  (bs #f)
  )
