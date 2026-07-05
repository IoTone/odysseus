#lang racket/base

;; domain/tools/result.rkt — render a tool's result jsexpr into the text fed
;; back to the model: the relevant branches of src/tool_execution.py
;; format_tool_result (response/results/error + leftover structured keys as a
;; data block; compact JSON where Python pretty-prints). Shared by every
;; DB-backed tool handler (manage_notes, manage_tasks, …).

(require json)

(provide tool-result->text)

;; keys the dedicated branches consume — never echoed in the data block
(define formatter-handled-keys
  '(response results error exit_code stdout stderr content size session_id name
    model session_name success path action title doc_id version applied output))

(define (tool-result->text result)
  (define main
    (cond [(hash-has-key? result 'response) (hash-ref result 'response)]
          [(hash-has-key? result 'results)  (hash-ref result 'results)]
          [(hash-has-key? result 'error)    (format "**Error:** ~a" (hash-ref result 'error))]
          [else ""]))
  (define extra (for/hasheq ([(k v) (in-hash result)]
                             #:unless (memq k formatter-handled-keys))
                  (values k v)))
  (cond
    [(zero? (hash-count extra)) main]
    [else
     ;; Cap the structured payload like Python format_tool_result
     ;; (src/tool_execution.py): a list_events/list over a populated DB can be
     ;; hundreds of KB, which would otherwise blow the model's context window.
     (define j (jsexpr->string extra))
     (define capped (if (> (string-length j) 8000)
                        (string-append (substring j 0 8000)
                                       (format "\n... (truncated, ~a chars total)" (string-length j)))
                        j))
     (string-append main "\n**data:**\n```json\n" capped "\n```")]))
