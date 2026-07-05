#lang racket/base

;; odysseus-research — inspect deep-research sessions stored as JSON blobs in
;; data/deep_research/<id>.json. Faithful Racket port of scripts/odysseus-research
;; (filesystem-only; new runs require the streaming endpoint, not exposed here).
;;
;;   odysseus-research list [--limit N] [--status complete|running|cancelled|error]
;;   odysseus-research show RP_ID
;;   odysseus-research report RP_ID [--raw]
;;   odysseus-research search "text"
;;   odysseus-research delete RP_ID

(require json
         racket/file
         racket/list
         racket/path
         racket/string
         cli-kit
         "../config.rkt")

(define (research-dir) (build-path (data-dir) "deep_research"))

;; CLI --status uses friendly "complete"; the writer stores "done".
(define (status-matches? stored requested)
  (define s (if (string? stored) stored ""))
  (define target (if (string=? requested "complete") "done" requested))
  (string=? s target))

(define (load-path p)
  (with-handlers ([exn:fail? (lambda (_) #f)])
    (define v (string->jsexpr (file->string p)))
    (and (hash? v) v)))

(define (load-id id)
  (define p (build-path (research-dir) (string-append id ".json")))
  (and (file-exists? p) (load-path p)))

(define (preview v) (let ([s (if (string? v) v "")])
                      (if (> (string-length s) 200) (substring s 0 200) s)))
(define (get* data key) (let ([v (hash-ref data key "")]) (if (eq? v 'null) "" v)))

(define (summarize id data)
  (define srcs (hash-ref data 'sources '()))
  (define stats (hash-ref data 'stats (hasheq)))
  (hasheq 'id           id
          'query        (preview (hash-ref data 'query ""))
          'category     (get* data 'category)
          'status       (get* data 'status)
          'started_at   (get* data 'started_at)
          'completed_at (get* data 'completed_at)
          'sources      (if (list? srcs) (length srcs) 0)
          'stats        (if (hash? stats) stats (hasheq))))

(define (all-json)
  (define d (research-dir))
  (if (directory-exists? d)
      (filter (lambda (p) (regexp-match? #rx"\\.json$" (path->string p)))
              (directory-list d #:build? #t))
      '()))

(define (rp-id p) (regexp-replace #rx"\\.json$" (path->string (file-name-from-path p)) ""))

(define (by-started-desc rows)
  (sort rows string>? #:key (lambda (r) (let ([v (hash-ref r 'started_at "")])
                                          (if (string? v) v "")))))

;; ---- subcommands -----------------------------------------------------------

(define (cmd-list status limit pretty?)
  (define rows
    (for/list ([p (in-list (sort (all-json) path<?))]
               #:when (load-path p)
               #:when (let ([d (load-path p)])
                        (or (not status) (status-matches? (hash-ref d 'status "") status))))
      (summarize (rp-id p) (load-path p))))
  (emit (take* (by-started-desc rows) limit) #:pretty? pretty?))

(define (cmd-show id pretty?)
  (define d (load-id id))
  (unless d (fail (format "no research session ~s" id)))
  (emit d #:pretty? pretty?))

(define (cmd-report id raw? pretty?)
  (define d (load-id id))
  (unless d (fail (format "no research session ~s" id)))
  (define report (let ([r (hash-ref d 'result #f)])
                   (cond [(and r (not (eq? r 'null)) (string? r)) r]
                         [else (let ([rr (hash-ref d 'raw_report "")]) (if (string? rr) rr ""))])))
  (cond
    [raw?
     (display report)
     (unless (and (> (string-length report) 0)
                  (char=? (string-ref report (sub1 (string-length report))) #\newline))
       (newline))]
    [else
     (emit (hasheq 'id id
                   'query (get* d 'query)
                   'report report
                   'sources (let ([s (hash-ref d 'sources '())]) (if (list? s) s '())))
           #:pretty? pretty?)]))

(define (cmd-search query limit pretty?)
  (define q (string-downcase query))
  (define rows
    (for/list ([p (in-list (all-json))]
               #:when (load-path p)
               #:when (let* ([d (load-path p)]
                             [hay (string-downcase
                                   (string-join (list (lc (hash-ref d 'query ""))
                                                      (lc (hash-ref d 'result ""))
                                                      (lc (hash-ref d 'category ""))) " "))])
                        (string-contains? hay q)))
      (summarize (rp-id p) (load-path p))))
  (emit (take* (by-started-desc rows) limit) #:pretty? pretty?))

(define (lc v) (if (string? v) v ""))

(define (cmd-delete id pretty?)
  (define p (build-path (research-dir) (string-append id ".json")))
  (unless (file-exists? p) (fail (format "no research session ~s" id)))
  (define snap (summarize id (or (load-id id) (hasheq))))
  (delete-file p)
  (emit (hasheq 'ok #t 'deleted snap) #:pretty? pretty?))

(define (take* lst n) (if (> (length lst) n) (take lst n) lst))

;; ---- arg parsing -----------------------------------------------------------
(define (opt args flag)
  (let loop ([xs args]) (cond [(null? xs) #f]
                              [(and (string=? (car xs) flag) (pair? (cdr xs))) (cadr xs)]
                              [else (loop (cdr xs))])))
(define (int-opt args flag d) (define v (opt args flag)) (if v (or (string->number v) d) d))

(define (dispatch)
  (define args (vector->list (current-command-line-arguments)))
  (define pretty? (pretty-from-args? args))
  (define rest (filter (lambda (a) (not (string=? a "--pretty"))) args))
  (when (null? rest) (fail "missing subcommand: list|show|report|search|delete" #:code 2))
  (define cmd (car rest)) (define a (cdr rest))
  (case cmd
    [("list") (cmd-list (opt a "--status") (int-opt a "--limit" 50) pretty?)]
    [("show") (when (null? a) (fail "show needs an RP_ID" #:code 2)) (cmd-show (car a) pretty?)]
    [("report") (when (null? a) (fail "report needs an RP_ID" #:code 2))
                (cmd-report (car a) (and (member "--raw" a) #t) pretty?)]
    [("search") (when (null? a) (fail "search needs a query" #:code 2))
                (cmd-search (car a) (int-opt a "--limit" 50) pretty?)]
    [("delete") (when (null? a) (fail "delete needs an RP_ID" #:code 2)) (cmd-delete (car a) pretty?)]
    [else (fail (format "unknown subcommand: ~a" cmd) #:code 2)]))

(module+ main
  (run "odysseus-research" app-version dispatch))
