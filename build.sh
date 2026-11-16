#!/usr/bin/env bash
# Builds the 3D rain from matrix-rain.c.
#
# On Linux:
#   matrix-rain   for Linux, which install.sh puts on each machine
#                 needs: sudo apt install gcc libgl-dev libx11-dev libxrandr-dev
#   Matrix.scr    for Windows, which install.ps1 puts on each machine; skipped without the cross-compiler
#                 needs: sudo apt install gcc-mingw-w64-x86-64
# On macOS:
#   matrix-rain-macos   for this Mac, to try it out. install-macos.sh builds its own copy on every Mac it
#                       installs on, so nothing built here is deployed.
#                       needs: xcode-select --install
#
# Both files built on Linux are kept in the project, so deploying from a Mac or from Windows needs no compiler.
set -e
cd "$(dirname "$0")"
if [ "$(uname -s)" = Darwin ]; then
    clang -x objective-c -fobjc-arc -O2 -o matrix-rain-macos matrix-rain.c -framework Cocoa -framework OpenGL
    echo "built $(pwd)/matrix-rain-macos"
    exit 0
fi
gcc -O2 -Wall -Wextra -o matrix-rain matrix-rain.c -lGL -lX11 -lXrandr -lm
echo "built $(pwd)/matrix-rain"
windows_gcc=$(command -v x86_64-w64-mingw32-gcc || command -v x86_64-w64-mingw32-gcc-win32 || true)
if [ -n "$windows_gcc" ]; then
    "$windows_gcc" -O2 -Wall -Wextra -o Matrix.scr matrix-rain.c -lopengl32 -lgdi32 -luser32 -mwindows -static
    echo "built $(pwd)/Matrix.scr"
else
    echo "no Windows cross-compiler: Matrix.scr not rebuilt" >&2
fi
