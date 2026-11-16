#!/bin/sh
# Puts what the app links but git does not keep into place:
#   Frameworks/{Slirp,GLib,StikJIT}.xcframework  from crate-ios's pinned releases
#   Resources/vmlinux                            the guest kernel (guest/build.sh kernel makes one)
#   Resources/Fonts                              the terminal's Nerd Fonts
# and builds the crate engine for containerization's CrateEngine target.
#
#     Scripts/fetch-frameworks.sh CRATE_IOS_CHECKOUT KERNEL
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
crate_ios=${1:?crate-ios checkout}
kernel=${2:-$here/../guest/out/vmlinux}
"$crate_ios/Scripts/fetch-frameworks.sh"
"$crate_ios/Scripts/fetch-stikjit.sh"
mkdir -p "$here/Frameworks"
for f in Slirp GLib StikJIT; do
    rm -rf "$here/Frameworks/$f.xcframework"
    cp -R "$crate_ios/Frameworks/$f.xcframework" "$here/Frameworks/"
done
cp "$kernel" "$here/Resources/vmlinux"
"$here/Scripts/fetch-fonts.sh"
# The containerization fork sits next to this repo (see the README).
"${CONTAINERIZATION:-$here/../../containerization}/scripts/build-crate.sh" >/dev/null
echo "frameworks and kernel in place"
