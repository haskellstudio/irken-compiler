;; -*- Mode: Irken -*-

(define (eq? a b)
  (%%cexp ('a 'a -> bool) "%0==%1" a b))

(define (+ a b)
  (%%cexp (int int -> int) "%0+%1" a b))

(define (kons x l)
  (:kons x l))

(define (klength l)
  (define loop
    (:nil)       n -> n
    (:kons _ tl) n -> (loop tl (+ n 1))
    )
  (loop l 0)
  )

(klength (kons 1 (kons 2 (kons 3 (:nil)))))


  
  