#!/bin/bash
set -euo pipefail
script_dir="$(cd "$(dirname "$0")" && pwd -P)"
exec python3 "$script_dir/prunlet_macos_package.py" publish "$@"
