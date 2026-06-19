#lang racket/base

;; domain/agent/exec.rkt — the #:exec effect: a tool dispatcher.
;;
;; Real implementations live in src/tool_implementations.py (4444 lines). This
;; ports a working subset and is the dispatch table the rest slot into. Each
;; handler takes the tool-block's content (the string function-call->tool-block
;; produced) and returns a result string. The file-based tools (read/write/edit/
;; glob/grep) are pure Racket so they work cross-platform; bash/python shell out.

(require racket/match
         racket/string
         racket/list
         racket/port
         racket/system
         racket/file
         file/glob
         net/http-client
         net/url
         json
         "../tools/convert.rkt")    ; tool-block-type / -content

(provide make-exec default-handlers
         truncate-output read-clip)   ; exported for tests (output-cap fidelity)

;; Output caps — single source of truth in src/constants.py.
(define MAX-OUTPUT-CHARS 10000)   ; bash/python/web_search/web_fetch/grep/glob/ls
(define MAX-READ-CHARS   20000)   ; read_file / document preview

;; Port of src/tool_execution.py _truncate: cap, then a total-length note.
(define (truncate-output s [limit MAX-OUTPUT-CHARS])
  (if (> (string-length s) limit)
      (string-append (substring s 0 limit)
                     (format "\n... (truncated, ~a chars total)" (string-length s)))
      s))

;; read_file caps at MAX_READ_CHARS with a DIFFERENT note (filesystem_tools.py).
(define (read-clip s)
  (if (> (string-length s) MAX-READ-CHARS)
      (string-append (substring s 0 MAX-READ-CHARS)
                     (format "\n... [truncated at ~a chars]" MAX-READ-CHARS))
      s))
(define (sj lines) (string-join lines "\n"))

;; ---- helpers ---------------------------------------------------------------
(define (parse-json-content content)        ; content is JSON for several tools
  (with-handlers ([exn:fail? (lambda (_) (hasheq))])
    (let ([v (string->jsexpr content)]) (if (hash? v) v (hasheq)))))

(define (shell-capture command)
  (define out (open-output-string))
  (parameterize ([current-output-port out] [current-error-port out]) (system command))
  (truncate-output (get-output-string out)))

