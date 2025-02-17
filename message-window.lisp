;; Copyright (C) 2003-2008 Shawn Betts
;;
;;  This file is part of stumpwm.
;;
;; stumpwm is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 2, or (at your option)
;; any later version.

;; stumpwm is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this software; see the file COPYING.  If not, see
;; <http://www.gnu.org/licenses/>.

;; Commentary:
;;
;; message printing functions
;;
;; Code:

(in-package #:stumpwm)

(export '(echo-string
          err
          message
          gravity-coords
          with-message-queuing
          *queue-messages-p*))

(defgeneric gravity-coords (gravity width height minx miny maxx maxy)
  (:documentation "Get the X and Y coordinates to place something of width WIDTH
and height HEIGHT within an area defined by MINX MINY MAXX and MAXY, guided by
GRAVITY."))

(defmacro define-simple-gravity (name x y)
  "Define a simple gravity calculation of name NAME, where X and Y are one of
:MIN, :MAX or :CENTER."
  `(defmethod gravity-coords ((gravity (eql ,name))
                              (width number) (height number)
                              (minx number) (miny number)
                              (maxx number) (maxy number))
     (declare (ignorable gravity width height minx miny maxx maxy))
     (values ,(ecase x
                (:min 'minx)
                (:max '(- maxx width))
                (:center '(+ minx (truncate (- maxx minx width) 2))))
             ,(ecase y
                (:min 'miny)
                (:max '(- maxy height))
                (:center '(+ miny (truncate (- maxy miny height) 2)))))))

(define-simple-gravity :top-right :max :min)
(define-simple-gravity :top-left :min :min)
(define-simple-gravity :bottom-right :max :max)
(define-simple-gravity :bottom-left :min :max)
(define-simple-gravity :right :max :center)
(define-simple-gravity :left :min :center)
(define-simple-gravity :top :center :min)
(define-simple-gravity :bottom :center :max)
(define-simple-gravity :center :center :center)

(defun message-window-real-gravity (screen)
  "Returns the gravity that should be used when displaying the
message window, taking into account *message-window-gravity*
and *message-window-input-gravity*."
  (if (eq (xlib:window-map-state (screen-input-window screen))
          :unmapped)
      *message-window-gravity*
      *message-window-input-gravity*))

(defun setup-win-gravity (screen win gravity)
  "Position the x, y of the window according to its gravity. This
function expects to be wrapped in a with-state for win."
  (xlib:with-state ((screen-root screen))
    (let* ((w (+ (xlib:drawable-width win)
                 (* (xlib:drawable-border-width win) 2)))
           (h (+ (xlib:drawable-height win)
                 (* (xlib:drawable-border-width win) 2)))
           (head-x (head-x (current-head)))
           (head-y (head-y (current-head)))
           (head-maxx (+ head-x (head-width (current-head))))
           (head-maxy (+ head-y (head-height (current-head)))))
      (multiple-value-bind (x y)
          (gravity-coords gravity w h head-x head-y head-maxx head-maxy)
        (setf (xlib:drawable-y win) (max head-y y)
              (xlib:drawable-x win) (max head-x x))))))

(defun setup-message-window (screen width height)
  (let ((win (screen-message-window screen)))
    ;; Now that we know the dimensions, raise and resize it.
    (xlib:with-state (win)
      (setf (xlib:drawable-height win) (+ height (* *message-window-y-padding* 2))
            (xlib:drawable-width win) (+ width (* *message-window-padding* 2))
            (xlib:window-priority win) :above)
      (setup-win-gravity screen win (message-window-real-gravity screen)))
    (xlib:map-window win)
    (incf (screen-ignore-msg-expose screen))
    ;; Have to flush this or the window might get cleared
    ;; after we've already started drawing it.
    (xlib:display-finish-output *display*)))

(defun unmap-message-window (screen)
  "Unmap the screen's message window, if it is mapped."
  (unless (eq (xlib:window-map-state (screen-message-window screen)) :unmapped)
    (xlib:unmap-window (screen-message-window screen))))

(defun unmap-all-message-windows ()
  (mapc #'unmap-message-window *screen-list*)
  (when (timer-p *message-window-timer*)
    (cancel-timer *message-window-timer*)
    (setf *message-window-timer* nil)))

(defun unmap-frame-indicator-window (screen)
  "Unmap the screen's message window, if it is mapped."
;;  (unless (eq (xlib:window-map-state (screen-frame-window screen)) :unmapped)
    (xlib:unmap-window (screen-frame-window screen)))

(defun unmap-all-frame-indicator-windows ()
  (mapc #'unmap-frame-indicator-window *screen-list*)
  (when (timer-p *frame-indicator-timer*)
    (cancel-timer *frame-indicator-timer*)
    (setf *frame-indicator-timer* nil)))

(defun reset-message-window-timer (timeout-wait)
  "Set the message window timer to timeout in timeout-wait seconds."
  (unless *ignore-echo-timeout*
    (when (timer-p *message-window-timer*)
      (cancel-timer *message-window-timer*))
    (setf *message-window-timer* (run-with-timer timeout-wait nil
                                                 'unmap-all-message-windows))))

(defun reset-frame-indicator-timer ()
  "Set the message window timer to timeout in *timeout-frame-indicator-wait* seconds."
  (when (timer-p *frame-indicator-timer*)
    (cancel-timer *frame-indicator-timer*))
  (setf *frame-indicator-timer* (run-with-timer *timeout-frame-indicator-wait* nil
                                                'unmap-all-frame-indicator-windows)))

(defun show-frame-outline (group &optional (clear t))
  ;; Don't draw if this isn't a current group!
  (when (find group (mapcar 'screen-current-group *screen-list*))
    (dformat 5 "show-frame-outline!~%")
    ;; *resize-hides-windows* uses the frame outlines for display,
    ;; so try not to interfere.
    (unless (eq *top-map* *resize-map*)
      (when clear
        (clear-frame-outlines group))
      (let ((frame (tile-group-current-frame group)))
        (unless (and (= 1 (length (tile-group-frame-tree group)))
                     (atom (first (tile-group-frame-tree group))))
          ;; draw the outline
          (unless (frame-window frame)
            (draw-frame-outline group frame t t)))))))

(defun redraw-frame-outline (group)
  (show-frame-outline group t))

(defun show-frame-indicator (group &optional force)
  (show-frame-outline group)
  ;; FIXME: Arg, these tests are already done in show-frame-outline
  (when (find group (mapcar 'screen-current-group *screen-list*))
    (when (or force
              (and (or (> (length (tile-group-frame-tree group)) 1)
                       (not (atom (first (tile-group-frame-tree group)))))
                   (not *suppress-frame-indicator*)))
      (let ((frame (tile-group-current-frame group))
            (w (screen-frame-window (current-screen)))
            (string (if (stringp *frame-indicator-text*)
                        *frame-indicator-text*
                        (prin1-to-string *frame-indicator-text*)))
            (font (screen-font (current-screen))))
        ;; If it's already mapped it'll appear briefly in the wrong
        ;; place, so unmap it first.
        (xlib:unmap-window w)
        (xlib:with-state (w)
          (setf (xlib:drawable-x w) (+ (frame-display-x group frame)
                                       (truncate (- (frame-width frame) (text-line-width font string)) 2))
                (xlib:drawable-y w) (+ (frame-display-y group frame)
                                       (truncate (- (frame-height frame) (font-height font)) 2))
                (xlib:window-priority w) :above))
        (xlib:map-window w)
        (echo-in-window w font (screen-fg-color (current-screen)) (screen-bg-color (current-screen)) string)
        (reset-frame-indicator-timer)))))


(defun redraw-frame-indicator (group)
  (when (and (timer-p *frame-indicator-timer*)
             (find group (mapcar 'screen-current-group *screen-list*)))
    (let ((frame (tile-group-current-frame group))
          (w (screen-frame-window (current-screen)))
          (string (if (stringp *frame-indicator-text*)
                      *frame-indicator-text*
                    (prin1-to-string *frame-indicator-text*)))
          (font (screen-font (current-screen))))
      (xlib:with-state (w)
                       (setf (xlib:drawable-x w) (+ (frame-display-x group frame)
                                                    (truncate (- (frame-width frame) (text-line-width font string)) 2))
                             (xlib:drawable-y w) (+ (frame-display-y group frame)
                                                    (truncate (- (frame-height frame) (font-height font)) 2))
                             (xlib:window-priority w) :above))
      (xlib:map-window w)
      (echo-in-window w font (screen-fg-color (current-screen)) (screen-bg-color (current-screen)) string))))

(defun echo-in-window (win font fg bg string)
  (let* ((height (font-height font))
         (gcontext (xlib:create-gcontext :drawable win
                                         :font (when (typep font 'xlib:font) font)
                                         :foreground fg
                                         :background bg))
         (width (text-line-width font string)))
    (xlib:with-state (win)
      (setf (xlib:drawable-height win) height
            (xlib:drawable-width win) width))
    (xlib:clear-area win)
    (xlib:display-finish-output *display*)
    (draw-image-glyphs win gcontext font 0
                       (font-ascent font) string :translate #'translate-id :size 16)))

(defun push-last-message (screen strings highlights)
  ;; only push unique messages
  (unless *record-last-msg-override*
    (push strings (screen-last-msg screen))
    (push highlights (screen-last-msg-highlights screen))
    ;; crop for size
    (when (>= (length (screen-last-msg screen)) *max-last-message-size*)
      (setf (screen-last-msg screen) (butlast (screen-last-msg screen)))
      (setf (screen-last-msg-highlights screen) (butlast (screen-last-msg-highlights screen))))))

(defun redraw-current-message (screen)
  (let ((*record-last-msg-override* t)
        (*ignore-echo-timeout* t))
    (dformat 5 "Redrawing message window!~%")
    (apply 'echo-string-list screen (screen-current-msg screen) (screen-current-msg-highlights screen))))

(defun echo-nth-last-message (screen n)
  (let ((*record-last-msg-override* t))
    (apply 'echo-string-list screen (nth n (screen-last-msg screen)) (nth n (screen-last-msg-highlights screen)))))

(defvar *queue-messages-p* nil
  "When non-nil, ECHO-STRING-LIST will retain old messages in addition to new ones.
When the value is :new-on-bottom, new messages are added to the bottom as in a log file.
See also WITH-MESSAGE-QUEUING.")

(defmacro with-message-queuing (new-on-bottom-p &body body)
  "Queue all messages sent by (MESSAGE ...), (ECHO-STRING ...), (ECHO-STRING-LIST ...)
 forms within BODY without clobbering earlier messages.
When NEW-ON-BOTTOM-P is non-nil, new messages are queued at the bottom."
  `(progn
     ;; clear current messages if not already queueing
     (unless *queue-messages-p*
       (setf (screen-current-msg (current-screen)) nil
             (screen-current-msg-highlights (current-screen)) nil))
     (let ((*queue-messages-p* ,(if new-on-bottom-p :new-on-bottom t)))
       ,@body)))

(defun combine-new-old-messages (new new-highlights
                                 old old-highlights &key new-on-bottom-p)
  "combine NEW and OLD messages and their highlights according to NEW-ON-TOP-P"
  (let (top top-highlights bot bot-highlights)
    (if new-on-bottom-p
        ;; new messages added to the bottom, like a log file
        (setf top old top-highlights old-highlights
              bot new bot-highlights new-highlights)
        ;; new messages at the top
        (setf bot old bot-highlights old-highlights
              top new top-highlights new-highlights))
    (values (append top bot)
            (append top-highlights
                    (loop for idx in bot-highlights
                       with offset = (length top)
                       collect (+ idx offset))))))

(defun echo-string-list (screen strings &rest highlights)
  "Draw each string in l in the screen's message window. HIGHLIGHT is
  the nth entry to highlight."
  (when strings
    (when *queue-messages-p*
      (multiple-value-bind (combined-strings combined-highlights)
          (combine-new-old-messages
           strings highlights
           (screen-current-msg screen) (screen-current-msg-highlights screen)
           :new-on-bottom-p (eq *queue-messages-p* :new-on-bottom))
        (setf strings combined-strings
              highlights combined-highlights)))
    (unless *executing-stumpwm-command*
      (multiple-value-bind (width height)
          (rendered-size strings (screen-message-cc screen))
        (setup-message-window screen width height)
        (render-strings (screen-message-cc screen)
                        *message-window-padding*
                        *message-window-y-padding*
                        strings
                        highlights))
      (setf (screen-current-msg screen)
            strings
            (screen-current-msg-highlights screen)
            highlights)
      ;; Set a timer to hide the message after a number of seconds
      (if *suppress-echo-timeout*
          ;; any left over timers need to be canceled.
          (when (timer-p *message-window-timer*)
            (cancel-timer *message-window-timer*)
            (setf *message-window-timer* nil))
          (reset-message-window-timer
            (if (> (length strings) 1)
                (or *timeout-wait-multiline* *timeout-wait*)
                *timeout-wait*))))
    (push-last-message screen strings highlights)
    (xlib:display-finish-output *display*)
    (dformat 5 "Outputting a message:~%~{        ~a~%~}" strings)
    (apply 'run-hook-with-args *message-hook* strings)))

(defun echo-string (screen msg)
  "Display @var{string} in the message bar on @var{screen}. You almost always want to use @command{message}."
  (echo-string-list screen (split-string msg (string #\Newline))))

(defun message (fmt &rest args)
  "run FMT and ARGS through `format' and echo the result to the current screen."
  (echo-string (current-screen) (apply 'format nil fmt args)))


(defun err (fmt &rest args)
  "run FMT and ARGS through format and echo the result to the
current screen along with a backtrace. For careful study, the
message does not time out."
  (let ((*suppress-echo-timeout* t))
    (echo-string (current-screen)
                 (concat (apply 'format nil fmt args)
                         (backtrace-string)))))

(defun message-no-timeout (fmt &rest args)
  "Like message, but the window doesn't disappear after a few seconds."
  (let ((*suppress-echo-timeout* t))
    (apply 'message fmt args)))

;;; Commands

(defvar *lastmsg-nth* nil)

(defcommand lastmsg () ()
  "Display the last message. If the previous command was lastmsg, then
continue cycling back through the message history."
  (if (string= *last-command* "lastmsg")
      (progn
        (incf *lastmsg-nth*)
        (if (>= *lastmsg-nth* (length (screen-last-msg (current-screen))))
            (setf *lastmsg-nth* 0)))
      (setf *lastmsg-nth* 0))
  (if (screen-last-msg (current-screen))
      (echo-nth-last-message (current-screen) *lastmsg-nth*)
      (message "No last message.")))
