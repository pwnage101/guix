;;; GNU Guix --- Functional package management for GNU
;;; Copyright © 2016, 2017 Ludovic Courtès <ludo@gnu.org>
;;;
;;; This file is part of GNU Guix.
;;;
;;; GNU Guix is free software; you can redistribute it and/or modify it
;;; under the terms of the GNU General Public License as published by
;;; the Free Software Foundation; either version 3 of the License, or (at
;;; your option) any later version.
;;;
;;; GNU Guix is distributed in the hope that it will be useful, but
;;; WITHOUT ANY WARRANTY; without even the implied warranty of
;;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;;; GNU General Public License for more details.
;;;
;;; You should have received a copy of the GNU General Public License
;;; along with GNU Guix.  If not, see <http://www.gnu.org/licenses/>.

(define-module (gnu tests base)
  #:use-module (gnu tests)
  #:use-module (gnu system)
  #:use-module (gnu system grub)
  #:use-module (gnu system file-systems)
  #:use-module (gnu system shadow)
  #:use-module (gnu system nss)
  #:use-module (gnu system vm)
  #:use-module (gnu services)
  #:use-module (gnu services base)
  #:use-module (gnu services dbus)
  #:use-module (gnu services avahi)
  #:use-module (gnu services mcron)
  #:use-module (gnu services shepherd)
  #:use-module (gnu services networking)
  #:use-module (gnu packages imagemagick)
  #:use-module (gnu packages ocr)
  #:use-module (guix gexp)
  #:use-module (guix store)
  #:use-module (guix monads)
  #:use-module (guix packages)
  #:use-module (srfi srfi-1)
  #:export (run-basic-test
            %test-basic-os
            %test-mcron
            %test-nss-mdns))

