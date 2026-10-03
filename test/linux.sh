#!/usr/bin/env bash
# Runs CI's checks (shellcheck, then test/run.sh) in an Ubuntu container, so
# Linux-only failures (bash 5, GNU tools, util-linux `script`) show up
# before a push. Needs a Docker-compatible runtime, e.g. OrbStack or Docker
# Desktop.
#
#   test/linux.sh             run both steps
#   test/linux.sh --rebuild   rebuild the image first (new Ubuntu packages)
set -eu

here=$(cd "$(dirname "$0")/.." && pwd)
image=soapcap-linux-test

command -v docker >/dev/null 2>&1 || { echo "linux.sh: docker not found (install OrbStack or Docker Desktop)" >&2; exit 1; }
docker info >/dev/null 2>&1 || { echo "linux.sh: the Docker daemon isn't running (start OrbStack/Docker Desktop)" >&2; exit 1; }

if [ "${1:-}" = --rebuild ] || ! docker image inspect "$image" >/dev/null 2>&1; then
  echo "== building $image (ubuntu 24.04, as on GitHub's ubuntu-latest)"
  docker build -q -t "$image" - <<'EOF'
FROM ubuntu:24.04
RUN apt-get update -qq && apt-get install -y -qq shellcheck jq perl procps bsdutils util-linux curl less python3 >/dev/null
EOF
fi

# The shellcheck line is read from the workflow so the two can't drift.
sc_cmd=$(grep -m1 '^ *shellcheck ' "$here/.github/workflows/shellcheck.yml" | sed 's/^ *//')
[ -n "$sc_cmd" ] || { echo "linux.sh: no shellcheck command found in the workflow" >&2; exit 1; }

# A copy, not a bind mount of the repo itself: the tests write temp files
# and mustn't touch the working tree.
docker run --rm -e LANG=C.UTF-8 -v "$here":/src:ro "$image" bash -c '
  set -e
  cp -a /src /work && cd /work
  echo "== shellcheck"
  '"$sc_cmd"'
  echo "== fixture tests"
  test/run.sh
'
