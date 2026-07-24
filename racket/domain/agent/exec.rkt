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
         racket/path
         racket/port
         racket/system
         racket/file
         net/http-client
         net/url
         json
         "../tools/convert.rkt")    ; tool-block-type / -content

(provide make-exec default-handlers
         truncate-output read-clip          ; exported for tests (output-cap fidelity)
         sensitive-path?)                    ; exported for tests (deny-list)

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

;; ---- file-tool security ----------------------------------------------------
;; Port of the deny-list + code-nav confinement from src/tool_execution.py
;; (_SENSITIVE_BASENAMES / _SENSITIVE_FILE_PATTERNS / _is_sensitive_path,
;; _CODENAV_SKIP_DIRS, _glob_to_regex) and filesystem_tools.py's pruning walk.
;; Wired into read/write/edit/grep/glob so the agent can't read or enumerate
;; ~/.ssh, id_rsa, .env, known_hosts, … regardless of the root it is pointed at,
;; and glob/grep never descend into .git/node_modules/… or a sensitive dir.
;; Matching is CASE-INSENSITIVE (#5189): a case-variant name (.SSH, Id_Rsa)
;; points at the same file on Windows/default-macOS, so a case-sensitive check
;; would let it slip past every tool that relies on the deny-list.
;;
;; NOTE: the app's workspace/DATA_DIR *allowlist* (_resolve_tool_path) is app
;; policy this config-free CLI spine has no equivalent for, so read/write take
;; arbitrary paths as before — but the blanket sensitive-file deny-list (which
;; applies "regardless of what root it sits under") and the glob search-root
;; confinement (#5010) ARE ported, since those are the exfil-critical pieces.
(define (casefold s) (string-downcase s))

(define sensitive-basenames-cf
  (map casefold '(".ssh" ".gnupg" ".gitconfig"
                  ".bashrc" ".bash_profile" ".bash_logout"
                  ".zshrc" ".zprofile" ".zshenv"
                  ".profile" ".tcshrc" ".cshrc" ".env" ".netrc")))
(define sensitive-file-patterns-cf
  (map casefold '("authorized_keys" "id_rsa" "id_ed25519" "id_ecdsa" "known_hosts")))
(define codenav-skip-dirs
  '(".git" ".hg" ".svn" "node_modules" "venv" ".venv" "__pycache__"
    ".mypy_cache" ".pytest_cache" ".ruff_cache" "dist" "build"
    ".next" ".cache" "site-packages" ".idea" ".tox"))

(define (path-parts s) (filter non-empty-string? (regexp-split #rx"[/\\]" s)))

;; port of _is_sensitive_path: True if any path component is a sensitive dir, or
;; the filename matches a sensitive file pattern (case-insensitive).
(define (sensitive-path? p)
  (define parts (map casefold (path-parts (if (path? p) (path->string p) p))))
  (or (for/or ([x (in-list parts)]) (and (member x sensitive-basenames-cf) #t))
      (and (pair? parts) (member (last parts) sensitive-file-patterns-cf) #t)))

;; a dir name to prune during a code-nav walk: a skip-dir OR a sensitive dir
;; (so glob/grep never enumerate the keys/tokens inside .ssh/.gnupg/…).
(define (prune-dir? name)
  (or (and (member name codenav-skip-dirs) #t)
      (and (member (casefold name) sensitive-basenames-cf) #t)))

;; lexically-resolved absolute path string (resolves ../ WITHOUT touching the
;; filesystem — for the confinement check on a literal glob pattern).
(define (norm-abs p)
  (path->string (simplify-path (path->complete-path (if (path? p) p (string->path p))) #f)))

;; is `cand` inside directory `rbase` (both norm-abs strings)? case-insensitive
;; to match the sibling deny-list's fold. equal counts as inside.
(define (within-root? cand rbase)
  (define c (casefold cand)) (define b (casefold rbase))
  (or (string=? c b)
      (string-prefix? c (string-append b "/"))
      (string-prefix? c (string-append b "\\"))))

;; rel path of p under base ("/"-separated), for glob regex fullmatch.
(define (rel-under base p)
  (define b (norm-abs base)) (define r (norm-abs p))
  (define stripped
    (cond [(within-root? r b) (substring r (min (string-length r) (add1 (string-length b))))]
          [else (path->string (file-name-from-path p))]))
  (regexp-replace* #rx"\\\\" stripped "/"))

;; port of _glob_to_regex: a forward-slash glob → an anchored regex.
;; **/ spans whole dirs; ** = anything; * within one segment; ? one char.
(define (glob->regex pat)
  (define out (open-output-string))
  (define n (string-length pat))
  (let loop ([i 0])
    (when (< i n)
      (cond
        [(and (<= (+ i 3) n) (string=? (substring pat i (+ i 3)) "**/"))
         (write-string "(?:[^/]+/)*" out) (loop (+ i 3))]
        [(and (<= (+ i 2) n) (string=? (substring pat i (+ i 2)) "**"))
         (write-string ".*" out) (loop (+ i 2))]
        [(char=? (string-ref pat i) #\*) (write-string "[^/]*" out) (loop (add1 i))]
        [(char=? (string-ref pat i) #\?) (write-string "[^/]" out) (loop (add1 i))]
        [else (write-string (regexp-quote (string (string-ref pat i))) out) (loop (add1 i))])))
  (pregexp (string-append "^" (get-output-string out) "$")))

;; recursively collect entries under `base`, pruning skip/sensitive dirs and
;; dropping sensitive files (never descends into or yields a sensitive path).
;; #:want-dirs? also yields the (surviving) directories, for glob matching.
(define (walk-tree base #:want-dirs? [want-dirs? #f])
  (let loop ([dir (if (path? base) base (string->path base))] [acc '()])
    (for/fold ([acc acc])
              ([p (in-list (with-handlers ([exn:fail? (lambda (_) '())])
                             (directory-list dir #:build? #t)))])
      (define name (path->string (file-name-from-path p)))
      (cond
        [(directory-exists? p)
         (if (prune-dir? name) acc
             (loop p (if want-dirs? (cons p acc) acc)))]
        [(sensitive-path? p) acc]
        [else (cons p acc)]))))

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
          [(sensitive-path? path) (format "error: access to sensitive file denied: ~a" path)]
          [(not (file-exists? path)) (format "error: no such file: ~a" path)]
          [else
           (define lines (string-split (file->string path) "\n" #:trim? #f))
           (define off (max 0 (sub1 (let ([o (hash-ref a 'offset 1)]) (if (number? o) o 1)))))
           (define lim (let ([l (hash-ref a 'limit #f)]) (and (number? l) l)))
           (define chosen (let ([tail (if (> off (length lines)) '() (drop lines off))])
                            (if lim (take tail (min lim (length tail))) tail)))
           (read-clip (sj chosen))])]
       [(sensitive-path? content) (format "error: access to sensitive file denied: ~a" content)]
       [(file-exists? content) (read-clip (file->string content))]
       [else (format "error: no such file: ~a" content)]))

   "write_file"
   (lambda (content)
     (define i (string-index content #\newline))
     (define-values (path body) (if i (values (substring content 0 i) (substring content (add1 i)))
                                    (values content "")))
     (cond
       [(sensitive-path? path) (format "error: access to sensitive file denied: ~a" path)]
       [else
        (make-parent-directory* path)
        (with-output-to-file path #:exists 'replace (lambda () (display body)))
        (format "wrote ~a bytes to ~a" (string-length body) path)]))

   "edit_file"
   (lambda (content)
     (define a (parse-json-content content))
     (define path (hash-ref a 'path ""))
     (define old (hash-ref a 'old_string ""))
     (define new (hash-ref a 'new_string ""))
     (define all? (eq? (hash-ref a 'replace_all #f) #t))
     (cond
       [(sensitive-path? path) (format "error: access to sensitive file denied: ~a" path)]
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
     (cond
       [(sensitive-path? path) (format "error: access to sensitive path denied: ~a" path)]
       [(directory-exists? path)
        (sj (sort (map path->string (directory-list path)) string<?))]
       [else (format "error: not a directory: ~a" path)]))

   "glob"
   (lambda (content)
     (define a (parse-json-content content))
     (define pat (let ([p (hash-ref a 'pattern "*")]) (if (string? p) (string-trim p) "*")))
     (define base (let ([p (hash-ref a 'path ".")]) (if (string? p) p ".")))
     (cond
       [(string=? pat "") "error: glob: pattern is required"]
       [(not (directory-exists? base)) (format "error: not a directory: ~a" base)]
       [else
        (define rbase (norm-abs base))
        (define norm-pat (regexp-replace* #rx"\\\\" pat "/"))
        (define literal? (not (regexp-match? #rx"[*?[]" norm-pat)))
        (define lit-cand (and literal? (norm-abs (build-path base norm-pat))))
        (cond
          ;; literal fast-path: confined to base (#5010) + not sensitive
          [(and literal?
                (within-root? lit-cand rbase)
                (or (file-exists? lit-cand) (directory-exists? lit-cand))
                (not (sensitive-path? lit-cand)))
           lit-cand]
          [else
           (define rx (glob->regex norm-pat))
           (define matched
             (for/list ([p (in-list (walk-tree base #:want-dirs? #t))]
                        #:when (or (regexp-match? rx (rel-under base p))
                                   (regexp-match? rx (path->string (file-name-from-path p)))))
               p))
           (define newest
             (sort matched >
                   #:key (lambda (p) (with-handlers ([exn:fail? (lambda (_) 0)])
                                       (file-or-directory-modify-seconds p)))))
           (if (null? newest) "(no matches)" (truncate-output (sj (map path->string newest))))])]))

   "grep"
   (lambda (content)
     (define a (parse-json-content content))
     (define rx (let ([p (hash-ref a 'pattern "")])
                  (if (eq? (hash-ref a 'ignore_case #f) #t) (pregexp (string-append "(?i:" p ")")) (pregexp p))))
     (define base (let ([p (hash-ref a 'path ".")]) (if (string? p) p ".")))
     (define gl (hash-ref a 'glob #f))
     (define cap (let ([m (hash-ref a 'max_results 200)]) (if (number? m) m 200)))
     ;; File set: a single file (unless sensitive), else a pruned walk that
     ;; skips sensitive files and .git/node_modules/… (#5011/#5094/#5189/#4538).
     (define files
       (cond [(file-exists? base) (if (sensitive-path? base) '() (list (string->path base)))]
             [(directory-exists? base)
              (let ([all (walk-tree base)])
                (if (and gl (string? gl))
                    (let ([grx (glob->regex (regexp-replace* #rx"\\\\" gl "/"))])
                      (filter (lambda (p) (regexp-match? grx (path->string (file-name-from-path p)))) all))
                    all))]
             [else '()]))
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
