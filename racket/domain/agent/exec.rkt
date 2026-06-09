#lang racket/base

;; domain/agent/exec.rkt — the #:exec effect: a tool dispatcher.
;;
;; The real implementations live in src/tool_implementations.py (4444 lines).
;; This is the wiring + a few real built-ins so the spine runs end-to-end; a
;; full port slots its do_* handlers into the same dispatch table. Each handler
;; takes the tool-block's content string and returns a result string.

(require racket/match
         racket/string
         racket/port
         racket/system
         racket/file
         json
         "../tools/convert.rkt")    ; tool-block-type / -content

(provide make-exec default-handlers)

(define MAX-OUT 4000)
(define (clip s) (if (> (string-length s) MAX-OUT)
                     (string-append (substring s 0 MAX-OUT) "\n…[truncated]") s))

;; content forms mirror what function-call->tool-block emits.
(define default-handlers
  (hash
   "bash"
   (lambda (content)
     (define out (open-output-string))
     (parameterize ([current-output-port out] [current-error-port out])
       (system content))
     (clip (get-output-string out)))

   "read_file"
   (lambda (content)
     ;; plain path, or JSON {path, offset?, limit?}
     (define path (if (string-prefix? (string-trim content) "{")
                      (hash-ref (string->jsexpr content) 'path "") content))
     (if (file-exists? path) (clip (file->string path)) (format "error: no such file: ~a" path)))

   "write_file"
   (lambda (content)
     (define-values (path body) (let ([i (string-index content #\newline)])
                                  (if i (values (substring content 0 i) (substring content (add1 i)))
                                      (values content ""))))
     (with-output-to-file path #:exists 'replace (lambda () (display body)))
     (format "wrote ~a bytes to ~a" (string-length body) path))

   "ls"
   (lambda (content)
     (define path (let ([a (string->jsexpr content)]) (if (hash? a) (hash-ref a 'path ".") ".")))
     (if (directory-exists? path)
         (string-join (map path->string (directory-list path)) "\n")
         (format "error: not a directory: ~a" path)))))

(define (string-index s ch)
  (for/first ([c (in-string s)] [i (in-naturals)] #:when (char=? c ch)) i))

;; (make-exec [extra-handlers]) -> (tool-block -> string)
(define (make-exec #:handlers [handlers default-handlers])
  (lambda (tb)
    (define h (hash-ref handlers (tool-block-type tb) #f))
    (if h
        (with-handlers ([exn:fail? (lambda (e) (format "error: ~a" (exn-message e)))])
          (h (tool-block-content tb)))
        (format "tool '~a' not implemented in this adapter" (tool-block-type tb)))))
