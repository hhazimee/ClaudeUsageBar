#!/bin/bash
# Runs the auth library's tests. The app itself still builds with app/build.sh.
set -euo pipefail
cd "$(dirname "$0")"
swift test "$@"
