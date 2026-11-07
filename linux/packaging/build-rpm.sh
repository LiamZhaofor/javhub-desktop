#!/bin/bash
# Builds build/linux/x64/release/bundle into JavHub-Linux-v<version>.x86_64.rpm (run on Fedora,
# after `flutter build linux --release`). Version and build number come from pubspec.yaml.
set -euo pipefail
cd "$(dirname "$0")/../.."
line=$(grep -E '^version:' pubspec.yaml | head -1 | awk '{print $2}')
version=${line%%+*}
build=${line##*+}
bundle=$PWD/build/linux/x64/release/bundle
test -x "$bundle/javhub"
# the plugin libraries come out of the build with the build tree as their runpath: their own
# folder instead (it holds libflutter_linux_gtk.so too)
for so in "$bundle"/lib/*.so; do
  if readelf -d "$so" | grep -qE 'R(UN)?PATH'; then patchelf --set-rpath '$ORIGIN' "$so"; fi
done
top=$(mktemp -d)
rpmbuild -bb linux/packaging/javhub.spec \
  --define "_topdir $top" --define "app_version $version" --define "app_build $build" \
  --define "bundle $bundle" --define "pkgdir $PWD/linux/packaging" --define "icon $PWD/assets/app_icon.png"
out="JavHub-Linux-v$version.x86_64.rpm"
cp "$top"/RPMS/x86_64/javhub-*.rpm "$out"
rm -rf "$top"
rpm -qpR "$out"
echo "built $out"
