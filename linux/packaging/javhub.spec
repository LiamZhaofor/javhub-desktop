# JavHub for Fedora: the Flutter bundle built on Fedora (it links the system's GTK 3 and libmpv),
# installed as it is under /usr/lib64/javhub. Built by linux/packaging/build-rpm.sh.
Name:           javhub
Version:        %{app_version}
Release:        %{app_build}%{?dist}
Summary:        JavHub client: library, search, downloads and player
License:        Proprietary
URL:            https://github.com/LiamZhaofor/javhub-desktop
ExclusiveArch:  x86_64
# the bundle carries Flutter's own libraries: no automatic Provides from them
%global __provides_exclude_from ^%{_libdir}/javhub/.*$
%global __requires_exclude ^libflutter_linux_gtk\.so.*|^lib.*_plugin\.so.*$
Requires:       gtk3
Requires:       mpv-libs
Recommends:     google-noto-sans-cjk-fonts

%description
The JavHub desktop client: the library, search and downloads, recommendations and
the player (libmpv), with updates from the JavHub server.

%install
mkdir -p %{buildroot}%{_libdir}/javhub %{buildroot}%{_bindir} \
         %{buildroot}%{_datadir}/applications %{buildroot}%{_datadir}/icons/hicolor/256x256/apps
cp -a %{bundle}/. %{buildroot}%{_libdir}/javhub/
ln -s %{_libdir}/javhub/javhub %{buildroot}%{_bindir}/javhub
install -m 644 %{pkgdir}/codes.liamzhao.javhub.desktop %{buildroot}%{_datadir}/applications/
install -m 644 %{icon} %{buildroot}%{_datadir}/icons/hicolor/256x256/apps/codes.liamzhao.javhub.png

%files
%{_libdir}/javhub
%{_bindir}/javhub
%{_datadir}/applications/codes.liamzhao.javhub.desktop
%{_datadir}/icons/hicolor/256x256/apps/codes.liamzhao.javhub.png
