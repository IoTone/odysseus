#lang racket/base

;; domain/documents.rkt — the manage_documents agent tool: list / read / delete
;; (soft) over the documents table. Port of do_manage_documents.
;;
;; Ownership is STRICT here (unlike notes/tasks): Python's
;; _owned_document_query filters to zero rows when owner is None, so the agent
;; must be invoked with an identity (odysseus-agent --owner …) to see any
;; documents. That mirrors the app's trusted-header identity model.
;;
;; `tidy` is an LLM-orchestrated action (src/document_actions.py) with no
;; offline path — it returns an actionable error here.

(require db
         json
         racket/string
         racket/date          ; find-seconds
         "util.rkt"
         db-kit)

(provide manage-documents rel-time)

(define MAX-READ-CHARS 20000)   ; src/constants.py MAX_READ_CHARS

(define (err msg) (hasheq 'error msg 'exit_code 1))

;; "YYYY-MM-DD HH:MM:SS[.ffffff]" (naive UTC) → seconds, or #f
(define (stamp->seconds s)
  (define m (and (string? s)
                 (regexp-match #px"^(\\d{4})-(\\d{2})-(\\d{2})[ T](\\d{2}):(\\d{2}):(\\d{2})" s)))
  (and m (let ([n (map string->number (cdr m))])
           (find-seconds (list-ref n 5) (list-ref n 4) (list-ref n 3)
                         (list-ref n 2) (list-ref n 1) (list-ref n 0) #f))))

;; port of _rel: relative "updated Xm ago" labels. #:now injectable for tests.
(define (rel-time ts #:now [now (current-seconds)])
  (cond
    [(not (jtruthy ts)) "never"]
    [else
     (define s (stamp->seconds (if (sql-null? ts) #f ts)))
     (cond
       [(not s) "unknown"]
       [else
        (define diff (- now s))
        (cond [(< diff 60) "just now"]
              [(< diff 3600) (format "~am ago" (quotient diff 60))]
              [(< diff 86400) (format "~ah ago" (quotient diff 3600))]
              [(< diff (* 86400 7)) (format "~ad ago" (quotient diff 86400))]
              [else (substring (if (sql-null? ts) "" ts) 0 10)])])]))   ; YYYY-MM-DD

(define (col v) (if (sql-null? v) #f v))

;; owner-scoped exact-id fetch → row #(id title language current_content updated_at) or #f
(define (find-doc conn doc-id owner #:active-only? [active-only? #f])
  (and owner
       (query-maybe-row conn
         (string-append "SELECT id, title, language, current_content, updated_at FROM documents"
                        " WHERE id = ? AND owner = ?"
                        (if active-only? " AND is_active = 1" ""))
         doc-id owner)))

(define (manage-documents conn content #:owner [owner #f] #:now [now (current-seconds)])
  (define args (with-handlers ([exn:fail? (lambda (_) 'bad)])
                 (let ([v (string->jsexpr content)]) (if (hash? v) v (hasheq)))))
  (cond
    [(eq? args 'bad) (err "Invalid JSON arguments")]
    [else
     (define action (or (jget args 'action) "list"))
     (with-handlers ([exn:fail? (lambda (e) (err (exn-message e)))])
       (case action
         [("list")
          (define search (jget args 'search))
          (define language (jget args 'language))
          (define lim (let ([l (jget args 'limit)]) (if (number? l) l 50)))
          ;; owner=None filters to zero rows in Python — same here
          (define rows
            (if owner
                (apply query-rows conn
                  (string-append "SELECT id, title, language, current_content, updated_at, created_at"
                                 " FROM documents WHERE is_active = 1 AND owner = ?"
                                 (if (jtruthy search) " AND title LIKE ?" "")
                                 (if (jtruthy language) " AND language = ?" "")
                                 " ORDER BY updated_at DESC LIMIT ?")
                  (append (list owner)
                          (if (jtruthy search) (list (string-append "%" search "%")) '())
                          (if (jtruthy language) (list language) '())
                          (list lim)))
                '()))
          (cond
            [(null? rows)
             (hasheq 'response (format "No documents found~a."
                                       (if (jtruthy search) (format " matching '~a'" search) ""))
                     'documents '() 'exit_code 0)]
            [else
             (define-values (lines items)
               (for/lists (ls is)
                          ([r (in-list rows)] [i (in-naturals)])
                 (define size (string-length (or (col (vector-ref r 3)) "")))
                 (define lang (or (col (vector-ref r 2)) "text"))
                 (define ts (or (col (vector-ref r 4)) (col (vector-ref r 5))))
                 (values
                  (format "- [~a](#document-~a) — ~a, ~a chars, updated ~a~a"
                          (col (vector-ref r 1)) (vector-ref r 0) lang size
                          (rel-time ts #:now now) (if (zero? i) " ← most recent" ""))
                  (hasheq 'id (vector-ref r 0) 'title (col (vector-ref r 1))
                          'language lang 'size size))))
             (hasheq 'response
                     (string-append
                      (format "Found ~a document(s), sorted most-recent first. Click a title to open:"
                              (length rows))
                      "\n" (string-join lines "\n"))
                     'documents items 'exit_code 0)])]
         [("read" "view" "open" "get")
          (define doc-id (or (jget args 'document_id) (jget args 'id) (jget args 'uid)))
          (cond
            [(not (jtruthy doc-id)) (err "Need document_id (use action=list to find one)")]
            [else
             (define r (find-doc conn doc-id owner #:active-only? #t))
             (cond
               [(not r) (err (format "Document '~a' not found" doc-id))]
               [else
                (define body (or (col (vector-ref r 3)) ""))
                (define blen (string-length body))
                ;; #4784: paginate via offset/limit; limit clamped to [1, MAX],
                ;; offset clamped to [0, len]. next_offset lets the model page on.
                (define (as-int v dflt)
                  (cond [(number? v) (inexact->exact (truncate v))]
                        [(and (string? v) (string->number v))
                         => (lambda (n) (inexact->exact (truncate n)))]
                        [else dflt]))
                (define lim (max 1 (min (as-int (jget args 'limit) MAX-READ-CHARS) MAX-READ-CHARS)))
                (define offset (min (max 0 (as-int (jget args 'offset) 0)) blen))
                (define end (min (+ offset lim) blen))
                (define truncated? (< end blen))
                (define preview
                  (string-append (substring body offset end)
                                 (if truncated?
                                     (format "\n... (truncated, ~a chars total; next_offset=~a)" blen end)
                                     "")))
                (hasheq 'response (format "[~a](#document-~a) — click to open in editor.\n\n```~a\n~a\n```"
                                          (col (vector-ref r 1)) (vector-ref r 0)
                                          (or (col (vector-ref r 2)) "") preview)
                        'document (hasheq 'id (vector-ref r 0) 'title (col (vector-ref r 1))
                                          'language (sql-or-null (vector-ref r 2))
                                          'size blen 'content preview
                                          'truncated truncated?
                                          'offset offset
                                          'next_offset (if truncated? end 'null))
                        'exit_code 0)])])]
         [("delete")
          (define doc-id (or (jget args 'document_id) (jget args 'id) (jget args 'uid)))
          ;; exact id, else most-recent active owned doc (Python's fallback)
          (define r
            (or (and (jtruthy doc-id) (find-doc conn doc-id owner))
                (and owner
                     (query-maybe-row conn
                       (string-append "SELECT id, title, language, current_content, updated_at"
                                      " FROM documents WHERE is_active = 1 AND owner = ?"
                                      " ORDER BY updated_at DESC LIMIT 1")
                       owner))))
          (cond
            [(not r) (err "No document to delete")]
            [else
             (query-exec conn "UPDATE documents SET is_active = 0, updated_at = ? WHERE id = ?"
                         (now-stamp) (vector-ref r 0))
             (hasheq 'response (format "Deleted document '~a'" (col (vector-ref r 1))) 'exit_code 0)])]
         [("tidy")
          (err "Document tidy is LLM-orchestrated (src/document_actions.py) and needs the Python runtime")]
         [else (err (format "Unknown action: ~a" action))]))]))
