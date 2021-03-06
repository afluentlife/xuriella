;;; -*- show-trailing-whitespace: t; indent-tabs-mode: nil -*-

;;; Copyright (c) 2007,2008 David Lichteblau, Ivan Shvedunov.
;;; All rights reserved.

;;; Redistribution and use in source and binary forms, with or without
;;; modification, are permitted provided that the following conditions
;;; are met:
;;;
;;;   * Redistributions of source code must retain the above copyright
;;;     notice, this list of conditions and the following disclaimer.
;;;
;;;   * Redistributions in binary form must reproduce the above
;;;     copyright notice, this list of conditions and the following
;;;     disclaimer in the documentation and/or other materials
;;;     provided with the distribution.
;;;
;;; THIS SOFTWARE IS PROVIDED BY THE AUTHOR 'AS IS' AND ANY EXPRESSED
;;; OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
;;; WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
;;; ARE DISCLAIMED.  IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY
;;; DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
;;; DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE
;;; GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
;;; INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY,
;;; WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING
;;; NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
;;; SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

(in-package :xuriella)

#+sbcl
(declaim (optimize (debug 2)))


(eval-when (:compile-toplevel :load-toplevel :execute)
  (defvar *xsl* "http://www.w3.org/1999/XSL/Transform")
  (defvar *xml* "http://www.w3.org/XML/1998/namespace")
  (defvar *html* "http://www.w3.org/1999/xhtml"))


;;;; XSLT-ERROR

(define-condition xslt-error (simple-error)
  ()
  (:documentation "The class of all XSLT errors."))

(define-condition recoverable-xslt-error (xslt-error)
  ()
  (:documentation "The class of recoverable XSLT errors."))

