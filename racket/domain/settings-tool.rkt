#lang racket/base

;; domain/settings-tool.rkt — the manage_settings agent tool: get/set/list/
;; reset over the real app settings store (data/settings.json — the same file
;; the Settings panel writes), plus the disable_tool/enable_tool toggles.
;; Port of do_manage_settings + the load/save slice of src/settings.py.
;;
;; Divergences (messages only, never stored data):
;; - save writes compact JSON (Python indent=2) — both sides read either.
;; - dict-valued defaults in chat messages are formatted with sorted keys
;;   (Python prints insertion order).

(require db
         json
         racket/string
         racket/list
         racket/file
         "util.rkt")

(provide manage-settings load-settings default-settings)

(define (err msg) (hasheq 'error msg 'exit_code 1))

;; ---- DEFAULT_SETTINGS (src/settings.py) — keys drive validation + coercion --
(define default-settings
  (hasheq
   'image_gen_enabled #t
   'image_model ""
   'image_quality "medium"
   'vision_model ""
   'vision_enabled #t
   'vision_model_fallbacks '()
   'app_public_url ""
   'tts_enabled #t
   'tts_provider "disabled"
   'tts_model "tts-1"
   'tts_voice "alloy"
   'tts_speed "1"
   'stt_enabled #f
   'stt_provider "disabled"
   'stt_model "base"
   'stt_language ""
   'search_provider "searxng"
   'search_fallback_chain '("duckduckgo")
   'search_url ""
   'search_result_count 5
   'search_safesearch "strict"
   'brave_api_key ""
   'google_pse_key ""
   'google_pse_cx ""
   'tavily_api_key ""
   'serper_api_key ""
   'research_endpoint_id ""
   'research_model ""
   'research_search_provider ""
   'research_max_tokens 16384
   'research_extraction_timeout_seconds 90
   'research_planning_timeout_seconds 90
   'research_query_timeout_seconds 90
   'research_extraction_concurrency 3
   'research_run_timeout_seconds 1800
   'agent_max_tool_calls 0
   'agent_max_rounds 20
   'agent_input_token_budget 6000
   'agent_input_token_hard_max 200000
   'agent_stream_timeout_seconds 300
   'tool_path_extra_roots '()
   'task_endpoint_id ""
   'task_model ""
   'default_endpoint_id ""
   'default_model ""
   'default_model_fallbacks '()
   'utility_endpoint_id ""
   'utility_model ""
   'utility_model_fallbacks '()
   'teacher_model ""
   'teacher_enabled #f
   'skill_autosave_min_confidence 0.85
   'skill_max_injected 3
   'reminder_channel "browser"
   'reminder_llm_synthesis #f
   'reminder_ntfy_topic "Reminders"
   'reminder_email_to ""
   'reminder_webhook_integration_id ""
   'reminder_webhook_payload_template ""
   'urgent_email_prompt
   (string-append
    "Flag as urgent: explicit deadlines, time-sensitive requests, "
    "work-blocking issues, messages from people I report to, or anything "
    "where a delayed reply costs money/trust. Someone waiting outside, "
    "at the door, locked out, or unable to get in is urgent now. "
    "Newsletters, marketing, automated digests, and FYI-only updates are "
    "NOT urgent.")
   'keybinds (hasheq 'search "ctrl+k" 'toggle_sidebar "ctrl+b" 'new_session "ctrl+alt+n"
                     'star_session "ctrl+alt+s" 'delete_session "ctrl+alt+d"
                     'admin_panel "ctrl+shift+u" 'cancel "escape")))

;; ---- store (load merged with defaults / atomic save) ------------------------
(define (load-settings path)
  (define saved
    (with-handlers ([exn:fail? (lambda (_) (hasheq))])
      (let ([v (string->jsexpr (file->string path))]) (if (hash? v) v (hasheq)))))
  (for/fold ([s default-settings]) ([(k v) (in-hash saved)]) (hash-set s k v)))

