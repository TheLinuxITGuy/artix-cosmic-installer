#!/usr/bin/env bash
# install-davinci-resolve -- build DaVinci Resolve from the AUR using the zip
# you downloaded from Blackmagic. The AUR package can't download it for you.
#
# Usage (as your normal user, NOT root):
#   install-davinci-resolve          # Studio edition (default)
#   install-davinci-resolve free     # free edition
set -euo pipefail

URL="https://www.blackmagicdesign.com/support/family/davinci-resolve-and-fusion"
case "${1:-studio}" in
    studio) PKG=davinci-resolve-studio; NAME="DaVinci Resolve Studio" ;;
    free)   PKG=davinci-resolve;        NAME="DaVinci Resolve" ;;
    *) echo "Usage: install-davinci-resolve [studio|free]"; exit 1 ;;
esac
[[ $EUID -ne 0 ]] || { echo "Run this as your normal user, not root/sudo (it asks for sudo when needed)."; exit 1; }
for c in git makepkg; do command -v "$c" >/dev/null || { echo "Missing '$c' -- install base-devel and git."; exit 1; }; done

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
echo "==> Fetching the current $PKG PKGBUILD from the AUR"
git clone -q --depth 1 "https://aur.archlinux.org/$PKG.git" "$work/$PKG"
cd "$work/$PKG"

ver=$(awk -F' = ' '/^\tpkgver = /{print $2; exit}' .SRCINFO)
want=$(grep -oE '[^ /=]+_Linux\.zip' .SRCINFO | head -1)
[[ -n "$want" ]] || { echo "Couldn't work out which zip $PKG expects -- check https://aur.archlinux.org/packages/$PKG"; exit 1; }

zip=""
for d in "$HOME/Downloads" "$HOME" "$PWD" "${OLDPWD:-$HOME}"; do
    [[ -f "$d/$want" ]] && { zip="$d/$want"; break; }
done

if [[ -z "$zip" ]]; then
    cat <<EOF

The AUR package needs:  $want   ($NAME $ver for Linux)

  1. Open $URL
  2. Download "$NAME $ver" -> Linux (fill in the short form to start the download)
  3. Save the zip to ~/Downloads without renaming it
  4. Run install-davinci-resolve${1:+ $1} again
EOF
    other=$(ls -1 "$HOME"/Downloads/DaVinci_Resolve*_Linux.zip 2>/dev/null | head -3 || true)
    [[ -n "$other" ]] && printf '\nFound in ~/Downloads, but not the version/edition the AUR expects:\n%s\n' "$other"
    if [[ -n "${WAYLAND_DISPLAY:-}${DISPLAY:-}" ]] && command -v xdg-open >/dev/null; then
        xdg-open "$URL" >/dev/null 2>&1 &
    fi
    exit 1
fi

echo "==> Using $zip"
ln -sf "$zip" "$want"
echo "==> Building $PKG $ver (this takes a while; you'll be asked for your sudo password)"
makepkg -si --noconfirm --needed

# Studio activation needs a license dir your user can write to
sudo install -dm0755 -o "$USER" -g "$(id -gn)" /opt/resolve/.license
echo "==> Done. Start $NAME from the app library."
