;;; my-net.el --- Gnus and mail configuration. -*- lexical-binding: t; -*-

;;; Commentary:
;;; Code:

(require 'cl-lib)

(defvar gnus-secondary-select-methods)
(defvar gnus-topic-alist)
(defvar gnus-topic-topology)

(declare-function gnus-close-server "gnus-int" (method))
(declare-function gnus-group-entry "gnus" (group))
(declare-function gnus-group-prefixed-name "gnus" (group method))
(declare-function gnus-method-to-server "gnus" (method &optional nocache no-enter-cache))
(declare-function gnus-set-active "gnus" (group active))
(declare-function gnus-subscribe-group "gnus-start" (group &optional previous method))
(declare-function gnus-subscribe-topics "gnus-topic" (newsgroup))
(declare-function gnus-topic-check-topology "gnus-topic" ())

(defconst my-gnus-feed-topics
  '("news" "tech" "cult" "viva" "life" "buzz")
  "Feed topic names used as 'group-name' prefixes.")

(defun my-gnus--feed-topic-regexp (prefix)
  "Return a topic regexp for individual feed group PREFIX."
  (format ":feed\\.%s\\." (regexp-quote prefix)))

(defun my-gnus--feed-source-regexp (prefix)
  "Return a virtual-group regexp for feed source PREFIX."
  (format "\\`nn\\(?:rss\\|atom\\)[^:]*:feed\\.%s\\." (regexp-quote prefix)))

(defun my-gnus--setup-declared-feed-groups ()
  "Provision declared feed and virtual groups."
  (require 'gnus-topic)
  (setq gnus-topic-topology
        `(("Gnus" visible)
          (("feed" visible nil
            ((subscribe . "\\`nnvirtual:feed\\.")))
           ,@(mapcar
              (lambda (topic)
                `((,topic visible nil
                          ((subscribe . ,(my-gnus--feed-topic-regexp topic))
                           (subscribe-level . 6)))))
              my-gnus-feed-topics))))
  (dolist (topic (append '("Gnus" "feed") my-gnus-feed-topics))
    (unless (assoc topic gnus-topic-alist) (push (list topic) gnus-topic-alist)))
  (gnus-topic-check-topology)
  (cl-labels
      ((subscribe
         (name method)
         (unless (gnus-group-entry name)
           (gnus-subscribe-group name nil method)
           (gnus-set-active name '(1 . 0))
           (gnus-subscribe-topics name))))
    (when-let* ((configured-method (assq 'nnrss gnus-secondary-select-methods))
                (feeds (cadr (assq 'nnrss-group-alist (cddr configured-method)))))
      (let ((method (format "%s:%s" (car configured-method) (cadr configured-method))))
        (dolist (feed feeds)
          (subscribe (gnus-group-prefixed-name (car feed) configured-method) method))))
    (dolist (configured-method gnus-secondary-select-methods)
      (when (eq (car configured-method) 'nnatom)
        (when-let* ((title-function
                     (cadr (assq 'nnatom-read-title-function (cddr configured-method)))))
          (subscribe
           (gnus-group-prefixed-name (funcall title-function nil) configured-method)
           (gnus-method-to-server configured-method)))))
    (dolist (topic my-gnus-feed-topics)
      (let* ((method `(nnvirtual ,(my-gnus--feed-source-regexp topic)))
             (name (gnus-group-prefixed-name (format "feed.%s" topic) method)))
        (if (gnus-group-entry name) (gnus-close-server method) (subscribe name method))))))

