#!/usr/bin/env bash
# Create a venv holding the PyYAML that workflow-lint.py needs, from the one
# hash-pinned requirements file. Wheels only: nothing is built or fetched
# beyond the pinned files.
#
# usage: install-pyyaml.sh <venv-dir>
# exit:  0 installed; non-zero otherwise.
set -euo pipefail

[ "$#" -eq 1 ] || { echo "install-pyyaml: usage: install-pyyaml.sh <venv-dir>" >&2; exit 2; }
req="$(cd "$(dirname "$0")" && pwd)/workflow-lint-requirements.txt"

python3 -m venv "$1"
"$1/bin/python" -I -m pip install --quiet --disable-pip-version-check \
  --require-hashes --only-binary=:all: --no-deps -r "$req"
