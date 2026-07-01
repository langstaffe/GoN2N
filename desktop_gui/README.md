# GoN2N Flutter Desktop GUI

This GUI is currently focused on Windows x64. It starts the ntop/n2n
`edge.exe` process, manages client configuration, displays online members, and
shows connection diagnostics.

See the [Chinese GUI guide](../docs/GUI.zh-CN.md) for VS Code build and runtime
instructions.

## Create platform files

After installing Flutter, run:

```sh
cd desktop_gui
flutter create --platforms=windows .
flutter pub get
flutter test
```

## Run during development

```powershell
flutter run -d windows
```

## Release builds

Windows builds must be produced on Windows with Visual Studio Desktop
development with C++ installed:

```powershell
flutter build windows --release
```

The target computer must also have a compatible `edge.exe` binary and
TAP-Windows support. The Windows build requests administrator privileges when
opened.

The GUI saves server, port, community, member-server address, virtual IP,
shared key, member-server secret, edge path, relay preference, TAP metric
preference, and theme preference. It also supports automatic reconnect after
unexpected disconnects.
