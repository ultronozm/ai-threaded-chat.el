;;; ai-org-chat.el --- Threaded chat with AI agent in org buffers  -*- lexical-binding: t; -*-

;; Copyright (C) 2023  Paul D. Nelson

;; Author: Paul D. Nelson <nelson.paul.david@gmail.com>
;; Version: 0.0
;; URL: https://github.com/ultronozm/ai-org-chat.el
;; Package-Requires: ((emacs "29.1") (gptel "0.3.5"))
;; Keywords: convenience, ai, chat

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; This is a simple Emacs package that supports a threaded AI chat
;; inside any org-mode buffer.
;;
;; The "plumbing" is outsourced to the `gptel' library, which requires
;; the user to provide an OpenAI API key, set via the `gptel-api-key'
;; variable.
;;
;; The user is encouraged to bind a key to `ai-org-chat-new' in
;; `global-map' and keys to `ai-org-chat-respond' and
;; `ai-org-chat-append-top-level-heading' in
;; `ai-org-chat-minor-mode-map'.  Here's a sample use-package
;; declaration, which assumes that the API key is set in the
;; OPENAI_API_KEY environment variable:
;; 
;; (use-package exec-path-from-shell
;;   :ensure
;;   :init
;;   (exec-path-from-shell-initialize))
;;   
;; (use-package gptel
;;   :ensure
;;   :after exec-path-from-shell
;;   :config
;;   (setq gptel-api-key (exec-path-from-shell-getenv "OPENAI_API_KEY")))
;;
;; (use-package ai-org-chat
;;   :bind
;;   (:map global-map
;; 	("C-c /" . ai-org-chat-new))
;;   (:map ai-org-chat-minor-mode
;; 	("C-c <return>" . ai-org-chat-respond)
;; 	("C-c n" . ai-org-chat-append-top-level-heading))
;;   :commands (ai-org-chat-minor-mode) ; for manual activation in an org-mode buffer
;;   :custom
;;   (ai-org-chat-user-name "Paul")
;;   (ai-org-chat-dir "~/gpt")
;;   (ai-org-chat-prompt-preamble "You are a brilliant and helpful assistant.")) ; modify to suit your needs
;; 
;; `ai-org-chat-new' creates a new org-mode file (by default, in
;; the directory "~/gpt/"), adds a top-level entry, and activates the
;; minor mode `ai-org-chat-minor-mode'.  If the region is active,
;; then the region contents are added to the top-level entry, enclosed
;; in src blocks if appropriate.
;; 
;; `ai-org-chat-respond' inserts a response from the AI agent as a new
;; heading.  Parent entries are treated as conversation history; they
;; are viewed as responses from the AI when their heading is equal to
;; "AI", and otherwise viewed as user messages.
;; 
;; `ai-org-chat-append-top-level-heading' appends a top-level
;; heading to the current buffer, with the user name as the heading.
;; This has the effect of starting a new top-level chat thread.


;;; Code:

