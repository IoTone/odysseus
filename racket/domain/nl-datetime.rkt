#lang racket/base

;; domain/nl-datetime.rkt — the calendar datetime engine. Ports the slice of
;; routes/calendar_routes.py the agent tools call: _parse_dt (strict ISO +
;; the natural-language phrasings LLMs emit), _parse_dt_pair, and
;; parse_due_for_user.
;;
;; Naive datetimes are represented as SECONDS with the wall-clock fields
;; encoded as UTC (find-seconds … #f) — arithmetic and comparisons then match
;; Python's naive-datetime semantics exactly.
;;
;; Divergences from Python (documented):
;; - No per-request user-timezone context here (chat_routes sets it from
;;   browser headers); parse-due-for-user therefore always takes Python's own
;;   "no user tz known" legacy path: tz-aware ISO preserved with offset,
;;   everything else parsed naive.
;; - No dateutil: formats only its fuzzy parser handles ("Jan 5 2026") raise
;;   the same ValueError text Python raises when dateutil ALSO fails.

(require racket/string
         racket/date
         racket/list)

(provide naive-now-local naive-now-utc
         naive->iso naive->date-iso naive->stamp stamp->naive
         fmt-day fmt-day-time
         parse-dt parse-dt-pair parse-due-for-user)

(define DAY 86400)

;; ---- naive encode/decode ------------------------------------------------------
(define (encode y mo d [h 0] [mi 0] [s 0]) (find-seconds s mi h d mo y #f))
(define (fields secs) (seconds->date secs #f))

(define (naive-now-local)                ; datetime.now() — server wall clock
  (define d (seconds->date (current-seconds) #t))
  (encode (date-year d) (date-month d) (date-day d)
          (date-hour d) (date-minute d) (date-second d)))

(define (naive-now-utc)                  ; datetime.utcnow()
  (current-seconds))

(define (p2 n) (if (< n 10) (format "0~a" n) (number->string n)))

(define (naive->iso secs)                ; datetime.isoformat(), micros omitted
  (define d (fields secs))
  (format "~a-~a-~aT~a:~a:~a" (date-year d) (p2 (date-month d)) (p2 (date-day d))
          (p2 (date-hour d)) (p2 (date-minute d)) (p2 (date-second d))))

(define (naive->date-iso secs)
  (define d (fields secs))
  (format "~a-~a-~a" (date-year d) (p2 (date-month d)) (p2 (date-day d))))

(define (naive->stamp secs)              ; SQLAlchemy DateTime text shape
  (define d (fields secs))
  (format "~a-~a-~a ~a:~a:~a.000000" (date-year d) (p2 (date-month d)) (p2 (date-day d))
          (p2 (date-hour d)) (p2 (date-minute d)) (p2 (date-second d))))

(define (stamp->naive s)                 ; DB text → naive seconds, or #f
  (define m (and (string? s)
                 (regexp-match #px"^(\\d{4})-(\\d{2})-(\\d{2})[ T](\\d{2}):(\\d{2}):(\\d{2})" s)))
  (and m (apply encode (map string->number (cdr m)))))

(define day-names #("Mon" "Tue" "Wed" "Thu" "Fri" "Sat" "Sun"))     ; Python %a, Mon=weekday 0
(define month-names #("Jan" "Feb" "Mar" "Apr" "May" "Jun" "Jul" "Aug" "Sep" "Oct" "Nov" "Dec"))

(define (py-weekday d) (modulo (+ (date-week-day d) 6) 7))          ; Racket Sun=0 → Python Mon=0

(define (fmt-day secs)                   ; strftime("%a %b %d")
  (define d (fields secs))
  (format "~a ~a ~a" (vector-ref day-names (py-weekday d))
          (vector-ref month-names (sub1 (date-month d))) (p2 (date-day d))))

(define (fmt-day-time secs)              ; strftime("%a %b %d %H:%M")
  (define d (fields secs))
  (format "~a ~a:~a" (fmt-day secs) (p2 (date-hour d)) (p2 (date-minute d))))

;; ---- ISO parsing (the fromisoformat subset the callers feed it) ----------------
;; → (values naive-seconds offset-seconds-or-#f) or #f when not ISO.
;; The naive seconds are the LITERAL fields; aware values carry their offset.
(define (iso->naive+offset s0)
  (define s (if (string-suffix? s0 "Z")
                (string-append (substring s0 0 (sub1 (string-length s0))) "+00:00")
                s0))
  (define m (regexp-match
             #px"^(\\d{4})-(\\d{2})-(\\d{2})(?:[T ](\\d{2}):(\\d{2})(?::(\\d{2})(?:\\.\\d{1,6})?)?([+-]\\d{2}:?\\d{2})?)?$"
             s))
  (and m
       (let* ([g (cdr m)]
              [num (lambda (i [d 0]) (if (list-ref g i) (string->number (list-ref g i)) d))]
              [y (num 0)] [mo (num 1)] [dd (num 2)]
              [h (num 3)] [mi (num 4)] [se (num 5)]
              [off (list-ref g 6)])
         (and (<= 1 mo 12) (<= 1 dd 31) (< h 24) (< mi 60) (< se 61)
              (cons (encode y mo dd h mi se)
                    (and off
                         (let* ([sign (if (char=? (string-ref off 0) #\-) -1 1)]
                                [digits (regexp-replace* #px"[+:-]" off "")]
                                [oh (string->number (substring digits 0 2))]
                                [om (string->number (substring digits 2 4))])
                           (* sign (+ (* oh 3600) (* om 60))))))))))

;; ---- time-of-day ("1pm", "1:30 PM", "13:00") → (hour minute) or #f -------------
(define (parse-time-of-day t0)
  (define t (regexp-replace* #px"(?i:\\b([ap])\\s*\\.?\\s*m\\.?\\b)" (string-trim t0) "\\1m"))
  (define m (regexp-match #px"(?i:^\\s*(\\d{1,2})(?::(\\d{2}))?\\s*(am|pm)?\\s*$)" t))
  (and m
       (let* ([h0 (string->number (cadr m))]
              [mn (if (caddr m) (string->number (caddr m)) 0)]
              [ampm (if (cadddr m) (string-downcase (cadddr m)) "")]
              [h (cond [(and (equal? ampm "pm") (< h0 12)) (+ h0 12)]
                       [(and (equal? ampm "am") (= h0 12)) 0]
                       [else h0])])
         (and (< h 24) (< mn 60) (list h mn)))))

(define (midnight-of secs)
  (define d (fields secs))
  (encode (date-year d) (date-month d) (date-day d)))

(define (at-time base hm) (+ (midnight-of base) (* 3600 (car hm)) (* 60 (cadr hm))))

(define weekday-names '("monday" "tuesday" "wednesday" "thursday" "friday" "saturday" "sunday"))

;; ---- _parse_dt: strict ISO, then the NL phrases; raises like Python ------------
(define (parse-dt s0 #:now [now (naive-now-local)])
  (define s (string-trim (or s0 "")))
  (when (string=? s "") (error 'parse-dt "empty datetime string"))
  (define iso (iso->naive+offset s))
  (cond
    [iso (if (cdr iso) (- (car iso) (cdr iso)) (car iso))]   ; aware → UTC naive
    [else
     (define lower (string-downcase s))
     (define today (midnight-of now))
     (or
      ;; today/tonight/tomorrow/yesterday [at] TIME
      (let ([m (regexp-match #px"^(today|tonight|tomorrow|tmrw|yesterday)(?:\\s+at)?\\s*(.*)$" lower)])
        (and m
             (let* ([word (cadr m)] [rest (string-trim (caddr m))]
                    [base (cond [(member word '("tomorrow" "tmrw")) (+ today DAY)]
                                [(equal? word "yesterday") (- today DAY)]
                                [else today])])
               (cond [(string=? rest "") base]
                     [(parse-time-of-day rest) => (lambda (hm) (at-time base hm))]
                     [else #f]))))
      ;; next <weekday> [at] TIME
      (let ([m (regexp-match #px"^next\\s+(\\w+)(?:\\s+at)?\\s*(.*)$" lower)])
        (and m (member (cadr m) weekday-names)
             (let* ([target (- (length weekday-names) (length (member (cadr m) weekday-names)))]
                    [days0 (modulo (- target (py-weekday (fields today))) 7)]
                    [base (+ today (* DAY (if (zero? days0) 7 days0)))]
                    [rest (string-trim (caddr m))])
               (cond [(string=? rest "") base]
                     [(parse-time-of-day rest) => (lambda (hm) (at-time base hm))]
                     [else #f]))))
      ;; in N hours/minutes/days
      (let ([m (regexp-match #px"^in\\s+(\\d+)\\s*(hour|hr|minute|min|day)s?\\s*$" lower)])
        (and m
             (let ([n (string->number (cadr m))] [unit (caddr m)])
               (cond [(member unit '("hour" "hr")) (+ now (* 3600 n))]
                     [(member unit '("minute" "min")) (+ now (* 60 n))]
                     [else (+ now (* DAY n))]))))
      ;; bare time → today at that time
      (let ([hm (parse-time-of-day lower)]) (and hm (at-time today hm)))
      ;; no dateutil fallback — raise Python's exhausted-parser error
      (error 'parse-dt "could not parse datetime: '~a'" s))]))

;; ---- _parse_dt_pair → (values naive-seconds is-utc?) ----------------------------
(define (parse-dt-pair s0 #:now [now (naive-now-local)])
  (define s (string-trim (or s0 "")))
  (when (string=? s "") (error 'parse-dt-pair "empty datetime string"))
  (define iso (iso->naive+offset s))
  (cond
    [(and iso (cdr iso)) (values (- (car iso) (cdr iso)) #t)]   ; aware → naive UTC
    [iso (values (car iso) #f)]
    [else (values (parse-dt s #:now now) #f)]))

;; ---- parse_due_for_user (legacy no-user-tz path) --------------------------------
;; tz-aware ISO → ISO with explicit offset; everything else → naive ISO.
(define (parse-due-for-user s0 #:now [now (naive-now-local)])
  (define s (string-trim (or s0 "")))
  (cond
    [(string=? s "") s]
    [else
     (define iso (iso->naive+offset s))
     (cond
       [(and iso (cdr iso))
        (define off (cdr iso))
        (define sign (if (< off 0) "-" "+"))
        (define a (abs off))
        (format "~a~a~a:~a" (naive->iso (car iso)) sign
                (p2 (quotient a 3600)) (p2 (quotient (remainder a 3600) 60)))]
       [else (naive->iso (parse-dt s #:now now))])]))