;; ---- handlers --------------------------------------------------------------
(define default-handlers
  (hash
   "bash"   (lambda (c) (shell-capture c))
   "python" (lambda (c)
              (define f (make-temporary-file "odypy~a.py"))
              (dynamic-wind void
                (lambda () (with-output-to-file f #:exists 'replace (lambda () (display c)))
                            (shell-capture (string-append "python3 " (path->string f))))
                (lambda () (when (file-exists? f) (delete-file f)))))

   "read_file"
   (lambda (content)
     (cond
       [(string-prefix? (string-trim content) "{")     ; JSON {path, offset?, limit?}
        (define a (parse-json-content content))
        (define path (hash-ref a 'path ""))
        (cond
          [(not (file-exists? path)) (format "error: no such file: ~a" path)]
          [else
           (define lines (string-split (file->string path) "\n" #:trim? #f))
           (define off (max 0 (sub1 (let ([o (hash-ref a 'offset 1)]) (if (number? o) o 1)))))
           (define lim (let ([l (hash-ref a 'limit #f)]) (and (number? l) l)))
           (define chosen (let ([tail (if (> off (length lines)) '() (drop lines off))])
                            (if lim (take tail (min lim (length tail))) tail)))
           (read-clip (sj chosen))])]
       [(file-exists? content) (read-clip (file->string content))]
       [else (format "error: no such file: ~a" content)]))

   "write_file"
   (lambda (content)
     (define i (string-index content #\newline))
     (define-values (path body) (if i (values (substring content 0 i) (substring content (add1 i)))
                                    (values content "")))
     (make-parent-directory* path)
     (with-output-to-file path #:exists 'replace (lambda () (display body)))
     (format "wrote ~a bytes to ~a" (string-length body) path))

   "edit_file"
   (lambda (content)
     (define a (parse-json-content content))
     (define path (hash-ref a 'path ""))
     (define old (hash-ref a 'old_string ""))
     (define new (hash-ref a 'new_string ""))
     (define all? (eq? (hash-ref a 'replace_all #f) #t))
     (cond
       [(not (file-exists? path)) (format "error: no such file: ~a" path)]
       [else
        (define text (file->string path))
        (define n (count-substr text old))
        (cond
          [(= n 0) (format "error: old_string not found in ~a" path)]
          [(and (not all?) (> n 1)) (format "error: old_string not unique in ~a (~a matches); set replace_all" path n)]
          [else
           (define out (if all? (string-replace text old new)
                           (string-replace text old new #:all? #f)))
           (with-output-to-file path #:exists 'replace (lambda () (display out)))
           (format "edited ~a (~a replacement~a)" path (if all? n 1) (if (and all? (> n 1)) "s" ""))])]))

   "ls"
   (lambda (content)
     (define a (parse-json-content content))
     (define path (let ([p (hash-ref a 'path ".")]) (if (string? p) p ".")))
     (if (directory-exists? path)
         (sj (sort (map path->string (directory-list path)) string<?))
         (format "error: not a directory: ~a" path)))

   "glob"
   (lambda (content)
     (define a (parse-json-content content))
     (define pat (hash-ref a 'pattern "*"))
     (define base (let ([p (hash-ref a 'path ".")]) (if (string? p) p ".")))
     (define matches (glob (build-path base pat)))
     (define newest (sort matches > #:key (lambda (p) (file-or-directory-modify-seconds p))))
     (if (null? newest) "(no matches)" (truncate-output (sj (map path->string newest)))))

   "grep"
   (lambda (content)
     (define a (parse-json-content content))
     (define rx (let ([p (hash-ref a 'pattern "")])
                  (if (eq? (hash-ref a 'ignore_case #f) #t) (pregexp (string-append "(?i:" p ")")) (pregexp p))))
     (define base (let ([p (hash-ref a 'path ".")]) (if (string? p) p ".")))
     (define gl (hash-ref a 'glob #f))
     (define cap (let ([m (hash-ref a 'max_results 200)]) (if (number? m) m 200)))
     (define files
       (cond [(file-exists? base) (list (string->path base))]
             [(and gl (string? gl)) (glob (build-path base "**" gl))]
             [else (find-files file-exists? base)]))
     (define hits
       (for*/list ([f (in-list files)] #:when (file-exists? f)
                   [lines (in-value (with-handlers ([exn:fail? (lambda (_) '())])
                                      (string-split (file->string f) "\n" #:trim? #f)))]
                   [(ln i) (in-indexed (in-list lines))]   ; ln + 0-based index, in parallel
                   #:when (regexp-match? rx ln))
         (format "~a:~a:~a" (path->string f) (add1 i) (string-trim ln))))
     (define limited (if (> (length hits) cap) (take hits cap) hits))
     (if (null? limited) "(no matches)" (truncate-output (sj limited))))

   "web_fetch"
   (lambda (content)
     (define a (parse-json-content content))
     (define url (let ([u (hash-ref a 'url "")]) (if (string-prefix? u "http") u (string-append "https://" u))))
     (with-handlers ([exn:fail? (lambda (e) (format "error fetching ~a: ~a" url (exn-message e)))])
       (truncate-output (port->string (get-pure-port (string->url url) #:redirections 5)))))))

;; index of first char (racket has no string-index)
(define (string-index s ch)
  (for/first ([c (in-string s)] [i (in-naturals)] #:when (char=? c ch)) i))

;; count non-overlapping occurrences of `sub` in `s`
(define (count-substr s sub)
  (if (string=? sub "") 0
      (let loop ([start 0] [n 0])
        (define i (let ([m (regexp-match-positions (regexp (regexp-quote sub)) s start)])
                    (and m (caar m))))
        (if i (loop (+ i (string-length sub)) (add1 n)) n))))

;; (make-exec [#:handlers h]) -> (tool-block -> string)
(define (make-exec #:handlers [handlers default-handlers])
  (lambda (tb)
    (define h (hash-ref handlers (tool-block-type tb) #f))
    (if h
        (with-handlers ([exn:fail? (lambda (e) (format "error: ~a" (exn-message e)))])
          (h (tool-block-content tb)))
        (format "tool '~a' not implemented in this adapter" (tool-block-type tb)))))
