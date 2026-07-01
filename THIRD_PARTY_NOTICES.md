# Third-Party Notices

This project includes or distributes the following third-party components.

## n2n / edge.exe

GoN2N launches the `edge.exe` executable from the n2n project to create the
virtual LAN connection.

- Project: n2n
- Website: https://www.ntop.org/products/n2n/
- Source repository: https://github.com/ntop/n2n
- License: GNU General Public License v3.0

The bundled `edge.exe` binary is built from n2n source code and is distributed
under the terms of the GNU General Public License v3.0.

## n2nR-server

GoN2N release assets may include `n2nR-server` binaries. These binaries are
built from the n2n supernode source code with GoN2N-specific patches for fast
reconnect behavior and version reporting.

- Upstream project: n2n
- Website: https://www.ntop.org/products/n2n/
- Source repository: https://github.com/ntop/n2n
- License: GNU General Public License v3.0

The distributed `n2nR-server` binaries remain derived from n2n source code and
are distributed under the terms of the GNU General Public License v3.0.

## Flutter

The Windows desktop GUI is built with Flutter and may distribute Flutter runtime
files such as `flutter_windows.dll` as part of the Windows release package.

- Project: Flutter
- Website: https://flutter.dev/
- Source repository: https://github.com/flutter/flutter
- License: BSD-style license

## TAP-Windows Driver

GoN2N may bundle TAP-Windows driver files under
`desktop_gui/windows/tap-driver/` so the Windows application can install a TAP
adapter when one is not already present.

Bundled files may include:

- `OemVista.inf`
- `tap0901.cat`
- `tap0901.sys`
- `tap-windows-9.24.7-I601-Win10.exe`

These files come from the OpenVPN / TAP-Windows project and are distributed
under their original upstream license terms.

- Project: OpenVPN TAP-Windows
- Website: https://openvpn.net/
- Source repository: https://github.com/OpenVPN/tap-windows6

These driver files are third-party components and are not original GoN2N source
code.
