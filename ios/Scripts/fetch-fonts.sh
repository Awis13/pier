#!/bin/sh
# Fetches the terminal's fonts (Nerd Fonts, Mono variants) into Resources/Fonts.
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
version=v3.5.1
dest=$here/Resources/Fonts
cache=${TMPDIR:-/tmp}/pier-nerd-fonts
mkdir -p "$dest/licenses" "$cache"
# archive:file-prefix
for pair in JetBrainsMono:JetBrainsMonoNerdFontMono FiraCode:FiraCodeNerdFontMono Hack:HackNerdFontMono \
    CascadiaCode:CaskaydiaCoveNerdFontMono IBMPlexMono:BlexMonoNerdFontMono SourceCodePro:SauceCodeProNerdFontMono \
    Meslo:MesloLGSNerdFontMono VictorMono:VictorMonoNerdFontMono CommitMono:CommitMonoNerdFontMono \
    GeistMono:GeistMonoNerdFontMono UbuntuMono:UbuntuMonoNerdFontMono; do
    name=${pair%%:*}
    prefix=${pair#*:}
    if [ ! -d "$cache/$name" ]; then
        mkdir -p "$cache/$name"
        curl -fsSL "https://github.com/ryanoasis/nerd-fonts/releases/download/$version/$name.tar.xz" | tar -xJ -C "$cache/$name"
    fi
    for style in Regular Bold Italic BoldItalic; do
        for ext in ttf otf; do
            [ -f "$cache/$name/$prefix-$style.$ext" ] && cp "$cache/$name/$prefix-$style.$ext" "$dest/"
        done
    done
    for lic in "$cache/$name"/LICENSE* "$cache/$name"/LICENCE* "$cache/$name"/OFL*; do
        [ -f "$lic" ] && cp "$lic" "$dest/licenses/$name-$(basename "$lic")"
    done
done
echo "fonts in Resources/Fonts"
