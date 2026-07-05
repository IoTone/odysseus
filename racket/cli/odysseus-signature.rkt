#lang racket/base

;; odysseus-signature — stored email signature images in the `signatures` table.
;; Faithful Racket port of scripts/odysseus-signature. First DB-backed CLI;
;; exercises core/db.rkt (SQLite). Uses raw SQL, like the Python tool (there is
;; no ORM model for this table).
;;
;;   odysseus-signature list                    # metadata only
;;   odysseus-signature show SIG_ID             # full record incl. data_png
;;   odysseus-signature export SIG_ID --png OUT # write PNG bytes to a file
;;   odysseus-signature delete SIG_ID

(require db
         net/base64
         racket/file
         racket/string
         cli-kit
         "../config.rkt")

;; ---- SQL value helpers -----------------------------------------------------

(define (s-or-empty v) (if (sql-null? v) "" v))          ; NULL -> ""
(define (s-or-null  v) (if (sql-null? v) 'null v))        ; NULL -> JSON null
(define (s-str      v) (if (sql-null? v) "" (format "~a" v)))
(define (s-bool     n) (not (zero? n)))                   ; sqlite 0/1 -> bool

(define png-magic (bytes 137 80 78 71 13 10 26 10))      ; \x89PNG\r\n\x1a\n

(define (decode-png-data data-png)
  (define raw0 (if (string? data-png) data-png ""))
  ;; strip data-URL prefix ("data:image/png;base64,....")
  (define raw (if (string-contains? raw0 ",")
                  (substring raw0 (add1 (caar (regexp-match-positions #rx"," raw0))))
                  raw0))
  (define decoded
    (with-handlers ([exn:fail? (lambda (e) (fail (format "data_png is not valid base64: ~a" (exn-message e))))])
      (base64-decode (string->bytes/utf-8 raw))))
  (unless (and (>= (bytes-length decoded) 8)
               (bytes=? (subbytes decoded 0 8) png-magic))
    (fail "data_png is not a PNG image"))
  decoded)

;; ---- subcommands -----------------------------------------------------------

(define (cmd-list pretty?)
  (define rows
    (call-with-app-db #:mode 'read-only
      (lambda (conn)
        (query-rows conn
          (string-append
           "SELECT id, owner, name, width, height, length(data_png) AS png_len, "
           "       svg IS NOT NULL AS has_svg, created_at "
           "FROM signatures ORDER BY created_at DESC")))))
  (emit
   (for/list ([r (in-list rows)])
     (hasheq 'id               (vector-ref r 0)
             'owner            (s-or-empty (vector-ref r 1))
             'name             (s-or-null  (vector-ref r 2))
             'width            (s-or-null  (vector-ref r 3))
             'height           (s-or-null  (vector-ref r 4))
             'png_bytes_approx (s-or-null  (vector-ref r 5))
             'has_svg          (s-bool     (vector-ref r 6))
             'created_at       (s-str      (vector-ref r 7))))
   #:pretty? pretty?))

(define (cmd-show id pretty?)
  (define r
    (call-with-app-db #:mode 'read-only
      (lambda (conn)
        (define rs (query-rows conn
          (string-append
           "SELECT id, owner, name, width, height, data_png, svg, created_at "
           "FROM signatures WHERE id = ?") id))
        (and (pair? rs) (car rs)))))
  (unless r (fail (format "no signature with id ~s" id)))
  (define svg (vector-ref r 6))
  (emit (hasheq 'id         (vector-ref r 0)
                'owner      (s-or-empty (vector-ref r 1))
                'name       (s-or-null  (vector-ref r 2))
                'width      (s-or-null  (vector-ref r 3))
                'height     (s-or-null  (vector-ref r 4))
                'data_png   (s-or-null  (vector-ref r 5))
                'has_svg    (and (not (sql-null? svg)) (not (equal? svg "")))
                'created_at (s-str      (vector-ref r 7)))
        #:pretty? pretty?))

(define (cmd-export id out-path pretty?)
  (define data-png
    (call-with-app-db #:mode 'read-only
      (lambda (conn)
        (define rs (query-rows conn "SELECT data_png FROM signatures WHERE id = ?" id))
        (cond [(null? rs) (fail (format "no signature with id ~s" id))]
              [else (vector-ref (car rs) 0)]))))
  (define png-bytes (decode-png-data (if (sql-null? data-png) "" data-png)))
  (define out (string->path out-path))
  (define parent (let-values ([(base name dir?) (split-path out)]) base))
  (when (path? parent) (make-directory* parent))
  (call-with-output-file out #:exists 'replace
    (lambda (o) (write-bytes png-bytes o)))
  (emit (hasheq 'ok #t 'id id 'path (path->string out) 'bytes (bytes-length png-bytes))
        #:pretty? pretty?))

(define (cmd-delete id pretty?)
  (call-with-app-db
   (lambda (conn)
     ;; existence check, then delete (db's query-exec doesn't surface rowcount)
     (define exists?
       (pair? (query-rows conn "SELECT 1 FROM signatures WHERE id = ? LIMIT 1" id)))
     (unless exists? (fail (format "no signature with id ~s" id)))
     (query-exec conn "DELETE FROM signatures WHERE id = ?" id)))
  (emit (hasheq 'ok #t 'id id 'deleted #t) #:pretty? pretty?))

;; ---- arg parsing -----------------------------------------------------------

(define (dispatch)
  (define args (vector->list (current-command-line-arguments)))
  (define pretty? (pretty-from-args? args))
  (define rest (filter (lambda (a) (not (string=? a "--pretty"))) args))
  (when (null? rest) (fail "missing subcommand: list|show|export|delete" #:code 2))
  (define cmd (car rest))
  (define cargs (cdr rest))
  (case cmd
    [("list") (cmd-list pretty?)]
    [("show") (when (null? cargs) (fail "show needs a SIG_ID" #:code 2)) (cmd-show (car cargs) pretty?)]
    [("export")
     (when (null? cargs) (fail "export needs a SIG_ID" #:code 2))
     (define id (car cargs))
     (define rest2 (cdr cargs))
     (define out
       (let loop ([xs rest2])
         (cond [(null? xs) (fail "export requires --png OUT" #:code 2)]
               [(string=? (car xs) "--png")
                (when (null? (cdr xs)) (fail "expected a path after --png" #:code 2))
                (cadr xs)]
               [else (loop (cdr xs))])))
     (cmd-export id out pretty?)]
    [("delete") (when (null? cargs) (fail "delete needs a SIG_ID" #:code 2)) (cmd-delete (car cargs) pretty?)]
    [else (fail (format "unknown subcommand: ~a" cmd) #:code 2)]))

(module+ main
  (run "odysseus-signature" app-version dispatch))
