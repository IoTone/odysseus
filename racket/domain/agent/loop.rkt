#lang racket/base

;; domain/agent/loop.rkt — the agent loop's *control spine*, as a pure driver.
;;
;; src/agent_loop.py is 2644 lines, but most of it is prompt assembly, endpoint
;; detection, retrieval, and LLM/tool I/O. The actual state machine is small and
;; universal:
;;
;;   each round: ask the model →
;;     • no tool calls  → the text is the final answer            → DONE
;;     • tool calls     → run them, feed results back, next round → CONTINUE
;;     • round cap hit                                            → MAX-ROUNDS
;;
;; Here that spine is a deterministic function with the two effects *injected*
;; (#:llm and #:exec), so it's testable without a model or real tools — and the
;; I/O adapter (real LLM client + tool executor) is the only impure part, kept
;; at the edges. Tool calls arrive as `tool-block`s (from domain/tools/convert).

(require racket/match
         racket/string
         "../tools/convert.rkt")     ; tool-block, tool-block-type/content

(provide (struct-out assistant-msg)
         (struct-out agent-result)
         run-agent)

;; what an #:llm turn yields: the model's text + any tool calls it requested
(struct assistant-msg (text tool-blocks) #:transparent)

;; how the loop ended. status: 'done | 'max-rounds
;; transcript: list of events, oldest first —
;;   (list 'assistant round text) | (list 'tools round (list (type . result) ...))
(struct agent-result (status rounds transcript) #:transparent)

;; run-agent : (listof message) -> agent-result
;;   #:llm  (messages) -> assistant-msg          [injected effect]
;;   #:exec (tool-block) -> string (result text) [injected effect]
(define (run-agent initial-messages
                   #:llm llm
                   #:exec exec
                   #:max-rounds [max-rounds 50])
  (let loop ([messages initial-messages] [round 1] [transcript '()])
    (cond
      [(> round max-rounds)
       (agent-result 'max-rounds (sub1 round) (reverse transcript))]
      [else
       (define msg (llm messages))
       (define tx (cons (list 'assistant round (assistant-msg-text msg)) transcript))
       (match (assistant-msg-tool-blocks msg)
         ['()  ; no tool calls — model's text is the final answer
          (agent-result 'done round (reverse tx))]
         [blocks
          (define results
            (for/list ([b (in-list blocks)])
              (cons (tool-block-type b) (exec b))))
          (loop (append messages
                        (list (hasheq 'role "assistant" 'content (assistant-msg-text msg))
                              (hasheq 'role "user" 'content (results->text results))))
                (add1 round)
                (cons (list 'tools round results) tx))])])))

;; Render tool results back into a user turn the model reads next round.
(define (results->text results)
  (string-join
   (for/list ([r (in-list results)]) (format "[~a]\n~a" (car r) (cdr r)))
   "\n\n"))
