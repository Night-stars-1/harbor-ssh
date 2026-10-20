#!/usr/bin/env bash
#
# Build the Harbor SSH Linux release packages from the Flutter bundle.
#
# Usage: bash tool/package_linux.sh [version]
#
# Run from the repository root (the script also resolves the root from its own
# location). Without an argument the version is read from pubspec.yaml and the
# "+build" suffix is dropped. A release tag such as "v1.0.39" is accepted and
# the leading "v" is stripped.
#
# Outputs:
#   build/linux/packages/harbor-ssh-linux-amd64.deb
#   build/linux/packages/harbor-ssh-linux-x64.tar.gz

set -euo pipefail

die() {
  printf 'package_linux: %s\n' "$*" >&2
  exit 1
}

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
repo_root="$(cd -- "$script_dir/.." && pwd -P)"
cd -- "$repo_root"

bundle_dir="build/linux/x64/release/bundle"
binary_name="harbor_ssh"
icon_src="assets/branding/harbor-ssh-icon.png"
desktop_src="linux/packaging/harbor-ssh.desktop"
control_src="linux/packaging/control.in"
output_dir="build/linux/packages"
deb_out="$output_dir/harbor-ssh-linux-amd64.deb"
tar_out="$output_dir/harbor-ssh-linux-x64.tar.gz"

[ "$(uname -s)" = "Linux" ] || die "Linux release packaging requires a Linux host."
command -v dpkg-deb >/dev/null 2>&1 || die "dpkg-deb is required (install the dpkg package)."
command -v tar >/dev/null 2>&1 || die "tar is required."

version="${1:-}"
if [ -z "$version" ]; then
  [ -f "pubspec.yaml" ] || die "pubspec.yaml not found in $repo_root."
  version="$(sed -n 's/^version:[[:space:]]*//p' pubspec.yaml | sed -n '1p' | tr -d '\r')"
  version="${version%%[[:space:]]*}"
fi
version="${version#v}"
version="${version%%+*}"

[ -n "$version" ] || die "Could not determine a version; pass one explicitly."

# Debian versions use "~" for pre-release ordering and reserve "-" for the
# package revision, so a tag such as 1.0.39-rc1 becomes 1.0.39~rc1.
if [[ "$version" == *-* ]]; then
  version="${version//-/\~}"
fi
[[ "$version" =~ ^[0-9][0-9A-Za-z.+~]*$ ]] ||
  die "Version '$version' is not a valid Debian version (expected e.g. 1.0.39)."

[ -d "$bundle_dir" ] ||
  die "Missing Flutter Linux release bundle '$bundle_dir'. Run: flutter build linux --release"
[ -x "$bundle_dir/$binary_name" ] ||
  die "Missing executable '$bundle_dir/$binary_name'; rebuild the Linux release bundle."
[ -f "$icon_src" ] || die "Missing branding icon '$icon_src'."
[ -f "$desktop_src" ] || die "Missing desktop entry '$desktop_src'."
[ -f "$control_src" ] || die "Missing Debian control template '$control_src'."

mkdir -p -- "$output_dir"

work_dir="$(mktemp -d "${TMPDIR:-/tmp}/harbor-ssh-package.XXXXXX")"
cleanup() {
  rm -rf -- "$work_dir"
}
trap cleanup EXIT

# ---------------------------------------------------------------- Debian ---

deb_root="$work_dir/deb"
install -d -m 0755 -- \
  "$deb_root/DEBIAN" \
  "$deb_root/opt/harbor-ssh" \
  "$deb_root/usr/bin" \
  "$deb_root/usr/share/applications" \
  "$deb_root/usr/share/pixmaps"

cp -a -- "$bundle_dir/." "$deb_root/opt/harbor-ssh/"
ln -s -- /opt/harbor-ssh/"$binary_name" "$deb_root/usr/bin/harbor-ssh"
install -m 0644 -- "$desktop_src" "$deb_root/usr/share/applications/com.harborssh.harbor_ssh.desktop"
install -m 0644 -- "$icon_src" "$deb_root/usr/share/pixmaps/harbor-ssh.png"

installed_size="$(du -sk -- "$deb_root" | cut -f1)"
sed \
  -e "s/@VERSION@/$version/" \
  -e "s/@INSTALLED_SIZE@/$installed_size/" \
  -- "$control_src" > "$deb_root/DEBIAN/control"
chmod 0644 -- "$deb_root/DEBIAN/control"

deb_tmp="$work_dir/harbor-ssh-linux-amd64.deb"
dpkg-deb --root-owner-group --build -- "$deb_root" "$deb_tmp"

# ------------------------------------------------------------- tar.gz ------

tar_stage="$work_dir/tar"
tar_top="harbor-ssh-linux-x64"
install -d -m 0755 -- "$tar_stage/$tar_top"
cp -a -- "$bundle_dir/." "$tar_stage/$tar_top/"
tar_tmp="$work_dir/harbor-ssh-linux-x64.tar.gz"
tar -C "$tar_stage" -czf "$tar_tmp" -- "$tar_top"

mv -f -- "$deb_tmp" "$deb_out"
mv -f -- "$tar_tmp" "$tar_out"

printf 'Packaged Harbor SSH %s\n' "$version"
printf '  %s\n' "$deb_out"
printf '  %s\n' "$tar_out"
