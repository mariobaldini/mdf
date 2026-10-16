#!/bin/sh
# Package the already optimized runtime files without rebuilding or changing them.
set -eu
umask 022
mdf_stage=$1
mdf_version=$2
mdf_package_work=$(mktemp -d "$mdf_stage/.packages.XXXXXX")
trap 'rm -rf "$mdf_package_work"' EXIT HUP INT TERM

mkdir -p "$mdf_package_work/rpm/SOURCES" "$mdf_package_work/rpm/SPECS" "$mdf_package_work/tmp"
cp "$mdf_stage/mdf" "$mdf_package_work/rpm/SOURCES/"
cat > "$mdf_package_work/rpm/SPECS/mdf.spec" <<SPEC
%global debug_package %{nil}
%global __os_install_post %{nil}
%global _build_id_links none
%global source_date_epoch_from_changelog 0
Name: mdf
Version: $mdf_version
Release: 1
Summary: Markdown FAST native Markdown viewer
License: LicenseRef-Markdown-FAST
URL: https://github.com/mariobaldini/mdf
BuildArch: x86_64
Requires: glibc >= 2.38
Requires: libwayland-client.so.0()(64bit)
Requires: libwayland-cursor.so.0()(64bit)
Requires: libxkbcommon.so.0()(64bit)
Requires: libpangocairo-1.0.so.0()(64bit)
Requires: libpangoft2-1.0.so.0()(64bit)
Requires: libcairo.so.2()(64bit)
Requires: libfontconfig.so.1()(64bit)

%description
Markdown FAST is a native Markdown viewer with a table of contents and minimap.
Bundled license notices are available with mdf --licenses.

%prep
%build
%install
mkdir -p "%{buildroot}/usr/bin"
install -m 755 "%{_sourcedir}/mdf" "%{buildroot}/usr/bin/mdf"

%files
%defattr(-,root,root,-)
/usr/bin/mdf
SPEC
rpmbuild --quiet -bb --define "_topdir $mdf_package_work/rpm" \
    --define "_tmppath $mdf_package_work/tmp" \
    --define '_binary_payload w9.xzdio' "$mdf_package_work/rpm/SPECS/mdf.spec"
cp "$mdf_package_work/rpm/RPMS/x86_64/mdf-$mdf_version-1.x86_64.rpm" "$mdf_stage/"

mdf_deb_root="$mdf_package_work/deb"
mkdir -p "$mdf_deb_root/DEBIAN" "$mdf_deb_root/usr/bin"
install -m 755 "$mdf_stage/mdf" "$mdf_deb_root/usr/bin/mdf"
cat > "$mdf_deb_root/DEBIAN/control" <<CONTROL
Package: mdf
Version: $mdf_version
Architecture: amd64
Maintainer: Markdown FAST maintainers <mariobaldini@users.noreply.github.com>
Depends: libc6 (>= 2.38), libwayland-client0, libwayland-cursor0, libxkbcommon0, libpangocairo-1.0-0, libpangoft2-1.0-0, libcairo2, libfontconfig1
Section: text
Priority: optional
Homepage: https://github.com/mariobaldini/mdf
Description: Markdown FAST native Markdown viewer
 A native Markdown viewer with a table of contents and minimap.
 Bundled license notices are available with mdf --licenses.
CONTROL
(cd "$mdf_deb_root" && md5sum usr/bin/mdf > DEBIAN/md5sums)
dpkg-deb --build --root-owner-group -Zxz -z9 "$mdf_deb_root" "$mdf_stage/mdf_${mdf_version}_amd64.deb"