(defun xslt-error (fmt &rest args)
  "@unexport{}"
  (error 'xslt-error :format-control fmt :format-arguments args))

;; Many errors in XSLT are "recoverable", with a specified action that must
;; be taken if the error isn't raised.  My original plan was to implement
;; such issues as continuable conditions, so that users are alerted about
;; portability issues with their stylesheet, but can contiue anyway.
;;
;; However, our current test suite driver compares against Saxon results,
;; and Saxon recovers (nearly) always.  So our coverage of these errors
;; is very incomplete.
;;
;; Re-enable this code once we can check that it's actually being used
;; everywhere.
(defun xslt-cerror (fmt &rest args)
  (declare (ignore fmt args))
  #+(or)
  (with-simple-restart (recover "recover")
    (error 'recoverable-xslt-error
           :format-control fmt
           :format-arguments args)))

(defvar *debug* nil)

(defmacro handler-case* (form &rest clauses)
  ;; like HANDLER-CASE if *DEBUG* is off.  If it's on, don't establish
  ;; a handler at all so that we see the real stack traces.  (We could use
  ;; HANDLER-BIND here and check at signalling time, but doesn't seem
  ;; important.)
  (let ((doit (gensym)))
    `(flet ((,doit () ,form))
       (if *debug*
           (,doit)
           (handler-case
               (,doit)
             ,@clauses)))))

(defmacro with-resignalled-errors ((&optional) &body body)
  `(invoke-with-resignalled-errors (lambda () ,@body)))

(defun invoke-with-resignalled-errors (fn)
  (handler-bind
      ((xpath:xpath-error
        (lambda (c)
          (xslt-error "~A" c)))
       (babel-encodings:character-encoding-error
        (lambda (c)
          (xslt-error "~A" c))))
    (funcall fn)))

(defmacro with-forward-compatible-errors (error-form &body body)
  `(invoke-with-forward-compatible-errors (lambda () ,@body)
                                          (lambda () ,error-form)))

(defvar *forwards-compatible-p*)

(defun invoke-with-forward-compatible-errors (fn error-fn)
  (let ((result))
    (tagbody
       (handler-bind
           ((xpath:xpath-error
             (lambda (c)
               (declare (ignore c))
               (when *forwards-compatible-p*
                 (go error)))))
         (setf result (funcall fn)))
       (go done)
     error
       (setf result (funcall error-fn))
     done)
    result))

(defun compile-xpath (xpath &optional env)
  (with-resignalled-errors ()
    (with-forward-compatible-errors
        (lambda (ctx)
          (xslt-error "attempt to evaluate an XPath expression with compile-time errors, delayed due to forwards compatible processing: ~A"
                      xpath))
      (xpath:compile-xpath xpath env))))

(defmacro with-stack-limit ((&optional) &body body)
  `(invoke-with-stack-limit (lambda () ,@body)))

(defparameter *without-xslt-current-p* nil)

(defmacro without-xslt-current ((&optional) &body body)
  `(invoke-without-xslt-current (lambda () ,@body)))

(defun invoke-without-xslt-current (fn)
  (let ((*without-xslt-current-p* t))
    (funcall fn)))

;;; (defun invoke-without-xslt-current (fn)
;;;   (let ((non-extensions (gethash "" xpath::*extensions*))
;;;         (xpath::*extensions*
;;;          ;; hide XSLT extensions
;;;          (make-hash-table :test #'equal)))
;;;     (setf (gethash "" xpath::*extensions*) non-extensions)
;;;     (funcall fn)))


;;;; Helper functions and macros

(defun check-for-invalid-attributes (valid-names node)
  (labels ((check-attribute (a)
             (unless
                 (let ((uri (stp:namespace-uri a)))
                   (or (and (plusp (length uri)) (not (equal uri *xsl*)))
                       (find (cons (stp:local-name a) uri)
                             valid-names
                             :test #'equal)))
               (xslt-error "attribute ~A not allowed on ~A"
                           (stp:local-name a)
                           (stp:local-name node)))))
    (stp:map-attributes nil #'check-attribute node)))

(defmacro only-with-attributes ((&rest specs) node &body body)
  (let ((valid-names
         (mapcar (lambda (entry)
                   (if (and (listp entry) (cdr entry))
                       (destructuring-bind (name &optional (uri ""))
                           (cdr entry)
                         (cons name uri))
                       (cons (string-downcase
                              (princ-to-string
                               (symbol-name entry)))
                             "")))
                 specs))
        (%node (gensym)))
    `(let ((,%NODE ,node))
       (check-for-invalid-attributes ',valid-names ,%NODE)
       (stp:with-attributes ,specs ,%NODE
         ,@body))))

(defun map-pipe-eagerly (fn pipe)
  (xpath::enumerate pipe :key fn :result nil))

(defmacro do-pipe ((var pipe &optional result) &body body)
  `(block nil
     (map-pipe-eagerly #'(lambda (,var) ,@body) ,pipe)
     ,result))


;;;; XSLT-ENVIRONMENT and XSLT-CONTEXT

(defparameter *initial-namespaces*
  '((nil . "")
    ("xmlns" . #"http://www.w3.org/2000/xmlns/")
    ("xml" . #"http://www.w3.org/XML/1998/namespace")))

(defparameter *namespaces*
  *initial-namespaces*)

(defvar *global-variable-declarations*)
(defvar *lexical-variable-declarations*)

(defvar *global-variable-values*)
(defvar *lexical-variable-values*)

(defclass xslt-environment () ())

(defun split-qname (str)
  (handler-case
      (multiple-value-bind (prefix local-name)
          (cxml::split-qname str)
        (unless
            ;; FIXME: cxml should really offer a function that does
            ;; checks for NCName and QName in a sensible way for user code.
            ;; cxml::split-qname is tailored to the needs of the parser.
            ;;
            ;; For now, let's just check the syntax explicitly.
            (and (or (null prefix) (xpath::nc-name-p prefix))
                 (xpath::nc-name-p local-name))
          (xslt-error "not a qname: ~A" str))
        (values prefix local-name))
    (cxml:well-formedness-violation ()
      (xslt-error "not a qname: ~A" str))))

(defun decode-qname (qname env attributep &key allow-unknown-namespace)
  (unless qname
    (xslt-error "missing name"))
  (multiple-value-bind (prefix local-name)
      (split-qname qname)
    (values local-name
            (if (or prefix (not attributep))
                (or (xpath-sys:environment-find-namespace env (or prefix ""))
                    (if allow-unknown-namespace
                        nil
                        (xslt-error "namespace not found: ~A" prefix)))
                "")
            prefix)))

(defmethod xpath-sys:environment-find-namespace ((env xslt-environment) prefix)
  (or (cdr (assoc prefix *namespaces* :test 'equal))
      ;; zzz gross hack.
      ;; Change the entire code base to represent "no prefix" as the
      ;; empty string consistently.  unparse.lisp has already been changed.
      (and (equal prefix "")
           (cdr (assoc nil *namespaces* :test 'equal)))
      (and (eql prefix nil)
           (cdr (assoc "" *namespaces* :test 'equal)))))

(defun find-variable-index (local-name uri table)
  (position (cons local-name uri) table :test 'equal))

(defun intern-global-variable (local-name uri)
  (or (find-variable-index local-name uri *global-variable-declarations*)
      (push-variable local-name uri *global-variable-declarations*)))

(defun push-variable (local-name uri table)
  (prog1
      (length table)
    (vector-push-extend (cons local-name uri) table)))

(defun lexical-variable-value (index &optional (errorp t))
  (let ((result (svref *lexical-variable-values* index)))
    (when errorp
      (assert (not (eq result 'unbound))))
    result))

(defun (setf lexical-variable-value) (newval index)
  (assert (not (eq newval 'unbound)))
  (setf (svref *lexical-variable-values* index) newval))

(defun global-variable-value (index &optional (errorp t))
  (let ((result (svref *global-variable-values* index)))
    (when errorp
      (assert (not (eq result 'unbound))))
    result))

(defun (setf global-variable-value) (newval index)
  (assert (not (eq newval 'unbound)))
  (setf (svref *global-variable-values* index) newval))

(defmethod xpath-sys:environment-find-function
    ((env xslt-environment) lname uri)
  (or (if (string= uri "")
          (or (xpath-sys:find-xpath-function lname *xsl*)
              (xpath-sys:find-xpath-function lname uri))
          (xpath-sys:find-xpath-function lname uri))
      (when *forwards-compatible-p*
        (lambda (&rest ignore)
          (declare (ignore ignore))
          (xslt-error "attempt to call an unknown XPath function (~A); error delayed until run-time due to forwards compatible processing"
                      lname)))))

(defmethod xpath-sys:environment-find-variable
    ((env xslt-environment) lname uri)
  (let ((index
         (find-variable-index lname uri *lexical-variable-declarations*)))
    (when index
      (lambda (ctx)
        (declare (ignore ctx))
        (svref *lexical-variable-values* index)))))

(defclass lexical-xslt-environment (xslt-environment) ())

(defmethod xpath-sys:environment-find-variable
    ((env lexical-xslt-environment) lname uri)
  (or (call-next-method)
      (let ((index
             (find-variable-index lname uri *global-variable-declarations*)))
        (when index
          (xslt-trace-thunk
           (lambda (ctx)
             (declare (ignore ctx))
             (svref *global-variable-values* index))
           "global ~s (uri ~s) = ~s" lname uri :result)))))

(defclass key-environment (xslt-environment) ())

(defmethod xpath-sys:environment-find-variable
    ((env key-environment) lname uri)
  (declare (ignore lname uri))
  (xslt-error "disallowed variable reference"))

(defclass global-variable-environment (xslt-environment)
  ((initial-global-variable-thunks
    :initarg :initial-global-variable-thunks
    :accessor initial-global-variable-thunks)))

(defmethod xpath-sys:environment-find-variable
    ((env global-variable-environment) lname uri)
  (or (call-next-method)
      (gethash (cons lname uri) (initial-global-variable-thunks env))))


;;;; TOPLEVEL-TEXT-OUTPUT-SINK
;;;;
;;;; A sink that serializes only text not contained in any element.

(defmacro with-toplevel-text-output-sink ((var) &body body)
  `(invoke-with-toplevel-text-output-sink (lambda (,var) ,@body)))

(defclass toplevel-text-output-sink (sax:default-handler)
  ((target :initarg :target :accessor text-output-sink-target)
   (depth :initform 0 :accessor textoutput-sink-depth)))

(defmethod sax:start-element ((sink toplevel-text-output-sink)
                              namespace-uri local-name qname attributes)
  (declare (ignore namespace-uri local-name qname attributes))
  (incf (textoutput-sink-depth sink)))

(defmethod sax:characters ((sink toplevel-text-output-sink) data)
  (when (zerop (textoutput-sink-depth sink))
    (write-string data (text-output-sink-target sink))))

(defmethod sax:unescaped ((sink toplevel-text-output-sink) data)
  (sax:characters sink data))

(defmethod sax:end-element ((sink toplevel-text-output-sink)
                              namespace-uri local-name qname)
  (declare (ignore namespace-uri local-name qname))
  (decf (textoutput-sink-depth sink)))

(defun invoke-with-toplevel-text-output-sink (fn)
  (with-output-to-string (s)
    (funcall fn (make-instance 'toplevel-text-output-sink :target s))))


;;;; TEXT-FILTER
;;;;
;;;; A sink that passes through only text (at any level) and turns to
;;;; into unescaped characters.

(defclass text-filter (sax:default-handler)
  ((target :initarg :target :accessor text-filter-target)))

(defmethod sax:characters ((sink text-filter) data)
  (sax:unescaped (text-filter-target sink) data))

(defmethod sax:unescaped ((sink text-filter) data)
  (sax:unescaped (text-filter-target sink) data))

(defmethod sax:end-document ((sink text-filter))
  (sax:end-document (text-filter-target sink)))

(defun make-text-filter (target)
  (make-instance 'text-filter :target target))


;;;; ESCAPER
;;;;
;;;; A sink that recovers from sax:unescaped using sax:characters, as per
;;;; XSLT 16.4.

(defclass escaper (cxml:broadcast-handler)
  ())

(defmethod sax:unescaped ((sink escaper) data)
  (sax:characters sink data))

(defun make-escaper (target)
  (make-instance 'escaper :handlers (list target)))


;;;; Names

(defun of-name (local-name)
  (stp:of-name local-name *xsl*))

(defun namep (node local-name)
  (and (typep node '(or stp:element stp:attribute))
       (equal (stp:namespace-uri node) *xsl*)
       (equal (stp:local-name node) local-name)))


;;;; PARSE-STYLESHEET

(defstruct stylesheet
  (modes (make-hash-table :test 'equal))
  (global-variables (make-empty-declaration-array))
  (output-specification (make-output-specification))
  (strip-tests nil)
  (strip-thunk nil)
  (named-templates (make-hash-table :test 'equal))
  (attribute-sets (make-hash-table :test 'equal))
  (keys (make-hash-table :test 'equal))
  (namespace-aliases (make-hash-table :test 'equal))
  (decimal-formats (make-hash-table :test 'equal))
  (initial-global-variable-thunks (make-hash-table :test 'equal)))

(setf (documentation 'stylesheet 'type)
      "The class of stylesheets that have been parsed and compiled.

       Pass instances of this class to @fun{apply-stylesheet} to invoke
       them.

       @see-constructor{parse-stylesheet}")

(defstruct mode
  (templates nil)
  (match-thunk (lambda (ignore) (declare (ignore ignore)) nil)))

(defun find-mode (stylesheet local-name &optional uri)
  (gethash (cons local-name uri) (stylesheet-modes stylesheet)))

(defun ensure-mode (stylesheet &optional local-name uri)
  (or (find-mode stylesheet local-name uri)
      (setf (gethash (cons local-name uri) (stylesheet-modes stylesheet))
            (make-mode))))

(defun ensure-mode/qname (stylesheet qname env)
  (if qname
      (multiple-value-bind (local-name uri)
          (decode-qname qname env nil)
        (ensure-mode stylesheet local-name uri))
      (find-mode stylesheet nil)))

(defun acons-namespaces
    (element &optional (bindings *namespaces*) include-redeclared)
  (map-namespace-declarations (lambda (prefix uri)
                                (push (cons prefix uri) bindings))
                              element
                              include-redeclared)
  bindings)

(defun find-key (name stylesheet)
  (or (gethash name (stylesheet-keys stylesheet))
      (xslt-error "unknown key: ~a" name)))

(defun make-key (match use) (cons match use))

(defun key-match (key) (car key))

(defun key-use (key) (cdr key))

(defun add-key (stylesheet name match use)
  (push (make-key match use)
        (gethash name (stylesheet-keys stylesheet))))

(defvar *excluded-namespaces* (list *xsl*))
(defvar *empty-mode*)
(defvar *default-mode*)

(defvar *xsl-include-stack* nil)

(defun uri-to-pathname (uri)
  (cxml::uri-to-pathname (puri:parse-uri uri)))

;; Why this extra check for literal result element used as stylesheets,
;; instead of a general check for every literal result element?  Because
;; Stylesheet__91804 says so.
(defun check-Errors_err035 (literal-result-element)
  (let ((*namespaces* (acons-namespaces literal-result-element))
        (env (make-instance 'lexical-xslt-environment)))
    (stp:with-attributes ((extension-element-prefixes
                           "extension-element-prefixes"
                           *xsl*))
        literal-result-element
      (dolist (prefix (words (or extension-element-prefixes "")))
        (if (equal prefix "#default")
            (setf prefix nil)
            (unless (cxml-stp-impl::nc-name-p prefix)
              (xslt-error "invalid prefix: ~A" prefix)))
        (let ((uri
               (or (xpath-sys:environment-find-namespace env prefix)
                   (xslt-error "namespace not found: ~A" prefix))))
          (when (equal uri (stp:namespace-uri literal-result-element))
            (xslt-error "literal result element used as stylesheet, but is ~
                         declared as an extension element")))))))

(defun unwrap-2.3 (document)
  (let ((literal-result-element (stp:document-element document))
        (new-template (stp:make-element "template" *xsl*))
        (new-document-element (stp:make-element "stylesheet" *xsl*)))
    (check-Errors_err035 literal-result-element)
    (setf (stp:attribute-value new-document-element "version")
          (or (stp:attribute-value literal-result-element "version" *xsl*)
              (xslt-error "not a stylesheet: root element lacks xsl:version")))
    (setf (stp:attribute-value new-template "match") "/")
    (setf (stp:document-element document) new-document-element)
    (stp:append-child new-document-element new-template)
    (stp:append-child new-template literal-result-element)
    (setf (stp:base-uri new-template) (stp:base-uri literal-result-element))
    new-document-element))

(defun parse-stylesheet-to-stp (input uri-resolver)
  (let* ((d (cxml:parse input (make-text-normalizer (cxml-stp:make-builder))))
         (<transform> (stp:document-element d)))
    (unless (equal (stp:namespace-uri <transform>) *xsl*)
      (setf <transform> (unwrap-2.3 d)))
    (strip-stylesheet <transform>)
    (unless (and (equal (stp:namespace-uri <transform>) *xsl*)
                 (or (equal (stp:local-name <transform>) "transform")
                     (equal (stp:local-name <transform>) "stylesheet")))
      (xslt-error "not a stylesheet"))
    (check-for-invalid-attributes
     '(("version" . "")
       ("exclude-result-prefixes" . "")
       ("extension-element-prefixes" . "")
       ("space" . "http://www.w3.org/XML/1998/namespace")
       ("id" . ""))
     <transform>)
    (let ((invalid
           (or (stp:find-child-if (of-name "stylesheet") <transform>)
               (stp:find-child-if (of-name "transform") <transform>))))
      (when invalid
        (xslt-error "invalid top-level element ~A" (stp:local-name invalid))))
    (dolist (include (stp:filter-children (of-name "include") <transform>))
      (let* ((uri (puri:merge-uris (or (stp:attribute-value include "href")
                                       (xslt-error "include without href"))
                                   (stp:base-uri include)))
             (uri (if uri-resolver
                      (funcall uri-resolver uri)
                      uri))
             (str (puri:render-uri uri nil))
             (pathname
              (handler-case
                  (uri-to-pathname uri)
                (cxml:xml-parse-error (c)
                  (xslt-error "cannot find included stylesheet ~A: ~A"
                              uri c)))))
        (with-open-file
            (stream pathname
                    :element-type '(unsigned-byte 8)
                    :if-does-not-exist nil)
          (unless stream
            (xslt-error "cannot find included stylesheet ~A at ~A"
                        uri pathname))
          (when (find str *xsl-include-stack* :test #'equal)
            (xslt-error "recursive inclusion of ~A" uri))
          (let* ((*xsl-include-stack* (cons str *xsl-include-stack*))
                 (<transform>2 (parse-stylesheet-to-stp stream uri-resolver)))
            (stp:insert-child-after <transform>
                                    (stp:copy <transform>2)
                                    include)
            (stp:detach include)))))
    <transform>))

(defvar *instruction-base-uri*) ;misnamed, is also used in other attributes
(defvar *apply-imports-limit*)
(defvar *import-priority*)
(defvar *extension-namespaces*)

(defmacro do-toplevel ((var xpath <transform>) &body body)
  `(map-toplevel (lambda (,var) ,@body) ,xpath ,<transform>))

(defun map-toplevel (fn xpath <transform>)
  (dolist (node (list-toplevel xpath <transform>))
    (let ((*namespaces* *initial-namespaces*))
      (xpath:do-node-set (ancestor (xpath:evaluate "ancestor::node()" node))
        (xpath:with-namespaces (("" #.*xsl*))
          (when (xpattern:node-matches-p ancestor "stylesheet|transform")
            ;; discard namespaces from including stylesheets
            (setf *namespaces* *initial-namespaces*)))
        (when (xpath-protocol:node-type-p ancestor :element)
          (setf *namespaces* (acons-namespaces ancestor *namespaces* t))))
      (funcall fn node))))

(defun list-toplevel (xpath <transform>)
  (labels ((recurse (sub)
             (let ((subsubs
                    (xpath-sys:pipe-of
                     (xpath:evaluate "transform|stylesheet" sub))))
               (xpath::append-pipes
                (xpath-sys:pipe-of (xpath:evaluate xpath sub))
                (xpath::mappend-pipe #'recurse subsubs)))))
    (xpath::sort-nodes (recurse <transform>))))

(defmacro with-import-magic ((node env) &body body)
  `(invoke-with-import-magic (lambda () ,@body) ,node ,env))

(defun invoke-with-import-magic (fn node env)
  (unless (or (namep node "stylesheet") (namep node "transform"))
    (setf node (stp:parent node)))
  (let ((*excluded-namespaces* (list *xsl*))
        (*extension-namespaces* '())
        (*forwards-compatible-p*
         (not (equal (stp:attribute-value node "version") "1.0"))))
    (parse-exclude-result-prefixes! node env)
    (parse-extension-element-prefixes! node env)
    (funcall fn)))

(defun parse-1-stylesheet (env stylesheet designator uri-resolver)
  (let* ((<transform> (parse-stylesheet-to-stp designator uri-resolver))
         (instruction-base-uri (stp:base-uri <transform>))
         (namespaces (acons-namespaces <transform>))
         (apply-imports-limit (1+ *import-priority*))
         (continuations '()))
    (let ((*namespaces* namespaces))
      (invoke-with-import-magic (constantly t) <transform> env))
    (do-toplevel (elt "node()" <transform>)
      (let ((version (stp:attribute-value (stp:parent elt) "version")))
        (cond
          ((null version)
           (xslt-error "stylesheet lacks version"))
          ((equal version "1.0")
           (if (typep elt 'stp:element)
               (when (or (equal (stp:namespace-uri elt) "")
                         (and (equal (stp:namespace-uri elt) *xsl*)
                              (not (find (stp:local-name elt)
                                         '("key" "template" "output"
                                           "strip-space" "preserve-space"
                                           "attribute-set" "namespace-alias"
                                           "decimal-format" "variable" "param"
                                           "import" "include"
                                           ;; for include handling:
                                           "stylesheet" "transform")
                                         :test #'equal))))
                 (xslt-error "unknown top-level element ~A" (stp:local-name elt)))
               (xslt-error "text at top-level"))))))
    (macrolet ((with-specials ((&optional) &body body)
                 `(let ((*instruction-base-uri* instruction-base-uri)
                        (*namespaces* namespaces)
                        (*apply-imports-limit* apply-imports-limit))
                    ,@body)))
      (with-specials ()
        (do-toplevel (import "import" <transform>)
          (when (let ((prev (xpath:first-node
                             (xpath:evaluate "preceding-sibling::*"
                                             import
                                             t))))
                  (and prev (not (namep prev "import"))))
            (xslt-error "import not at beginning of stylesheet"))
          (let ((uri (puri:merge-uris (or (stp:attribute-value import "href")
                                          (xslt-error "import without href"))
                                      (stp:base-uri import))))
            (push (parse-imported-stylesheet env stylesheet uri uri-resolver)
                  continuations))))
      (let ((import-priority
             (incf *import-priority*))
            (var-cont (prepare-global-variables stylesheet <transform>)))
        (parse-namespace-aliases! stylesheet <transform> env)
        ;; delay the rest of compilation until we've seen all global
        ;; variables:
        (lambda ()
          (mapc #'funcall (nreverse continuations))
          (with-specials ()
            (let ((*import-priority* import-priority))
              (funcall var-cont)
              (parse-keys! stylesheet <transform> env)
              (parse-templates! stylesheet <transform> env)
              (parse-output! stylesheet <transform> env)
              (parse-strip/preserve-space! stylesheet <transform> env)
              (parse-attribute-sets! stylesheet <transform> env)
              (parse-decimal-formats! stylesheet <transform> env))))))))

(defvar *xsl-import-stack* nil)

(defun parse-imported-stylesheet (env stylesheet uri uri-resolver)
  (let* ((uri (if uri-resolver
                  (funcall uri-resolver uri)
                  uri))
         (str (puri:render-uri uri nil))
         (pathname
          (handler-case
              (uri-to-pathname uri)
            (cxml:xml-parse-error (c)
              (xslt-error "cannot find imported stylesheet ~A: ~A"
                          uri c)))))
    (with-open-file
        (stream pathname
                :element-type '(unsigned-byte 8)
                :if-does-not-exist nil)
      (unless stream
        (xslt-error "cannot find imported stylesheet ~A at ~A"
                    uri pathname))
      (when (find str *xsl-import-stack* :test #'equal)
        (xslt-error "recursive inclusion of ~A" uri))
      (let ((*xsl-import-stack* (cons str *xsl-import-stack*)))
        (parse-1-stylesheet env stylesheet stream uri-resolver)))))

(defvar *included-attribute-sets*)

(defvar *stylesheet*)

(defun parse-stylesheet (designator &key uri-resolver)
  "@arg[designator]{an XML designator}
   @arg[uri-resolver]{optional function of one argument}
   @return{An instance of @class{stylesheet}.}

   @short{Parse a stylesheet.}

   This function parses and compiles an XSLT stylesheet.
   The precompiled stylesheet object can then be passed to
   @fun{apply-stylesheet}.

   Also refer to @fun{apply-stylesheet} for details on XML designators."
  (with-resignalled-errors ()
    (xpath:with-namespaces ((nil #.*xsl*))
      (let* ((*import-priority* 0)
             (xpattern:*allow-variables-in-patterns* nil)
             (puri:*strict-parse* nil)
             (stylesheet (make-stylesheet))
             (*stylesheet*
              ;; zzz this is for remove-excluded-namespaces only
              stylesheet)
             (env (make-instance 'lexical-xslt-environment))
             (*excluded-namespaces* *excluded-namespaces*)
             (*global-variable-declarations* (make-empty-declaration-array))
             (*included-attribute-sets* nil))
        (ensure-mode stylesheet nil)
        (funcall (parse-1-stylesheet env stylesheet designator uri-resolver))
        ;; reverse attribute sets:
        (let ((table (stylesheet-attribute-sets stylesheet)))
          (maphash (lambda (k v)
                     (setf (gethash k table) (nreverse v)))
                   table))
        ;; for Errors_err011
        (dolist (sets *included-attribute-sets*)
          (loop for (local-name uri nil) in sets do
               (find-attribute-set local-name uri stylesheet)))
        ;; add default df
        (unless (find-decimal-format "" "" stylesheet nil)
          (setf (find-decimal-format "" "" stylesheet)
                (make-decimal-format)))
        ;; compile a template matcher for each mode:
        (loop
           for mode being each hash-value in (stylesheet-modes stylesheet)
           do
             (setf (mode-match-thunk mode)
                   (xpattern:make-pattern-matcher
                    (mapcar #'template-compiled-pattern
                            (mode-templates mode)))))
        ;; and for the strip tests
        (setf (stylesheet-strip-thunk stylesheet)
              (let ((patterns (stylesheet-strip-tests stylesheet)))
                (and patterns
                     (xpattern:make-pattern-matcher
                      (mapcar #'strip-test-compiled-pattern patterns)))))
        stylesheet))))

(defun parse-attribute-sets! (stylesheet <transform> env)
  (do-toplevel (elt "attribute-set" <transform>)
    (with-import-magic (elt env)
      (push (let* ((sets
                    (mapcar (lambda (qname)
                              (multiple-value-list (decode-qname qname env nil)))
                            (words
                             (stp:attribute-value elt "use-attribute-sets"))))
                   (instructions
                    (stp:map-children
                     'list
                     (lambda (child)
                       (unless
                           (and (typep child 'stp:element)
                                (or (and (equal (stp:namespace-uri child) *xsl*)
                                         (equal (stp:local-name child)
                                                "attribute"))
                                    (find (stp:namespace-uri child)
                                          *extension-namespaces*
                                          :test 'equal)))
                         (xslt-error "non-attribute found in attribute set"))
                       (parse-instruction child))
                     elt))
                   (*lexical-variable-declarations*
                    (make-empty-declaration-array))
                   (thunk
                    (compile-instruction `(progn ,@instructions) env))
                   (n-variables (length *lexical-variable-declarations*)))
              (push sets *included-attribute-sets*)
              (lambda (ctx)
                (with-stack-limit ()
                  (loop for (local-name uri nil) in sets do
                       (dolist (thunk (find-attribute-set local-name uri))
                         (funcall thunk ctx)))
                  (let ((*lexical-variable-values*
                         (make-variable-value-array n-variables)))
                    (funcall thunk ctx)))))
            (gethash (multiple-value-bind (local-name uri)
                         (decode-qname (or (stp:attribute-value elt "name")
                                           (xslt-error "missing name"))
                                       env
                                       nil)
                       (cons local-name uri))
                     (stylesheet-attribute-sets stylesheet))))))

(defun parse-namespace-aliases! (stylesheet <transform> env)
  (do-toplevel (elt "namespace-alias" <transform>)
    (let ((*namespaces* (acons-namespaces elt)))
      (only-with-attributes (stylesheet-prefix result-prefix) elt
        (unless stylesheet-prefix
          (xslt-error "missing stylesheet-prefix in namespace-alias"))
        (unless result-prefix
          (xslt-error "missing result-prefix in namespace-alias"))
        (setf (gethash
               (if (equal stylesheet-prefix "#default")
                   ""
                   (or (xpath-sys:environment-find-namespace
                        env
                        stylesheet-prefix)
                       (xslt-error "stylesheet namespace not found in alias: ~A"
                                   stylesheet-prefix)))
               (stylesheet-namespace-aliases stylesheet))
              (or (xpath-sys:environment-find-namespace
                   env
                   (if (equal result-prefix "#default")
                       ""
                       result-prefix))
                  (xslt-error "result namespace not found in alias: ~A"
                              result-prefix)))))))

(defun parse-decimal-formats! (stylesheet <transform> env)
  (do-toplevel (elt "decimal-format" <transform>)
    (stp:with-attributes (name
                          ;; strings
                          infinity
                          (nan "NaN")
                          ;; characters:
                          decimal-separator
                          grouping-separator
                          zero-digit
                          percent
                          per-mille
                          digit
                          pattern-separator
                          minus-sign)
        elt
      (multiple-value-bind (local-name uri)
          (if name
              (decode-qname name env nil)
              (values "" ""))
        (let ((current (find-decimal-format local-name uri stylesheet nil))
              (new
               (let ((seen '()))
                 (flet ((chr (key x)
                          (when x
                            (unless (eql (length x) 1)
                              (xslt-error "not a single character: ~A" x))
                            (let ((chr (elt x 0)))
                              (when (find chr seen)
                                (xslt-error
                                 "conflicting decimal format characters: ~A"
                                 chr))
                              (push chr seen)
                              (list key chr))))
                        (str (key x)
                          (when x
                            (list key x))))
                   (apply #'make-decimal-format
                          (append (str :infinity infinity)
                                  (str :nan nan)
                                  (chr :decimal-separator decimal-separator)
                                  (chr :grouping-separator grouping-separator)
                                  (chr :zero-digit zero-digit)
                                  (chr :percent percent)
                                  (chr :per-mille per-mille)
                                  (chr :digit digit)
                                  (chr :pattern-separator pattern-separator)
                                  (chr :minus-sign minus-sign)))))))
          (if current
              (unless (decimal-format= current new)
                (xslt-error "decimal format mismatch for ~S" local-name))
              (setf (find-decimal-format local-name uri stylesheet) new)))))))

(defun parse-exclude-result-prefixes! (node env)
  (stp:with-attributes (exclude-result-prefixes)
      node
    (dolist (prefix (words (or exclude-result-prefixes "")))
      (if (equal prefix "#default")
          (setf prefix nil)
          (unless (cxml-stp-impl::nc-name-p prefix)
            (xslt-error "invalid prefix: ~A" prefix)))
      (push (or (xpath-sys:environment-find-namespace env prefix)
                (xslt-error "namespace not found: ~A" prefix))
            *excluded-namespaces*))))

(defun parse-extension-element-prefixes! (node env)
  (stp:with-attributes (extension-element-prefixes)
      node
    (dolist (prefix (words (or extension-element-prefixes "")))
      (if (equal prefix "#default")
          (setf prefix nil)
          (unless (cxml-stp-impl::nc-name-p prefix)
            (xslt-error "invalid prefix: ~A" prefix)))
      (let ((uri
             (or (xpath-sys:environment-find-namespace env prefix)
                 (xslt-error "namespace not found: ~A" prefix))))
        (unless (equal uri *xsl*)
          (push uri *extension-namespaces*)
          (push uri *excluded-namespaces*))))))

(defun parse-nametest-tokens (str)
  (labels ((check (boolean)
             (unless boolean
               (xslt-error "invalid nametest token")))
           (check-null (boolean)
             (check (not boolean))))
    (cons
     :patterns
     (mapcar (lambda (name-test)
               (destructuring-bind (&optional path &rest junk)
                   (cdr (xpattern:parse-pattern-expression name-test))
                 (check-null junk)
                 (check (eq (car path) :path))
                 (destructuring-bind (&optional child &rest junk) (cdr path)
                   (check-null junk)
                   (check (eq (car child) :child))
                   (destructuring-bind (nodetest &rest junk) (cdr child)
                     (check-null junk)
                     (check (or (stringp nodetest)
                                (eq nodetest '*)
                                (and (consp nodetest)
                                     (or (eq (car nodetest) :namespace)
                                         (eq (car nodetest) :qname)))))))
                 path))
             (words str)))))

(defstruct strip-test
  compiled-pattern
  priority
  position
  value)

(defun parse-strip/preserve-space! (stylesheet <transform> env)
  (let ((i 0))
    (do-toplevel (elt "strip-space|preserve-space" <transform>)
      (let ((*namespaces* (acons-namespaces elt))
            (value
             (if (equal (stp:local-name elt) "strip-space")
                 :strip
                 :preserve)))
        (dolist (expression
                  (cdr (parse-nametest-tokens
                        (stp:attribute-value elt "elements"))))
          (let* ((compiled-pattern
                  (car (without-xslt-current ()
                         (xpattern:compute-patterns
                          `(:patterns ,expression)
                          *import-priority*
                          "will set below"
                          env))))
                 (strip-test
                  (make-strip-test :compiled-pattern compiled-pattern
                                   :priority (expression-priority expression)
                                   :position i
                                   :value value)))
            (setf (xpattern:pattern-value compiled-pattern) strip-test)
            (push strip-test (stylesheet-strip-tests stylesheet)))))
      (incf i))))

(defstruct (output-specification
             (:conc-name "OUTPUT-"))
  method
  indent
  omit-xml-declaration
  encoding
  doctype-system
  doctype-public
  cdata-section-matchers
  standalone-p
  media-type)

(defun parse-output! (stylesheet <transform> env)
  (dolist (<output> (list-toplevel "output" <transform>))
    (let ((spec (stylesheet-output-specification stylesheet)))
      (only-with-attributes (version
                             method
                             indent
                             encoding
                             media-type
                             doctype-system
                             doctype-public
                             omit-xml-declaration
                             standalone
                             cdata-section-elements)
          <output>
        (declare (ignore version))
        (when method
          (multiple-value-bind  (local-name uri)
              (decode-qname method env t)
            (setf (output-method spec)
                  (if (plusp (length uri))
                      nil
                      (cond
                        ((equalp local-name "HTML") :html)
                        ((equalp local-name "TEXT") :text)
                        ((equalp local-name "XML") :xml)
                        (t
                         (xslt-error "invalid output method: ~A" method)))))))
        (when indent
          (setf (output-indent spec) indent))
        (when encoding
          (setf (output-encoding spec) encoding))
        (when doctype-system
          (setf (output-doctype-system spec) doctype-system))
        (when doctype-public
          (setf (output-doctype-public spec) doctype-public))
        (when omit-xml-declaration
          (setf (output-omit-xml-declaration spec) omit-xml-declaration))
        (when cdata-section-elements
          (dolist (qname (words cdata-section-elements))
            (decode-qname qname env nil) ;check the syntax
            (push (xpattern:make-pattern-matcher* qname env)
                  (output-cdata-section-matchers spec))))
        (when standalone
          (setf (output-standalone-p spec)
                (boolean-or-error standalone)))
        (when media-type
          (setf (output-media-type spec) media-type))))))

(defun make-empty-declaration-array ()
  (make-array 1 :fill-pointer 0 :adjustable t))

(defun make-variable-value-array (n-lexical-variables)
  (make-array n-lexical-variables :initial-element 'unbound))

(defun compile-global-variable (<variable> env) ;; also for <param>
  (stp:with-attributes (name select) <variable>
    (when (and select (stp:list-children <variable>))
      (xslt-error "variable with select and body"))
    (let* ((*lexical-variable-declarations* (make-empty-declaration-array))
           (inner (cond
                    (select
                     (compile-xpath select env))
                    ((stp:list-children <variable>)
                     (let* ((inner-sexpr `(progn ,@(parse-body <variable>)))
                            (inner-thunk (compile-instruction inner-sexpr env)))
                       (lambda (ctx)
                         (apply-to-result-tree-fragment ctx inner-thunk))))
                    (t
                     (lambda (ctx)
                       (declare (ignore ctx))
                       ""))))
           (n-lexical-variables (length *lexical-variable-declarations*)))
      (xslt-trace-thunk
       (lambda (ctx)
         (let* ((*lexical-variable-values*
                 (make-variable-value-array n-lexical-variables)))
           (funcall inner ctx)))
       "global ~s (~s) = ~s" name select :result))))

(defstruct (variable-chain
             (:constructor make-variable-chain)
             (:conc-name "VARIABLE-CHAIN-"))
  definitions
  index
  local-name
  thunk
  uri)

(defstruct (import-variable
             (:constructor make-variable)
             (:conc-name "VARIABLE-"))
  value-thunk
  value-thunk-setter
  param-p)

(defun parse-global-variable! (stylesheet <variable> global-env)
  (let* ((*namespaces* (acons-namespaces <variable>))
         (instruction-base-uri (stp:base-uri <variable>))
         (*instruction-base-uri* instruction-base-uri)
         (*excluded-namespaces* (list *xsl*))
         (*extension-namespaces* '())
         (qname (stp:attribute-value <variable> "name")))
    (with-import-magic (<variable> global-env)
      (unless qname
        (xslt-error "name missing in ~A" (stp:local-name <variable>)))
      (multiple-value-bind (local-name uri)
          (decode-qname qname global-env nil)
        ;; For the normal compilation environment of templates, install it
        ;; into *GLOBAL-VARIABLE-DECLARATIONS*:
        (let ((index (intern-global-variable local-name uri)))
          ;; For the evaluation of a global variable itself, build a thunk
          ;; that lazily resolves other variables, stored into
          ;; INITIAL-GLOBAL-VARIABLE-THUNKS:
          (let* ((value-thunk :unknown)
                 (sgv (stylesheet-global-variables stylesheet))
                 (chain
                  (if (< index (length sgv))
                      (elt sgv index)
                      (make-variable-chain
                       :index index
                       :local-name local-name
                       :uri uri)))
                 (next (car (variable-chain-definitions chain)))
                 (global-variable-thunk
                  (lambda (ctx)
                    (let ((v (global-variable-value index nil)))
                      (cond
                        ((eq v 'seen)
                         (unless next
                           (xslt-error "no next definition for: ~A"
                                       local-name))
                         (funcall (variable-value-thunk next) ctx))
                        ((eq v 'unbound)
                         (setf (global-variable-value index) 'seen)
                         (setf (global-variable-value index)
                               (funcall value-thunk ctx)))
                        (t
                         v)))))
                 (excluded-namespaces *excluded-namespaces*)
                 (extension-namespaces *extension-namespaces*)
                 (variable
                  (make-variable :param-p (namep <variable> "param")))
                 (forwards-compatible-p *forwards-compatible-p*)
                 (value-thunk-setter
                  (lambda ()
                    (let* ((*instruction-base-uri* instruction-base-uri)
                           (*excluded-namespaces* excluded-namespaces)
                           (*extension-namespaces* extension-namespaces)
                           (*forwards-compatible-p* forwards-compatible-p)
                           (fn
                            (compile-global-variable <variable> global-env)))
                      (setf value-thunk fn)
                      (setf (variable-value-thunk variable) fn)))))
            (setf (variable-value-thunk-setter variable)
                  value-thunk-setter)
            (setf (gethash (cons local-name uri)
                           (initial-global-variable-thunks global-env))
                  global-variable-thunk)
            (setf (variable-chain-thunk chain) global-variable-thunk)
            (push variable (variable-chain-definitions chain))
            chain))))))

(defun parse-keys! (stylesheet <transform> env)
  (xpath:with-namespaces ((nil #.*xsl*))
    (do-toplevel (<key> "key" <transform>)
      (with-import-magic (<key> env)
        (let ((*instruction-base-uri* (stp:base-uri <key>)))
          (only-with-attributes (name match use) <key>
            (unless name (xslt-error "key name attribute not specified"))
            (unless match (xslt-error "key match attribute not specified"))
            (unless use (xslt-error "key use attribute not specified"))
            (multiple-value-bind (local-name uri)
                (decode-qname name env nil)
              (add-key stylesheet
                       (cons local-name uri)
                       (compile-xpath `(xpath:xpath ,(parse-key-pattern match))
                                      env)
                       (compile-xpath use
                                      (make-instance 'key-environment))))))))))

(defun prepare-global-variables (stylesheet <transform>)
  (xpath:with-namespaces ((nil #.*xsl*))
    (let* ((igvt (stylesheet-initial-global-variable-thunks stylesheet))
           (global-env (make-instance 'global-variable-environment
                                      :initial-global-variable-thunks igvt))
           (chains '()))
      (do-toplevel (<variable> "variable|param" <transform>)
        (let ((chain
               (parse-global-variable! stylesheet <variable> global-env)))
          (xslt-trace "parsing global variable ~s (uri ~s)"
                      (variable-chain-local-name chain)
                      (variable-chain-uri chain))
          (when (find chain
                      chains
                      :test (lambda (a b)
                              (and (equal (variable-chain-local-name a)
                                          (variable-chain-local-name b))
                                   (equal (variable-chain-uri a)
                                          (variable-chain-uri b)))))
            (xslt-error "duplicate definition for global variable ~A"
                        (variable-chain-local-name chain)))
          (push chain chains)))
      (setf chains (nreverse chains))
      (let ((table (stylesheet-global-variables stylesheet))
            (newlen (length *global-variable-declarations*)))
        (adjust-array table newlen :fill-pointer newlen)
        (dolist (chain chains)
          (setf (elt table (variable-chain-index chain)) chain)))
      (lambda ()
        ;; now that the global environment knows about all variables, run the
        ;; thunk setters to perform their compilation
        (mapc (lambda (chain)
                (dolist (var (variable-chain-definitions chain))
                  (funcall (variable-value-thunk-setter var))))
              chains)))))


(defstruct template
  match-expression
  compiled-pattern
  name
  import-priority
  apply-imports-limit
  priority
  position
  mode
  mode-qname
  params
  body
  n-variables
  ;; for profiling output only:
  unparsed-qname
  stylesheet
  base-uri)

(defun parse-templates! (stylesheet <transform> env)
  (let ((i 0))
    (do-toplevel (<template> "template" <transform>)
      (let ((*namespaces* (acons-namespaces <template>))
            (*instruction-base-uri* (stp:base-uri <template>)))
        (with-import-magic (<template> env)
          (dolist (template (compile-template <template> env i))
            (setf (template-stylesheet template) stylesheet)
            (setf (template-base-uri template) (stp:base-uri <template>))
            (let ((name (template-name template)))
              (if name
                  (let* ((table (stylesheet-named-templates stylesheet))
                         (head (car (gethash name table))))
                    (when (and head (eql (template-import-priority head)
                                         (template-import-priority template)))
                      ;; fixme: is this supposed to be a run-time error?
                      (xslt-error "conflicting templates for ~A" name))
                    (push template (gethash name table)))
                  (let ((mode (ensure-mode/qname stylesheet
                                                 (template-mode-qname template)
                                                 env)))
                    (setf (template-mode template) mode)
                    (push template (mode-templates mode))))))))
      (incf i))))


;;;; APPLY-STYLESHEET

(deftype xml-designator () '(or runes:xstream runes:rod array stream pathname))

(defun unalias-uri (uri)
  (let ((result
         (gethash uri (stylesheet-namespace-aliases *stylesheet*)
                  uri)))
    (check-type result string)
    result))

(defstruct (parameter
             (:constructor make-parameter (value local-name &optional uri)))
  (uri "")
  local-name
  value)

(setf (documentation 'parameter 'type)
      "The class of top-level parameters to XSLT stylesheets.

       Parameters are identified by expanded names, i.e. a namespace URI
       and local-name.

       Their value is string.

       @see-constructor{make-parameter}
       @see-slot{parameter-uri}
       @see-slot{parameter-local-name}
       @see-slot{parameter-value}")

(setf (documentation 'make-parameter 'function)
      "@arg[value]{The parameter's value, a string.}
       @arg[local-name]{The parameter's local name, a string.}
       @arg[local-name]{The parameter's namespace URI, a string.}
       @return{An instance of @class{parameter}.}

       @short{Creates a paramater.}

       @see{parameter-uri}
       @see{parameter-local-name}
       @see{parameter-value}")

(setf (documentation 'parameter-uri 'function)
      "@arg[instance]{An instance of @class{parameter}.}
       @return{A string}
       @return{Returns the parameter's namespace URI.}

       @see{parameter-local-name}
       @see{parameter-value}")

(setf (documentation 'parameter-local-name 'function)
      "@arg[instance]{An instance of @class{parameter}.}
       @return{A string}
       @return{Returns the parameter's local name.}

       @see{parameter-uri}
       @see{parameter-value}")

(setf (documentation 'parameter-value 'function)
      "@arg[instance]{An instance of @class{parameter}.}
       @return{A string}
       @return{Returns the parameter's value.}

       @see{parameter-uri}
       @see{parameter-local-name}")

(defun find-parameter-value (local-name uri parameters)
  (dolist (p parameters)
    (when (and (equal (parameter-local-name p) local-name)
               (equal (parameter-uri p) uri))
      (return (parameter-value p)))))

(defvar *uri-resolver*)

(defun parse-allowing-microsoft-bom (pathname handler)
  (with-open-file (s pathname :element-type '(unsigned-byte 8))
    (unless (and (eql (read-byte s nil) #xef)
                 (eql (read-byte s nil) #xbb)
                 (eql (read-byte s nil) #xbf))
      (file-position s 0))
    (cxml:parse s handler)))

(defstruct source-document
  id
  root-node
  (indices (make-hash-table)))

(defvar *uri-to-document*)
(defvar *root-to-document*)

(defun %document (uri-string base-uri)
  (let* ((absolute-uri
          (puri:merge-uris uri-string (or base-uri "")))
         (resolved-uri
          (if *uri-resolver*
              (funcall *uri-resolver* absolute-uri)
              absolute-uri))
         (pathname
          (handler-case
              (uri-to-pathname resolved-uri)
            (cxml:xml-parse-error (c)
              (xslt-error "cannot find referenced document ~A: ~A"
                          resolved-uri c))))
         (document (gethash pathname *uri-to-document*)))
    (unless document
      (let ((root-node
             (make-whitespace-stripper
              (handler-case
                  (parse-allowing-microsoft-bom pathname
                                                (stp:make-builder))
                ((or file-error cxml:xml-parse-error) (c)
                  (xslt-error "cannot parse referenced document ~A: ~A"
                              pathname c)))
              (stylesheet-strip-thunk *stylesheet*)))
            (id (hash-table-count *root-to-document*)))
        (setf document (make-source-document :id id :root-node root-node))
        (setf (gethash pathname *uri-to-document*) document)
        (setf (gethash root-node *root-to-document*) document)))
    (when (puri:uri-fragment absolute-uri)
      (xslt-error "use of fragment identifiers in document() not supported"))
    (source-document-root-node document)))

(xpath-sys:define-extension xslt *xsl*)

(defun document-base-uri (node)
  (xpath-protocol:base-uri
   (cond
     ((xpath-protocol:node-type-p node :document)
      (xpath::find-in-pipe-if
       (lambda (x)
         (xpath-protocol:node-type-p x :element))
       (xpath-protocol:child-pipe node)))
     ((xpath-protocol:node-type-p node :element)
      node)
     (t
      (xpath-protocol:parent-node node)))))

(xpath-sys:define-xpath-function/lazy
    xslt :document
    (object &optional node-set)
  (let ((instruction-base-uri *instruction-base-uri*))
    (lambda (ctx)
      (with-profile-counter (*parse-xml-counter*)
        (let* ((object (funcall object ctx))
               (node-set (and node-set (funcall node-set ctx)))
               (base-uri
                (if node-set
                    (document-base-uri (xpath::textually-first-node node-set))
                    instruction-base-uri)))
          (xpath-sys:make-node-set
           (if (xpath:node-set-p object)
               (xpath:map-node-set->list
                (lambda (node)
                  (%document (xpath:string-value node)
                             (if node-set
                                 base-uri
                                 (document-base-uri node))))
                object)
               (list (%document (xpath:string-value object) base-uri)))))))))


(defun build-key-index (document key-conses)
  (let ((index (make-hash-table :test 'equal)))
    (dolist (key key-conses)
      (xpath:do-node-set
          (node
           (xpath:evaluate-compiled (key-match key)
                                    (xpath:make-context
                                     (source-document-root-node document))))
        (let* ((use-result (xpath:evaluate-compiled (key-use key) node))
               (uses (if (xpath:node-set-p use-result)
                         (xpath:all-nodes use-result)
                         (list use-result))))
          (dolist (use uses)
            (push node (gethash (xpath:string-value use) index))))))
    index))

(defun %key (document key-conses value)
  (let* ((indices (source-document-indices document))
         (index (or (gethash key-conses indices)
                    (setf (gethash key-conses indices)
                          (build-key-index document key-conses)))))
    (gethash value index)))

(xpath-sys:define-xpath-function/lazy xslt :key (name object)
  (let ((namespaces *namespaces*))
    (lambda (ctx)
      (let* ((qname (xpath:string-value (funcall name ctx)))
             (object (funcall object ctx))
             (expanded-name
              (multiple-value-bind (local-name uri)
                  (decode-qname/runtime qname namespaces nil)
                (cons local-name uri)))
             (key-conses (find-key expanded-name *stylesheet*)))
        (xpath-sys:make-node-set
         (labels ((get-by-key (value)
                    (%key (node-to-source-document (xpath:context-node ctx))
                          key-conses
                          (xpath:string-value value))))
           (xpath::sort-pipe
            (if (xpath:node-set-p object)
                (xpath::mappend-pipe #'get-by-key (xpath-sys:pipe-of object))
                (get-by-key object)))))))))

;; FIXME: add alias mechanism for XPath extensions in order to avoid duplication

(xpath-sys:define-xpath-function/lazy xslt :current ()
  (when *without-xslt-current-p*
    (xslt-error "current() not allowed here"))
  #'(lambda (ctx)
      (xpath-sys:make-node-set
       (xpath-sys:make-pipe
        (xpath:context-starting-node ctx)
        nil))))

(xpath-sys:define-xpath-function/lazy xslt :unparsed-entity-uri (name)
  #'(lambda (ctx)
      (or (xpath-protocol:unparsed-entity-uri (xpath:context-node ctx)
                                              (funcall name ctx))
          "")))

(defun node-to-source-document (node)
  (gethash (xpath:first-node
            (xpath:evaluate (xpath:xpath (:path (:root :node))) node))
           *root-to-document*))

(defun %get-node-id (node)
  (when (xpath:node-set-p node)
    (setf node (xpath::textually-first-node node)))
  (when node
    (format nil "d~D~A"
            (source-document-id (node-to-source-document node))
            (xpath-sys:get-node-id node))))

(xpath-sys:define-xpath-function/lazy xslt :generate-id (&optional node-set-thunk)
  (if node-set-thunk
      #'(lambda (ctx)
          (%get-node-id (xpath:node-set-value (funcall node-set-thunk ctx))))
      #'(lambda (ctx)
          (%get-node-id (xpath:context-node ctx)))))

(declaim (special *builtin-instructions*))

(xpath-sys:define-xpath-function/lazy xslt :element-available (qname)
  (let ((namespaces *namespaces*)
        (extensions *extension-namespaces*))
    #'(lambda (ctx)
        (let ((qname (funcall qname ctx)))
          (multiple-value-bind (local-name uri)
              (decode-qname/runtime qname namespaces nil)
            (cond
              ((equal uri *xsl*)
               (and (gethash local-name *builtin-instructions*) t))
              ((find uri extensions :test #'equal)
               (and (find-extension-element local-name uri) t))
              (t
               nil)))))))

(xpath-sys:define-xpath-function/lazy xslt :function-available (qname)
  (let ((namespaces *namespaces*))
    #'(lambda (ctx)
        (let ((qname (funcall qname ctx)))
          (multiple-value-bind (local-name uri)
              (decode-qname/runtime qname namespaces nil)
            (and (zerop (length uri))
                 (or (xpath-sys:find-xpath-function local-name *xsl*)
                     (xpath-sys:find-xpath-function local-name uri))
                 t))))))

(xpath-sys:define-xpath-function/lazy xslt :system-property (qname)
  (let ((namespaces *namespaces*))
    (lambda (ctx)
      (let ((qname (xpath:string-value (funcall qname ctx))))
        (multiple-value-bind (local-name uri)
            (decode-qname/runtime qname namespaces nil)
          (if (equal uri *xsl*)
              (cond
                ((equal local-name "version")
                 "1")
                ((equal local-name "vendor")
                 "Xuriella")
                ((equal local-name "vendor-url")
                 "http://repo.or.cz/w/xuriella.git")
                (t
                 ""))
              ""))))))

;; FIXME: should there be separate uri-resolver arguments for stylesheet
;; and data?
(defun apply-stylesheet
    (stylesheet source-designator
     &key output parameters uri-resolver navigator)
  "@arg[stylesheet]{a stylesheet designator (see below for details)}
   @arg[source-designator]{a source document designator (see below for details)}
   @arg[output]{optional output sink designator (see below for details)}
   @arg[parameters]{a list of @class{parameter} instances}
   @arg[uri-resolver]{optional function of one argument}
   @arg[navigator]{optional XPath navigator}
   @return{The value returned by sax:end-document when called on the
     designated output sink.}

   @short{Apply a stylesheet to a document.}

   This function takes @code{stylesheet} (either a parsed @class{stylesheet}
   or a designator for XML file to be parsed) and a source document, specified
   using the XML designator @code{source-designator}, and applies the
   stylesheet to the document.

   An XML designator is any value accepted by @code{cxml:parse}, in particular:
   @begin{ul}
     @item{Pathnames -- The file referred to by the pathname will parsed
       using cxml.}
     @item{Stream -- The stream will be parsed using cxml.}
     @item{Xstream -- Similar to the stream case, but using cxml's internal
       representation of rune streams.}
     @item{String -- The string itself will be parsed as an XML document,
       and is assumed to have been decoded into characters already.}
     @item{Array of (unsigned-byte 8) -- The array itself will be parsed as
       an XML document (which has not been decoded yet).}
   @end{ul}

   Note: Since strings are interpreted as documents, namestrings are
   not acceptable.  Use pathnames instead of namestrings.

   An output sink designator is has the following form:
   @begin{ul}
     @item{Null -- Designates a string sink.  I.e., the result document
       of the stylesheet will be returned as a string.  This as the default.}
     @item{Pathnames -- The file referred to by the pathname will created
       and written to.}
     @item{Stream -- The stream will be written to.}
     @item{SAX or HAX handler -- Events will be sent directly to this sink.}
   @end{ul}

   Note: Specificaton of a sink overrides the specification of XML or HTML
   output method in the styl.sheet.

   Parameters are identified by names, and have values that are strings.
   Top-level parameters of these names are bound accordingly.  If a paramater
   is not specified, its default value is computed as implemented in the
   stylesheet. If parameters are specified that the stylesheet does not
   recognize, they will be ignored.

   A @code{uri-resolver} is a function taking a PURI object as an argument
   and returning a PURI object as a value.  The URI resolver will be invoked
   for all references to external files, e.g. at compilation time using
   xsl:import and xsl:include, and at run-time using the document() function.

   The URI resolver can be used to rewrite URLs so that file http:// links
   are replaced by file:// links, for example.  Another application are
   URI resolvers that signal an error instead of returning, for example
   so that file:// links forbidden.

   The specified @code{navigator} will be passed to XPath protocol functions.

   @see{parse-stylesheet}"
  (with-profile-counter (*apply-stylesheet-counter*)
    (when (typep stylesheet 'xml-designator)
      (with-profile-counter (*parse-stylesheet-counter*)
        (setf stylesheet
              (handler-bind
                  ((cxml:xml-parse-error
                    (lambda (c)
                      (xslt-error "cannot parse stylesheet: ~A" c))))
                (parse-stylesheet stylesheet :uri-resolver uri-resolver)))))
    (with-resignalled-errors ()
      (invoke-with-output-sink
       (lambda ()
         (let* ((*uri-to-document* (make-hash-table :test 'equal))
                (*root-to-document*
                 ;; fixme? should be xpath-protocol:node-equal
                 (make-hash-table :test 'equal))
                (xpath:*navigator* (or navigator :default-navigator))
                (puri:*strict-parse* nil)
                (*stylesheet* stylesheet)
                (*empty-mode* (make-mode))
                (*default-mode* (find-mode stylesheet nil))
                (global-variable-chains
                 (stylesheet-global-variables stylesheet))
                (*global-variable-values*
                 (make-variable-value-array (length global-variable-chains)))
                (*uri-resolver* uri-resolver)
                (source-document
                 (if (typep source-designator 'xml-designator)
                     (with-profile-counter (*parse-xml-counter*)
                       (cxml:parse source-designator (stp:make-builder)))
                     source-designator))
                (xpath-root-node
                 (make-whitespace-stripper
                  source-document
                  (stylesheet-strip-thunk stylesheet)))
                (ctx (xpath:make-context xpath-root-node))
                (document (make-source-document
                           :id 0
                           :root-node xpath-root-node)))
           (when (pathnamep source-designator) ;fixme: else use base uri?
             (setf (gethash source-designator *uri-to-document*) document))
           (setf (gethash xpath-root-node *root-to-document*) document)
           (map nil
                (lambda (chain)
                  (let ((head (car (variable-chain-definitions chain))))
                    (when (variable-param-p head)
                      (let ((value
                             (find-parameter-value
                              (variable-chain-local-name chain)
                              (variable-chain-uri chain)
                              parameters)))
                        (when value
                          (setf (global-variable-value
                                 (variable-chain-index chain))
                                value))))))
                global-variable-chains)
           (map nil
                (lambda (chain)
                  (funcall (variable-chain-thunk chain) ctx))
                global-variable-chains)
           ;; zzz we wouldn't have to mask float traps here if we used the
           ;; XPath API properly.  Unfortunately I've been using FUNCALL
           ;; everywhere instead of EVALUATE, so let's paper over that
           ;; at a central place to be sure:
           (xpath::with-float-traps-masked ()
             (apply-templates ctx :mode *default-mode*))))
       (stylesheet-output-specification stylesheet)
       output))))

(defun find-attribute-set (local-name uri &optional (stylesheet *stylesheet*))
  (or (gethash (cons local-name uri) (stylesheet-attribute-sets stylesheet))
      (xslt-error "no such attribute set: ~A/~A" local-name uri)))

(defun apply-templates/list (list &key param-bindings sort-predicate mode)
  (when sort-predicate
    (setf list
          (mapcar #'xpath:context-node
                  (stable-sort (contextify-node-list list)
                               sort-predicate))))
  (let* ((n (length list))
         (s/d (lambda () n)))
    (loop
       for i from 1
       for child in list
       do
         (apply-templates (xpath:make-context child s/d i)
                          :param-bindings param-bindings
                          :mode mode))))

(defvar *stack-limit* 200)

(defun invoke-with-stack-limit (fn)
  (let ((*stack-limit* (1- *stack-limit*)))
    (unless (plusp *stack-limit*)
      (xslt-error "*stack-limit* reached; stack overflow"))
    (funcall fn)))

(defun invoke-template (ctx template param-bindings)
  (let ((*lexical-variable-values*
         (make-variable-value-array (template-n-variables template))))
    (with-stack-limit ()
      (loop
         for (name-cons value) in param-bindings
         for (nil index nil) = (find name-cons
                                     (template-params template)
                                     :test #'equal
                                     :key #'car)
         do
           (when index
             (setf (lexical-variable-value index) value)))
      (funcall (template-body template) ctx))))

(defun apply-default-templates (ctx mode)
  (let ((node (xpath:context-node ctx)))
    (cond
      ((or (xpath-protocol:node-type-p node :processing-instruction)
           (xpath-protocol:node-type-p node :comment)))
      ((or (xpath-protocol:node-type-p node :text)
           (xpath-protocol:node-type-p node :attribute))
       (write-text (xpath-protocol:node-text node)))
      (t
       (apply-templates/list
        (xpath::force
         (xpath-protocol:child-pipe node))
        :mode mode)))))

(defvar *apply-imports*)

(defun apply-applicable-templates (ctx templates param-bindings finally)
  (labels ((apply-imports (&optional actual-param-bindings)
             (if templates
                 (let* ((this (pop templates))
                        (low (template-apply-imports-limit this))
                        (high (template-import-priority this)))
                   (setf templates
                         (remove-if-not
                          (lambda (x)
                            (<= low (template-import-priority x) high))
                          templates))
                   (if *profiling-enabled-p*
                       (invoke-template/profile ctx this actual-param-bindings)
                       (invoke-template ctx this actual-param-bindings)))
                 (funcall finally))))
    (let ((*apply-imports* #'apply-imports))
      (apply-imports param-bindings))))

(defun apply-templates (ctx &key param-bindings mode)
  (apply-applicable-templates ctx
                              (find-templates ctx (or mode *default-mode*))
                              param-bindings
                              (lambda ()
                                (apply-default-templates ctx mode))))

(defun call-template (ctx name &optional param-bindings)
  (apply-applicable-templates ctx
                              (find-named-templates name)
                              param-bindings
                              (lambda ()
                                (xslt-error "cannot find named template: ~s"
                                            name))))

(defun find-templates (ctx mode)
  (let* ((matching-candidates
          (xpattern:matching-values (mode-match-thunk mode)
                                    (xpath:context-node ctx)))
         (npriorities
          (if matching-candidates
              (1+ (reduce #'max
                          matching-candidates
                          :key #'template-import-priority))
              0))
         (priority-groups (make-array npriorities :initial-element nil)))
    (dolist (template matching-candidates)
      (push template
            (elt priority-groups (template-import-priority template))))
    (loop
       for i from (1- npriorities) downto 0
       for group = (elt priority-groups i)
       for template = (maximize #'template< group)
       when template
       collect template)))

(defun find-named-templates (name)
  (gethash name (stylesheet-named-templates *stylesheet*)))

(defun template< (a b)                  ;assuming same import priority
  (let ((p (template-priority a))
        (q (template-priority b)))
    (cond
      ((< p q) t)
      ((> p q) nil)
      (t
       (xslt-cerror "conflicting templates:~_~A,~_~A"
                    (template-match-expression a)
                    (template-match-expression b))
       (< (template-position a) (template-position b))))))

(defun maximize (< things)
  (when things
    (let ((max (car things)))
      (dolist (other (cdr things))
        (when (funcall < max other)
          (setf max other)))
      max)))

(defun invoke-with-output-sink (fn output-spec output)
  (etypecase output
    (pathname
     (with-open-file (s output
                        :direction :output
                        :element-type '(unsigned-byte 8)
                        :if-exists :rename-and-delete)
       (invoke-with-output-sink fn output-spec s)))
    ((or stream null)
     (invoke-with-output-sink fn
                              output-spec
                              (make-output-sink output-spec output)))
    ((or hax:abstract-handler sax:abstract-handler)
     (with-xml-output output
       (when (typep output '(or combi-sink auto-detect-sink))
         (sax:start-dtd output
                        :autodetect-me-please
                        (output-doctype-public output-spec)
                        (output-doctype-system output-spec)))
       (funcall fn)))))

(defun make-output-sink (output-spec stream)
  (let* ((ystream
          (if stream
              (let ((et (stream-element-type stream)))
                (cond
                  ((or (null et) (subtypep et '(unsigned-byte 8)))
                   (runes:make-octet-stream-ystream stream))
                  ((subtypep et 'character)
                   (runes:make-character-stream-ystream stream))))
              (runes:make-rod-ystream)))
         (omit-xml-declaration-p
          (boolean-or-error (output-omit-xml-declaration output-spec)))
         (sink-encoding (or (output-encoding output-spec) "UTF-8"))
         (sax-target
          (progn
            (setf (runes:ystream-encoding ystream)
                  (cxml::find-output-encoding sink-encoding))
            (make-instance 'cxml::sink
                           :ystream ystream
                           :omit-xml-declaration-p omit-xml-declaration-p
                           :encoding sink-encoding))))
    (flet ((make-combi-sink ()
             (make-instance 'combi-sink
                            :hax-target (make-instance 'chtml::sink
                                                       :ystream ystream)
                            :sax-target sax-target
                            :media-type (output-media-type output-spec)
                            :encoding sink-encoding)))
      (let ((method-key (output-method output-spec)))
        (cond
          ((and (eq method-key :html)
                (null (output-doctype-system output-spec))
                (null (output-doctype-public output-spec)))
           (make-combi-sink))
          ((eq method-key :text)
           (make-text-filter sax-target))
          ((and (eq method-key :xml)
                (null (output-doctype-system output-spec)))
           sax-target)
          (t
           (make-auto-detect-sink (make-combi-sink) method-key)))))))

(defun expression-priority (form)
  (let ((step (second form)))
    (if (and (null (cddr form))
             (listp step)
             (member (car step) '(:child :attribute))
             (null (cddr step)))
        (let ((name (second step)))
          (cond
            ((or (stringp name)
                 (and (consp name)
                      (or (eq (car name) :qname)
                          (eq (car name) :processing-instruction))))
             0.0)
            ((and (consp name)
                  (or (eq (car name) :namespace)
                      (eq (car name) '*)))
             -0.25)
            (t
             -0.5)))
        0.5)))

(defun parse-key-pattern (str)
  (with-resignalled-errors ()
    (with-forward-compatible-errors
        (xpath:parse-xpath "compile-time-error()") ;hack
      (let ((parsed
             (mapcar #'(lambda (item)
                         `(:path (:root :node)
                                 (:descendant-or-self :node)
                                 ,@(cdr item)))
                     (cdr (xpath::parse-pattern-expression str)))))
        (if (null (rest parsed))
            (first parsed)
            `(:union ,@parsed))))))

(defun compile-value-thunk (value env)
  (if (and (listp value) (eq (car value) 'progn))
      (let ((inner-thunk (compile-instruction value env)))
        (lambda (ctx)
          (apply-to-result-tree-fragment ctx inner-thunk)))
      (compile-xpath value env)))

(defun compile-var-binding (name value env)
  (multiple-value-bind (local-name uri)
      (decode-qname name env nil)
    (let ((thunk (xslt-trace-thunk
                  (compile-value-thunk value env)
                  "local variable ~s = ~s" name :result)))
      (list (cons local-name uri)
            (push-variable local-name
                           uri
                           *lexical-variable-declarations*)
            thunk))))

(defun compile-var-bindings (forms env)
  (loop
     for (name value) in forms
     collect (compile-var-binding name value env)))

(defmacro sometimes-with-attributes ((&rest attrs) node &body body)
  (let ((x (gensym)))
    `(let ((,x ,node))
       (if *forwards-compatible-p*
           (stp:with-attributes (,@attrs) ,x ,@body)
           (only-with-attributes (,@attrs) ,x ,@body)))))

(defun compile-template (<template> env position)
  (sometimes-with-attributes (match name priority mode) <template>
    (unless (or name match)
      (xslt-error "missing match in template"))
    (multiple-value-bind (params body-pos)
        (loop
          for i from 0
          for child in (stp:list-children <template>)
          while (namep child "param")
          collect (parse-param child) into params
          finally (return (values params i)))
      (let* ((*lexical-variable-declarations* (make-empty-declaration-array))
             (param-bindings (compile-var-bindings params env))
             (body (parse-body <template> body-pos (mapcar #'car params)))
             (body-thunk (compile-instruction `(progn ,@body) env))
             (outer-body-thunk
              (xslt-trace-thunk
               #'(lambda (ctx)
                   (unwind-protect
                       (progn
                         ;; set params that weren't initialized by apply-templates
                         (loop for (name index param-thunk) in param-bindings
                               when (eq (lexical-variable-value index nil) 'unbound)
                                 do (setf (lexical-variable-value index)
                                          (funcall param-thunk ctx)))
                         (funcall body-thunk ctx))))
               "template: match = ~s name = ~s" match name))
             (n-variables (length *lexical-variable-declarations*)))
        (append
         (when name
           (multiple-value-bind (local-name uri)
               (decode-qname name env nil)
             (list
              (make-template :name (cons local-name uri)
                             :import-priority *import-priority*
                             :apply-imports-limit *apply-imports-limit*
                             :params param-bindings
                             :body outer-body-thunk
                             :n-variables n-variables
                             ;; record unparsed `name' for profiler output:
                             :unparsed-qname name))))
         (when match
           (mapcar (lambda (expression)
                     (let* ((compiled-pattern
                             (xslt-trace-thunk
                              (car (without-xslt-current ()
                                     (xpattern:compute-patterns
                                      `(:patterns ,expression)
                                      42
                                      :dummy
                                      env)))
                              "match-thunk for template (match ~s): ~s --> ~s"
                              match expression :result))
                            (p (if priority
                                   (xpath::parse-xnum priority)
                                   (expression-priority expression)))
                            (p
                             (progn
                               (unless (and (numberp p)
                                            (not (xpath::inf-p p))
                                            (not (xpath::nan-p p)))
                                 (xslt-error "failed to parse priority"))
                               (float p 1.0d0)))
                            (template
                             (make-template :match-expression expression
                                            :compiled-pattern compiled-pattern
                                            :import-priority *import-priority*
                                            :apply-imports-limit *apply-imports-limit*
                                            :priority p
                                            :position position
                                            :mode-qname mode
                                            :params param-bindings
                                            :body outer-body-thunk
                                            :n-variables n-variables)))
                       (setf (xpattern:pattern-value compiled-pattern)
                             template)
                       template))
                   (cdr (xpattern:parse-pattern-expression match)))))))))
#+(or)
(xuriella::parse-stylesheet #p"/home/david/src/lisp/xuriella/test.xsl")
