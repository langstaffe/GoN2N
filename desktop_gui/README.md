# GoN2N Flutter Desktop GUI

This GUI is currently focused on Windows. It starts the official ntop/n2n
`edge.exe` process and displays its logs.

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

The GUI saves server, port, community, virtual IP, shared key, edge path, and
relay preference.
