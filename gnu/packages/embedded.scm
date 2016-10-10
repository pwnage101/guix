;;; GNU Guix --- Functional package management for GNU
;;; Copyright © 2016 Ricardo Wurmus <rekado@elephly.net>
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

(define-module (gnu packages embedded)
  #:use-module (guix utils)
  #:use-module (guix packages)
  #:use-module (guix download)
  #:use-module (guix svn-download)
  #:use-module (guix git-download)
  #:use-module ((guix licenses) #:prefix license:)
  #:use-module (guix build-system gnu)
  #:use-module (gnu packages)
  #:use-module (gnu packages cross-base)
  #:use-module (gnu packages flex)
  #:use-module (gnu packages perl)
  #:use-module (gnu packages texinfo))

;; We must not use the released GCC sources here, because the cross-compiler
;; does not produce working binaries.  Instead we take the very same SVN
;; revision from the branch that is used for a release of the "GCC ARM
;; embedded" project on launchpad.
;; See https://launchpadlibrarian.net/218827644/release.txt
(define-public gcc-arm-none-eabi-4.9
  (let ((xgcc (cross-gcc "arm-none-eabi"
                         (cross-binutils "arm-none-eabi")))
        (revision "1")
        (svn-revision 227977))
    (package (inherit xgcc)
      (version (string-append (package-version xgcc) "-"
                              revision "." (number->string svn-revision)))
      (source
       (origin
         (method svn-fetch)
         (uri (svn-reference
               (url "svn://gcc.gnu.org/svn/gcc/branches/ARM/embedded-4_9-branch/")
               (revision svn-revision)))
         (file-name (string-append "gcc-arm-embedded-" version "-checkout"))
         (sha256
          (base32
           "113r98kygy8rrjfv2pd3z6zlfzbj543pq7xyq8bgh72c608mmsbr"))
         (patches (origin-patches (package-source xgcc)))))
      (native-inputs
       `(("flex" ,flex)
         ,@(package-native-inputs xgcc)))
      (arguments
       (substitute-keyword-arguments (package-arguments xgcc)
         ((#:phases phases)
          `(modify-phases ,phases
             (add-after 'unpack 'fix-genmultilib
               (lambda _
                 (substitute* "gcc/genmultilib"
                   (("#!/bin/sh") (string-append "#!" (which "sh"))))
                 #t))))
         ((#:configure-flags flags)
          ;; The configure flags are largely identical to the flags used by the
          ;; "GCC ARM embedded" project.
          `(append (list "--enable-multilib"
                         "--with-newlib"
                         "--with-multilib-list=armv6-m,armv7-m,armv7e-m"
                         "--with-host-libstdcxx=-static-libgcc -Wl,-Bstatic,-lstdc++,-Bdynamic -lm"
                         "--enable-plugins"
                         "--disable-decimal-float"
                         "--disable-libffi"
                         "--disable-libgomp"
                         "--disable-libmudflap"
                         "--disable-libquadmath"
                         "--disable-libssp"
                         "--disable-libstdcxx-pch"
                         "--disable-nls"
                         "--disable-shared"
                         "--disable-threads"
                         "--disable-tls")
                   (delete "--disable-multilib" ,flags)))))
      (native-search-paths
       (list (search-path-specification
              (variable "CROSS_C_INCLUDE_PATH")
              (files '("arm-none-eabi/include")))
             (search-path-specification
              (variable "CROSS_CPLUS_INCLUDE_PATH")
              (files '("arm-none-eabi/include")))
             (search-path-specification
              (variable "CROSS_LIBRARY_PATH")
              (files '("arm-none-eabi/lib"))))))))

(define-public newlib-arm-none-eabi
  (package
    (name "newlib")
    (version "2.4.0")
    (source (origin
              (method url-fetch)
              (uri (string-append "ftp://sourceware.org/pub/newlib/newlib-"
                                  version ".tar.gz"))
              (sha256
               (base32
                "01i7qllwicf05vsvh39qj7qp5fdifpvvky0x95hjq39mbqiksnsl"))))
    (build-system gnu-build-system)
    (arguments
     `(#:out-of-source? #t
       ;; The configure flags are identical to the flags used by the "GCC ARM
       ;; embedded" project.
       #:configure-flags '("--target=arm-none-eabi"
                           "--enable-newlib-io-long-long"
                           "--enable-newlib-register-fini"
                           "--disable-newlib-supplied-syscalls"
                           "--disable-nls")
       #:phases
       (modify-phases %standard-phases
         (add-after 'unpack 'fix-references-to-/bin/sh
           (lambda _
             (substitute* '("libgloss/arm/cpu-init/Makefile.in"
                            "libgloss/arm/Makefile.in"
                            "libgloss/libnosys/Makefile.in"
                            "libgloss/Makefile.in")
               (("/bin/sh") (which "sh")))
             #t)))))
    (native-inputs
     `(("xbinutils" ,(cross-binutils "arm-none-eabi"))
       ("xgcc" ,gcc-arm-none-eabi-4.9)
       ("texinfo" ,texinfo)))
    (home-page "http://www.sourceware.org/newlib/")
    (synopsis "C library for use on embedded systems")
    (description "Newlib is a C library intended for use on embedded
systems.  It is a conglomeration of several library parts that are easily
usable on embedded products.")
    (license (license:non-copyleft
              "https://www.sourceware.org/newlib/COPYING.NEWLIB"))))

(define-public newlib-nano-arm-none-eabi
  (package (inherit newlib-arm-none-eabi)
    (name "newlib-nano")
    (arguments
     (substitute-keyword-arguments (package-arguments newlib-arm-none-eabi)
       ;; The configure flags are identical to the flags used by the "GCC ARM
       ;; embedded" project.  They optimize newlib for use on small embedded
       ;; systems with limited memory.
       ((#:configure-flags flags)
        ''("--target=arm-none-eabi"
           "--enable-multilib"
           "--disable-newlib-supplied-syscalls"
           "--enable-newlib-reent-small"
           "--disable-newlib-fvwrite-in-streamio"
           "--disable-newlib-fseek-optimization"
           "--disable-newlib-wide-orient"
           "--enable-newlib-nano-malloc"
           "--disable-newlib-unbuf-stream-opt"
           "--enable-lite-exit"
           "--enable-newlib-global-atexit"
           "--enable-newlib-nano-formatted-io"
           "--disable-nls"))))
    (synopsis "Newlib variant for small systems with limited memory")))