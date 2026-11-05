# Louppe app icon ("In Review")

Files here:
- `AppIcon.icon` — native Icon Composer source for macOS 26 appearances
- `AppIcon-1024.png` — 1024×1024 master
- `AppIcon.iconset/` and `AppIcon.icns` — previous legacy bitmap sources

## Build the app icon

`build_app.sh` compiles `AppIcon.icon` with Xcode's asset compiler. The build
ships both `Assets.car` for native Default/Dark/Clear/Tinted rendering and an
automatically generated `AppIcon.icns` fallback.

Rebuild with:

    ./build_app.sh

(If the Dock/Finder still shows the old icon, it's icon caching — a logout/login
or `killall Dock Finder` clears it.)
