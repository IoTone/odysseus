#lang racket/base

;; domain/notes.rkt — notes domain logic shared by the CLI and the HTTP server.
;;
;; This is the strangler-fig payoff: one serialization + list query, reused by
;; `cli/odysseus-notes.rkt` AND the `/api/notes` route in `server/main.rkt`. As
;; routes migrate off FastAPI, their logic lands here (db-kit-backed, no HTTP/CLI
;; assumptions) and both surfaces call it.

(require db
         json
         racket/string
         db-kit
         "util.rkt"
         "nl-datetime.rkt")        ; parse-due-for-user (NL → ISO)

(provide notes-cols note->jsexpr list-notes        ; CLI shape (Unix tool)
         note->web-jsexpr list-notes-web           ; HTTP shape (matches routes/note_routes.py)
         manage-notes)                             ; agent tool (ports do_manage_notes)

;; columns selected for serialization, in fixed order
(define notes-cols
  (string-append "id,title,content,items,note_type,color,label,pinned,archived,"
                 "due_date,source,created_at,updated_at"))

;; notes.items is a JSON-array TEXT column
(define (load-items raw)
  (cond
    [(or (sql-null? raw) (not (string? raw)) (string=? raw "")) '()]
    [else (with-handlers ([exn:fail? (lambda (_) '())])
            (define v (string->jsexpr raw))
            (if (list? v) v '()))]))

(define (note->jsexpr r)
  (hasheq 'id         (vector-ref r 0)
          'title      (sql-or-empty (vector-ref r 1))
          'content    (sql-or-empty (vector-ref r 2))
          'items      (load-items (vector-ref r 3))
          'note_type  (let ([v (vector-ref r 4)]) (if (sql-null? v) "note" v))
          'color      (sql-or-empty (vector-ref r 5))
          'label      (sql-or-empty (vector-ref r 6))
          'pinned     (sql->bool (vector-ref r 7))
          'archived   (sql->bool (vector-ref r 8))
          'due_date   (sql-or-empty (vector-ref r 9))
          'source     (let ([v (vector-ref r 10)]) (if (sql-null? v) "user" v))
          'created_at (sqlite-datetime->iso (vector-ref r 11))
          'updated_at (sqlite-datetime->iso (vector-ref r 12))))

;; List notes (jsexpr) given an open connection. Same filters/ordering as the UI.
(define (list-notes conn
                    #:archived? [archived? #f]
                    #:label [label #f]
                    #:pinned? [pinned? #f]
                    #:limit [limit 50])
  (define where
    (string-append
     (if archived? "" "WHERE archived = 0 ")
     (if label (string-append (if archived? "WHERE " "AND ") "label = ? ") "")
     (if pinned? (string-append (if (or archived? label) "AND " "WHERE ") "pinned = 1 ") "")))
  (define params (if label (list label) '()))
  (define sql (string-append "SELECT " notes-cols " FROM notes " where
                             "ORDER BY pinned DESC, sort_order ASC, updated_at DESC LIMIT ?"))
  (map note->jsexpr (apply query-rows conn sql (append params (list limit)))))

;; ---- HTTP shape: byte-compatible with routes/note_routes.py _note_to_dict ----
;; All Note columns; NULL -> json null (not ""); items/ai_classification parsed
;; (or null); timestamps isoformat-or-null; wrapped in {"notes": [...]}.

(define (parse-json-or-null raw)
  (cond [(or (sql-null? raw) (not (string? raw)) (string=? raw "")) 'null]
        [else (with-handlers ([exn:fail? (lambda (_) 'null)]) (string->jsexpr raw))]))
(define (dt-or-null v) (if (sql-null? v) 'null (sqlite-datetime->iso v)))

(define web-cols
  (string-append "id,owner,title,content,items,note_type,color,label,pinned,archived,"
                 "due_date,source,session_id,sort_order,image_url,repeat,ai_classification,"
                 "ai_content_hash,agent_session_id,created_at,updated_at"))

(define (note->web-jsexpr r)
  (hasheq 'id                (vector-ref r 0)
          'owner             (sql-or-null (vector-ref r 1))
          'title             (sql-or-null (vector-ref r 2))
          'content           (sql-or-null (vector-ref r 3))
          'items             (parse-json-or-null (vector-ref r 4))
          'note_type         (sql-or-null (vector-ref r 5))
          'color             (sql-or-null (vector-ref r 6))
          'label             (sql-or-null (vector-ref r 7))
          'pinned            (sql->bool (vector-ref r 8))
          'archived          (sql->bool (vector-ref r 9))
          'due_date          (sql-or-null (vector-ref r 10))
          'source            (sql-or-null (vector-ref r 11))
          'session_id        (sql-or-null (vector-ref r 12))
          'sort_order        (sql->int (vector-ref r 13))
          'image_url         (sql-or-null (vector-ref r 14))
          'repeat            (let ([v (vector-ref r 15)]) (if (or (sql-null? v) (equal? v "")) "none" v))
          'ai_classification (parse-json-or-null (vector-ref r 16))
          'ai_content_hash   (sql-or-null (vector-ref r 17))
          'agent_session_id  (sql-or-null (vector-ref r 18))
          'created_at        (dt-or-null (vector-ref r 19))
          'updated_at        (dt-or-null (vector-ref r 20))))

;; Mirrors list_notes: archived? #f → active (pin/sort/updated order); #t →
;; archived (updated_at desc). Optional label filter. owner filters owner==owner
;; when supplied (= the Python route's `if user is not None`); #f = no filter
;; (auth disabled). Identity comes from upstream as a trusted header — we do NOT
;; re-implement auth here (see PORTING_PLAN "auth as a trusted header").
(define (list-notes-web conn #:archived? [archived? #f] #:label [label #f] #:owner [owner #f])
  (define clauses (append (list (string-append "archived = " (if archived? "1" "0")))
                          (if owner '("owner = ?") '())
                          (if label '("label = ?") '())))
  (define params  (append (if owner (list owner) '()) (if label (list label) '())))
  (define order (if archived? "ORDER BY updated_at DESC"
                    "ORDER BY pinned DESC, sort_order ASC, updated_at DESC"))
  (define sql (string-append "SELECT " web-cols " FROM notes WHERE "
                             (string-join clauses " AND ") " " order))
  (hasheq 'notes (map note->web-jsexpr (apply query-rows conn sql params))))

;; ---- agent tool: manage_notes -----------------------------------------------
;; Port of src/tool_implementations.py do_manage_notes — CRUD on notes and
;; checklists driven by the model's JSON arguments. due_date is parsed through
;; parse-due-for-user (today/tomorrow/ISO…), matching Python; on a parse
;; failure it falls back to the raw value, exactly like Python's except branch.

;; Python: try: parse_due_for_user(raw) except Exception: raw
(define (parse-due raw)
  (with-handlers ([exn:fail? (lambda (_) raw)])
    (parse-due-for-user (format "~a" raw))))

(define (or-untitled t) (if (jtruthy t) t "(untitled)"))
(define (b->i v) (if (jtruthy v) 1 0))
(define (or-sql-null v) (if (eq? v #f) sql-null v))

;; lowercase, drop a leading "reminder:", collapse whitespace — for dedup compare
(define (norm-note-title value)
  (define t (string-downcase (string-trim (or value ""))))
  (regexp-replace* #px"\\s+" (regexp-replace #px"^\\s*reminder\\s*:\\s*" t "") " "))

(define action-aliases
  (hash "create" "add" "new" "add" "save" "add" "remind" "add"
        "remove" "delete" "remove_item" "toggle_item"))

;; _note_visible_to_owner (#f2a79aa): empty owner = single-user/auth-disabled
;; mode → visible; a real owner must match EXACTLY. Legacy null/empty-owner rows
;; are NOT shared with an authenticated account.
(define (note-visible-to-owner? note-owner owner)
  (or (not (jtruthy owner))
      (equal? (if (sql-null? note-owner) #f note-owner) owner)))

;; find a note by id prefix → vector #(id owner title items) or #f.
;; Port of _note_by_prefix + _note_visible_to_owner (#f2a79aa): the lookup query
;; itself is owner-scoped when an owner is set (so a prefix collision with
;; another account's note can't 404 the owner's own note, and null-owner rows
;; aren't returned). Returns 'forbidden if a row is found but not visible — the
;; same "Note not found" the callers map it to (unreachable once the query is
;; owner-scoped, kept as defense-in-depth, mirroring Python's two-step check).
(define (find-note conn note-id owner)
  (cond
    [(not (jtruthy note-id)) #f]
    [else
     (define r
       (if (jtruthy owner)
           (query-maybe-row conn
             "SELECT id, owner, title, items FROM notes WHERE id LIKE ? AND owner = ? LIMIT 1"
             (string-append note-id "%") owner)
           (query-maybe-row conn
             "SELECT id, owner, title, items FROM notes WHERE id LIKE ? LIMIT 1"
             (string-append note-id "%"))))
     (cond [(not r) #f]
           [(note-visible-to-owner? (vector-ref r 1) owner) r]
           [else 'forbidden])]))

(define (err msg) (hasheq 'error msg 'exit_code 1))

;; manage-notes : conn × JSON-args-string × #:owner → result jsexpr
(define (manage-notes conn content #:owner [owner #f])
  (define args (with-handlers ([exn:fail? (lambda (_) 'bad)])
                 (let ([v (string->jsexpr content)]) (if (hash? v) v (hasheq)))))
  (cond
    [(eq? args 'bad) (err "Invalid JSON arguments")]
    [else
     (define action0 (string-downcase (string-trim (string-replace (or (jget args 'action) "") "-" "_"))))
     (define action (hash-ref action-aliases action0 action0))
     (with-handlers ([exn:fail? (lambda (e) (err (exn-message e)))])
       (case action
         [("list")        (notes-tool-list conn args owner)]
         [("add")         (notes-tool-add conn args owner)]
         [("update")      (notes-tool-update conn args owner)]
         [("delete")      (notes-tool-delete conn args owner)]
         [("toggle_item") (notes-tool-toggle conn args owner)]
         [else (err (format "Unknown action: ~a. Use list/add/update/delete/toggle_item" action))]))]))

(define (notes-tool-list conn args owner)
  (define clauses (append '("archived = ?")
                          (if owner '("owner = ?") '())
                          (if (jtruthy (jget args 'label)) '("label = ?") '())))
  (define params (append (list (b->i (jget args 'archived)))
                         (if owner (list owner) '())
                         (if (jtruthy (jget args 'label)) (list (jget args 'label)) '())))
  (define rows (apply query-rows conn
                      (string-append "SELECT id, title, content, items, note_type, label, pinned"
                                     " FROM notes WHERE " (string-join clauses " AND ")
                                     " ORDER BY pinned DESC, updated_at DESC")
                      params))
  (cond
    [(null? rows) (hasheq 'response "No notes found." 'exit_code 0)]
    [else
     (define lines
       (for*/list ([r (in-list rows)]
                   [title (in-value (or-untitled (sql-or-empty (vector-ref r 1))))]
                   [checklist? (in-value (equal? (vector-ref r 4) "checklist"))]
                   [line (in-list
                          (cons (format "- [~a] **~a**~a~a~a"
                                        (id8 (vector-ref r 0)) title
                                        (if (sql->bool (vector-ref r 6)) " [PINNED]" "")
                                        (if checklist? " [checklist]" "")
                                        (let ([l (sql-or-empty (vector-ref r 5))])
                                          (if (jtruthy l) (format " #~a" l) "")))
                                (cond
                                  [(and checklist? (jtruthy (sql-or-empty (vector-ref r 3))))
                                   (for/list ([item (in-list (load-items (vector-ref r 3)))] [i (in-naturals)])
                                     (format "  [~a] ~a: ~a"
                                             (if (jtruthy (hash-ref item 'done #f)) "x" " ") i
                                             (hash-ref item 'text "")))]
                                  [(jtruthy (sql-or-empty (vector-ref r 2)))
                                   (define c (sql-or-empty (vector-ref r 2)))
                                   (list (format "  ~a" (string-replace (substring c 0 (min 80 (string-length c)))
                                                                        "\n" " ")))]
                                  [else '()])))])
         line))
     (hasheq 'results (string-join lines "\n"))]))

(define (notes-tool-add conn args owner)
  (define title0 (string-trim (or (jget args 'title) "")))
  (define content0 (jget args 'content))
  (define text-raw (let ([t (jget args 'text)]) (if (jtruthy t) t (jget args 'body))))
  (define-values (title content-raw)
    (cond [(and (not (jtruthy title0)) (not (jtruthy content0)) (jtruthy text-raw))
           (values (string-trim text-raw) content0)]
          [(and (not (jtruthy content0)) (jtruthy text-raw)) (values title0 text-raw)]
          [else (values title0 content0)]))
  (define items-raw (let ([ci (jget args 'checklist_items)]) (if (eq? ci #f) (jget args 'items) ci)))
  (define items-json (if (eq? items-raw #f) #f (jsexpr->string items-raw)))
  (define note-type (or (jget args 'note_type) (if (jtruthy items-raw) "checklist" "note")))
  (define due-iso (let ([d (jget args 'due_date)]) (and (jtruthy d) (parse-due d))))
  ;; duplicate-reminder check: same due_date + (normalized) same title → keep existing
  (define dup
    (and due-iso (jtruthy title)
         (let ([target (norm-note-title title)])
           (for/first ([r (in-list (apply query-rows conn
                            (string-append "SELECT id, title FROM notes WHERE archived = 0 AND due_date = ?"
                                           (if owner " AND owner = ?" "") " LIMIT 25")
                            (cons due-iso (if owner (list owner) '()))))]
                       #:when (equal? (norm-note-title (sql-or-empty (vector-ref r 1))) target))
             r))))
  (cond
    [dup
     (hasheq 'response (format "Reminder already exists: \"~a\" (id: ~a)"
                               (let ([t (sql-or-empty (vector-ref dup 1))]) (if (jtruthy t) t title))
                               (id8 (vector-ref dup 0)))
             'note_id (vector-ref dup 0) 'duplicate #t 'exit_code 0)]
    [else
     (define id (uuid4))
     (define now (now-stamp))
     (query-exec conn
       (string-append "INSERT INTO notes(id, owner, title, content, items, note_type, color, label,"
                      " pinned, archived, due_date, source, session_id, sort_order, repeat,"
                      " created_at, updated_at)"
                      " VALUES(?,?,?,?,?,?,?,?,?,0,?,'agent',?,0,'none',?,?)")
       id (or-sql-null owner) title (or-sql-null content-raw) (or-sql-null items-json) note-type
       (or-sql-null (jget args 'color)) (or-sql-null (jget args 'label))
       (b->i (jget args 'pinned)) (or-sql-null due-iso) (or-sql-null (jget args 'session_id))
       now now)
     (hasheq 'response (format "Note created: \"~a\" (id: ~a)" (or-untitled title) (id8 id))
             'note_id id 'note_title title
             'open_url (format "/#open=notes&note=~a" id) 'exit_code 0)]))

(define (notes-tool-update conn args owner)
  (define note-id (or (jget args 'id) ""))
  (define n (find-note conn note-id owner))
  (cond
    [(not n) (err (format "Note '~a' not found" note-id))]
    [(eq? n 'forbidden) (err "Note not found")]
    [else
     (define id (vector-ref n 0))
     ;; plain fields: set when the key is present with a non-null value
     (define field-sets
       (for/list ([f (in-list '(title content note_type color label))]
                  #:when (and (hash-has-key? args f) (not (eq? (hash-ref args f) 'null))))
         (cons (symbol->string f) (hash-ref args f))))
     (define due-sets (let ([d (jget args 'due_date)])
                        (if d (list (cons "due_date" (parse-due d))) '())))
     (define items-raw (let ([ci (jget args 'checklist_items)]) (if (eq? ci #f) (jget args 'items) ci)))
     (define items-sets (if (eq? items-raw #f) '() (list (cons "items" (jsexpr->string items-raw)))))
     (define flag-sets
       (for/list ([f (in-list '(pinned archived))] #:when (hash-has-key? args f))
         (cons (symbol->string f) (b->i (jget args f)))))
     (define sets (append field-sets due-sets items-sets flag-sets
                          (list (cons "updated_at" (now-stamp)))))
     (apply query-exec conn
            (string-append "UPDATE notes SET "
                           (string-join (for/list ([s (in-list sets)]) (string-append (car s) " = ?")) ", ")
                           " WHERE id = ?")
            (append (map cdr sets) (list id)))
     (define final-title (cond [(assoc "title" field-sets) => cdr]
                               [else (sql-or-empty (vector-ref n 2))]))
     (hasheq 'response (format "Note updated: \"~a\"" (or-untitled final-title)) 'exit_code 0)]))

(define (notes-tool-delete conn args owner)
  (define note-id (or (jget args 'id) ""))
  (define n (find-note conn note-id owner))
  (cond
    [(not n) (err (format "Note '~a' not found" note-id))]
    [(eq? n 'forbidden) (err "Note not found")]
    [else
     (query-exec conn "DELETE FROM notes WHERE id = ?" (vector-ref n 0))
     (hasheq 'response (format "Deleted note: \"~a\"" (or-untitled (sql-or-empty (vector-ref n 2))))
             'exit_code 0)]))

;; Python does `index = args.get("index", 0)` then `index < 0` — a string index
;; raises TypeError and surfaces as an error (the model retries). We don't
;; silently default a bad index to 0 (that would toggle the wrong item); we
;; accept a real int or a numeric string and reject anything else.
(define (toggle-index args)
  (define i (jget args 'index))
  (cond [(eq? i #f) 0]                                  ; missing/null → Python default 0
        [(exact-integer? i) i]
        [(and (number? i) (integer? i)) (inexact->exact i)]
        [(and (string? i) (let ([n (string->number (string-trim i))])
                            (and n (exact-integer? n) n))) => values]
        [else 'bad]))

(define (notes-tool-toggle conn args owner)
  (define note-id (or (jget args 'id) ""))
  (define index (toggle-index args))
  (define n (find-note conn note-id owner))
  (cond
    [(eq? index 'bad) (err (format "Invalid item index: ~a" (jget args 'index)))]
    [(not n) (err (format "Note '~a' not found" note-id))]
    [(eq? n 'forbidden) (err "Note not found")]
    [(not (jtruthy (sql-or-empty (vector-ref n 3)))) (err "Note has no checklist items")]
    [else
     (define items (load-items (vector-ref n 3)))
     (cond
       [(or (< index 0) (>= index (length items)))
        (err (format "Item index ~a out of range (0-~a)" index (sub1 (length items))))]
       [else
        (define cur (list-ref items index))
        (define now-done (not (jtruthy (hash-ref cur 'done #f))))
        (define new-items (for/list ([it (in-list items)] [i (in-naturals)])
                            (if (= i index) (hash-set it 'done now-done) it)))
        (query-exec conn "UPDATE notes SET items = ?, updated_at = ? WHERE id = ?"
                    (jsexpr->string new-items) (now-stamp) (vector-ref n 0))
        (hasheq 'response (format "Item '~a' marked ~a" (hash-ref cur 'text "")
                                  (if now-done "done" "undone"))
                'exit_code 0)])]))

;; result rendering lives in domain/tools/result.rkt (tool-result->text),
;; shared by all DB-backed tool handlers.
