;;;; Copyright (c) 2007-2013 Nikodemus Siivola <nikodemus@random-state.net>
;;;; Copyright (c) 2012-2016 Jan Moringen <jmoringe@techfak.uni-bielefeld.de>
;;;;
;;;; Permission is hereby granted, free of charge, to any person
;;;; obtaining a copy of this software and associated documentation files
;;;; (the "Software"), to deal in the Software without restriction,
;;;; including without limitation the rights to use, copy, modify, merge,
;;;; publish, distribute, sublicense, and/or sell copies of the Software,
;;;; and to permit persons to whom the Software is furnished to do so,
;;;; subject to the following conditions:
;;;;
;;;; THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
;;;; EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
;;;; MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
;;;; IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY
;;;; CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,
;;;; TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE
;;;; SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

(cl:in-package #:esrap)

;;;

(eval-when (:compile-toplevel :load-toplevel :execute)
  (defvar *expression-kinds*
    `((character        . (eql character))
      (character-ranges . (cons (eql character-ranges)))
      (string           . (cons (eql string) (cons array-length null)))
      (and              . (cons (eql and)))
      (or               . (cons (eql or)))
      ,@(mapcar (lambda (symbol)
                  `(,symbol . (cons (eql ,symbol) (cons t null))))
                '(not * + ? & !))
      (terminal         . terminal)
      (nonterminal      . nonterminal)
      (predicate        . predicate)
      (function         . (cons (eql function) (cons symbol null)))
      (t                . t))
    "Names and corresponding types of acceptable expression
constructors."))

(eval-when (:compile-toplevel :load-toplevel :execute)
  (defmacro expression-case (expression &body clauses)
    "Similar to

  (cl:typecase EXPRESSION CLAUSES)

but clause heads designate kinds of expressions instead of types. See
*EXPRESSION-KINDS*."
    (let ((available (copy-list *expression-kinds*)))
      (labels ((type-for-expression-kind (kind)
                 (if-let ((cell (assoc kind available)))
                   (progn
                     (removef available cell)
                     (cdr cell))
                   (error "Invalid or duplicate clause: ~S" kind)))
               (process-clause (clause)
                 (destructuring-bind (kind &body body) clause
                   (etypecase kind
                     (cons
                      `((or ,@(mapcar #'type-for-expression-kind kind))
                        ,@body))
                     (symbol
                      `(,(type-for-expression-kind kind)
                         ,@body))))))
        (let ((clauses (mapcar #'process-clause clauses)))
          ;; We did not provide clauses for all expression
          ;; constructors and did not specify a catch-all clause =>
          ;; error.
          (when (and (assoc t available) (> (length available) 1))
            (error "Unhandled expression kinds: ~{~S~^, ~}"
                   (remove t (mapcar #'car available))))
          ;; If we did not specify a catch-all clause, insert one
          ;; which signals INVALID-EXPRESSION-ERROR.
          (once-only (expression)
            `(typecase ,expression
               ,@clauses
               ,@(when (assoc t available)
                   `((t (invalid-expression-error ,expression)))))))))))

(defmacro with-expression ((expr lambda-list) &body body)
  (let* ((type (car lambda-list))
         (car-var (gensym "CAR"))
         (fixed-list (cons car-var (cdr lambda-list))))
    (once-only (expr)
      `(destructuring-bind ,fixed-list ,expr
         ,(if (eq t type)
              `(declare (ignore ,car-var))
              `(unless (eq ',type ,car-var)
                 (error "~S-expression expected, got: ~S" ',type ,expr)))
         (locally ,@body)))))

;;;

(defun check-expression (expression)
  (labels
      ((rec (expression)
         (expression-case expression
           ((character string function terminal nonterminal))
           (character-ranges
            (unless (every (of-type 'character-range) (rest expression))
              (invalid-expression-error expression)))
           ((and or not * + ? & ! predicate)
            (mapc #'rec (rest expression))))))
    (rec expression)))

(defun %expression-dependencies (expression seen)
  (expression-case expression
    ((character string character-ranges function terminal)
     seen)
    (nonterminal
     (if (member expression seen :test #'eq)
         seen
         (let ((rule (find-rule expression))
               (seen (cons expression seen)))
           (if rule
               (%expression-dependencies (rule-expression rule) seen)
               seen))))
    ((and or)
     (dolist (subexpr (cdr expression) seen)
       (setf seen (%expression-dependencies subexpr seen))))
    ((not * + ? & ! predicate)
     (%expression-dependencies (second expression) seen))))

(defun %expression-direct-dependencies (expression seen)
  (expression-case expression
    ((character string character-ranges function terminal)
     seen)
    (nonterminal
     (cons expression seen))
    ((and or)
     (dolist (subexpr (rest expression) seen)
       (setf seen (%expression-direct-dependencies subexpr seen))))
    ((not * + ? & ! predicate)
     (%expression-direct-dependencies (second expression) seen))))

(defun expression-start-terminals (expression)
  "Return a list of terminals or tree of expressions with which a text
   parsable by EXPRESSION can start.

   A tree instead of a list is returned when EXPRESSION contains
   semantic predicates, NOT or !. Elements in the returned list or
   tree are

   * case (in)sensitive characters, character ranges,
     case (in)sensitive strings, function terminals
   * semantic predicates represented as

       (PREDICATE-NAME NESTED-ELEMENTS)

     where NESTED-ELEMENTS is the list of start terminals of the
     expression to which PREDICATE-NAME is applied.
   * NOT and ! expressions are represented as

       ({not,!} NESTED-ELEMENTS)

     where NESTED-ELEMENTS is the list of start terminals of the
     negated expression.

   The (outermost) list is sorted likes this:

   1. string terminals
   2. character terminals
   3. the CHARACTER wildcard terminal
   4. semantic predicates
   5. everything else"
  (labels ((rec (expression seen)
             (expression-case expression
               ((character string character-ranges function terminal)
                (list expression))
               (predicate
                (when-let ((result (rec/sorted (second expression) seen)))
                  (list (list (first expression) result))))
               (nonterminal
                (unless (member expression seen :test #'equal)
                  (when-let ((rule (find-rule expression)))
                    (rec (rule-expression rule) (list* expression seen)))))
               ((not !)
                (when-let ((result (rec/sorted (second expression) seen)))
                  (list (list (first expression) result))))
               ((+ &)
                (rec (second expression) seen))
               ((? *)
                (values (rec (second expression) seen) t))
               (and
                (let ((result '()))
                  (dolist (sub-expression (rest expression) result)
                    (multiple-value-bind (sub-start-terminals optionalp)
                        (rec sub-expression seen)
                      (when sub-start-terminals
                        (appendf result sub-start-terminals)
                        (unless optionalp
                          (return result)))))))
               (or
                (mapcan (rcurry #'rec seen) (rest expression)))))
           (rec/without-duplicates (expression seen)
             (remove-duplicates (rec expression seen) :test #'equal))
           (rec/sorted (expression seen)
             (stable-sort (rec/without-duplicates expression seen)
                          #'expression<)))
    (rec/sorted expression '())))

(defun expression< (left right)
  (or (and (typep left  'string)
           (typep right '(not string)))
      (and (typep left  'string)
           (string-lessp left right))
      (and (typep left  'character)
           (typep right '(not (or string character))))
      (and (typep left  'character)
           (typep right 'character)
           (char-lessp left right))
      (and (typep left  '(eql character))
           (typep left  '(not (eql character))))
      (and (typep left  '(cons predicate-name))
           (typep right '(not (or string character (eql character)
                               (cons predicate-name)))))
      (typep right '(not (or string character (eql character)
                          (cons predicate-name))))))

(defun expression-equal-p (left right)
  (labels ((rec (left right)
             (cond
               ((and (typep left  '(or string character))
                     (typep right '(or string character)))
                (string= left right))
               ((and (consp left) (consp right))
                (and (rec (car left) (car right))
                     (rec (cdr left) (cdr right))))
               (t
                (equalp left right)))))
    (declare (dynamic-extent #'rec))
    (rec left right)))

(defun describe-terminal (terminal &optional (stream *standard-output*))
  "Print a description of TERMINAL onto STREAM.

   In additional to actual terminals, TERMINAL can be of the forms

     (PREDICATE-NAME TERMINALS)
     ({not,!} TERMINALS)

   (i.e. as produced by EXPRESSION-START-TERMINALS)."
  (labels
      ((output (format-control &rest format-arguments)
         (apply #'format stream format-control format-arguments))
       (rec/sub-expression (sub-expression prefix separator)
         (output prefix (length sub-expression))
         (rec (first sub-expression))
         (loop :for terminal :in (rest sub-expression)
            :do (output separator) (rec terminal)))
       (rec (terminal)
         (expression-case terminal
           (character
            (output "any character"))
           (string
            (output "a string of length ~D" (second terminal)))
           (character-ranges
            (output "a character in ~{[~{~C~^-~C~}]~^ or ~}"
                    (mapcar #'ensure-list (rest terminal))))
           (function
            (output "a string that can be parsed by the function ~S"
                    (second terminal)))
           (terminal
            (labels ((rec (thing)
                       (etypecase thing
                         (character
                          ;; For non-graphic or whitespace characters,
                          ;; just print the name.
                          (output "the character ~:[~*~A~:;~A (~A)~]"
                                  (and (graphic-char-p thing)
                                       (not (member thing '(#\Space #\Tab #\Newline))))
                                  thing (char-name thing)))
                         (string
                          (if (length= 1 thing)
                              (rec (char thing 0))
                              (output "the string ~S" thing)))
                         ((cons (eql ~))
                          (rec (second thing))
                          (output ", disregarding case")))))
              (rec terminal)))
           ((not !)
            (let ((sub-expression (second terminal)))
              (typecase sub-expression
                ((cons (eql character) null)
                 (output "<end of input>"))
                (t
                 (output "anything but")
                 (pprint-logical-block (stream sub-expression)
                   (rec/sub-expression
                    sub-expression "~[~; ~:; ~5:T~]" "~@:_ and "))))))
           (predicate
            (let ((sub-expression (second terminal)))
              (pprint-logical-block (stream sub-expression)
                (rec/sub-expression
                 sub-expression "~[~;~:; ~4:T~]" "~@:_ or ")
                (output "~[~; ~:;~@:_~]satisfying ~A"
                        (length sub-expression) (first terminal)))))
           (t
            (error "~@<Not a terminal: ~S~@:>" terminal)))))
    (rec terminal)))

;; For use as ~/esrap:print-terminal/ in format control.
(defun print-terminal (stream terminal &optional colonp atp)
  (declare (ignore colonp atp))
  (describe-terminal terminal stream))