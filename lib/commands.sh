# shellcheck shell=bash
# soapcap — subcommand implementations, one file per command.

_sc_lib="${BASH_SOURCE[0]%/*}"
# shellcheck source=lib/doctor.sh
. "$_sc_lib/doctor.sh"
# shellcheck source=lib/model.sh
. "$_sc_lib/model.sh"
# shellcheck source=lib/live.sh
. "$_sc_lib/live.sh"
# shellcheck source=lib/generate.sh
. "$_sc_lib/generate.sh"
# shellcheck source=lib/bonsai.sh
. "$_sc_lib/bonsai.sh"
# shellcheck source=lib/note.sh
. "$_sc_lib/note.sh"
# shellcheck source=lib/deidentify.sh
. "$_sc_lib/deidentify.sh"
# shellcheck source=lib/session.sh
. "$_sc_lib/session.sh"
unset _sc_lib
