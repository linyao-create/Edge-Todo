#!/bin/bash
set -euo pipefail

project="$(cd "$(dirname "$0")/.." && pwd)"
output="$project/dist"
if [[ $# -ge 1 ]]; then output="$1"; fi
mkdir -p "$output"
output="$(cd "$output" && pwd)"
temporary="$(mktemp -d /tmp/edgetodo-package.XXXXXX)"
trap 'rm -rf "$temporary"' EXIT
export CLANG_MODULE_CACHE_PATH="$temporary/module-cache"

# Compile a temporary copy so compiler-generated paths do not expose the source location.
mkdir -p "$temporary/source"
rsync -a --exclude='.git' --exclude='.build' --exclude='.swiftpm' --exclude='dist' \
    "$project/" "$temporary/source/"
build_source="$temporary/source"
cd "$build_source"
for arch in arm64 x86_64; do
    triple="$arch-apple-macosx14.0"
    # Avoid embedding the builder's personal project path in the distributed binary.
    swift build --disable-sandbox --triple "$triple" --scratch-path "$temporary/$arch" -c release \
        -Xswiftc -file-prefix-map -Xswiftc "$build_source=."
    bin="$(swift build --disable-sandbox --triple "$triple" --scratch-path "$temporary/$arch" -c release --show-bin-path)"
    cp "$bin/EdgeTodoApp" "$temporary/$arch-binary"
    if [[ "$arch" == arm64 ]]; then
        cp -R "$bin/EdgeTodo_EdgeTodoApp.bundle" "$temporary/"
    fi
done

distribution="$temporary/EdgeTodo 安装"
app="$distribution/EdgeTodo.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$project/AppBundle/Contents/Info.plist" "$app/Contents/"
lipo -create "$temporary/arm64-binary" "$temporary/x86_64-binary" -output "$app/Contents/MacOS/EdgeTodoApp"
python3 - "$app/Contents/MacOS/EdgeTodoApp" "$project" <<'PY'
import os
import sys

with open(sys.argv[1], 'rb') as binary:
    contents = binary.read()
for private_path in (os.path.expanduser('~'), sys.argv[2]):
    if private_path not in ('', '/') and os.fsencode(private_path) in contents:
        raise SystemExit('Build stopped: a local private path was found in the application.')
PY
cp -R "$temporary/EdgeTodo_EdgeTodoApp.bundle" "$app/Contents/Resources/"
cp -R "$project/browser/extension" "$app/Contents/Resources/BrowserExtension"
cp "$project/docs/使用说明.html" "$app/Contents/Resources/"
cp "$project/docs/使用说明.html" "$distribution/先看这里.html"
find "$app" -name .DS_Store -delete
codesign --force --sign - "$app/Contents/Resources/EdgeTodo_EdgeTodoApp.bundle"
codesign --force --sign - "$app"
codesign --verify --strict --deep "$app"
ditto -c -k --norsrc --keepParent "$distribution" "$temporary/EdgeTodo-Mac.zip"
cp "$temporary/EdgeTodo-Mac.zip" "$output/EdgeTodo-Mac.zip"
lipo -archs "$app/Contents/MacOS/EdgeTodoApp"
printf 'Created %s\n' "$output/EdgeTodo-Mac.zip"
