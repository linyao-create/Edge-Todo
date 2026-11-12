#!/bin/bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
    printf 'Usage: %s /path/to/EdgeTodo.app /absolute/path/to/data\n' "$0" >&2
    exit 2
fi
app="$1"
data="$2"
if [[ "$data" != /* || ! -d "$app/Contents/MacOS" || ! -f "$app/Contents/Info.plist" ]]; then
    printf 'An existing application and an absolute data path are required.\n' >&2
    exit 2
fi
mkdir -p "$data"
/usr/bin/python3 - "$app/Contents/Info.plist" "$data" <<'PY'
import os
import plistlib
import sys
import tempfile

path, directory = sys.argv[1:]
with open(path, 'rb') as file:
    plist = plistlib.load(file)
environment = plist.setdefault('LSEnvironment', {})
environment['EDGE_TODO_DATA_DIRECTORY'] = directory
fd, temp_path = tempfile.mkstemp(dir=os.path.dirname(path))
try:
    with os.fdopen(fd, 'wb') as file:
        plistlib.dump(plist, file)
    os.replace(temp_path, path)
finally:
    if os.path.exists(temp_path):
        os.unlink(temp_path)
PY
codesign --force --sign - "$app"
codesign --verify --strict --deep "$app"
printf 'Data directory: %s\n' "$data"