(define (save-settings path s)
  (make-parent-directory* path)
  (define tmp (string-append (if (path? path) (path->string path) path) ".tmp"))
  (call-with-output-file tmp #:exists 'replace (lambda (out) (write-json s out)))
  (rename-file-or-directory tmp path #t))

;; ---- helpers (each ports its underscored Python twin) -----------------------
(define secret-keys
  '("brave_api_key" "google_pse_key" "google_pse_cx" "tavily_api_key" "serper_api_key"
    "app_public_url"))
(define (secret? k)
  (or (member k secret-keys)
      (string-suffix? k "token")
      (ormap (lambda (t) (string-contains? k t)) '("api_key" "_key" "secret" "password"))))

(define set-aliases
  (hash "voice" "tts_voice" "tts voice" "tts_voice" "tts" "tts_enabled"
        "text to speech" "tts_enabled" "tts provider" "tts_provider"
        "speech speed" "tts_speed" "voice speed" "tts_speed"
        "stt" "stt_enabled" "speech to text" "stt_enabled" "transcription" "stt_enabled"
        "search engine" "search_provider" "search provider" "search_provider"
        "search results" "search_result_count" "result count" "search_result_count"
        "default model" "default_model" "chat model" "default_model"
        "default endpoint" "default_endpoint_id"
        "task model" "task_model" "background model" "task_model"
        "teacher model" "teacher_model" "teacher" "teacher_enabled"
        "utility model" "utility_model" "research model" "research_model"
        "research max tokens" "research_max_tokens"
        "vision model" "vision_model" "vision" "vision_enabled"
        "image model" "image_model" "image quality" "image_quality"
        "image gen" "image_gen_enabled" "image generation" "image_gen_enabled"
        "reminder channel" "reminder_channel" "reminders" "reminder_channel"
        "ntfy topic" "reminder_ntfy_topic"
        "webhook integration" "reminder_webhook_integration_id"
        "webhook template" "reminder_webhook_payload_template"
        "webhook payload" "reminder_webhook_payload_template"
        "agent tool calls" "agent_max_tool_calls" "max tool calls" "agent_max_tool_calls"
        "agent timeout" "agent_stream_timeout_seconds" "stream timeout" "agent_stream_timeout_seconds"
        "token budget" "agent_input_token_budget" "input budget" "agent_input_token_budget"
        "hard max" "agent_input_token_hard_max"
        "token budget cap" "agent_input_token_hard_max"
        "input budget cap" "agent_input_token_hard_max"))

(define (resolve-key k)
  (define k2 (string-downcase (string-trim (or k ""))))
  (cond [(hash-has-key? default-settings (string->symbol k2)) k2]
        [(hash-ref set-aliases k2 #f)]
        [else (string-trim (or k ""))]))

(define setting-enums
  (hash "image_quality" '("low" "medium" "high")
        "reminder_channel" '("browser" "email" "ntfy" "webhook")))

;; Python-flavored value rendering for chat messages (True/False, ['x'], {'k': 'v'})
(define (py-fmt v)
  (cond [(eq? v #t) "True"] [(eq? v #f) "False"]
        [(string? v) v]
        [(list? v) (string-append "[" (string-join (map py-repr v) ", ") "]")]
        [(hash? v) (string-append "{" (string-join
                                       (for/list ([k (sort (hash-keys v) symbol<?)])
                                         (format "'~a': ~a" k (py-repr (hash-ref v k))))
                                       ", ") "}")]
        [else (format "~a" v)]))
(define (py-repr v) (if (string? v) (format "'~a'" v) (py-fmt v)))

(define (mask k v) (if (and (secret? k) (jtruthy v)) "••••• (set in panel)" v))

;; bool/int coercion driven by the default's type; raises on a bad int
(define (coerce value default)
  (cond
    [(boolean? default)
     (if (boolean? value) value
         (and (member (string-downcase (string-trim (py-fmt value)))
                      '("true" "on" "yes" "1" "enable" "enabled")) #t))]
    [(exact-integer? default)
     ;; Python int(value): accepts ints, floats (int(5.0)=5, truncates),
     ;; booleans (int(True)=1), and integer-literal strings ("5" ok, "5.0" not).
     (cond [(boolean? value) (if value 1 0)]
           [(number? value) (inexact->exact (truncate value))]
           [(and (string? value) (let ([n (string->number (string-trim value))])
                                   (and n (exact-integer? n) n)))]
           [else (error 'coerce "bad int")])]
    [else value]))

;; ---- model → endpoint resolution over cached model lists --------------------
(define (model-slug s) (regexp-replace* #px"[^a-z0-9]+" (string-downcase (or s "")) ""))

(define (endpoint-model-from-cache conn wanted0)
  (define wanted (string-trim (or wanted0 "")))
  (define wanted-slug (model-slug wanted))
  (define tokens (filter (lambda (t) (not (string=? t "")))
                         (map model-slug (regexp-match* #px"[A-Za-z0-9]+" wanted))))
  (and (not (string=? wanted-slug ""))
       (let loop ([rows (query-rows conn
                          "SELECT id, cached_models FROM model_endpoints WHERE is_enabled = 1")]
                  [best #f])
         (cond
           [(null? rows) (and best (hasheq 'endpoint_id (cadr best) 'model (caddr best)))]
           [else
            (define r (car rows))
            (define models (with-handlers ([exn:fail? (lambda (_) '())])
                             (let* ([raw (vector-ref r 1)]
                                    [v (if (sql-null? raw) '() (string->jsexpr (or raw "[]")))])
                               (if (list? v) v '()))))
            (define new-best
              (for/fold ([b best]) ([mid0 (in-list models)])
                (define mid (format "~a" mid0))
                (define mid-slug (model-slug mid))
                (cond
                  [(string=? mid-slug "") b]
                  [else
                   (define exact? (string-ci=? mid wanted))
                   (define compact? (or (string-contains? mid-slug wanted-slug)
                                        (string-contains? wanted-slug mid-slug)))
                   (define token? (and (pair? tokens)
                                       (andmap (lambda (t) (string-contains? mid-slug t)) tokens)))
                   (define score (cond [exact? 3] [compact? 2] [token? 1] [else 0]))
                   (if (and (> score 0) (or (not b) (> score (car b))))
                       (list score (vector-ref r 0) mid)
                       b)])))
            (loop (cdr rows) new-best)]))))

;; tool-toggle aliases (disable_tool / enable_tool)
(define toggle-aliases
  (hash "shell" '("bash") "terminal" '("bash")
        "search" '("web_search") "web" '("web_search") "browser" '("builtin_browser")
        "documents" '("create_document" "edit_document" "update_document" "suggest_document")
        "doc" '("create_document" "edit_document" "update_document" "suggest_document")
        "memory" '("manage_memory") "skills" '("manage_skills")
        "images" '("generate_image") "image" '("generate_image")
        "tasks" '("manage_tasks") "notes" '("manage_notes") "calendar" '("manage_calendar")
        "email" '("mcp__email__list_emails" "mcp__email__read_email" "mcp__email__send_email")
        "research" '("web_search")))

;; ---- the tool ----------------------------------------------------------------
;; conn is only used by `set` for endpoint-model resolution.
(define model-keys '("default_model" "research_model" "utility_model" "task_model"
                     "vision_model" "image_model"))

(define (manage-settings conn settings-path content #:owner [owner #f])
  (define args (with-handlers ([exn:fail? (lambda (_) 'bad)])
                 (let ([v (string->jsexpr content)]) (if (hash? v) v (hasheq)))))
  (cond
    [(eq? args 'bad) (err "Invalid JSON arguments")]
    [else
     (define action (or (jget args 'action) "list"))
     (with-handlers ([exn:fail? (lambda (e) (err (exn-message e)))])
       (case action
         [("list")
          (define s (load-settings settings-path))
          (define shown (for/hasheq ([(k v) (in-hash s)]
                                     #:when (and (hash-has-key? default-settings k) (not (hash? v))))
                          (values k (mask (symbol->string k) v))))
          (hasheq 'response (format "~a settings (use get/set with a key)" (hash-count shown))
                  'settings shown 'exit_code 0)]
         [("get")
          (define key (resolve-key (jget args 'key)))
          (cond
            [(not (jtruthy key)) (err "key is required")]
            [(not (hash-has-key? default-settings (string->symbol key)))
             (err (format "Unknown setting '~a'. Use action='list' to see them." (or (jget args 'key) "")))]
            [else
             (define val (hash-ref (load-settings settings-path) (string->symbol key)
                                   (hash-ref default-settings (string->symbol key))))
             (hasheq 'response (format "~a = ~a" key (py-fmt (mask key val)))
                     'value (mask key val) 'exit_code 0)])]
         [("set")
          (define raw (or (jget args 'key) ""))
          (define value0 (hash-ref args 'value 'null))
          (cond
            [(not (jtruthy raw)) (err "key is required")]
            [else
             (define key (resolve-key raw))
             (define ksym (string->symbol key))
             (cond
               [(not (hash-has-key? default-settings ksym))
                (err (format "Unknown setting '~a'. Use action='list' to see available settings." raw))]
               [(secret? key)
                (hasheq 'response (format "'~a' is a credential/secret — for security I can't set it from chat. Open Settings and set it there." key)
                        'exit_code 0)]
               [(or (hash? (hash-ref default-settings ksym)) (list? (hash-ref default-settings ksym)))
                (hasheq 'response (format "'~a' is a structured setting — edit it in its panel, not from chat. (You can reset it to default here.)" key)
                        'exit_code 0)]
               [else
                (define default (hash-ref default-settings ksym))
                (define value
                  (with-handlers ([exn:fail? (lambda (_) 'bad-coerce)])
                    (coerce (if (eq? value0 'null) #f value0) default)))
                (cond
                  [(eq? value 'bad-coerce)
                   (err (format "'~a' isn't a valid value for ~a (expected int)." (py-fmt value0) key))]
                  [(and (hash-ref setting-enums key #f)
                        (not (member (string-downcase (py-fmt value)) (hash-ref setting-enums key))))
                   (err (format "~a must be one of: ~a." key
                                (string-join (hash-ref setting-enums key) ", ")))]
                  [else
                   (define s0 (load-settings settings-path))
                   (define-values (s1 final-value)
                     (cond
                       [(member key model-keys)
                        (define resolved (endpoint-model-from-cache conn (py-fmt value)))
                        (if resolved
                            (let ([prefix (substring key 0 (- (string-length key) 6))])
                              (values (hash-set* (hash-set s0 ksym (hash-ref resolved 'model))
                                                 (string->symbol (string-append prefix "_endpoint_id"))
                                                 (hash-ref resolved 'endpoint_id))
                                      (hash-ref resolved 'model)))
                            (values (hash-set s0 ksym value) value))]
                       [else (values (hash-set s0 ksym value) value)]))
                   (save-settings settings-path s1)
                   (define prefix-ep
                     (and (string-suffix? key "_model")
                          (let ([ep (hash-ref s1 (string->symbol
                                                  (string-append (substring key 0 (- (string-length key) 6))
                                                                 "_endpoint_id")) #f)])
                            (and (jtruthy ep) ep))))
                   (hasheq 'response
                           (if prefix-ep
                               (format "Set ~a = ~a (endpoint ~a)." key (py-fmt final-value) prefix-ep)
                               (format "Set ~a = ~a." key (py-fmt final-value)))
                           'exit_code 0)])])])]
         [("delete" "reset")
          (define key (resolve-key (jget args 'key)))
          (define ksym (string->symbol key))
          (cond
            [(not (hash-has-key? default-settings ksym))
             (err (format "Unknown setting '~a'." (or (jget args 'key) "")))]
            [(secret? key)
             (hasheq 'response (format "'~a' is a credential — reset it in the panel." key) 'exit_code 0)]
            [else
             (define s (hash-set (load-settings settings-path) ksym (hash-ref default-settings ksym)))
             (save-settings settings-path s)
             (hasheq 'response (format "Reset ~a to default (~a)." key (py-fmt (hash-ref default-settings ksym)))
                     'exit_code 0)])]
         [("list_tools")
          (define current (let ([v (hash-ref (load-settings settings-path) 'disabled_tools '())])
                            (if (list? v) v '())))
          (hasheq 'response
                  (string-append
                   (format "Currently disabled: ~a.\n"
                           (if (pair? current) (string-join current ", ") "(none)"))
                   "Common toggles: shell (bash), search (web_search), browser, documents, "
                   "memory, skills, images, tasks, notes, calendar, email.")
                  'disabled current 'exit_code 0)]
         [("disable_tool" "enable_tool")
          (define tool-name (string-downcase (string-trim (or (jget args 'tool) (jget args 'name) ""))))
          (cond
            [(not (jtruthy tool-name)) (err "tool name required (e.g. 'shell', 'search', 'bash')")]
            [else
             (define targets (hash-ref toggle-aliases tool-name (list tool-name)))
             (define s (load-settings settings-path))
             (define before (let ([v (hash-ref s 'disabled_tools '())]) (if (list? v) v '())))
             (define current
               (if (equal? action "disable_tool")
                   (append before (filter (lambda (t) (not (member t before))) targets))
                   (filter (lambda (t) (not (member t targets))) before)))
             (save-settings settings-path (hash-set s 'disabled_tools current))
             (define changed (sort (append (filter (lambda (t) (not (member t current))) before)
                                           (filter (lambda (t) (not (member t before))) current))
                                   string<?))
             (hasheq 'response
                     (format "~a ~a (~a). Now disabled: ~a."
                             (if (equal? action "disable_tool") "Disabled" "Enabled")
                             tool-name (string-join targets ", ")
                             (if (pair? current) (string-join current ", ") "(none)"))
                     'changed changed 'disabled current 'exit_code 0)])]
         [else (err (format "Unknown action: ~a" action))]))]))
