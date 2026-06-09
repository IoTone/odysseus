#lang racket/base

;; odysseus-agent — run the Racket agent spine against a real OpenAI-compatible
;; endpoint with a real tool dispatcher. Ties together domain/agent/{loop,llm,exec}
;; and the tool-schema DSL.
;;
;;   LLM_ENDPOINT=http://localhost:7000/v1/chat/completions LLM_MODEL=gpt-4o \
;;   OPENAI_API_KEY=sk-... \
;;     racket cli/odysseus-agent.rkt "list the .rkt files here" --pretty
;;
;; --endpoint / --model / --max-rounds override the env. The Python agent's huge
;; system prompt / retrieval / streaming are not ported; this is the spine + a
;; minimal prompt + a few real tools (see domain/agent/exec.rkt).

(require racket/match
         racket/string
         cli-kit
         "../domain/agent/loop.rkt"
         "../domain/agent/llm.rkt"
         "../domain/agent/exec.rkt"
         "../domain/tools/dsl.rkt"
         "../domain/tools/core-tools.rkt"   ; registers the ported tools
         "../config.rkt")

(define SYSTEM
  (string-append
   "You are an Odysseus agent running on the user's machine. Use the provided "
   "tools to accomplish the request. Take one concrete step at a time. When the "
   "task is complete, reply with a short final answer and DO NOT call any tool."))

(define (opt args flag) (let loop ([xs args])
                          (cond [(null? xs) #f]
                                [(and (string=? (car xs) flag) (pair? (cdr xs))) (cadr xs)]
                                [else (loop (cdr xs))])))
(define (flag-token? a) (string-prefix? a "--"))

(define (ev->jsexpr e)
  (match e
    [(list 'assistant r text) (hasheq 'kind "assistant" 'round r 'text text)]
    [(list 'tools r results)
     (hasheq 'kind "tools" 'round r
             'results (for/list ([rr (in-list results)]) (hasheq 'tool (car rr) 'result (cdr rr))))]))

(define (final-text result)
  (or (for/last ([e (in-list (agent-result-transcript result))] #:when (eq? (car e) 'assistant)) (caddr e))
      ""))

(define (dispatch)
  (define args (vector->list (current-command-line-arguments)))
  (define pretty? (pretty-from-args? args))
  (define a (filter (lambda (x) (not (string=? x "--pretty"))) args))
  (define endpoint (or (opt a "--endpoint") (getenv "LLM_ENDPOINT")))
  (define model (or (opt a "--model") (getenv "LLM_MODEL")))
  (define api-key (or (getenv "OPENAI_API_KEY") (getenv "LLM_API_KEY")))
  (define max-rounds (let ([m (opt a "--max-rounds")]) (if m (or (string->number m) 12) 12)))
  ;; prompt = first positional token that isn't a flag or a flag's value
  (define flag-vals (filter values (map (lambda (f) (opt a f)) '("--endpoint" "--model" "--max-rounds"))))
  (define prompt (for/first ([x (in-list a)]
                             #:when (and (not (flag-token? x)) (not (member x flag-vals)))) x))
  (unless endpoint (fail "set --endpoint or LLM_ENDPOINT (OpenAI-compatible /v1/chat/completions URL)" #:code 2))
  (unless model (fail "set --model or LLM_MODEL" #:code 2))
  (unless prompt (fail "usage: odysseus-agent \"your prompt\" [--endpoint URL] [--model M]" #:code 2))
  (define llm (openai-llm #:endpoint endpoint #:model model #:api-key api-key #:tools (all-tool-schemas)))
  (define result
    (run-agent (list (hasheq 'role "system" 'content SYSTEM)
                     (hasheq 'role "user" 'content prompt))
               #:llm llm #:exec (make-exec) #:max-rounds max-rounds))
  (emit (hasheq 'status (symbol->string (agent-result-status result))
                'rounds (agent-result-rounds result)
                'final (final-text result)
                'transcript (map ev->jsexpr (agent-result-transcript result)))
        #:pretty? pretty?))

(module+ main
  (run "odysseus-agent" app-version dispatch))
