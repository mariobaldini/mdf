#!/bin/sh
# Package the already optimized runtime files without rebuilding or changing them.
set -eu
umask 022
mdf_stage=$1
mdf_version=$2
desktop-file-validate assets/mdf.desktop
mdf_package_release=${MDF_PACKAGE_RELEASE:-1}
case "$mdf_package_release" in
    ''|0*|*[!0-9]*) printf '%s\n' 'MDF_PACKAGE_RELEASE must be a positive integer.' >&2; exit 1 ;;
esac
mdf_deb_version=$mdf_version
if [ -n "${MDF_PACKAGE_RELEASE:-}" ]; then mdf_deb_version="$mdf_version-$mdf_package_release"; fi
mdf_cairo_rpm_requires=
mdf_cairo_deb_depends=
if grep -q '^MDF_BUNDLED_CAIRO:BOOL=OFF$' build/fltk-ui/ReleaseFast/CMakeCache.txt;then
    mdf_cairo_rpm_requires='Requires: libcairo.so.2()(64bit)
Requires: cairo >= 1.18'
    mdf_cairo_deb_depends=', libcairo2 (>= 1.18)'
fi
mdf_package_work=$(mktemp -d "$mdf_stage/.packages.XXXXXX")
trap 'rm -rf "$mdf_package_work"' EXIT HUP INT TERM

mkdir -p "$mdf_package_work/rpm/SOURCES" "$mdf_package_work/rpm/SPECS" "$mdf_package_work/tmp"
cp "$mdf_stage/mdf" "$mdf_package_work/rpm/SOURCES/"
cp assets/mdf.desktop "$mdf_package_work/rpm/SOURCES/"
cat > "$mdf_package_work/rpm/SPECS/mdf.spec" <<SPEC
%global debug_package %{nil}
%global __os_install_post %{nil}
%global _build_id_links none
%global source_date_epoch_from_changelog 0
Name: mdf
Version: $mdf_version
Release: $mdf_package_release
Summary: Markdown FAST native Markdown viewer
License: LicenseRef-Markdown-FAST AND PolyForm-Noncommercial-1.0.0 AND MPL-2.0 AND LGPL-2.1-or-later AND LGPL-2.1-only
URL: https://github.com/mariobaldini/mdf
BuildArch: x86_64
Requires: glibc >= 2.38
Requires: desktop-file-utils
Requires: shared-mime-info
Requires: libwayland-client.so.0()(64bit)
Requires: libwayland-cursor.so.0()(64bit)
Requires: libxkbcommon.so.0()(64bit)
Requires: libgio-2.0.so.0()(64bit)
Requires: libglib-2.0.so.0()(64bit)
Requires: libgobject-2.0.so.0()(64bit)
Requires: libfribidi.so.0()(64bit)
Requires: libharfbuzz.so.0()(64bit)
Requires: libfreetype.so.6()(64bit)
Requires: libpixman-1.so.0()(64bit)
Requires: libfontconfig.so.1()(64bit)
Requires: glib2 >= 2.82
Requires: pixman >= 0.40
$mdf_cairo_rpm_requires
Requires: fontconfig >= 2.17
Requires: harfbuzz >= 8.4
Recommends: xdg-desktop-portal

%description
Markdown FAST is a native Markdown viewer with a table of contents and minimap.
Bundled license notices are available with mdf --licenses.
Includes Pozeiden under PolyForm Noncommercial 1.0.0; commercial use requires separate upstream permission.

%prep
%build
%install
mkdir -p "%{buildroot}/usr/bin"
install -m 755 "%{_sourcedir}/mdf" "%{buildroot}/usr/bin/mdf"
mkdir -p "%{buildroot}/usr/share/applications"
install -m 644 "%{_sourcedir}/mdf.desktop" "%{buildroot}/usr/share/applications/mdf.desktop"

%files
%defattr(-,root,root,-)
/usr/bin/mdf
/usr/share/applications/mdf.desktop
SPEC
rpmbuild --quiet -bb --define "_topdir $mdf_package_work/rpm" \
    --define "_tmppath $mdf_package_work/tmp" \
    --define '_binary_payload w9.xzdio' "$mdf_package_work/rpm/SPECS/mdf.spec"
cp "$mdf_package_work/rpm/RPMS/x86_64/mdf-$mdf_version-$mdf_package_release.x86_64.rpm" "$mdf_stage/"

mdf_deb_root="$mdf_package_work/deb"
mkdir -p "$mdf_deb_root/DEBIAN" "$mdf_deb_root/usr/bin"
install -m 755 "$mdf_stage/mdf" "$mdf_deb_root/usr/bin/mdf"
mkdir -p "$mdf_deb_root/usr/share/applications"
install -m 644 assets/mdf.desktop "$mdf_deb_root/usr/share/applications/mdf.desktop"
cat > "$mdf_deb_root/DEBIAN/control" <<CONTROL
Package: mdf
Version: $mdf_deb_version
Architecture: amd64
Maintainer: Markdown FAST maintainers <mariobaldini@users.noreply.github.com>
Depends: desktop-file-utils, shared-mime-info, libc6 (>= 2.38), libwayland-client0, libwayland-cursor0, libxkbcommon0, libglib2.0-0 (>= 2.82), libfribidi0, libharfbuzz0b (>= 8.4), libfreetype6, libpixman-1-0 (>= 0.40), libfontconfig1 (>= 2.17)$mdf_cairo_deb_depends
Recommends: xdg-desktop-portal
Section: text
Priority: optional
Homepage: https://github.com/mariobaldini/mdf
Description: Markdown FAST native Markdown viewer
 A native Markdown viewer with a table of contents and minimap.
 Bundled license notices are available with mdf --licenses.
 Includes Pozeiden under PolyForm Noncommercial 1.0.0; commercial use requires separate upstream permission.
CONTROL
(cd "$mdf_deb_root" && md5sum usr/bin/mdf usr/share/applications/mdf.desktop > DEBIAN/md5sums)
dpkg-deb --build --root-owner-group -Zxz -z9 "$mdf_deb_root" "$mdf_stage/mdf_${mdf_deb_version}_amd64.deb"
