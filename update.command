#!/usr/bin/env bash
# Double-click entry point to pull the latest soapcap changes. Finder opens
# a .command file in Terminal.app automatically. Only meaningful for a git
# clone -- install.sh only creates a Desktop shortcut to this file when the
# repo actually is one; running it directly against a ZIP-downloaded copy
# just prints a clear explanation instead of a raw git error.
set -u

_src="${BASH_SOURCE[0]}"
while [ -h "$_src" ]; do
  _dir=$(cd -P "$(dirname "$_src")" && pwd)
  _src=$(readlink "$_src")
  case "$_src" in
    /*) ;;
    *) _src="$_dir/$_src" ;;
  esac
done
cd -P "$(dirname "$_src")" || exit 1

if [ ! -d .git ]; then
  echo "This copy of soapcap wasn't installed via git, so it can't check for"
  echo "updates this way. Download the latest version instead:"
  echo "  https://github.com/pglockner/soapcap"
  echo
  read -r -p "Press Enter to close..." _ || true
  exit 1
fi

echo "==> Checking for soapcap updates..."
git pull
echo
read -r -p "Press Enter to close..." _ || true
