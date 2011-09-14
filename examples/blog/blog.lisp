(in-package "BLOG")

(defparameter *posts-directory* 
  (pathname (concatenate 'string (directory-namestring (truename ".")) "/posts/*.pst")))

(setf *yaws-server-node-name* "jon-VirtualBox")
(setf *cookie-file* "/home/jon/Dropbox/Lisp-on-Yaws/COOKIE")

(defun timestamp ()
  (multiple-value-bind (second minute hour date month year)  
      (decode-universal-time (get-universal-time))
    (format nil "~a/~2,'0d/~2,'0d ~2,'0d:~2,'0d:~2,'0d" year month date hour minute second)))

(defun uuid-string (&optional (uuid (uuid:make-v4-uuid)))
  (with-open-stream (s (make-string-output-stream))
    (uuid:print-bytes s uuid)
    (get-output-stream-string s)))

(defun generate-post-html (universal-time author title body)
  (multiple-value-bind (second minute hour date month year)  (decode-universal-time universal-time)
    (declare (ignore second))
    (let* ((body-string (let ((s (make-string-output-stream))) 
			  (cl-markdown:markdown body :stream s)
			  (get-output-stream-string s)))
	   (date-string (format nil "At ~a/~2,'0d/~2,'0d ~2,'0d:~2,'0d" year month date hour minute))
	   (page (cl-who:with-html-output-to-string (var)
		   (:h2 
		    (:a :href 
			(format nil "/posts/~a_~a.html" author universal-time)
			(cl-who:str title)))
		   (cl-who:str body-string)
		   (:h4 (cl-who:str author))
		   (:h4 (cl-who:str date-string)))))
      (send-static-page "posts" (format nil "~a_~a.html" author universal-time) page))))

(defun read-body (stream &optional (len (file-length stream)))
  (let* ((pos (file-position stream))
	 (body-string (make-string (- len pos))))
    (read-sequence body-string stream)
    body-string))

(defun setredis (key ns val &optional secs)
  (let ((predicated (concatenate 'string ns ":" key)))
    (if secs
	(redis:with-connection ()
	  (first (redis:with-pipelining 
		   (redis:red-set predicated val)
		   (redis:red-expire predicated secs))))
	(redis:with-connection ()
	  (redis:red-set predicated val)))))

(defun getprop (list indicator &optional (default nil))
  (do* ((key (car list) (car rest))
	(val (cadr list) (cadr rest))
	(rest (cddr list) (cddr rest)))
       ((or (string-equal key indicator) (null key)) (or val default))))

(defun getredis (key ns)
  (let ((predicated (concatenate 'string ns ":" key)))
    (redis:with-connection ()
      (redis:red-get predicated))))

(defun hgetredis (key field ns)
  (let ((predicated (concatenate 'string ns ":" key)))
    (redis:with-connection ()
      (redis:red-hget predicated field))))

(defun hsetredis (key field value ns)
  (let ((predicated (concatenate 'string ns ":" key)))
    (redis:with-connection ()
      (redis:red-hset predicated field value))))

(defun hmgetredis (key ns)
  (let ((predicated (concatenate 'string ns ":" key)))
    (redis:with-connection ()
      (redis:red-hgetall predicated))))

(defun hmsetredis (key ns &rest vals)
  (let ((predicated (concatenate 'string ns ":" key)))
    (redis:with-connection ()
      (apply #'redis:red-hmset predicated vals))))



(defun lpushredis (key ns val)
  (let ((predicated (concatenate 'string ns ":" key)))
    (redis:with-connection ()
      (redis:red-lpush predicated val))))

(defun lrangeredis (key ns start end)
  (let ((predicated (concatenate 'string ns ":" key)))
    (redis:with-connection ()
      (redis:red-lrange predicated start end))))

(defsetf getredis (key ns &optional expire) (store)
  (if expire
      `(setredis ,key ,ns ,store ,expire)
      `(setredis ,key ,ns ,store)))

(defvar *pst-ns* "PST")
(defvar *pst-title* "PST-TITLE")
(defvar *pst-idx* "PSTDX")

(defun generate-post-from-file (pst-id)
  (let ((pst-string (getredis pst-id *pst-ns*)))
    (with-input-from-string (post-stream pst-string)
      (let* ((universal-time (read-line post-stream nil :eof nil))
	     (author (read-line post-stream nil :eof nil))
	     (title (getredis pst-id *pst-title*))
	     (time (parse-integer universal-time))
	     (body (read-body post-stream (length pst-string))))
	(generate-post-html time author title body)))))

(defun generate-post-pst-file (title author lines)
  (flet ((write-header (stream author time)
	   (format stream "~a~%~a~%" time author)))
    (let* ((time (get-universal-time))
	   (post-path (format nil "~a_~a" author time)))
      (lpushredis author *pst-idx* time)
      (setf (getredis post-path *pst-title*) title)
      (setf (getredis post-path *pst-ns*)
	    (with-open-stream (stream (make-string-output-stream))
	      (write-header stream author time)
	      (format stream "~a" lines)
	      (get-output-stream-string stream)))
      post-path)))

(defun most-recent-post (author)
  (first (lrangeredis author *pst-idx* 0 0)))

(defun generate-index (author)
  (let ((post-times (lrangeredis author *pst-idx*  0 -1)))
    (let ((index-page 
	   (cl-who:with-html-output-to-string (var)
	     (:ul :class "navbar"
		  (loop for time in post-times
		     do 
		     (let ((link (format nil "/posts/~a_~a.html" author time))) 
		       (clickable-li var (getredis (format nil "~a_~a" author time) *pst-title*)  link "div#blog" ))))
	     (:input :type "hidden" :id "latest" :name "latest" :value (most-recent-post author)))))
      (send-static-page "posts" (format nil "~a_index.html" (hgetredis author "display-name" *settings-ns*))  index-page)
      nil)))


(defvar *salt* (let ((salt (redis:with-connection () (redis:red-get "PASSWORD:SALT"))))
		       (if salt 
			   salt
			   (let ((uuid (uuid-string))) 
			     (redis:with-connection () (redis:red-set "PASSWORD:SALT" uuid))
			     uuid))))

(defvar *site-cookie-name* (uuid-string)) ;;can go into redis later on.

(defun obfuscate-password (password)
  (let* ((salted (concatenate 'string *salt* password)))
    (map 'string #'code-char (md5::MD5SUM-SEQUENCE salted))))

(defvar *password-ns* "PW")
(defvar *settings-ns* "SET")

(defun add-password (name password)
    (setf (getredis (string-downcase name) *password-ns*) (obfuscate-password password)))

(defun check-password (name password)
  (string= (getredis (string-downcase name) *password-ns*) (obfuscate-password password)))

(eval-when (:compile-toplevel :load-toplevel :execute)
  (ps:defpsmacro js-link (link div-id &optional afterfn object)
    (let ((data (gensym)))
      `($.get ,link
	      ,(if object object `(ps:create))
	      (lambda (,data)
		(console.log ,data)
		(ps:chain ($ ,div-id) 
			  (html ,data))
		,@(if afterfn
		      `((,afterfn))
		      ())))))

  (ps:defpsmacro defpostfn (name path 
				 (args1 &body body1) 
				 (args2 &body body2))
    (let ((strings (mapcar #'(lambda (symbol) (string-downcase (symbol-name symbol))) path)))
      (let ((path-name (reduce (lambda (name1 name2)
				 (format nil "~a~a/" name1 name2)) 
			       (cons (format nil "/~a/" (car strings))
				     (cdr strings))))
	    (post-result (gensym)))
	`(defun ,name (,@args1)
	   (let ((,post-result (progn ,@body1)))
	     ($.post 
	      ,path-name
	      ,post-result
	      (lambda (,@args2) ,@body2))))))))
 
(defun named-link (stream link div-id name)
  (cl-who:with-html-output (stream)
    (:a :href "#" :onclick  
	(ps:ps-inline* `(js-link ,link ,div-id))
	(cl-who:str name))))

(defun clickable-li (stream name &rest rest)
  (cl-who:with-html-output (stream)
    (:li :onclick (ps:ps-inline* `(js-link ,@rest))
	 (cl-who:str name))))

(defhandler (blog get ("last_post" author)) (:|content| "application/json")
    (reply (most-recent-post author)))

(defhandler (blog get ("main" author)) (:|html|)
  (setf author (string-downcase author))
  (let ((properties (hmgetredis author *settings-ns*)))
    (reply 
     (cl-who:with-html-output-to-string (var)
       (:html (:head (:title (cl-who:str (getprop properties "title")))
		     (:link :rel "stylesheet" :href "/blog.css"))
	      (:body 
	       (:div :id "header" :class "header"
		     (:div  :id "notify" :class "notify")
		     (:div :id "login" :class "login")
		     (:h1 (cl-who:str (getprop properties "title")))
		     (:h4 (cl-who:str (getprop properties "subtitle"))))

	       (:div :id "index" :class "index")
	       (:div :id "chat" :class "chat")
	       (:div  :id "blog" :class "blog")	     
	  
	       (:div  :id "menu" :class "menu"
		      (:ul
		       (clickable-li var "Add A Post" "/blog/post/new" "div#blog")
		       (clickable-li var
				     "Settings"
				     "/blog/settings"
				     "div#blog" 
				     '(lambda ())
				     '(ps:create :session-id (ps:chain ($ "input#session-id") (val))))
		       (clickable-li var "Edit a Post" "/blog/post/edit" "div#blog")))

	       (:script :src "/jquery.min.js")
	       (let ((link (format nil "/posts/~a_~a.html" author (most-recent-post author))))
		 (cl-who:htm
		  (:script :type "text/javascript"
			   (cl-who:str 
			    (ps:ps* 
			     `(defvar author ,author)
			     `(defun get-init-post ()
				(js-link ,link "div#blog"))
			     `(defun init-login ()
				(let ((session-id (get-cookie ,*site-cookie-name*)))
				  ($.post "/blog/re-auth/" (ps:create :session-id session-id)
					  (lambda (data textstatus qxhr)
					    (if (equal (ps:getprop data 'status) "success")
						(progn
						  (ps:chain ($ "input#session-id") (val session-id))
						  (ps:chain ($ "div#login") 
							    (html 
							     (logged-in-message (ps:getprop data 'user))))
						  (js-link "/blog/chat/" "div#chat" chat-loop-init))
						(js-link "/blog/login/" "div#login"))))))
			     `(defun log-out ()
				(set-cookie ,*site-cookie-name* "" 0)
				(ps:chain ($ "div#chat") (html ""))
				(init-login))

			     `(defun update-index ()
				($.get ,(format nil "/posts/~a_index.html" author)
				       (ps:create)
				       (lambda (data)
					 (ps:chain 
					  ($ "div#index")
					  (html data)))))

			     `(defun check-last-post ()
				($.get ,(format nil "/blog/last_post/~a" author)  
				       (ps:create)
				       (lambda (server-id)
					 (let ((this-id (ps:chain ($ "input#latest") (val))))
					   (unless (equal this-id server-id)
					     (update-index)
					     (ps:chain ($ "input#latest") (val server-id)))))
				       "json"))))

			   (cl-who:str
			    (ps:ps 
			      (ps:chain 
			       ($ document) 
			       (ready
				(lambda ()
				  (init-login)
				  (get-init-post)		  
				  (update-index)
				  (poll-index))))

			      (defun logged-in-message (user)
				(let ((a (concatenate 'string  "Logged In As " user))
				      (b (ps:lisp (cl-who:with-html-output-to-string (s) 
						    :br
						    (:a :href "#" :onclick (ps:ps-inline (log-out)) "Log Out")
						    ))))
					;(console.log a)
					;(console.log b)
				  (concatenate 'string a b)))
			      (defun set-cookie (c-name value exdays)
				(let ((exdate (ps:new (-date))))
				  (ps:chain exdate (set-date (+ (ps:chain exdate (get-Date)) exdays)))
				  (let ((c-val (concatenate 
						'string
						(escape value)
						(if (not exdays)
						    ""
						    (concatenate 
						     'string
						     #.(format nil ";~%expires=")
						     (ps:chain exdate (to-u-t-c-string)))))))
				    (setf (ps:chain document cookie)
					  (concatenate 'string c-name "=" c-val)))))

			      (defun get-cookie (cname)
				(let ((arr-cookies  (ps:chain document cookie (split ";"))))
				  (let (eqlidx x y r) 
				    (do* ((i 0 (+ i 1))
					  (current (ps:getprop arr-cookies i) (ps:getprop arr-cookies i)))
					 ((or (equal r cname) (>= i (ps:chain arr-cookies length)))
					  (if (equal r cname)  y  y))
				      (setf eqlidx (ps:chain current (index-of "=")))
				      (setf x (ps:chain current (substr 0 eqlidx)))
				      (setf y  (ps:chain current (substr (+ eqlidx 1))))
				      (setf r (ps:chain x (replace (ps:regex "/^\s|\s|$/g") "")))))))
				
			      (defun poll-index ()
				(ps:var timer (set-interval "checkLastPost()" 30000))))))
		  (:input :type "hidden" :id "session-id" :name "session-id")))))))))

(defhandler (blog get ("post" "new")) (:|html|)
  (reply (cl-who:with-html-output-to-string (var)
	   (:html (:body
		   (:script :type "text/javascript"
			    (cl-who:str
			     (ps:ps (defpostfn make-post (blog post new)
				      ((session-id title text)
				       (ps:create "session-id" session-id
						  "title" title
						  "post" text))
				      ((data textstatus qxhr)
				       (let ((notify (ps:getprop data 'notify)))
					 (if (equal notify "success")
					     (let* ((most-recent-post (ps:getprop data 'post-id))
						    (user (ps:getprop data 'user))
						    (posts-link (concatenate 'string
									     "/posts/"
									     user  "_" most-recent-post ".html"))
						    (indexes-link (concatenate 'string "/posts/" user "_index.html")))
					       (js-link posts-link "div#blog")
					       (js-link "/blog/chat/" "div#chat" chat-loop-init)
					       (js-link indexes-link "div#index")
					       (ps:chain ($ "div#notify") 
							 (html (concatenate 'string "Post Success!"))))
					     (ps:chain ($ "div#notify") 
						       (html (concatenate 'string "Post Failure!"))))))))))
	 
		   (:B "Not Much Here")		   
		   :br
		   "Title"
		   (:input :type "text" :name "title" :id "title")
		   :br
		   "Text"
		   :br
		   (:textarea :row "6" :cols "60" :name "post-text" :id "post-text")
		   :br
		   (:input :type "submit" :value "Submit" :onclick
			   (ps:ps-inline 
			    (make-post (ps:chain ($ "input#session-id")
						 (val))
				       (ps:chain ($ "input#title")
						 (val))
				       (ps:chain ($ "textarea#post-text")
						 (val))))))))))

(defhandler (blog post ("post" "new")) (:|content| "application/json")
  (let* ((q (parse-query *query*))
	 (session-id (second (assoc "session-id" q :test #'string=)))
	 (title (second (assoc "title" q :test #'string=)))
	 (post (second (assoc "post" q :test #'string=))))
    (let ((user (check-login session-id)))
      (if (and user title post)	
	  (let ((pst-id (generate-post-pst-file title (hgetredis user "display-name" *settings-ns*) post)))
	    (generate-post-from-file pst-id)
	    (generate-index user)
	    (reply (json:encode-json-to-string (list (cons "user" user)
						     (cons "postId" (most-recent-post user))
						     (cons "notify" "success")))))
	    (reply (json:encode-json-to-string (list (cons "user" "")
						     (cons "postId" "")
						     (cons "notify" "failure"))))))))

(defhandler (blog get ("post" "edit")) (:|html|)
  (reply (cl-who:with-html-output-to-string (var))))

(defhandler (blog post ("post" "edit")) (:|content| "application/json"))



(defhandler (blog get ("settings")) (:|html|)
  (let* ((q (parse-query *query*))
	 (session-id (second (assoc "session-id" q :test #'string=))))
    (let ((user (check-login session-id)))
      (if user
	  (let* ((settings (hmgetredis user *settings-ns*)))
	    (let ((title (getprop settings "title" "Title"))
		  (display-name (getprop settings "display-name" user))
		  (subtitle (getprop settings "subtitle" "Subtitle")))

	      (reply (cl-who:with-html-output-to-string (var)
		       (:body
			(:script :type "text/javascript"
				 (cl-who:str 
				  (ps:ps (defpostfn update-settings (blog settings)
					   ((object) object)
					   ((data texstatus qxhr)
					    (let ((status (ps:getprop data 'status)))
					      (if (eql status "success")
						  (ps:chain ($ "div#notify") (html "Settings Updated"))
						  (ps:chain ($ "div#notify") (html "Settings Not Upated")))))))))

			"Display Name" :br
			(:input :type "text" :id "display-name" :name "display-name" :value display-name) :br
			"Title" :br
			(:input :type "text" :id "title" :name "title" :value title) :br
			"Subtitle" :br
			(:input :type "text" :id "subtitle" :name "subtitle" :value subtitle) :br
			(:input 
			 :type "submit"
			 :name "submit"
			 :onclick (cl-who:str (ps:ps-inline (update-settings
							     (ps:create 
							      :session-id 
							      (ps:chain ($ "input#session-id")
									(val))
							      :display-name 
							      (ps:chain ($ "input#display-name")
									(val))
							      :title
							      (ps:chain ($ "input#title")
									(val))
							      :subtitle
							      (ps:chain ($ "input#subtitle")
									(val)))
							     )))
			 :value "Update Settings"))))))
	  (reply "Log In First"))
      )))

(defhandler (blog post ("settings")) (:|content| "application/json")
  (let* ((q (parse-query *query*))
	 (session-id (second (assoc "session-id" q :test #'string=))))
    (format t "~s~%" q)
    (let ((user (check-login session-id)))
      (if user
	  (let ((title (cl-who:escape-string-iso-8859-1(second (assoc "title" q :test #'string=))))
		(subtitle (cl-who:escape-string-iso-8859-1 (second (assoc "subtitle" q :test #'string=))))
		(display-name (cl-who:escape-string-iso-8859-1 (second (assoc "display-name" q :test #'string=)))))
	    (hmsetredis user *settings-ns* "title" title "subtitle" subtitle "display-name" display-name)
	    (reply (json:encode-json-to-string (list (cons "status" "success")))))
	  (reply (json:encode-json-to-string (list (cons "status" "failure"))))))))

(defhandler (blog get ("register")) (:|html|)
  (reply (cl-who:with-html-output-to-string (var)
	   (:html (:title "Registration")
		  (:body (:B "Register to Post and Chat")
			 (:form :action "/blog/register" :method "POST"
				"UserId"
				:br
				(:input :type "text" :name "user")
				:br
				"Password"
				:br
				(:input :type "password" :name "password")
				:br
				"Password Again"
				:br
				(:input :type "password" :name "password2")
				:br
				"Authorization Code"
				:br
				(:input :type "text" :name "auth")
				:br
				(:input :type "submit" :value "Submit")))))))

(defvar *auth-code* "lisp rocks")

(defhandler (blog post ("register")) (:|html|)
  (let*  ((q (parse-query *query*))
	  (auth-code (second (assoc "auth" q :test #'string=)))
	  (user (string-downcase (cl-who:escape-string-iso-8859-1 (second (assoc "user" q :test #'string=)))))
	  (password (second (assoc "password" q :test #'string=)))
	  (password2 (second (assoc "password2" q :test #'string=)))
	  (auth-code-valid (and auth-code (string= auth-code *auth-code*))))
    (cond 
      ((or (getredis user *password-ns*)
	   (< (length user) 3))
       (reply (cl-who:with-html-output-to-string (var)
		(:html (:body (:B "Name already taken or name must be at least 3 characters")
			      :br (:b (:a :href "/blog/register" "Try Again")))))))
      ((and (string= password password2) auth-code-valid)
       (add-password user password)
       (hmsetredis user *settings-ns* "title" "Your Title Here" "subtitle" "Go To Settings to Change Title" "display-name" user)
       (reply (format nil "/blog/main/~a" user) :|redirect|))
      (T (reply (cl-who:with-html-output-to-string (var)
		  (:html (:body (:B "Passwords do not match")
				:br (:b (:a :href "/blog/register" "Try Again"))))))))))

(defhandler (blog get ("login")) (:|html|)
  (reply (cl-who:with-html-output-to-string (stream)
	   (:body 
	    (:script 
	     :type "text/javascript" 
	     (cl-who:str
	      (ps:ps
		(defpostfn login (blog login)
		  ((user password) 
		   (ps:create "user" user "password" password))
		  ((data texstatus qxhr)
		   (let ((expires (ps:getprop data 'expires))
			 (cookie-id (ps:getprop data 'cookie-id))
			 (session-id (ps:getprop data 'session-id))
			 (user2 (ps:getprop data 'user)))
		       (ps:chain ($ "input#session-id") (val session-id))
		       (set-cookie cookie-id session-id expires)
		       (let ((b (logged-in-message user2)))
			 (console.log b)
		       (ps:chain ($ "div#login") (html b)))
		       (js-link "/blog/chat/" "div#chat" chat-loop-init)))))))
	    "Login Name"
	    :br
	    (:input :type "text" :id "user" :name "user") :br
	    "Password"
	    :br
	    (:input :type "password" :id "password" :name "password") :br
	    (:input :type "submit" :value "Login" :onclick 
		    (ps:ps-inline (login
				   (ps:chain ($ "input#user")
					     (val))
				   (ps:chain ($ "input#password")
					     (val)))))
	    :br 
	    "Don't Have an Account? " 
	    (named-link stream "/blog/register/" "div#blog" "Register")
	    ))))

(defvar *login-cookie-ns* "LC")

(defvar *expire-days* 1)
(defvar *login-timeout* (* *expire-days* 24 60 60))


(defun create-login (user password)
  (when (check-password user password)
    (let* ((uuid (uuid-string)))
      (setf (getredis uuid *login-cookie-ns* *login-timeout*) (string-downcase user))
      uuid)))

(defun check-login (uuid)
  (let ((user (getredis uuid *login-cookie-ns*)))
    (when user
      (setf (getredis uuid *login-cookie-ns* *login-timeout*) user) user)))

(defhandler (blog post ("login")) (:|content| "application/json")
  (let ((q (parse-query *query*)))
    (let ((user (string-downcase (cl-who:escape-string-iso-8859-1 (second (assoc "user" q  :test #'string=)))))
	  (password (second (assoc "password" q :test #'string=))))
      (let ((uuid (create-login user password)))
	(if uuid 
	    (reply (json:encode-json-to-string (list 
						(cons "expires" *expire-days*)
						(cons "cookieId" *site-cookie-name*)
						(cons "postId" (most-recent-post user))
						(cons "sessionId" uuid)
						(cons "user" (hgetredis user "display-name" *settings-ns*)))))
	    (reply "error"))))))

(defhandler (blog post ("re-auth")) (:|content| "application/json")
  (let ((q (parse-query *query*)))
    (let ((session-id (second (assoc "session-id" q :test #'string=))))
      (let ((logged-in? (check-login session-id)))
	(if logged-in?
	    (reply (json:encode-json-to-string (list (cons "user" logged-in?)
						     (cons "status" "success"))))
	    (reply (json:encode-json-to-string (list (cons "user" "")
						     (cons "status" "failure")))))))))


(defvar *chat-ns* "chat")
(let ((chat-reply-table (make-hash-table :test  #'equalp :synchronized t)))

  (defun get-chat-text (user &optional (chat-length 20))
    (let ((text-list (lrangeredis user *chat-ns* 0 chat-length)))
      (apply #'concatenate 'string (nreverse text-list))))

  (defun set-chat-text (user string)
    (lpushredis user *chat-ns* string)
    (reply-chat user))

  (defun queue-request (user) 
    (sb-ext:with-locked-hash-table (chat-reply-table)
      (push (get-reply-information) (gethash user chat-reply-table nil))))

  (defun reply-chat (user)
    (let ((chat-reply-list (sb-ext:with-locked-hash-table (chat-reply-table)
			     (prog1 (gethash user chat-reply-table)
			       (setf (gethash user chat-reply-table) nil)))))
      (let ((text (get-chat-text user)))
	(reply-all text  chat-reply-list :|html|)))))

(defhandler (blog get ("chat")) (:|html|)
  (reply (cl-who:with-html-output-to-string (val)
	   (:html (:body 
		   (:script :type "text/javascript" 
			    (cl-who:str
			     (ps:ps
			       (defun chat-loop-init ()
				 ($.get (concatenate 'string "/blog/chat/instant/" author)
					(ps:create :session-id 
						   (ps:chain ($ "input#session-id")
							     (val)))
					(lambda (data)
					  (ps:chain ($ "div#chatwindow")
						    (html data))
					  (chat-loop))))
			       (defun chat-loop ()
				 ($.get (concatenate 'string "/blog/chat/wait/" author)
					(ps:create :session-id 
						   (ps:chain ($ "input#session-id")
							     (val)))
					(lambda (data)
					  (ps:chain ($ "div#chatwindow") 
						    (html data))
					  (chat-loop))))
			       
			       (defun chat-history (start end)
				 ($.get (concatenate 'string "/blog/chat/history/" author)
					(ps:create :session-id (ps:chain ($ "input#session-id") (val))
						   :start start
						   :end end)
					(lambda (data)
					  (let ((status (ps:getprop data 'status)))
					    (if (eql status "success")
						(let ((result (ps:getprop data 'result)))
						  (ps:chain ($ "div#blog")
							    (html result))))))))

			       (defun key-stroke-update (event)
				 (if (or (= (ps:chain event char-code) 13)
					 (= (ps:chain event key-code) 13))
				     (post)))

			       (defun post () 
				 ($.post
				  (concatenate 'string "/blog/chat/p/" author)
				  (ps:create 
				   :message 
				   (ps:chain 
				    ($ "input#message")
				    (val))
				   :session-id
				   (ps:chain 
				    ($ "input#session-id")
				    (val))))
				 (ps:chain ($ "input#message") (val ""))))))
		   (:a :href "#" :onclick (ps:ps-inline (chat-history 0 20)) "history")
		   (:div :id "chatwindow")
		   :br
		   "Message: "
		   (:input 
		    :id "message"
		    :type "text"
		    :name "message"
		    :onkeypress (ps:ps-inline (key-stroke-update event)))
		   :br
		   (:input :type "submit" 
			   :value "Send"
			   :onclick (ps:ps-inline 
				     (post))))))))

(defhandler (blog get ("chat" "wait" author)) (:|html|)
  (let* ((q (parse-query *query*))
	 (session-id (second (assoc "session-id" q :test #'string=))))
    (when (check-login session-id)
      (queue-request author))))

(defhandler (blog get ("chat" "instant" author)) (:|html|)
  (let* ((q (parse-query *query*))
	 (session-id (second (assoc "session-id" q :test #'string=))))
    (when (check-login session-id)
      (reply (get-chat-text author)))))

(defhandler (blog get ("chat" "history" author)) (:|content| "application/json")
  (let* ((q (parse-query *query*))
	 (session-id (second (assoc "session-id" q :test #'string=)))
	 (start (parse-integer (second (assoc "start" q :test #'string=)) :junk-allowed t))
	 (end (parse-integer (second (assoc "end" q :test #'string=)) :junk-allowed t)))
    (if (and (check-login session-id) start end)
	(reply (json:encode-json-to-string 
		(list (cons "status" "success")
		      (cons "result"
			    (cl-who:with-html-output-to-string (var)
			      (when (>= start 20) 
				(cl-who:htm (:a :href "#" :onclick (ps:ps-inline* `(chat-history 
										    ,(- start 20)
										    ,(- end 20))) "Newer")
					    (cl-who:str " ")))
			      (cl-who:htm (:a :href "#" :onclick (ps:ps-inline* `(chat-history
										  ,(+ start 20)
										  ,(+ end 20))) "Older") :br)

			      (cl-who:str (apply #'concatenate 'string (nreverse (lrangeredis author *chat-ns* start end)))))))))
	(reply (json:encode-json-to-string (list (cons "status" "failure")))))))
			      

(defhandler (blog post ("chat" "p" author)) (:|html|)
  (reply "")
  (let* ((q (parse-query *query*))
	 (session-id (second (assoc "session-id" q :test #'string=)))
	 (message (second (assoc "message" q :test #'string=))))
    (let ((name (check-login session-id)))
      (when (and name message)
	(set-chat-text author (cl-who:with-html-output-to-string (str)
				(cl-who:str (timestamp)) " " 
				(:a :href (format nil "/blog/main/~a" name) 
				    (cl-who:str (format nil "~a:" (hgetredis name "display-name" *settings-ns*))))
				" "
				(cl-who:str (cl-who:escape-string-iso-8859-1  message))
				:br))))))

(defun blog-main ()
  (init-server-connection)
  (generate-appmods))