(use-package smtpmail
  :ensure nil
  :custom
  (message-send-mail-function #'smtpmail-send-it)
  (user-mail-address my-user-email)
  (user-full-name my-user-fullname)
  (smtpmail-smtp-server "smtp.gmail.com")
  (smtpmail-smtp-service 465)
  (smtpmail-stream-type 'ssl)
  (smtpmail-smtp-user my-user-email))

(use-package message
  :ensure nil
  :hook
  (message-mode . variable-pitch-mode))

(use-package gnus
  :ensure nil
  :commands gnus
  :config
  (gnus-add-configuration
   '(summary
     (vertical 1.0
               (summary 0.6 point)
               (group 1.0))))
  (gnus-add-configuration
   '(article
     (horizontal 1.0
                 (vertical 1.0
                           (summary 0.6 point)
                           (group 1.0))
                 (article 72))))
  (defun gnus-user-format-function-g (header)
    (let ((xref (or (mail-header-xref header) "")))
      (if (string-match "\\.\\([^.:]+\\):[0-9]+[[:space:]]*\\'" xref) (match-string 1 xref) "")))

  :hook
  ((gnus-group-mode . gnus-topic-mode)
   (gnus-article-mode . variable-pitch-mode)
   (gnus-setup-news . my-gnus--setup-declared-feed-groups))

  :custom
  (shr-use-colors nil)
  (shr-use-fonts nil)
  (gnus-large-newsgroup nil)
  (gnus-always-force-window-configuration t)
  (gnus-face-1 'gnus-header-name)
  (gnus-face-2 `gnus-header-from)
  (gnus-face-3 `gnus-server-offline)
  (gnus-article-time-format "%Y-%m-%d %H:%M:%S %u")
  (gnus-article-date-headers '(user-defined lapsed))
  (gnus-treat-date 'head)
  (gnus-thread-sort-functions '(gnus-thread-sort-by-number gnus-thread-sort-by-most-recent-date))
  (gnus-subthread-sort-functions '(gnus-thread-sort-by-number gnus-thread-sort-by-date))
  (gnus-group-line-format "%1{%-5t%-5y%}%3{%S%B%}%(%*%g%)\n") ;  3.1.1 Group Line Speciication
  (gnus-summary-line-format "%1{%U%R%z%&user-date; %}%2{%-30,30f%}%1{%4k %B%}%(%*%s%)\n")
  (gnus-user-date-format-alist '((t . "%y-%m-%d %H:%M %u")))

  (gnus-message-archive-group nil)
  (gnus-search-use-parsed-queries t)
  (gnus-extra-headers '(To Cc Newsgroups X-GM-LABELS))

  (gnus-parameters
   '(("^nnvirtual:" (gnus-summary-line-format "%1{%&user-date;%R%U%}%2{%-24,24ug%}%(%*%s%)\n"))
     ("^\\(?:nnrss:\\|nnatom\\+\\)" (gnus-summary-line-format "%1{%U%R%&user-date; %}%(%*%s%)\n"))))

  (gnus-select-method
   '(nnimap "ozkayaogzhn"
            (nnimap-address "imap.gmail.com")
            (nnimap-user "ozkaya.ogzhn@gmail.com")
            (nnimap-server-port 993)
            (nnimap-stream tls)
            (nnimap-authenticator login)
            (nnimap-expunge never)))

  (gnus-secondary-select-methods
   '((nnrss ""
            (nnrss-group-alist
             (
              ("feed.news.The Economist" "https://www.economist.com/finance-and-economics/rss.xml")
              ("feed.news.Bloomberg" "https://www.bloomberg.com/feeds/news.rss")
              ("feed.news.Wall Street Journal" "https://feeds.content.dowjones.io/public/rss/RSSMarketsMain")
              ("feed.news.Financial Times" "https://www.ft.com/news-feed?format=rss")
              ("feed.news.Channel NewsAsia" "https://www.channelnewsasia.com/api/v1/rss-outbound-feed?_format=xml")
              ("feed.news.The Guardian" "https://www.theguardian.com/international/rss")
              ("feed.news.BBC" "https://feeds.bbci.co.uk/news/rss.xml")
              ("feed.news.New York Times" "https://rss.nytimes.com/services/xml/rss/nyt/HomePage.xml")
              ("feed.news.Dünya Gazetesi" "https://www.dunya.com/rss")
              ("feed.news.CNBC-e" "https://www.cnbce.com/rss")
              ("feed.news.Cumhuriyet" "https://www.cumhuriyet.com.tr/rss")
              ("feed.news.TRT" "https://www.trthaber.com/sondakika_articles.rss")

              ("feed.tech.TechRepublic" "https://www.techrepublic.com/rssfeeds/articles/")
              ("feed.tech.TechSpot" "https://www.techspot.com/backend.xml")
              ("feed.tech.The Verge" "https://www.theverge.com/rss/partner/subscriber-only-full-feed/rss.xml")
              ("feed.tech.Engadget" "https://www.engadget.com/feed/")
              ("feed.tech.InfoQ" "https://feed.infoq.com/")
              ("feed.tech.The Register" "https://www.theregister.com/?lab_viewport=rss")
              ("feed.tech.Phoronix" "https://www.phoronix.com/rss.php")
              ("feed.tech.The New Stack" "https://thenewstack.io/feed/")
              ("feed.tech.Ars Technica" "https://feeds.arstechnica.com/arstechnica/index")
              ("feed.tech.LWN" "https://lwn.net/headlines/rss")
              ("feed.tech.MIT Technology Review" "https://www.technologyreview.com/feed/")
              ("feed.tech.IEEE Spectrum" "https://spectrum.ieee.org/feeds/feed.rss")

              ("feed.cult.Psyche" "https://psyche.co/feed")
              ("feed.cult.Quanta Magazine" "https://www.quantamagazine.org/feed/")
              ("feed.cult.Nautilus" "https://nautil.us/feed")
              ("feed.cult.Noema" "https://www.noemamag.com/feed")
              ("feed.cult.Language Log" "https://languagelog.ldc.upenn.edu/nll/?feed=rss2")
              ("feed.cult.Works in Progress" "https://worksinprogress.co/rss.xml")
              ("feed.cult.Tarihistan" "https://www.tarihistan.org/rss")
              ("feed.cult.Colossal" "https://www.thisiscolossal.com/feed/")
              ("feed.cult.Aeon" "https://aeon.co/feed.rss")
              ("feed.cult.JSTOR Daily" "https://daily.jstor.org/feed")
              ("feed.cult.Public Domain Review" "https://publicdomainreview.org/rss.xml")
              ("feed.cult.Nature" "https://www.nature.com/nature.rss")

              ("feed.viva.Indie Wire" "https://www.indiewire.com/feed/")
              ("feed.viva.Book Riot" "https://bookriot.com/feed/")
              ("feed.viva.New Musical Express" "https://www.nme.com/feed")
              ("feed.viva.The Athletic" "https://www.nytimes.com/athletic/rss/news/")
              ("feed.viva.TRT Spor" "https://www.trthaber.com/spor_articles.rss")
              ("feed.viva.Galatasaray" "http://www.galatasaray.org/xml/gs.rss")

              ("feed.life.Muscle and Fitness" "https://www.muscleandfitness.com/feed/")
              ("feed.life.Valet" "https://valetmag.com/distribution/rss_all.xml")
              ("feed.life.Ape to Gentleman" "https://www.apetogentleman.com/feed/")
              ("feed.life.Gentleman's Gazette" "https://www.gentlemansgazette.com/feed/")
              ("feed.life.Vogue" "https://www.vogue.com/feed/rss")
              ("feed.life.GQ" "https://www.gq.com/feed/rss")

              ("feed.buzz.Ray Dalio" "https://raydalio.substack.com/feed")
              ("feed.buzz.Michael Burry" "https://michaeljburry.substack.com/feed")
              ("feed.buzz.Robin Brooks" "https://robinjbrooks.substack.com/feed")
              ("feed.buzz.Barry Knapp" "https://ironsidesmacro.substack.com/feed")
              ("feed.buzz.Jim Paulsen" "https://paulsenperspectives.substack.com/feed")
              ("feed.buzz.Matthew Klein" "https://theovershoot.co/feed")
              ("feed.buzz.Pragmatic Engineer" "https://newsletter.pragmaticengineer.com/feed")
              ("feed.buzz.Its Foss" "https://feed.itsfoss.com/")
              ("feed.buzz.A List Apart" "https://alistapart.com/main/feed/")
              ("feed.buzz.Scrum Blog" "https://www.scrum.org/resources/blog/rss.xml")
              ("feed.buzz.Pragdave" "https://articles.pragdave.me/feed")
              ("feed.buzz.DZone" "https://feeds.dzone.com/home")
              ("feed.buzz.Hacker News" "https://news.ycombinator.com/rss")
              ("feed.buzz.Stack Overflow Blog" "https://stackoverflow.blog/feed/")
              ("feed.buzz.LWN Comments" "https://lwn.net/headlines/Comments")
              ("feed.buzz.Irreal" "https://irreal.org/blog/?feed=rss2")
              ("feed.buzz.Ruslan" "https://codelearn.me/feed.xml")
              ("feed.buzz.Gary Marcus" "https://garymarcus.substack.com/feed")
              ("feed.buzz.Dan Luu" "https://danluu.com/atom.xml")
              ("feed.buzz.Kent Beck" "https://newsletter.kentbeck.com/feed")
              ("feed.buzz.Protesilaos" "https://protesilaos.com/master.xml")
              ("feed.buzz.Rahul Juliato" "https://rahuljuliato.com/rss.xml"))))
     (nnatom "simonwillison.net/atom/everything/" (nnatom-read-title-function (lambda (_group) "feed.buzz.Simon Willison")))
     (nnatom "martinfowler.com/feed.atom" (nnatom-read-title-function (lambda (_group) "feed.buzz.Martin Fowler"))))))

(provide 'my-net)
;;; my-net.el ends here
