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

(provide chat-response->assistant-msg openai-llm http-post-json)

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

;; ---- impure: POST JSON to a URL, return (values status-code jsexpr) ---------
(define (http-post-json url body-jsexpr headers)
  (define u (string->url url))
  (define ssl? (equal? (url-scheme u) "https"))
  (define host (url-host u))
  (define port (or (url-port u) (if ssl? 443 80)))
  (define path (string-append "/" (string-join (map path/param-path (url-path u)) "/")))
  (define-values (status _hdrs in)
    (http-sendrecv host path #:ssl? ssl? #:port port #:method #"POST"
                   #:headers headers #:data (jsexpr->bytes body-jsexpr)))
  (values (let ([m (regexp-match #px#"\\b([0-9]{3})\\b" status)])
            (if m (string->number (bytes->string/utf-8 (cadr m))) 0))
          (string->jsexpr (port->string in))))

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
