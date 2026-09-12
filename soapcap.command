#!/usr/bin/env bash
# Double-click entry point. Finder opens a .command file in Terminal.app
# automatically and runs it there — this just cd's to the repo (following
# symlinks, so a Desktop shortcut works) and hands off to the guided flow.
# See README "Clickable shortcut".
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

exec ./bin/soapcap session "$@"