(require 'org)
(require 'gptel)

(defgroup ai-org-chat nil
  "Threaded chat with AI agent in org buffers."
  :group 'hypermedia)

(defcustom ai-org-chat-user-name "User"
  "User name to insert into buffer."
  :type 'string)

(defcustom ai-org-chat-ai-name "AI"
  "AI name to insert into buffer."
  :type 'string
  :group 'ai-org-chat)

(defcustom ai-org-chat-prompt-preamble "You are a brilliant and helpful assistant."
  "Preamble to insert before the prompt."
  :type 'string
  :group 'ai-org-chat)

(defcustom ai-org-chat-dir "~/gpt"
  "Directory for storing files created by `ai-org-chat-new'."
  :type 'string
  :group 'ai-org-chat)

(defcustom ai-org-chat-request-fn #'ai-org-chat--request
  "Function to call to get a response from OpenAI.
MESSAGES and POINT are as in the docstring for
`ai-org-chat--request'.  Modify this if you want to use some
backend other than `gptel'."
  :type 'function
  :group 'ai-org-chat)

(defun ai-org-chat--request (messages point)
  "Use `gptel' library to get a response from OpenAI.
MESSAGES is a list of alists, each of which has a `role' and a
`content' key.  `role' is either \"system\", \"user\" or
\"assistant\" (see the OpenAI API docs).  POINT is a marker
indicating where the response should be inserted."
  (gptel-request
   messages :position point :stream t :in-place t))

(defun ai-org-chat--org-entry-minus-properties (entry)
  "Remove properties drawer (if any) from ENTRY.
ENTRY is text from an `org-mode' entry, excluding the heading and
any subtrees.  The properties drawer is a sequence of lines
delimited by \":PROPERTIES:\" and \":END:\"."
  (let* ((prop-start-re "^[ \t]*:PROPERTIES:[ \t]*$")
         (prop-end-re "^[ \t]*:END:[ \t]*$")
         (lines-without-property-drawer
          (let* ((lines (split-string entry "\n"))
                 (prop-start
                  (cl-position-if
                   (lambda (line) (string-match-p prop-start-re line))
                   lines))
                 (prop-end
                  (when prop-start
                    (cl-position-if
                     (lambda (line) (string-match-p prop-end-re line))
                     lines :from-end t))))
            (if (and prop-start prop-end)
                (append (cl-subseq lines 0 prop-start)
                        (cl-subseq lines (1+ prop-end) (length lines)))
              lines))))
    (mapconcat 'identity (cdr lines-without-property-drawer) "\n")))

(defun ai-org-chat--current-heading-and-body ()
  "Return cons cell with heading and body of current entry.
The heading excludes tags and TODO keywords.  The body consists
of all text between the heading and the first subtree, but
excluding the :PROPERTIES: drawer (if any)."
  (let* ((heading (org-get-heading t t))
	 (content
	  ;; content of current entry, excluding children
	  (save-excursion
	    (org-back-to-heading)
	    (buffer-substring-no-properties
	     (point)
	     (save-excursion
	       (outline-next-heading)
	       (point)))))
	 (body (ai-org-chat--org-entry-minus-properties content)))
    (cons heading body)))

(defun ai-org-chat--get-ancestors ()
  "Return list of ancestors the current entry.
Each ancestor is represented by a cons cell (heading . body),
where heading and body are as in the docstring for
`ai-org-chat--current-heading-and-body'."
  (let ((ancestors '()))
    (push (ai-org-chat--current-heading-and-body) ancestors)
    (save-excursion
      (while (org-up-heading-safe)
        (push (ai-org-chat--current-heading-and-body) ancestors)))
    ancestors))

(defun ai-org-chat--ancestor-messages ()
  "Return list of ancestor messages for the current entry.
Each message is formatted as an alist with `role' and `content'
keys, suitable for passing to `ai-org-chat-request-fn'.
The `role' is either \"user\" or \"assistant\", depending upon
whether the heading is equal to `ai-org-chat-ai-name'.  The
`content' is the body of the heading."
  (mapcar
   (lambda (ancestor)
     (let* ((heading (car ancestor))
	    (content (cdr ancestor))
	    (role (if (equal heading ai-org-chat-ai-name)
		      "assistant" "user")))
       `((role . ,role) (content . ,content))))
   (ai-org-chat--get-ancestors)))

(defun ai-org-chat--new-subtree (heading)
  "Create new subtree with HEADING as heading."
  (org-insert-heading-after-current)
  (org-demote-subtree)
  (insert heading))

;;;###autoload
(defun ai-org-chat-respond ()
  "Insert response from OpenAI after current heading.
Retrieve conversation history via
`ai-org-chat--ancestor-messages', then call
`ai-org-chat-request-fn' to get a response from OpenAI.  The
response is inserted after the next \"AI\" heading and before the
next \"User\" heading."
  (interactive)
  (let ((messages (append
		   `(((role . "system")
		      (content . ,ai-org-chat-prompt-preamble)))
		   (ai-org-chat--ancestor-messages)))
	(point (save-excursion
                 (ai-org-chat--new-subtree ai-org-chat-ai-name)
                 (insert "\n")
		 (save-excursion
                   (ai-org-chat--new-subtree ai-org-chat-user-name))
		 (point-marker))))
    (funcall ai-org-chat-request-fn messages point)))

(define-minor-mode ai-org-chat-minor-mode
  "Toggle ai-org-chat-minor-mode.
With no argument, this command toggles the mode.
Non-null prefix argument turns on the mode.
Null prefix argument turns off the mode."
  :lighter nil
  :keymap (let ((map (make-sparse-keymap)))
	    map))

(defun ai-org-chat-new ()
  "Start new AI chat buffer, possibly with region contents.
If the mark is active, then copy the region contents into the new
buffer, enclosed by an appropriate source block.  Otherwise,
create an empty buffer."
  (interactive)
  (if mark-active
      (ai-org-chat-new-region (region-beginning) (region-end))
    (ai-org-chat-new-empty)))

;;;###autoload
(defun ai-org-chat-new-empty ()
  "Create new AI chat buffer.
Create org buffer with timestamped filename.  Enable
`ai-chat-minor-mode'.  Insert a top-level heading."
  (interactive)
  (let ((dir ai-org-chat-dir)
	(file (format-time-string "gpt-%Y%m%dT%H%M%S.org")))
    (unless (file-directory-p dir)
      (make-directory dir t))
    (let ((path (expand-file-name file dir)))
      (find-file path)))
  (ai-org-chat-minor-mode)
  (ai-org-chat-append-top-level-heading))

(defcustom ai-org-chat-region-filter-functions
  '(ai-org-chat--ensure-trailing-newline
    ai-org-chat--enclose-in-src-block)
  "List of functions to call on quoted region contents.
These functions are applied as preprocessing steps to the region
passed to `ai-org-chat-new-region'.  Each function should accept
two arguments: the region as a string, and the buffer from which
it came.  It should return the processed string."
  :type '(repeat function)
  :group 'ai-org-chat)

(defun ai-org-chat--ensure-trailing-newline (content _buffer)
  "Ensure that CONTENT ends with a newline."
  (if (string-match "\n\\'" content)
      content
    (concat content "\n")))

(defun ai-org-chat--enclose-in-src-block (content buffer)
  "Enclose CONTENT in a src block, if appropriate.
A src block is used if BUFFER's major mode is a programming mode
or `latex-mode'."
  (with-current-buffer buffer
    (if (or (derived-mode-p 'prog-mode)
            (eq major-mode 'latex-mode))
        (let ((mode (replace-regexp-in-string
                     "-mode\\'"
                     ""
                     (symbol-name major-mode))))
          (concat
           (format "#+begin_src %s\n" mode)
           content
           "#+end_src"))
      content)))

;;;###autoload
(defun ai-org-chat-new-region (beg end)
  "Start new AI chat, quoting region between BEG and END.
Send user to an AI chat buffer.  Copy current region contents
into that buffer, applying the filters in the variable
`ai-org-chat-region-filter-functions'."
  (interactive "r")
  (let ((region-contents
         (buffer-substring-no-properties beg end)))
    (dolist (filter ai-org-chat-region-filter-functions)
      (setq region-contents (funcall filter region-contents (current-buffer))))
    (ai-org-chat-new-empty)
    (save-excursion
      (newline 2)
      (insert region-contents))))

;; TODO: modify this to insert heading just below the first AI entry
;; above the current one, or top-level if no such entry exists.

;;;###autoload
(defun ai-org-chat-append-top-level-heading ()
  "Create new chat thread branch."
  (interactive)
  (goto-char (point-max))
  (org-insert-heading t nil t)
  (insert (concat ai-org-chat-user-name))
  ;; (save-excursion (insert "\n"))
  (insert "\n"))

(provide 'ai-org-chat)
;;; ai-org-chat.el ends here