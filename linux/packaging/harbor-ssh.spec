# Native RPM packaging for the Flutter Linux release bundle.
#
# tool/package_linux.sh builds this spec with `rpmbuild -bb` and passes the
# two values it cannot read from the repository:
#
#   --define "_harbor_version <version>"   value for Version (may use "~")
#   --define "_harbor_stage <directory>"   staging root containing opt/ and usr/
#
# Nothing is compiled here: %install copies the already-built, already-stripped
# bundle and the launcher/desktop/icon files from the staging root.

%{!?_harbor_version:%{error:_harbor_version is not defined}}
%{!?_harbor_stage:%{error:_harbor_stage is not defined}}

Name:           harbor-ssh
Version:        %{_harbor_version}
Release:        1
Summary:        SSH workspace with terminal sessions, SFTP and port forwarding
License:        LicenseRef-Proprietary
URL:            https://github.com/Night-stars-1/harbor-ssh
Group:          Applications/Internet
BuildArch:      x86_64

# Preserve the prebuilt Flutter/native ELF objects without a debug subpackage,
# stripping, rewriting, or adding build-id links outside the application tree.
%global debug_package %{nil}
%global __os_install_post %{nil}
%global _build_id_links none

# Auto-generated ELF dependencies are deliberately kept.
Requires:       gtk3
Requires:       libsecret
Requires:       xdg-utils
# Flutter's renderer loads these dynamically, outside ELF DT_NEEDED scanning.
Requires:       libEGL.so.1()(64bit)
Requires:       libGLESv2.so.2()(64bit)
Recommends:     gnome-keyring
Recommends:     xdg-desktop-portal
Recommends:     google-noto-sans-cjk-fonts

%description
Harbor SSH is a cross-platform SSH workspace with terminal sessions,
SFTP file browsing, port forwarding and AI-assisted commands.
.
This package installs the Flutter Linux desktop bundle and its assets under
/opt/harbor-ssh and provides the /usr/bin/harbor-ssh launcher together with
the desktop entry and icon.

%prep

%install
rm -rf "%{buildroot}"
install -d -m 0755 \
  "%{buildroot}/opt/harbor-ssh" \
  "%{buildroot}/usr/bin" \
  "%{buildroot}/usr/share/applications" \
  "%{buildroot}/usr/share/pixmaps"
cp -a "%{_harbor_stage}/opt/harbor-ssh/." "%{buildroot}/opt/harbor-ssh/"
cp -a "%{_harbor_stage}/usr/bin/harbor-ssh" "%{buildroot}/usr/bin/harbor-ssh"
cp -a "%{_harbor_stage}/usr/share/applications/com.harborssh.harbor_ssh.desktop" \
  "%{buildroot}/usr/share/applications/"
cp -a "%{_harbor_stage}/usr/share/pixmaps/harbor-ssh.png" \
  "%{buildroot}/usr/share/pixmaps/"

%files
%defattr(-,root,root,-)
%dir /opt/harbor-ssh
/opt/harbor-ssh/*
/usr/bin/harbor-ssh
/usr/share/applications/com.harborssh.harbor_ssh.desktop
/usr/share/pixmaps/harbor-ssh.png
