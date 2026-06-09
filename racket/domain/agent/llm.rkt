#lang racket/base

;; domain/agent/llm.rkt — the #:llm effect: an OpenAI-compatible chat adapter.
;;
;; Splits into a PURE parser (chat-response->assistant-msg) — fully unit-tested —
;; and the impure HTTP call (openai-llm). The agent spine (loop.rkt) stays pure;
;; this is the edge. Tool calls in the response are decoded with the same
;; function-call->tool-block converter the rest of the system uses.

(require racket/port
         racket/string
         net/http-client
         net/url
         json
         "loop.rkt"                 ; assistant-msg
         "../tools/convert.rkt")    ; function-call->tool-block

(provide chat-response->assistant-msg openai-llm http-post-json
         stream-deltas->assistant-msg openai-llm-stream)

;; ---- pure: parse a /v1/chat/completions response into an assistant-msg ------
(define (chat-response->assistant-msg resp)
  (define choices (hash-ref resp 'choices '()))
  (define msg (if (pair? choices) (hash-ref (car choices) 'message (hasheq)) (hasheq)))
  (define content (let ([c (hash-ref msg 'content 'null)]) (if (string? c) c "")))
  (define blocks
    (for*/list ([tc (in-list (let ([t (hash-ref msg 'tool_calls '())]) (if (list? t) t '())))]
                [fn (in-value (hash-ref tc 'function (hasheq)))]
                [b  (in-value (function-call->tool-block
                               (hash-ref fn 'name "")
                               (let ([a (hash-ref fn 'arguments "{}")]) (if (string? a) a (jsexpr->string a)))))]
                #:when b)
      b))
  (assistant-msg content blocks))

;; ---- impure: HTTP -----------------------------------------------------------
(define (status-code status) (let ([m (regexp-match #px#"\\b([0-9]{3})\\b" status)])
                               (if m (string->number (bytes->string/utf-8 (cadr m))) 0)))
(define (url-parts url)
  (define u (string->url url))
  (define ssl? (equal? (url-scheme u) "https"))
  (values (url-host u) (or (url-port u) (if ssl? 443 80)) ssl?
          (string-append "/" (string-join (map path/param-path (url-path u)) "/"))))

;; POST JSON, return (values status-code jsexpr) — non-streaming.
(define (http-post-json url body-jsexpr headers)
  (define-values (host port ssl? path) (url-parts url))
  (define-values (status _hdrs in)
    (http-sendrecv host path #:ssl? ssl? #:port port #:method #"POST"
                   #:headers headers #:data (jsexpr->bytes body-jsexpr)))
  (values (status-code status) (string->jsexpr (port->string in))))

;; POST JSON, return (values status-code body-input-port) — for SSE streaming.
(define (http-post-stream url body-jsexpr headers)
  (define-values (host port ssl? path) (url-parts url))
  (define-values (status _hdrs in)
    (http-sendrecv host path #:ssl? ssl? #:port port #:method #"POST"
                   #:headers headers #:data (jsexpr->bytes body-jsexpr)))
  (values (status-code status) in))

;; ---- streaming -------------------------------------------------------------
;; Read an OpenAI SSE stream into the list of `delta` objects, invoking
;; on-content with each text chunk (for live output).
(define (read-sse-deltas in on-content)
  (let loop ([acc '()])
    (define line (read-line in 'any))
    (cond
      [(eof-object? line) (reverse acc)]
      [(string-prefix? line "data:")
       (define payload (string-trim (substring line 5)))
       (cond
         [(string=? payload "[DONE]") (reverse acc)]
         [(string=? payload "") (loop acc)]
         [else
          (define chunk (with-handlers ([exn:fail? (lambda (_) #f)]) (string->jsexpr payload)))
          (cond
            [(not (hash? chunk)) (loop acc)]
            [else
             (define choices (hash-ref chunk 'choices '()))
             (define delta (if (pair? choices) (hash-ref (car choices) 'delta (hasheq)) (hasheq)))
             (let ([c (hash-ref delta 'content #f)]) (when (string? c) (on-content c)))
             (loop (cons delta acc))])])]
      [else (loop acc)])))   ; skip blanks / comments

;; PURE: fold streamed deltas into a final assistant-msg. content chunks
;; concatenate; tool_calls arrive by `index` with name once and `arguments` in
;; pieces — reassemble per index, then decode with function-call->tool-block.
(define (stream-deltas->assistant-msg deltas)
  (define content (open-output-string))
  (define calls (make-hash))                 ; index -> (mcons name args-so-far)
  (for ([d (in-list deltas)])
    (let ([c (hash-ref d 'content #f)]) (when (string? c) (write-string c content)))
    (for ([tc (in-list (let ([t (hash-ref d 'tool_calls '())]) (if (list? t) t '())))])
      (define idx (let ([i (hash-ref tc 'index 0)]) (if (number? i) i 0)))
      (define cur (hash-ref! calls idx (lambda () (mcons "" ""))))
      (define fn (hash-ref tc 'function (hasheq)))
      (let ([n (hash-ref fn 'name #f)]) (when (and (string? n) (not (string=? n ""))) (set-mcar! cur n)))
      (let ([a (hash-ref fn 'arguments #f)]) (when (string? a) (set-mcdr! cur (string-append (mcdr cur) a))))))
  (define blocks
    (for*/list ([idx (in-list (sort (hash-keys calls) <))]
                [cur (in-value (hash-ref calls idx))]
                [b (in-value (function-call->tool-block (mcar cur)
                              (let ([a (mcdr cur)]) (if (string=? a "") "{}" a))))]
                #:when b)
      b))
  (assistant-msg (get-output-string content) blocks))

;; streaming #:llm — same shape as openai-llm, but reads SSE and (optionally)
;; emits content chunks live via #:on-content.
(define (openai-llm-stream #:endpoint endpoint #:model model
                           #:api-key [api-key #f] #:tools [tools '()]
                           #:on-content [on-content void])
  (define headers
    (append (list "Content-Type: application/json")
            (if api-key (list (string-append "Authorization: Bearer " api-key)) '())))
  (lambda (messages)
    (define body (hasheq 'model model 'messages messages 'stream #t
                         'tool_choice "auto" 'tools tools))
    (define-values (code in) (http-post-stream endpoint body headers))
    (unless (= code 200) (error 'openai-llm-stream "endpoint returned HTTP ~a" code))
    (stream-deltas->assistant-msg (read-sse-deltas in on-content))))

;; ---- the #:llm effect ------------------------------------------------------
;; (openai-llm …) -> (messages -> assistant-msg)
(define (openai-llm #:endpoint endpoint #:model model
                    #:api-key [api-key #f] #:tools [tools '()])
  (define headers
    (append (list "Content-Type: application/json")
            (if api-key (list (string-append "Authorization: Bearer " api-key)) '())))
  (lambda (messages)
    (define body (hasheq 'model model 'messages messages 'stream #f
                         'tool_choice "auto" 'tools tools))
    (define-values (code resp) (http-post-json endpoint body headers))
    (unless (= code 200)
      (error 'openai-llm "endpoint returned HTTP ~a: ~a" code resp))
    (chat-response->assistant-msg resp)))
