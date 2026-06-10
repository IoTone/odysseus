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
  (if (zero? (hash-count extra))
      main
      (string-append main "\n**data:**\n```json\n" (jsexpr->string extra) "\n```")))
