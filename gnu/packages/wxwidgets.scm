;;; GNU Guix --- Functional package management for GNU
;;; Copyright © 2015 Taylan Ulrich Bayırlı/Kammer <taylanbayirli@gmail.com>
;;; Copyright © 2016 Ricardo Wurmus <rekado@elephly.net>
;;; Copyright © 2016 Theodoros Foradis <theodoros.for@openmailbox.org>
;;; Copyright © 2016 Danny Milosavljevic <dannym@scratchpost.org>
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

(define-module (gnu packages wxwidgets)
  #:use-module (guix packages)
  #:use-module (guix download)
  #:use-module ((guix licenses) #:prefix l:)
  #:use-module (guix build-system glib-or-gtk)
  #:use-module (guix build-system python)
  #:use-module (guix build utils)
  #:use-module (gnu packages)
  #:use-module (gnu packages compression)
  #:use-module (gnu packages databases)
  #:use-module (gnu packages gl)
  #:use-module (gnu packages gstreamer)
  #:use-module (gnu packages gtk)
  #:use-module (gnu packages image)
  #:use-module (gnu packages pkg-config)
  #:use-module (gnu packages python)
  #:use-module (gnu packages sdl)
  #:use-module (gnu packages webkit)
  #:use-module (gnu packages xorg))

(define-public wxwidgets
  (package
    (name "wxwidgets")
    (version "3.0.2")
    (source
     (origin
       (method url-fetch)
       (uri (string-append "https://github.com/wxWidgets/wxWidgets/"
                           "releases/download/v" version
                           "/wxWidgets-" version ".tar.bz2"))
       (sha256
        (base32 "0paq27brw4lv8kspxh9iklpa415mxi8zc117vbbbhfjgapf7js1l"))))
    (build-system glib-or-gtk-build-system)
    (inputs
     `(("glu" ,glu)
       ;; XXX gstreamer-0.10 builds fail
       ;; ("gstreamer" ,gstreamer-0.10)
       ("gtk" ,gtk+)
       ("libjpeg" ,libjpeg)
       ("libmspack" ,libmspack)
       ("libsm" ,libsm)
       ("libtiff" ,libtiff)
       ("mesa" ,mesa)
       ("webkitgtk" ,webkitgtk-2.4)
       ("sdl" ,sdl)))
    (native-inputs
     `(("pkg-config" ,pkg-config)))
    (arguments
     '(#:configure-flags
       '("--with-regex" "--with-libmspack"
         "--with-sdl"
         "--enable-webview"
         "--enable-webkit"
         "--enable-webviewwebkit")
       #:make-flags
       (list (string-append "LDFLAGS=-Wl,-rpath="
                            (assoc-ref %outputs "out") "/lib"))
       ;; No 'check' target.
       #:tests? #f))
    (home-page "https://www.wxwidgets.org/")
    (synopsis "Widget toolkit for creating graphical user interfaces")
    (description
     "wxWidgets is a C++ library that lets developers create applications with
a graphical user interface.  It has language bindings for Python, Perl, Ruby
and many other languages.")
    (license (list l:lgpl2.0+ (l:fsf-free "file://doc/license.txt")))))

(define-public wxwidgets-2
  (package
    (inherit wxwidgets)
    (version "2.8.12")
    (source
     (origin
       (method url-fetch)
       (uri (string-append "https://github.com/wxWidgets/wxWidgets/"
                           "releases/download/v" version
                           "/wxGTK-" version ".tar.gz"))
       (sha256
        (base32 "1gjs9vfga60mk4j4ngiwsk9h6c7j22pw26m3asxr1jwvqbr8kkqk"))))
    (inputs
     `(("gtk" ,gtk+-2)
       ("libjpeg" ,libjpeg)
       ("libtiff" ,libtiff)
       ("libmspack" ,libmspack)
       ("sdl" ,sdl)
       ("unixodbc" ,unixodbc)))
    (arguments
     `(#:configure-flags
       '("--enable-unicode" "--with-regex=sys" "--with-sdl")
       #:make-flags
       (list (string-append "LDFLAGS=-Wl,-rpath="
                            (assoc-ref %outputs "out") "/lib"))
       ;; No 'check' target.
       #:tests? #f))))

(define-public wxwidgets-gtk2
  (package (inherit wxwidgets)
           (inputs `(("gtk+" ,gtk+-2)
                     ,@(alist-delete
                        "gtk+"
                        (package-inputs wxwidgets))))
           (name "wxwidgets-gtk2")))

(define-public python2-wxpython
  (package
    (name "python2-wxpython")
    (version "3.0.2.0")
    (source
      (origin
        (method url-fetch)
        (uri (string-append "mirror://sourceforge/wxpython/wxPython/"
                            version "/wxPython-src-" version ".tar.bz2"))
        (sha256
         (base32
          "0qfzx3sqx4mwxv99sfybhsij4b5pc03ricl73h4vhkzazgjjjhfm"))
        (modules '((guix build utils)))
        (snippet
         '(begin
            (lambda (folder)
              (delete-file-recursively (string-append "src/" folder))
              '("expat" "jpeg" "png" "tiff" "zlib" "msw" "osx" "msdos"))
            (substitute* '("wxPython/setup.py")
              ;; setup.py tries to keep its own license the same as wxwidget's
              ;; license (which it expects under $WXWIN/docs).
              (("'preamble.txt', 'licence.txt', 'licendoc.txt', 'lgpl.txt'")
                ""))))))
    (build-system python-build-system)
    (arguments
     `(#:python ,python-2
       #:tests? #f ; tests fail
       ;; wxPython directly extends distutils command classes,
       ;; we can't easily make setup.py use setuptools.
       #:use-setuptools? #f
       #:configure-flags (list "WXPORT=gtk2"
                               "UNICODE=1")
       #:phases
       (modify-phases %standard-phases
         (add-before 'build 'chdir
           (lambda _
             (chdir "wxPython")
             #t))
         (add-after 'chdir 'set-wx-out-dir
           (lambda* (#:key outputs #:allow-other-keys)
             ;; By default, install phase tries to copy the wxPython headers in
             ;; gnu/store/...-wxwidgets-3.0.2 , which it can't, so they are
             ;; redirected to the output directory by setting WXPREFIX.
             (substitute* "config.py"
               (("= getWxConfigValue\\('--prefix'\\)")
                (string-append "= '" (assoc-ref outputs "out") "'")))
             (substitute* "wx/build/config.py"
               (("= getWxConfigValue\\('--prefix'\\)")
                (string-append "= '" (assoc-ref outputs "out") "'")))
             #t))
         (add-after 'set-wx-out-dir 'setenv
           (lambda* (#:key inputs outputs #:allow-other-keys)
             (setenv "WXWIN" (assoc-ref inputs "wxwidgets"))
             (use-modules (ice-9 popen) (ice-9 rdelim))
             (let ((port (open-pipe* OPEN_READ
                                     (string-append (assoc-ref inputs "wxwidgets")
                                                    "/bin/wx-config") "--cppflags")))
               (setenv "CPPFLAGS" (read-string port))
               (close-pipe port))
             #t)))))
    (native-inputs
     `(("mesa" ,mesa) ; for glcanvas
       ("pkg-config" ,pkg-config)))
    (inputs
     `(("gtk+" ,gtk+-2) ; for wxPython/src/helpers.cpp
       ("wxwidgets" ,wxwidgets-gtk2)))
    (synopsis "Python 2 Bindings for wxWidgets")
    (description "@code{wxpython} provides Python 2 bindings for wxWidgets.")
    (home-page "http://wxpython.org/")
    (license (package-license wxwidgets))))