(define %simple-os
  (operating-system
    (host-name "komputilo")
    (timezone "Europe/Berlin")
    (locale "en_US.UTF-8")

    (bootloader (grub-configuration (device "/dev/sdX")))
    (file-systems (cons (file-system
                          (device "my-root")
                          (title 'label)
                          (mount-point "/")
                          (type "ext4"))
                        %base-file-systems))
    (firmware '())

    (users (cons (user-account
                  (name "alice")
                  (comment "Bob's sister")
                  (group "users")
                  (supplementary-groups '("wheel" "audio" "video"))
                  (home-directory "/home/alice"))
                 %base-user-accounts))))


(define* (run-basic-test os command #:optional (name "basic")
                         #:key initialization)
  "Return a derivation called NAME that tests basic features of the OS started
using COMMAND, a gexp that evaluates to a list of strings.  Compare some
properties of running system to what's declared in OS, an <operating-system>.

When INITIALIZATION is true, it must be a one-argument procedure that is
passed a gexp denoting the marionette, and it must return gexp that is
inserted before the first test.  This is used to introduce an extra
initialization step, such as entering a LUKS passphrase."
  (define test
    (with-imported-modules '((gnu build marionette)
                             (guix build syscalls))
      #~(begin
          (use-modules (gnu build marionette)
                       (guix build syscalls)
                       (srfi srfi-1)
                       (srfi srfi-26)
                       (srfi srfi-64)
                       (ice-9 match))

          (define marionette
            (make-marionette #$command))

          (mkdir #$output)
          (chdir #$output)

          (test-begin "basic")

          #$(and initialization
                 (initialization #~marionette))

          (test-assert "uname"
            (match (marionette-eval '(uname) marionette)
              (#("Linux" host-name version _ architecture)
               (and (string=? host-name
                              #$(operating-system-host-name os))
                    (string-prefix? #$(package-version
                                       (operating-system-kernel os))
                                    version)
                    (string-prefix? architecture %host-type)))))

          (test-assert "shell and user commands"
            ;; Is everything in $PATH?
            (zero? (marionette-eval '(system "
. /etc/profile
set -e -x
guix --version
ls --version
grep --version
info --version")
                                    marionette)))

          (test-assert "accounts"
            (let ((users (marionette-eval '(begin
                                             (use-modules (ice-9 match))
                                             (let loop ((result '()))
                                               (match (getpw)
                                                 (#f (reverse result))
                                                 (x  (loop (cons x result))))))
                                          marionette)))
              (lset= string=?
                     (map passwd:name users)
                     (list
                      #$@(map user-account-name
                              (operating-system-user-accounts os))))))

          (test-assert "shepherd services"
            (let ((services (marionette-eval
                             '(begin
                                (use-modules (gnu services herd))

                                (map (compose car live-service-provision)
                                     (current-services)))
                             marionette)))
              (lset= eq?
                     (pk 'services services)
                     '(root #$@(operating-system-shepherd-service-names os)))))

          (test-assert "homes"
            (let ((homes
                   '#$(map user-account-home-directory
                           (filter user-account-create-home-directory?
                                   (operating-system-user-accounts os)))))
              (marionette-eval
               `(begin
                  (use-modules (gnu services herd) (srfi srfi-1))

                  ;; Home directories are supposed to exist once 'user-homes'
                  ;; has been started.
                  (start-service 'user-homes)

                  (every (lambda (home)
                           (and (file-exists? home)
                                (file-is-directory? home)))
                         ',homes))
               marionette)))

          (test-assert "skeletons in home directories"
            (let ((homes
                   '#$(filter-map (lambda (account)
                                    (and (user-account-create-home-directory?
                                          account)
                                         (not (user-account-system? account))
                                         (user-account-home-directory account)))
                                  (operating-system-user-accounts os))))
              (marionette-eval
               `(begin
                  (use-modules (srfi srfi-1) (ice-9 ftw))
                  (every (lambda (home)
                           (null? (lset-difference string=?
                                                   (scandir "/etc/skel/")
                                                   (scandir home))))
                         ',homes))
               marionette)))

          (test-equal "login on tty1"
            "root\n"
            (begin
              (marionette-control "sendkey ctrl-alt-f1" marionette)
              ;; Wait for the 'term-tty1' service to be running (using
              ;; 'start-service' is the simplest and most reliable way to do
              ;; that.)
              (marionette-eval
               '(begin
                  (use-modules (gnu services herd))
                  (start-service 'term-tty1))
               marionette)

              ;; Now we can type.
              (marionette-type "root\n\nid -un > logged-in\n" marionette)

              ;; It can take a while before the shell commands are executed.
              (marionette-eval '(use-modules (rnrs io ports)) marionette)
              (marionette-eval
               '(let loop ((i 0))
                  (catch 'system-error
                    (lambda ()
                      (call-with-input-file "/root/logged-in"
                        get-string-all))
                    (lambda args
                      (if (and (< i 15) (= ENOENT (system-error-errno args)))
                          (begin
                            (sleep 1)
                            (loop (+ i 1)))
                          (apply throw args)))))
               marionette)))

          ;; There should be one utmpx entry for the user logged in on tty1.
          (test-equal "utmpx entry"
            '(("root" "tty1" #f))
            (marionette-eval
             '(begin
                (use-modules (guix build syscalls)
                             (srfi srfi-1))

                (filter-map (lambda (entry)
                              (and (equal? (login-type USER_PROCESS)
                                           (utmpx-login-type entry))
                                   (list (utmpx-user entry) (utmpx-line entry)
                                         (utmpx-host entry))))
                            (utmpx-entries)))
             marionette))

          ;; Likewise for /var/log/wtmp (used by 'last').
          (test-assert "wtmp entry"
            (match (marionette-eval
                    '(begin
                       (use-modules (guix build syscalls)
                                    (srfi srfi-1))

                       (define (entry->list entry)
                         (list (utmpx-user entry) (utmpx-line entry)
                               (utmpx-host entry) (utmpx-login-type entry)))

                       (call-with-input-file "/var/log/wtmp"
                         (lambda (port)
                           (let loop ((result '()))
                             (if (eof-object? (peek-char port))
                                 (map entry->list (reverse result))
                                 (loop (cons (read-utmpx port) result)))))))
                    marionette)
              (((users lines hosts types) ..1)
               (every (lambda (type)
                        (eqv? type (login-type LOGIN_PROCESS)))
                      types))))

          (test-assert "host name resolution"
            (match (marionette-eval
                    '(begin
                       ;; Wait for nscd or our requests go through it.
                       (use-modules (gnu services herd))
                       (start-service 'nscd)

                       (list (getaddrinfo "localhost")
                             (getaddrinfo #$(operating-system-host-name os))))
                    marionette)
              ((((? vector?) ..1) ((? vector?) ..1))
               #t)
              (x
               (pk 'failure x #f))))

          (test-equal "host not found"
            #f
            (marionette-eval
             '(false-if-exception (getaddrinfo "does-not-exist"))
             marionette))

          (test-equal "locale"
            "en_US.utf8"
            (marionette-eval '(let ((before (setlocale LC_ALL "en_US.utf8")))
                                (setlocale LC_ALL before))
                             marionette))

          (test-assert "/run/current-system is a GC root"
            (marionette-eval '(begin
                                ;; Make sure the (guix …) modules are found.
                                (eval-when (expand load eval)
                                  (set! %load-path
                                    (cons
                                     (string-append
                                      "/run/current-system/profile/share/guile/site/"
                                      (effective-version))
                                     %load-path))
                                  (set! %load-compiled-path
                                    (cons
                                     (string-append
                                      "/run/current-system/profile/share/guile/site/"
                                      (effective-version))
                                     %load-compiled-path)))

                                (use-modules (srfi srfi-34) (guix store))

                                (let ((system (readlink "/run/current-system")))
                                  (guard (c ((nix-protocol-error? c)
                                             (file-exists? system)))
                                    (with-store store
                                      (delete-paths store (list system))
                                      #f))))
                             marionette))

          ;; This symlink is currently unused, but better have it point to the
          ;; right place.  See
          ;; <https://lists.gnu.org/archive/html/guix-devel/2016-08/msg01641.html>.
          (test-equal "/var/guix/gcroots/profiles is a valid symlink"
            "/var/guix/profiles"
            (marionette-eval '(readlink "/var/guix/gcroots/profiles")
                             marionette))


          (test-assert "screendump"
            (begin
              (marionette-control (string-append "screendump " #$output
                                                 "/tty1.ppm")
                                  marionette)
              (file-exists? "tty1.ppm")))

          (test-assert "screen text"
            (let ((text (marionette-screen-text marionette
                                                #:ocrad
                                                #$(file-append ocrad
                                                               "/bin/ocrad"))))
              ;; Check whether the welcome message and shell prompt are
              ;; displayed.  Note: OCR confuses "y" and "V" for instance, so
              ;; we cannot reliably match the whole text.
              (and (string-contains text "This is the GNU")
                   (string-contains text
                                    (string-append
                                     "root@"
                                     #$(operating-system-host-name os))))))

          (test-end)
          (exit (= (test-runner-fail-count (test-runner-current)) 0)))))

  (gexp->derivation name test))

(define %test-basic-os
  (system-test
   (name "basic")
   (description
    "Instrument %SIMPLE-OS, run it in a VM, and run a series of basic
functionality tests.")
   (value
    (mlet* %store-monad ((os -> (marionette-operating-system
                                 %simple-os
                                 #:imported-modules '((gnu services herd)
                                                      (guix combinators))))
                         (run   (system-qemu-image/shared-store-script
                                 os #:graphic? #f)))
      ;; XXX: Add call to 'virtualized-operating-system' to get the exact same
      ;; set of services as the OS produced by
      ;; 'system-qemu-image/shared-store-script'.
      (run-basic-test (virtualized-operating-system os '())
                      #~(list #$run))))))


;;;
;;; Mcron.
;;;

(define %mcron-os
  ;; System with an mcron service, with one mcron job for "root" and one mcron
  ;; job for an unprivileged user (note: #:user is an 'mcron2' thing.)
  (let ((job1 #~(job next-second-from
                     (lambda ()
                       (call-with-output-file "witness"
                         (lambda (port)
                           (display (list (getuid) (getgid)) port))))))
        (job2 #~(job next-second-from
                     (lambda ()
                       (call-with-output-file "witness"
                         (lambda (port)
                           (display (list (getuid) (getgid)) port))))
                     #:user "alice"))
        (job3 #~(job next-second-from             ;to test $PATH
                     "touch witness-touch")))
    (operating-system
      (inherit %simple-os)
      (services (cons (mcron-service (list job1 job2 job3))
                      (operating-system-user-services %simple-os))))))

(define (run-mcron-test name)
  (mlet* %store-monad ((os ->   (marionette-operating-system
                                 %mcron-os
                                 #:imported-modules '((gnu services herd)
                                                      (guix combinators))))
                       (command (system-qemu-image/shared-store-script
                                 os #:graphic? #f)))
    (define test
      (with-imported-modules '((gnu build marionette))
        #~(begin
            (use-modules (gnu build marionette)
                         (srfi srfi-64)
                         (ice-9 match))

            (define marionette
              (make-marionette (list #$command)))

            (define (wait-for-file file)
              ;; Wait until FILE exists in the guest; 'read' its content and
              ;; return it.
              (marionette-eval
               `(let loop ((i 10))
                  (cond ((file-exists? ,file)
                         (call-with-input-file ,file read))
                        ((> i 0)
                         (sleep 1)
                         (loop (- i 1)))
                        (else
                         (error "file didn't show up" ,file))))
               marionette))

            (mkdir #$output)
            (chdir #$output)

            (test-begin "mcron")

            (test-eq "service running"
              'running!
              (marionette-eval
               '(begin
                  (use-modules (gnu services herd))
                  (start-service 'mcron)
                  'running!)
               marionette))

            ;; Make sure root's mcron job runs, has its cwd set to "/root", and
            ;; runs with the right UID/GID.
            (test-equal "root's job"
              '(0 0)
              (wait-for-file "/root/witness"))

            ;; Likewise for Alice's job.  We cannot know what its GID is since
            ;; it's chosen by 'groupadd', but it's strictly positive.
            (test-assert "alice's job"
              (match (wait-for-file "/home/alice/witness")
                ((1000 gid)
                 (>= gid 100))))

            ;; Last, the job that uses a command; allows us to test whether
            ;; $PATH is sane.  (Note that 'marionette-eval' stringifies objects
            ;; that don't have a read syntax, hence the string.)
            (test-equal "root's job with command"
              "#<eof>"
              (wait-for-file "/root/witness-touch"))

            (test-end)
            (exit (= (test-runner-fail-count (test-runner-current)) 0)))))

    (gexp->derivation name test)))

(define %test-mcron
  (system-test
   (name "mcron")
   (description "Make sure the mcron service works as advertised.")
   (value (run-mcron-test name))))


;;;
;;; Avahi and NSS-mDNS.
;;;

(define %avahi-os
  (operating-system
    (inherit %simple-os)
    (name-service-switch %mdns-host-lookup-nss)
    (services (cons* (avahi-service #:debug? #t)
                     (dbus-service)
                     (dhcp-client-service)        ;needed for multicast

                     ;; Enable heavyweight debugging output.
                     (modify-services (operating-system-user-services
                                       %simple-os)
                       (nscd-service-type config
                                          => (nscd-configuration
                                              (inherit config)
                                              (debug-level 3)
                                              (log-file "/dev/console")))
                       (syslog-service-type config
                                            =>
                                            (syslog-configuration
                                             (inherit config)
                                             (config-file
                                              (plain-file
                                               "syslog.conf"
                                               "*.* /dev/console\n")))))))))

(define (run-nss-mdns-test)
  ;; Test resolution of '.local' names via libc.  Start the marionette service
  ;; *after* nscd.  Failing to do that, libc will try to connect to nscd,
  ;; fail, then never try again (see '__nss_not_use_nscd_hosts' in libc),
  ;; leading to '.local' resolution failures.
  (mlet* %store-monad ((os -> (marionette-operating-system
                               %avahi-os
                               #:requirements '(nscd)
                               #:imported-modules '((gnu services herd)
                                                    (guix combinators))))
                       (run   (system-qemu-image/shared-store-script
                               os #:graphic? #f)))
    (define mdns-host-name
      (string-append (operating-system-host-name os)
                     ".local"))

    (define test
      (with-imported-modules '((gnu build marionette))
        #~(begin
            (use-modules (gnu build marionette)
                         (srfi srfi-1)
                         (srfi srfi-64)
                         (ice-9 match))

            (define marionette
              (make-marionette (list #$run)))

            (mkdir #$output)
            (chdir #$output)

            (test-begin "avahi")

            (test-assert "wait for services"
              (marionette-eval
               '(begin
                  (use-modules (gnu services herd))

                  (start-service 'nscd)

                  ;; XXX: Work around a race condition in nscd: nscd creates its
                  ;; PID file before it is listening on its socket.
                  (let ((sock (socket PF_UNIX SOCK_STREAM 0)))
                    (let try ()
                      (catch 'system-error
                        (lambda ()
                          (connect sock AF_UNIX "/var/run/nscd/socket")
                          (close-port sock)
                          (format #t "nscd is ready~%"))
                        (lambda args
                          (format #t "waiting for nscd...~%")
                          (usleep 500000)
                          (try)))))

                  ;; Wait for the other useful things.
                  (start-service 'avahi-daemon)
                  (start-service 'networking)

                  #t)
               marionette))

            (test-equal "avahi-resolve-host-name"
              0
              (marionette-eval
               '(system*
                 "/run/current-system/profile/bin/avahi-resolve-host-name"
                 "-v" #$mdns-host-name)
               marionette))

            (test-equal "avahi-browse"
              0
              (marionette-eval
               '(system* "avahi-browse" "-avt")
               marionette))

            (test-assert "getaddrinfo .local"
              ;; Wait for the 'avahi-daemon' service and perform a resolution.
              (match (marionette-eval
                      '(getaddrinfo #$mdns-host-name)
                      marionette)
                (((? vector? addrinfos) ..1)
                 (pk 'getaddrinfo addrinfos)
                 (and (any (lambda (ai)
                             (= AF_INET (addrinfo:fam ai)))
                           addrinfos)
                      (any (lambda (ai)
                             (= AF_INET6 (addrinfo:fam ai)))
                           addrinfos)))))

            (test-assert "gethostbyname .local"
              (match (pk 'gethostbyname
                         (marionette-eval '(gethostbyname #$mdns-host-name)
                                          marionette))
                ((? vector? result)
                 (and (string=? (hostent:name result) #$mdns-host-name)
                      (= (hostent:addrtype result) AF_INET)))))


            (test-end)
            (exit (= (test-runner-fail-count (test-runner-current)) 0)))))

    (gexp->derivation "nss-mdns" test)))

(define %test-nss-mdns
  (system-test
   (name "nss-mdns")
   (description
    "Test Avahi's multicast-DNS implementation, and in particular, test its
glibc name service switch (NSS) module.")
   (value (run-nss-mdns-test))))
