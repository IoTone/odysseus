#lang racket/base

;; domain/skills.rkt — skills storage + the manage_skills agent tool.
;; Ports the slice of services/memory/skills.py (SkillsManager) that
;; do_manage_skills uses, plus do_manage_skills itself.
;;
;; Layout on disk (same as Python): <data-dir>/skills/<category>/<name>/SKILL.md
;; with usage counters in <data-dir>/skills/_usage.json (sidecar, keyed
;; "owner::name" when owned). Legacy data/skills.json entries surface
;; read-only, exactly like Python.
;;
;; Not ported (not reachable from the tool): set_audit/set_necessity,
;; backfill_owner, import_bundle_from_files, index_for. The Python
;; fire_event("skill_added") goes to the live event bus — its failure path is
;; a silent no-op, which is this CLI's behavior too.

(require racket/string
         racket/list
         racket/file
         racket/path          ; file-name-from-path, path-only
         racket/set
         json
         "util.rkt"
         "skill-format.rkt")

(provide make-skills-manager manage-skills
         skills-load skills-add skills-update skills-delete
         skills-read-md skills-read-reference skills-relevant)

;; a manager is just the resolved paths
(struct skman (root usage-file legacy-file) #:transparent)

(define (make-skills-manager data-dir)
  (define root (build-path data-dir "skills"))
  (make-directory* root)
  (skman root (build-path root "_usage.json") (build-path data-dir "skills.json")))

;; ---- token / similarity helpers ------------------------------------------------
(define (tokenize text)
  (for/set ([w (in-list (string-split (string-downcase (or text "")) ))]
            #:when (> (string-length w) 1))
    (string-trim w #px"[.,!?\";:()\\[\\]]+")))

(define (jaccard a b)
  (if (or (set-empty? a) (set-empty? b))
      0.0
      (/ (exact->inexact (set-count (set-intersect a b))) (set-count (set-union a b)))))

(define (to-float x [default 0.0])
  (cond [(number? x) (exact->inexact x)]
        [(and (string? x) (string->number x)) => exact->inexact]
        [else default]))

;; ---- usage sidecar --------------------------------------------------------------
(define (load-usage m)
  (with-handlers ([exn:fail? (lambda (_) (hasheq))])
    (let ([v (string->jsexpr (file->string (skman-usage-file m)))])
      (if (hash? v) v (hasheq)))))

(define (save-usage m usage)
  (define tmp (string-append (path->string (skman-usage-file m)) ".tmp"))
  (call-with-output-file tmp #:exists 'replace (lambda (out) (write-json usage out)))
  (rename-file-or-directory tmp (skman-usage-file m) #t))

(define (usage-key name owner)
  (string->symbol (if (jtruthy owner) (format "~a::~a" owner name) name)))

(define (record-use! m name owner)
  (define usage (load-usage m))
  (define k (usage-key name owner))
  (define e (let ([v (hash-ref usage k #f)]) (if (hash? v) v (hasheq 'uses 0 'last_used 'null))))
  (save-usage m (hash-set usage k (hash-set* e 'uses (add1 (let ([u (hash-ref e 'uses 0)])
                                                             (if (number? u) u 0)))
                                             'last_used (current-seconds)))))

;; ---- disk scan -------------------------------------------------------------------
(define (iter-skill-files m)
  (if (directory-exists? (skman-root m))
      (find-files (lambda (p) (and (file-exists? p)
                                   (equal? (path->string (file-name-from-path p)) "SKILL.md")))
                  (skman-root m))
      '()))

(define (read-skill path)
  (with-handlers ([exn:fail? (lambda (_) #f)])
    (skill-from-markdown (file->string path) #:path (path->string path))))

(define (skill-file m category name)
  (build-path (skman-root m) (slugify (if (jtruthy category) category "general") "general")
              (slugify name "skill") "SKILL.md"))

(define (write-skill! m sk)
  (define path (skill-file m (hash-ref sk 'category "general") (hash-ref sk 'name)))
  (make-parent-directory* path)
  (define tmp (string-append (path->string path) ".tmp"))
  (call-with-output-file tmp #:exists 'replace
    (lambda (out) (display (skill->markdown sk) out)))
  (rename-file-or-directory tmp path #t)
  (hash-set sk 'path (path->string path)))

;; ---- load (with usage merge + legacy JSON fallback) ------------------------------
(define (skills-load-all m)
  (define usage (load-usage m))
  (define disk
    (for*/list ([path (in-list (iter-skill-files m))]
                [sk (in-value (read-skill path))] #:when sk)
      (define u (let ([v (hash-ref usage (usage-key (hash-ref sk 'name) (hash-ref sk 'owner)) #f)])
                  (if (hash? v) v (hasheq))))
      (hash-set* (skill->dict sk)
                 'uses (let ([x (hash-ref u 'uses 0)]) (if (number? x) x 0))
                 'last_used (hash-ref u 'last_used 'null)
                 'audit_verdict (hash-ref u 'audit_verdict 'null)
                 'audit_by_teacher (jtruthy (hash-ref u 'audit_by_teacher #f))
                 'audit_worker_model (hash-ref u 'audit_worker_model 'null)
                 'audit_teacher_model (hash-ref u 'audit_teacher_model 'null)
                 'audited_at (hash-ref u 'audited_at 'null)
                 'necessity (hash-ref u 'necessity 'null))))
  (define seen (for/set ([s (in-list disk)]) (hash-ref s 'name)))
  (define legacy
    (with-handlers ([exn:fail? (lambda (_) '())])
      (if (file-exists? (skman-legacy-file m))
          (let ([rows (string->jsexpr (file->string (skman-legacy-file m)))])
            (for*/list ([row (in-list (if (list? rows) rows '()))] #:when (hash? row)
                        [name (in-value (slugify (let ([t (jget row 'title)] [i (jget row 'id)])
                                                   (or t i "skill"))))]
                        #:unless (set-member? seen name))
              (hasheq 'id (or (jget row 'id) name) 'name name
                      'description (hash-ref row 'title "") 'version "0.0.1"
                      'category "legacy" 'tags (or (jget row 'tags) '())
                      'status (or (jget row 'status) "draft")
                      'confidence (hash-ref row 'confidence 0.5)
                      'source (hash-ref row 'source "imported")
                      'owner (hash-ref row 'owner 'null)
                      'when_to_use (hash-ref row 'problem "")
                      'procedure (or (jget row 'steps) '()) 'pitfalls '() 'verification '()
                      'body_extra (hash-ref row 'solution "")
                      'title (hash-ref row 'title "") 'problem (hash-ref row 'problem "")
                      'solution (hash-ref row 'solution "") 'steps (or (jget row 'steps) '())
                      'uses (hash-ref row 'uses 0) 'last_used (hash-ref row 'last_used 'null)
                      '_legacy #t)))
          '())))
  (append disk legacy))

;; strict owner filter (owner #f = unscoped, sees everything — Python None)
(define (skills-load m #:owner [owner #f])
  (define all (skills-load-all m))
  (if owner
      (filter (lambda (s) (equal? (let ([o (hash-ref s 'owner #f)]) (if (eq? o 'null) #f o)) owner))
              all)
      all))

;; ---- CRUD ------------------------------------------------------------------------

(define (dedup-text-of-dict s)
  (string-join (list (hash-ref s 'name "") (hash-ref s 'description "")
                     (hash-ref s 'when_to_use "")
                     (string-join (map (lambda (x) (format "~a" x))
                                       (or (jget s 'procedure) '())) " "))
               " "))

;; → skill dict; carries '_deduped #t when a near-identical skill already existed
(define (skills-add m
                    #:name [name #f] #:title [title ""] #:description [description #f]
                    #:category [category "general"] #:tags [tags '()]
                    #:platforms [platforms '()] #:requires-toolsets [requires-toolsets '()]
                    #:fallback-for-toolsets [fallback-for-toolsets '()]
                    #:when-to-use [when-to-use #f] #:problem [problem ""]
                    #:procedure [procedure #f] #:steps [steps '()]
                    #:pitfalls [pitfalls '()] #:verification [verification '()]
                    #:status [status "draft"] #:version [version "1.0.0"]
                    #:confidence [confidence 0.8] #:source [source "learned"]
                    #:teacher-model [teacher-model #f] #:solution [solution ""]
                    #:owner [owner #f])
  (define nm0 (slugify (or (and (jtruthy name) name) (and (jtruthy title) title)
                           (and (jtruthy description) description) "skill")))
  (define all (skills-load-all m))
  (define pool (if owner
                   (filter (lambda (s) (equal? (let ([o (hash-ref s 'owner #f)])
                                                 (if (eq? o 'null) #f o)) owner)) all)
                   all))
  (define wtu (if (eq? when-to-use #f) (or problem "") when-to-use))
  (define proc (if (eq? procedure #f) (or steps '()) procedure))
  (define dup
    (and (not (equal? source "user"))
         (let ([cand (tokenize (string-join (list nm0 (or description title "")
                                                  wtu (string-join (map (lambda (x) (format "~a" x)) proc) " "))
                                            " "))])
           (and (not (set-empty? cand))
                (for/first ([s (in-list pool)]
                            #:when (>= (jaccard cand (tokenize (dedup-text-of-dict s))) 0.82))
                  s)))))
  (cond
    [dup
     (with-handlers ([exn:fail? void])
       (record-use! m (hash-ref dup 'name) (let ([o (hash-ref dup 'owner #f)])
                                             (if (eq? o 'null) #f o))))
     (hash-set* dup '_deduped #t '_duplicate_of (hash-ref dup 'name))]
    [else
     ;; unique name: -2, -3, …
     (define existing (for/set ([s (in-list all)]) (hash-ref s 'name)))
     (define nm (let loop ([cand nm0] [i 2])
                  (if (set-member? existing cand) (loop (format "~a-~a" nm0 i) (add1 i)) cand)))
     (define sk
       (make-skill #:name nm
                   #:description (string-trim (or description title ""))
                   #:version version #:category (if (jtruthy category) category "general")
                   #:tags tags #:platforms platforms
                   #:requires-toolsets requires-toolsets
                   #:fallback-for-toolsets fallback-for-toolsets
                   #:status (if (jtruthy status) status "draft")
                   #:confidence (to-float confidence 0.8) #:source source
                   #:teacher-model teacher-model #:owner owner
                   #:created (skill-now-iso)
                   #:when-to-use wtu #:procedure proc
                   #:pitfalls pitfalls #:verification verification
                   #:body-extra (if (and (jtruthy solution) (not (and procedure (pair? procedure))))
                                    solution "")))
     (skill->dict (write-skill! m sk))]))

;; find the on-disk skill matching name + owner ("" and #f are both ownerless)
(define (find-skill m name owner)
  (for/first ([path (in-list (iter-skill-files m))]
              #:when (let ([sk (read-skill path)])
                       (and sk (equal? (hash-ref sk 'name) name)
                            (equal? (or (hash-ref sk 'owner #f) "") (or owner "")))))
    (cons path (read-skill path))))

(define update-scalar-keys '(description version category status confidence source
                             teacher_model when_to_use body_extra))
(define update-list-keys '(tags procedure pitfalls verification platforms
                           requires_toolsets fallback_for_toolsets))

(define (skills-update m name updates #:owner [owner #f])
  (define hit (find-skill m name owner))
  (cond
    [(not hit) #f]
    [else
     (define path (car hit))
     (define old-dir (path-only path))
     (define sk0 (cdr hit))
     (define sk1 (for/fold ([sk sk0]) ([k (in-list update-scalar-keys)])
                   (if (hash-has-key? updates k) (hash-set sk k (hash-ref updates k)) sk)))
     (define sk2 (for/fold ([sk sk1]) ([k (in-list update-list-keys)])
                   (if (hash-has-key? updates k)
                       (hash-set sk k (or (jget updates k) '()))
                       sk)))
     ;; old-schema aliases
     (define sk3
       (let* ([sk (if (and (hash-has-key? updates 'title) (not (hash-has-key? updates 'description)))
                      (hash-set sk2 'description (hash-ref updates 'title)) sk2)]
              [sk (if (and (hash-has-key? updates 'problem) (not (hash-has-key? updates 'when_to_use)))
                      (hash-set sk 'when_to_use (hash-ref updates 'problem)) sk)]
              [sk (if (and (hash-has-key? updates 'solution) (not (hash-has-key? updates 'body_extra))
                           (null? (hash-ref sk 'procedure '())))
                      (hash-set sk 'body_extra (hash-ref updates 'solution)) sk)]
              [sk (if (and (hash-has-key? updates 'steps) (not (hash-has-key? updates 'procedure)))
                      (hash-set sk 'procedure (or (jget updates 'steps) '())) sk)])
         sk))
     (define new-name (slugify (let ([n (jget updates 'name)])
                                 (if (jtruthy n) n (hash-ref sk3 'name)))))
     (define sk4 (hash-set sk3 'name new-name))
     (define new-path (skill-file m (hash-ref sk4 'category "general") new-name))
     (cond
       [(not (equal? (path->string new-path) (path->string path)))
        (define new-dir (path-only new-path))
        (cond
          [(directory-exists? new-dir) #f]            ; rename target exists
          [else
           (make-parent-directory* new-dir)
           (rename-file-or-directory old-dir new-dir)
           (define usage (load-usage m))
           (define ok (usage-key name (hash-ref sk4 'owner #f)))
           (when (hash-has-key? usage ok)
             (save-usage m (hash-set (hash-remove usage ok)
                                     (usage-key new-name (hash-ref sk4 'owner #f))
                                     (hash-ref usage ok))))
           (write-skill! m sk4)
           #t])]
       [else (write-skill! m sk4) #t])]))

(define (skills-delete m name #:owner [owner #f])
  (define hit (find-skill m name owner))
  (cond
    [(not hit) #f]
    [else
     (with-handlers ([exn:fail? (lambda (_) #f)])
       (delete-directory/files (path-only (car hit)))
       (define usage (load-usage m))
       (define k (usage-key name (hash-ref (cdr hit) 'owner #f)))
       (when (hash-has-key? usage k) (save-usage m (hash-remove usage k)))
       #t)]))

(define (skills-read-md m name #:owner [owner #f])
  (define hit (find-skill m name owner))
  (and hit (with-handlers ([exn:fail? (lambda (_) #f)]) (file->string (car hit)))))

;; sub-file under the skill dir; refuses traversal outside it
(define (skills-read-reference m name ref #:owner [owner #f])
  (define hit (find-skill m name owner))
  (and hit
       (let* ([base (simplify-path (path->complete-path (path-only (car hit))))]
              [target (simplify-path (path->complete-path (build-path base ref)))]
              [base-s (path->string base)]
              [target-s (path->string target)])
         (and (string-prefix? target-s base-s)
              (not (equal? (string-trim target-s "/" #:left? #f)
                           (string-trim base-s "/" #:left? #f)))
              (file-exists? target)
              (with-handlers ([exn:fail? (lambda (_) #f)]) (file->string target))))))

;; ---- relevance search (the manage_skills action="search" path) -------------------
(define (skills-relevant m query skills #:max-items [max-items 5] #:threshold [threshold 0.3])
  (cond
    [(or (null? skills) (string=? (string-trim query) "")) '()]
    [else
     (define eligible (filter (lambda (s) (member (hash-ref s 'status #f) '("published" "draft")))
                              skills))
     (define qt (tokenize query))
     (define scored
       (for*/list ([sk (in-list eligible)]
                   [text (in-value (string-join
                                    (list (hash-ref sk 'name "") (hash-ref sk 'description "")
                                          (hash-ref sk 'when_to_use "")
                                          (string-join (map (lambda (x) (format "~a" x))
                                                            (or (jget sk 'tags) '())) " ")
                                          (string-join (map (lambda (x) (format "~a" x))
                                                            (or (jget sk 'procedure) '())) " "))
                                    " "))]
                   [score0 (in-value (jaccard qt (tokenize text)))]
                   [score1 (in-value
                            (for/fold ([sc score0]) ([tag (in-list (or (jget sk 'tags) '()))])
                              (define tt (tokenize (format "~a" tag)))
                              (if (and (not (set-empty? tt)) (subset? tt qt))
                                  (* (max sc 0.3) 1.3) sc)))]
                   [score2 (in-value
                            (if (string-contains? (string-downcase (or (jget sk 'description) ""))
                                                  (string-downcase query))
                                (max score1 0.6) score1))]
                   [score (in-value (* score2
                                       (+ 1.0 (* (to-float (hash-ref sk 'confidence 'null) 0.5) 0.1))
                                       (if (> (let ([u (hash-ref sk 'uses 0)])
                                                (if (number? u) u 0)) 0) 1.05 1.0)))]
                   #:when (>= score threshold))
         (cons score sk)))
     (map cdr (take (sort scored > #:key car) (min max-items (length scored))))]))

;; ---- the manage_skills tool --------------------------------------------------------

(define (err msg) (hasheq 'error msg 'exit_code 1))

;; Port of routes/prefs_routes._load_for_user over <data-dir>/user_prefs.json.
;; Missing/bad file → {} (matches _load's FileNotFoundError/JSONDecodeError →
;; {}). _users[owner] when present; legacy flat dict otherwise; owner=#f
;; (auth-disabled) → first user's prefs for backward compat. data-dir is the
;; parent of the manager's skills root.
(define (load-prefs-for-user m owner)
  (define data-dir (let-values ([(base name dir?) (split-path (skman-root m))]) base))
  (define all
    (with-handlers ([exn:fail? (lambda (_) (hasheq))])
      (let ([v (string->jsexpr (file->string (build-path data-dir "user_prefs.json")))])
        (if (hash? v) v (hasheq)))))
  (cond
    [(hash-has-key? all '_users)
     (define users (hash-ref all '_users))
     (cond
       [(not (hash? users)) (hasheq)]
       [(not (jtruthy owner))
        (if (positive? (hash-count users))
            (let ([v (hash-ref users (car (hash-keys users)))]) (if (hash? v) v (hasheq)))
            (hasheq))]
       [else (let ([v (hash-ref users (string->symbol owner) #f)]) (if (hash? v) v (hasheq)))])]
    [else all]))

;; #fa8c93e: explicit status wins; otherwise publish immediately iff the owner's
;; auto_approve_skills pref is on (default on) — else draft. ("" status, like
;; Python's `if not _status_arg`, counts as unpinned → goes through the gate.)
(define (skill-add-status m owner status-arg)
  (cond
    [(jtruthy status-arg) status-arg]
    [(jtruthy (hash-ref (load-prefs-for-user m owner) 'auto_approve_skills #t)) "published"]
    [else "draft"]))

(define (manage-skills data-dir content #:owner [owner #f])
  (define args (with-handlers ([exn:fail? (lambda (_) 'bad)])
                 (let ([v (string->jsexpr content)]) (if (hash? v) v (hasheq)))))
  (cond
    [(eq? args 'bad) (err "Invalid JSON arguments")]
    [else
     (define m (make-skills-manager data-dir))
     (define action (string-downcase (or (jget args 'action) "")))
     (define name (string-trim (or (jget args 'name) (jget args 'skill_id) "")))
     (with-handlers ([exn:fail? (lambda (e) (err (exn-message e)))])
       (case action
         [("list" "index" "") (skills-tool-list m owner)]
         [("view")
          (cond
            [(not (jtruthy name)) (err "name is required for view")]
            [(skills-read-md m name #:owner owner) => (lambda (md) (hasheq 'results md))]
            [else (err (format "Skill '~a' not found" name))])]
         [("view_ref")
          (define ref (string-trim (or (jget args 'path) "")))
          (cond
            [(not (jtruthy name)) (err "name is required for view_ref")]
            [(not (jtruthy ref)) (err "path is required for view_ref")]
            [(skills-read-reference m name ref #:owner owner) => (lambda (text) (hasheq 'results text))]
            [else (err (format "Reference '~a' not found under '~a'" ref name))])]
         [("add") (skills-tool-add m args name owner)]
         [("edit") (skills-tool-edit m args name owner)]
         [("patch") (skills-tool-patch m args name owner)]
         [("publish") (skills-tool-publish m args name owner)]
         [("delete")
          (cond
            [(not (jtruthy name)) (err "name is required for delete")]
            [(skills-delete m name #:owner owner) (hasheq 'results (format "Deleted skill `~a`." name))]
            [else (err (format "Skill '~a' not found" name))])]
         [("search")
          (define query (string-trim (or (jget args 'query) "")))
          (cond
            [(not (jtruthy query)) (err "query is required for search")]
            [else
             (define results (skills-relevant m query (skills-load m #:owner owner)))
             (if (null? results)
                 (hasheq 'results "No matching skills found.")
                 (hasheq 'results
                         (string-join
                          (for/list ([sk (in-list results)])
                            (define proc (let ([p (or (jget sk 'procedure) (jget sk 'steps) '())])
                                           (if (list? p) p '())))
                            (format "**~a**: ~a\n  When: ~a\n  Steps: ~a"
                                    (hash-ref sk 'name) (hash-ref sk 'description "")
                                    (hash-ref sk 'when_to_use "")
                                    (string-join (map (lambda (x) (format "~a" x))
                                                      (take proc (min 5 (length proc)))) " → ")))
                          "\n\n")))])]
         [else (err (format "Unknown action: '~a'. Use one of: list, view, view_ref, add, edit, patch, publish, delete, search." action))]))]))

(define (skills-tool-list m owner)
  (define all (skills-load m #:owner owner))
  (cond
    [(null? all) (hasheq 'results "No skills yet. Create one with action='add'.")]
    [else
     (define (by-name xs) (sort xs string<? #:key (lambda (s) (hash-ref s 'name))))
     (define published (by-name (filter (lambda (s) (equal? (hash-ref s 'status #f) "published")) all)))
     (define drafts (by-name (filter (lambda (s) (equal? (hash-ref s 'status #f) "draft")) all)))
     (define lines
       (append
        (if (pair? published)
            (cons "## Published"
                  (for/list ([s (in-list published)])
                    (format "- **~a** (~a): ~a" (hash-ref s 'name)
                            (hash-ref s 'category "general") (hash-ref s 'description ""))))
            '())
        (if (pair? drafts)
            (cons "\n## Drafts"
                  (for/list ([s (in-list drafts)])
                    (format "- **~a** [draft]: ~a" (hash-ref s 'name) (hash-ref s 'description ""))))
            '())))
     (hasheq 'results (if (pair? lines) (string-join lines "\n") "No skills yet."))]))

(define (skills-tool-add m args name owner)
  (define proc (let ([p (jget args 'procedure)]) (if (eq? p #f) (or (jget args 'steps) '()) p)))
  (cond
    [(not (jtruthy name))
     (err "name is required for add. Provide the exact slug the user should see, then report the returned name.")]
    [(and (not (jtruthy proc)) (not (jtruthy (jget args 'body_extra))) (not (jtruthy (jget args 'solution))))
     (err "procedure (or solution body) is required")]
    [else
     (define entry
       (skills-add m
        #:name (jget args 'name)
        #:title (or (jget args 'title) "")
        #:description (string-trim (or (jget args 'description) (jget args 'title) ""))
        #:category (or (jget args 'category) "general")
        #:tags (or (jget args 'tags) '())
        #:platforms (or (jget args 'platforms) '())
        #:requires-toolsets (or (jget args 'requires_toolsets) '())
        #:fallback-for-toolsets (or (jget args 'fallback_for_toolsets) '())
        #:when-to-use (if (hash-has-key? args 'when_to_use)
                          (let ([w (hash-ref args 'when_to_use)]) (if (eq? w 'null) "" w))
                          (or (jget args 'problem) ""))
        #:problem (or (jget args 'problem) "")
        #:procedure proc
        #:steps (or (jget args 'steps) '())
        #:pitfalls (or (jget args 'pitfalls) '())
        #:verification (or (jget args 'verification) '())
        #:status (skill-add-status m owner (jget args 'status))
        #:version (or (jget args 'version) "1.0.0")
        #:confidence (to-float (jget args 'confidence) 0.8)   ; Python float() parses "0.95"
        #:source (or (jget args 'source) "learned")
        #:teacher-model (jget args 'teacher_model)
        #:solution (or (jget args 'solution) "")
        #:owner owner))
     (cond
       [(jtruthy (hash-ref entry '_deduped #f))
        (hasheq 'results (format "A near-identical skill already exists: `~a` — not creating a duplicate. View or edit it with action='view', name='~a'."
                                 (hash-ref entry 'name) (hash-ref entry 'name)))]
       [else
        (define verify-hint
          (if (equal? (hash-ref entry 'status #f) "draft")
              (format "\n\nThis skill is a DRAFT. Run through the procedure once to verify, then publish with action='publish', name='~a'." (hash-ref entry 'name))
              ""))
        (hasheq 'results (format "Created skill `~a` — ~a~a"
                                 (hash-ref entry 'name) (hash-ref entry 'description "") verify-hint))])]))

;; the update payload skill_dump builds from a parsed Skill
(define (skill-dump sk)
  (for/hasheq ([k (in-list '(name description version category tags platforms
                             requires_toolsets fallback_for_toolsets status confidence
                             source teacher_model owner when_to_use procedure pitfalls
                             verification body_extra))])
    (values k (hash-ref sk k 'null))))

(define (skills-tool-edit m args name owner)
  (define new-content (jget args 'content))
  (cond
    [(not (jtruthy name)) (err "name is required for edit")]
    [(or (not (string? new-content)) (string=? (string-trim new-content) ""))
     (err "content (full SKILL.md) is required for edit")]
    [else
     (define sk-new (with-handlers ([exn:fail? (lambda (e) e)])
                      (skill-from-markdown new-content)))
     (cond
       [(exn:fail? sk-new) (err (format "Could not parse content as SKILL.md: ~a" (exn-message sk-new)))]
       [else
        (define existing (skills-load m #:owner owner))
        (define match (findf (lambda (s) (equal? (hash-ref s 'name) name)) existing))
        (cond
          [(not match) (err (format "Skill '~a' not found" name))]
          [else
           (define named (hash-set sk-new 'name
                                   (slugify (let ([n (hash-ref sk-new 'name "")])
                                              (if (jtruthy n) n name)))))
           (define owned (if (jtruthy (hash-ref named 'owner #f)) named
                             (hash-set named 'owner (or (jget match 'owner) owner))))
           (if (skills-update m name (skill-dump owned) #:owner owner)
               (hasheq 'results (format "Edited skill `~a`." (hash-ref owned 'name)))
               (err "Update failed"))])])]))

(define (count-substr s sub)
  (if (string=? sub "") 0 (length (regexp-match* (regexp (regexp-quote sub)) s))))

(define (skills-tool-patch m args name owner)
  (define old (jget args 'old_string))
  (define new-str (or (jget args 'new_string) ""))
  (cond
    [(not (jtruthy name)) (err "name is required for patch")]
    [(or (not (string? old)) (string=? old "")) (err "old_string is required and must be non-empty")]
    [else
     (define md (skills-read-md m name #:owner owner))
     (cond
       [(not md) (err (format "Skill '~a' not found" name))]
       [else
        (define count (count-substr md old))
        (cond
          [(= count 0) (err "old_string not found in SKILL.md")]
          [(> count 1) (err (format "old_string is ambiguous (appears ~a times). Make it more specific." count))]
          [else
           (define new-md (string-replace md old new-str #:all? #f))
           (define sk-new (with-handlers ([exn:fail? (lambda (e) e)])
                            (skill-from-markdown new-md)))
           (cond
             [(exn:fail? sk-new)
              (err (format "Patched content is not valid SKILL.md: ~a" (exn-message sk-new)))]
             [else
              (define named (hash-set sk-new 'name
                                      (slugify (let ([n (hash-ref sk-new 'name "")])
                                                 (if (jtruthy n) n name)))))
              (if (skills-update m name (skill-dump named) #:owner owner)
                  (hasheq 'results (format "Patched skill `~a`." (hash-ref named 'name)))
                  (err "Patch update failed"))])])])]))

(define (skills-tool-publish m args name owner)
  (cond
    [(not (jtruthy name)) (err "name is required for publish")]
    [else
     (define match (findf (lambda (s) (equal? (hash-ref s 'name) name))
                          (skills-load m #:owner owner)))
     (cond
       [(not match) (err (format "Skill '~a' not found" name))]
       [else
        (define updates
          (let ([c (jget args 'confidence)])           ; Python: if confidence is not None
            (if c
                (hasheq 'status "published" 'confidence (max 0.0 (min 1.0 (to-float c 0.0))))
                (hasheq 'status "published"))))
        (skills-update m name updates #:owner owner)
        (hasheq 'results (format "✅ Published `~a`. It now appears in the skills index for future turns." name))])]))
