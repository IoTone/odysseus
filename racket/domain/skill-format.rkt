#lang racket/base

;; domain/skill-format.rkt — SKILL.md parser & writer. Port of
;; services/memory/skill_format.py: YAML-subset frontmatter (scalars, inline
;; [a, b] lists, block `-` lists), known body sections (When to Use /
;; Procedure / Pitfalls / Verification) with everything else preserved in
;; body_extra, and the Skill record round-trip.
;;
;; A skill is represented as a hasheq mirroring the Python dataclass fields
;; (name description version category tags platforms requires_toolsets
;;  fallback_for_toolsets status confidence source teacher_model owner created
;;  when_to_use procedure pitfalls verification body_extra uses last_used path).

(require racket/string
         racket/list
         json
         "util.rkt")

(provide slugify parse-frontmatter emit-frontmatter parse-body emit-body
         skill-from-markdown skill->markdown skill->dict make-skill skill-now-iso)

;; ---- slugify -----------------------------------------------------------------
(define (slugify text [fallback "skill"])
  (define s0 (string-downcase (string-trim (format "~a" (or text "")))))
  (define s (string-trim (regexp-replace* #px"[^a-z0-9]+" s0 "-") "-"))
  (define out (if (string=? s "") fallback s))
  (substring out 0 (min 60 (string-length out))))

;; ---- frontmatter (mini-YAML) ---------------------------------------------------

;; split on sep at depth 0, respecting [] nesting and quotes
(define (split-top-level s sep)
  (let loop ([cs (string->list s)] [buf '()] [depth 0] [quote-ch #f] [out '()])
    (cond
      [(null? cs)
       (reverse (if (null? buf) out (cons (string-trim (list->string (reverse buf))) out)))]
      [else
       (define ch (car cs))
       (cond
         [quote-ch (loop (cdr cs) (cons ch buf) depth (if (char=? ch quote-ch) #f quote-ch) out)]
         [(or (char=? ch #\') (char=? ch #\")) (loop (cdr cs) (cons ch buf) depth ch out)]
         [(char=? ch #\[) (loop (cdr cs) (cons ch buf) (add1 depth) #f out)]
         [(char=? ch #\]) (loop (cdr cs) (cons ch buf) (max 0 (sub1 depth)) #f out)]
         [(and (char=? ch sep) (zero? depth))
          (loop (cdr cs) '() 0 #f (cons (string-trim (list->string (reverse buf))) out))]
         [else (loop (cdr cs) (cons ch buf) depth #f out)])])))

(define (parse-scalar raw0)
  (define raw (string-trim raw0))
  (define lo (string-downcase raw))
  (cond
    [(string=? raw "") ""]
    [(and (string-prefix? raw "[") (string-suffix? raw "]"))
     (define inner (string-trim (substring raw 1 (sub1 (string-length raw)))))
     (if (string=? inner "") '() (map parse-scalar (split-top-level inner #\,)))]
    [(member lo '("true" "yes")) #t]
    [(member lo '("false" "no")) #f]
    [(member lo '("null" "none" "~")) 'null]
    [(and (> (string-length raw) 1)
          (char=? (string-ref raw 0) (string-ref raw (sub1 (string-length raw))))
          (memv (string-ref raw 0) '(#\' #\")))
     (substring raw 1 (sub1 (string-length raw)))]
    [(regexp-match? #px"^[+-]?[0-9]+$" raw) (string->number raw)]
    [(and (string-contains? raw ".")
          (regexp-match? #px"^[+-]?([0-9]*\\.[0-9]+|[0-9]+\\.[0-9]*)([eE][+-]?[0-9]+)?$" raw))
     (exact->inexact (string->number raw))]
    [else raw]))

;; → (values fm-hasheq body-string)
(define (parse-frontmatter text)
  (cond
    [(not (string-prefix? text "---")) (values (hasheq) text)]
    [else
     (define end (let ([m (regexp-match-positions #rx"\n---" text 3)]) (and m (caar m))))
     (cond
       [(not end) (values (hasheq) text)]
       [else
        (define fm-text (string-trim (substring text 3 end) "\n" #:right? #f))
        (define body (string-trim (substring text (+ end 4)) "\n" #:right? #f))
        (define-values (fm _pending)
          (for/fold ([fm (hasheq)] [pending #f])
                    ([line (in-list (string-split fm-text "\n" #:trim? #f))])
            (cond
              [(or (string=? (string-trim line) "")
                   (string-prefix? (string-trim line #:right? #f) "#"))
               (values fm pending)]
              [(regexp-match #px"^([a-zA-Z_][a-zA-Z0-9_]*):\\s*(.*)$" line)
               => (lambda (m)
                    (define key (string->symbol (cadr m)))
                    (define val (caddr m))
                    (if (string=? (string-trim val) "")
                        (values (hash-set fm key '()) key)
                        (values (hash-set fm key (parse-scalar val)) #f)))]
              [(and pending (regexp-match #px"^\\s*-\\s*(.*)$" line))
               => (lambda (m)
                    (define existing (hash-ref fm pending '()))
                    (values (hash-set fm pending
                                      (append (if (list? existing) existing '())
                                              (list (parse-scalar (cadr m)))))
                            pending))]
              [else (values fm pending)])))
        (values fm body)])]))

(define (emit-scalar v)
  (cond
    [(eq? v 'null) "null"]
    [(eq? v #t) "true"] [(eq? v #f) "false"]
    [(number? v) (number->string v)]
    [(list? v) (string-append "[" (string-join (map emit-scalar v) ", ") "]")]
    [else
     (define s (format "~a" v))
     (if (ormap (lambda (c) (memv c '(#\: #\# #\newline #\[ #\] #\{ #\} #\, #\& #\* #\! #\| #\> #\' #\" #\% #\@)))
                (string->list s))
         (jsexpr->string s)
         s)]))

;; fm is an ordered (key . value) alist — skips null/empty values like Python
(define (emit-frontmatter fm-alist)
  (string-join
   (for/list ([kv (in-list fm-alist)]
              #:unless (or (eq? (cdr kv) 'null) (equal? (cdr kv) '()) (equal? (cdr kv) "")
                           (eq? (cdr kv) #f)))
     (format "~a: ~a" (car kv) (emit-scalar (cdr kv))))
   "\n"))

;; ---- body sections -------------------------------------------------------------

(define heading->key
  (hash "when to use" 'when_to_use "procedure" 'procedure "steps" 'procedure
        "pitfalls" 'pitfalls "verification" 'verification))

;; bullets / numbered lines; plain lines continue the previous bullet
(define (parse-list-lines text)
  (for/fold ([items '()] #:result (reverse items))
            ([line (in-list (string-split (or text "") "\n"))])
    (define s (string-trim line))
    (cond
      [(string=? s "") items]
      [(regexp-match #px"^(?:[-*]|[0-9]+[.)])\\s+(.*)$" s)
       => (lambda (m) (cons (string-trim (cadr m)) items))]
      [(pair? items) (cons (string-append (car items) " " s) (cdr items))]
      [else (cons s items)])))

;; → hasheq with when_to_use (string), procedure/pitfalls/verification (lists),
;;   body_extra (string)
(define (parse-body body)
  (define empty-out (hasheq 'when_to_use "" 'procedure '() 'pitfalls '() 'verification '()
                            'body_extra ""))
  (cond
    [(or (not body) (string=? (string-trim body) "")) empty-out]
    [else
     ;; split into ((key-or-#f . lines) ...) on ## headings
     (define sections
       (reverse
        (for/fold ([acc (list (cons #f '()))])
                  ([line (in-list (string-split body "\n" #:trim? #f))])
          (cond
            [(regexp-match #px"^##\\s+(.*?)\\s*$" line)
             => (lambda (m)
                  (cons (cons (hash-ref heading->key (string-downcase (string-trim (cadr m))) #f) '())
                        acc))]
            [else (cons (cons (caar acc) (cons line (cdar acc))) (cdr acc))]))))
     (for/fold ([out empty-out]) ([sec (in-list sections)])
       (define key (car sec))
       (define text (string-trim (string-join (reverse (cdr sec)) "\n") "\n"))
       (cond
         [(not key)
          (define extras (string-trim text))
          (if (string=? extras "")
              out
              (hash-set out 'body_extra
                        (string-trim (string-append (hash-ref out 'body_extra) "\n\n" extras))))]
         [(eq? key 'when_to_use) (hash-set out 'when_to_use (string-trim text))]
         [else (hash-set out key (parse-list-lines text))]))]))

(define (emit-body sections)
  (define parts
    (append
     (let ([when (string-trim (or (hash-ref sections 'when_to_use "") ""))])
       (if (string=? when "") '() (list (format "## When to Use\n\n~a" when))))
     (for/list ([kv (in-list '((procedure . "Procedure") (pitfalls . "Pitfalls")
                               (verification . "Verification")))]
                #:when (pair? (hash-ref sections (car kv) '())))
       (define items (hash-ref sections (car kv)))
       (format "## ~a\n\n~a" (cdr kv)
               (if (eq? (car kv) 'procedure)
                   (string-join (for/list ([x (in-list items)] [i (in-naturals 1)])
                                  (format "~a. ~a" i x)) "\n")
                   (string-join (for/list ([x (in-list items)]) (format "- ~a" x)) "\n"))))
     (let ([extra (string-trim (or (hash-ref sections 'body_extra "") ""))])
       (if (string=? extra "") '() (list extra)))))
  (if (null? parts) "" (string-append (string-join parts "\n\n") "\n")))

;; ---- the Skill record ------------------------------------------------------------

(define (skill-now-iso)
  (define d (seconds->date (current-seconds) #f))
  (define (p2 n) (if (< n 10) (format "0~a" n) (number->string n)))
  (format "~a-~a-~aT~a:~a:~aZ" (date-year d) (p2 (date-month d)) (p2 (date-day d))
          (p2 (date-hour d)) (p2 (date-minute d)) (p2 (date-second d))))

(define (as-list v)
  (cond [(or (eq? v #f) (eq? v 'null)) '()]
        [(list? v) (for/list ([x (in-list v)] #:unless (or (eq? x 'null) (equal? x "")))
                     (format "~a" x))]
        [else (list (format "~a" v))]))

(define (as-float v [default 0.8])
  (cond [(number? v) (exact->inexact v)]
        [(and (string? v) (string->number v)) => exact->inexact]
        [else default]))

(define (s-or v default)   ; str(fm.get(k, default) or default)
  (if (jtruthy v) (format "~a" v) default))

;; constructor with the dataclass defaults
(define (make-skill #:name name
                    #:description [description ""] #:version [version "1.0.0"]
                    #:category [category "general"] #:tags [tags '()]
                    #:platforms [platforms '()] #:requires-toolsets [requires-toolsets '()]
                    #:fallback-for-toolsets [fallback-for-toolsets '()]
                    #:status [status "draft"] #:confidence [confidence 0.8]
                    #:source [source "learned"] #:teacher-model [teacher-model #f]
                    #:owner [owner #f] #:created [created ""]
                    #:when-to-use [when-to-use ""] #:procedure [procedure '()]
                    #:pitfalls [pitfalls '()] #:verification [verification '()]
                    #:body-extra [body-extra ""] #:path [path #f])
  (hasheq 'name name 'description description 'version version 'category category
          'tags tags 'platforms platforms 'requires_toolsets requires-toolsets
          'fallback_for_toolsets fallback-for-toolsets 'status status
          'confidence confidence 'source source 'teacher_model teacher-model
          'owner owner 'created created 'when_to_use when-to-use 'procedure procedure
          'pitfalls pitfalls 'verification verification 'body_extra body-extra
          'uses 0 'last_used 'null 'path path))

(define (skill-from-markdown text #:path [path #f])
  (define-values (fm body) (parse-frontmatter text))
  (define sections (parse-body body))
  (define (fmget k [d #f]) (let ([v (hash-ref fm k d)]) (if (eq? v 'null) d v)))
  (define raw-name (fmget 'name))
  (make-skill
   #:name (slugify (if (jtruthy raw-name) raw-name (fmget 'description "")) "skill")
   #:description (s-or (fmget 'description "") "")
   #:version (s-or (fmget 'version "1.0.0") "1.0.0")
   #:category (s-or (fmget 'category "general") "general")
   #:tags (as-list (fmget 'tags))
   #:platforms (as-list (fmget 'platforms))
   #:requires-toolsets (as-list (fmget 'requires_toolsets))
   #:fallback-for-toolsets (as-list (fmget 'fallback_for_toolsets))
   #:status (s-or (fmget 'status "draft") "draft")
   #:confidence (as-float (fmget 'confidence 0.8) 0.8)
   #:source (s-or (fmget 'source "learned") "learned")
   #:teacher-model (let ([v (fmget 'teacher_model)]) (and (jtruthy v) (format "~a" v)))
   #:owner (let ([v (fmget 'owner)]) (and (jtruthy v) (format "~a" v)))
   #:created (s-or (fmget 'created) (skill-now-iso))
   #:when-to-use (hash-ref sections 'when_to_use)
   #:procedure (hash-ref sections 'procedure)
   #:pitfalls (hash-ref sections 'pitfalls)
   #:verification (hash-ref sections 'verification)
   #:body-extra (hash-ref sections 'body_extra)
   #:path path))

(define (round3 x) (/ (round (* (exact->inexact x) 1000.0)) 1000.0))

(define (skill->markdown sk)
  (define (g k [d #f]) (hash-ref sk k d))
  (define fm-alist
    (append
     (list (cons 'name (g 'name)) (cons 'description (g 'description ""))
           (cons 'version (g 'version "1.0.0")) (cons 'category (g 'category "general"))
           (cons 'tags (g 'tags '())) (cons 'platforms (g 'platforms '()))
           (cons 'requires_toolsets (g 'requires_toolsets '()))
           (cons 'fallback_for_toolsets (g 'fallback_for_toolsets '()))
           (cons 'status (g 'status "draft"))
           (cons 'confidence (round3 (g 'confidence 0.8)))
           (cons 'source (g 'source "learned")))
     (let ([tm (g 'teacher_model)]) (if (jtruthy tm) (list (cons 'teacher_model tm)) '()))
     (let ([ow (g 'owner)]) (if (jtruthy ow) (list (cons 'owner ow)) '()))
     (list (cons 'created (let ([c (g 'created "")]) (if (jtruthy c) c (skill-now-iso)))))))
  (format "---\n~a\n---\n\n~a" (emit-frontmatter fm-alist)
          (emit-body (hasheq 'when_to_use (g 'when_to_use "")
                             'procedure (g 'procedure '()) 'pitfalls (g 'pitfalls '())
                             'verification (g 'verification '())
                             'body_extra (g 'body_extra "")))))

;; the to_dict shape the tool's list/search render from (incl. legacy aliases)
(define (skill->dict sk)
  (define (g k [d #f]) (hash-ref sk k d))
  (define procedure (g 'procedure '()))
  (define body-extra (g 'body_extra ""))
  (hash-set* sk
             'id (g 'name)
             'confidence (round3 (g 'confidence 0.8))
             'title (let ([d (g 'description "")])
                      (if (jtruthy d) d (string-titlecase (string-replace (g 'name) "-" " "))))
             'problem (g 'when_to_use "")
             'solution (if (jtruthy body-extra) body-extra
                           (if (pair? procedure) (car procedure) ""))
             'steps procedure))
