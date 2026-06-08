#lang racket/base

;; odysseus-preset — AI system-prompt presets stored in data/presets.json.
;; Faithful Racket port of scripts/odysseus-preset (pure JSON CRUD, no DB/HTTP).
;;
;;   odysseus-preset list
;;   odysseus-preset get NAME
;;   odysseus-preset set NAME --temperature 0.7 --prompt "You are..."
;;   odysseus-preset set NAME --prompt-file ./prompt.md
;;   odysseus-preset delete NAME

(require json
         racket/file
         racket/list
         racket/string
         "common.rkt")

(define (presets-path) (build-path (data-dir) "presets.json"))

;; ---- load / save -----------------------------------------------------------

(define (load-presets)
  (define p (presets-path))
  (cond
    [(not (file-exists? p)) (hasheq)]
    [else
     (define data
       (with-handlers ([exn:fail? (lambda (e) (fail (format "presets.json corrupt: ~a" (exn-message e))))])
         (string->jsexpr (file->string p))))
     (unless (hash? data) (fail "presets.json corrupt: expected an object"))
     data]))

(define (save-presets data)
  (define p (presets-path))
  (make-directory* (data-dir))
  ;; backup, then atomic tmp + rename (same pattern as the Python tool).
  (when (file-exists? p)
    (with-handlers ([exn:fail? void])
      (copy-file p (path-add-extension p #".bak" #".") #t)))
  (define tmp (path-add-extension p #".tmp" #"."))
  (call-with-output-file tmp #:exists 'replace
    (lambda (out) (write-string (jsexpr->pretty-string data) out)))
  (rename-file-or-directory tmp p #t))

(define (entry-or-fail presets name)
  (define key (string->symbol name))
  (unless (hash-has-key? presets key) (fail (format "no preset named ~s" name)))
  (define entry (hash-ref presets key))
  (unless (hash? entry) (fail (format "preset ~s is corrupt: expected an object" name)))
  entry)

;; ---- subcommands -----------------------------------------------------------

(define (cmd-list pretty?)
  (define presets (load-presets))
  (define rows
    (for/list ([key (in-list (sort (map symbol->string (hash-keys presets)) string<?))]
               #:when (hash? (hash-ref presets (string->symbol key))))
      (define val (hash-ref presets (string->symbol key)))
      (hasheq 'id key
              'name (let ([n (hash-ref val 'name #f)]) (if (and n (not (eq? n 'null))) n key))
              'temperature (hash-ref val 'temperature 'null)
              'prompt_length (string-length (let ([p (hash-ref val 'system_prompt #f)])
                                              (if (string? p) p ""))))))
  (emit rows #:pretty? pretty?))

(define (cmd-get name pretty?)
  (define presets (load-presets))
  (define entry (entry-or-fail presets name))
  (emit (hash-set entry 'id name) #:pretty? pretty?))

(define (cmd-set name prompt prompt-file temperature display-name pretty?)
  (define final-prompt
    (cond [prompt-file (file->string prompt-file)]
          [else prompt]))
  (when (and (not final-prompt) (not temperature))
    (fail "nothing to set — pass --prompt, --prompt-file, or --temperature"))
  (define presets (load-presets))
  (define current (hash-ref presets (string->symbol name) #f))
  (define base (if (hash? current) current (hasheq)))
  (define e1 (if (hash-has-key? base 'name) base (hash-set base 'name name)))
  (define e2 (if final-prompt (hash-set e1 'system_prompt final-prompt) e1))
  (define e3 (if temperature (hash-set e2 'temperature temperature) e2))
  (define entry (if display-name (hash-set e3 'name display-name) e3))
  (define updated (hash-set presets (string->symbol name) entry))
  (save-presets updated)
  (emit (hasheq 'ok #t 'id name 'entry entry) #:pretty? pretty?))

(define (cmd-delete name pretty?)
  (define presets (load-presets))
  (define snap (entry-or-fail presets name))
  (save-presets (hash-remove presets (string->symbol name)))
  (emit (hasheq 'ok #t 'deleted (hash-set snap 'id name)) #:pretty? pretty?))

;; ---- arg parsing -----------------------------------------------------------

(define (next xs flag)
  (when (null? (cdr xs)) (fail (format "expected a value after ~a" flag) #:code 2))
  (cadr xs))

(define (parse-set cargs)
  (when (null? cargs) (fail "set needs a NAME" #:code 2))
  (let loop ([xs (cdr cargs)] [prompt #f] [prompt-file #f] [temp #f] [disp #f])
    (cond
      [(null? xs) (values (car cargs) prompt prompt-file temp disp)]
      [(string=? (car xs) "--prompt")      (loop (cddr xs) (next xs "--prompt") prompt-file temp disp)]
      [(string=? (car xs) "--prompt-file") (loop (cddr xs) prompt (next xs "--prompt-file") temp disp)]
      [(string=? (car xs) "--temperature")
       (define n (string->number (next xs "--temperature")))
       (unless (real? n) (fail "--temperature wants a number" #:code 2))
       (loop (cddr xs) prompt prompt-file n disp)]
      [(string=? (car xs) "--display-name") (loop (cddr xs) prompt prompt-file temp (next xs "--display-name"))]
      [else (fail (format "unexpected argument: ~a" (car xs)) #:code 2)])))

(define (dispatch)
  (define args (vector->list (current-command-line-arguments)))
  (define pretty? (pretty-from-args? args))
  (define rest (filter (lambda (a) (not (string=? a "--pretty"))) args))
  (when (null? rest) (fail "missing subcommand: list|get|set|delete" #:code 2))
  (define cmd (car rest))
  (define cargs (cdr rest))
  (case cmd
    [("list") (cmd-list pretty?)]
    [("get")  (when (null? cargs) (fail "get needs a NAME" #:code 2)) (cmd-get (car cargs) pretty?)]
    [("set")  (define-values (n p pf t d) (parse-set cargs)) (cmd-set n p pf t d pretty?)]
    [("delete") (when (null? cargs) (fail "delete needs a NAME" #:code 2)) (cmd-delete (car cargs) pretty?)]
    [else (fail (format "unknown subcommand: ~a" cmd) #:code 2)]))

(module+ main
  (run "odysseus-preset" dispatch))
