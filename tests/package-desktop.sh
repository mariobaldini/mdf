#!/usr/bin/env bash
# Exercise native package registration in the disposable CI build container.
set -euo pipefail
if [[ ! -f /.dockerenv && ! -f /run/.containerenv ]]; then
    printf '%s\n' 'Desktop package installation tests require a disposable container.' >&2
    exit 1
fi
cd "$(dirname -- "$0")/.."
mdf_fixture=$(mktemp -d)
trap 'rm -rf "$mdf_fixture"' EXIT
export XDG_CONFIG_HOME="$mdf_fixture/config" XDG_DATA_HOME="$mdf_fixture/data" LC_ALL=C
mkdir -p "$XDG_CONFIG_HOME" "$XDG_DATA_HOME/applications"
cat > "$XDG_DATA_HOME/applications/mdf-existing.desktop" <<'DESKTOP'
[Desktop Entry]
Type=Application
Name=Existing Markdown viewer
Exec=/bin/true %f
MimeType=text/markdown;
DESKTOP
update-desktop-database "$XDG_DATA_HOME/applications"
printf '[Default Applications]\ntext/markdown=mdf-existing.desktop;\n' > "$XDG_CONFIG_HOME/mimeapps.list"
cp "$XDG_CONFIG_HOME/mimeapps.list" "$mdf_fixture/default-before"
mdf_version=$(build/mdf --version);mdf_version=${mdf_version#mdf }
mdf_revision=${MDF_PACKAGE_RELEASE:-1}
. /etc/os-release
case "$ID" in
    fedora)
        dnf install -y "$(pwd)/build/mdf-$mdf_version-$mdf_revision.x86_64.rpm"
        ;;
    ubuntu)
        mdf_deb_version=$mdf_version
        if [[ -n ${MDF_PACKAGE_RELEASE:-} ]]; then mdf_deb_version+="-$mdf_revision"; fi
        apt-get install -y "$(pwd)/build/mdf_${mdf_deb_version}_amd64.deb"
        ;;
    *) exit 1 ;;
esac
gio mime text/markdown > "$mdf_fixture/registered"
cat "$mdf_fixture/registered"
grep -q '^Default application.*mdf-existing.desktop' "$mdf_fixture/registered"
grep -Fq 'mdf.desktop' "$mdf_fixture/registered"
cmp "$mdf_fixture/default-before" "$XDG_CONFIG_HOME/mimeapps.list"
printf '%s\n' 'PASS: MDF appears in Open With and preserves the existing Markdown default'
case "$ID" in
    fedora) dnf remove -y mdf ;;
    ubuntu) apt-get remove -y mdf ;;
esac
gio mime text/markdown > "$mdf_fixture/removed"
if grep -Fq 'mdf.desktop' "$mdf_fixture/removed"; then exit 1; fi
cmp "$mdf_fixture/default-before" "$XDG_CONFIG_HOME/mimeapps.list"
printf '%s\n' 'PASS: uninstall removes the handler and preserves the default'
