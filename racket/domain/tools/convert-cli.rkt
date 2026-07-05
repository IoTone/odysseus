#lang racket/base

;; convert-cli.rkt — test harness for ci/fidelity-convert.sh. Reads a JSON array
;; of [name, args] cases (args = object or raw string) on argv, runs each through
;; function-call->tool-block, and emits a JSON array of [type, content] (or null).

(require json "convert.rkt")

(module+ main
  (define cases (string->jsexpr (vector-ref (current-command-line-arguments) 0)))
  (define out
    (for/list ([c (in-list cases)])
      (define name (car c))
      (define args (cadr c))
      (define argstr (if (string? args) args (jsexpr->string args)))
      (define tb (function-call->tool-block name argstr))
      (if tb (list (tool-block-type tb) (tool-block-content tb)) 'null)))
  (write-json out)
  (newline))
