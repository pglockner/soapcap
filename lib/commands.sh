# shellcheck shell=bash
# soapcap — the commands (doctor, model, live, note, deidentify, session) and
# the note-model pieces they draft with (generate, ollama, bonsai).

_sc_lib="${BASH_SOURCE[0]%/*}"
# shellcheck source=lib/doctor.sh
. "$_sc_lib/doctor.sh"
# shellcheck source=lib/model.sh
. "$_sc_lib/model.sh"
# shellcheck source=lib/live.sh
. "$_sc_lib/live.sh"
# shellcheck source=lib/generate.sh
. "$_sc_lib/generate.sh"
# shellcheck source=lib/ollama.sh
. "$_sc_lib/ollama.sh"
# shellcheck source=lib/bonsai.sh
. "$_sc_lib/bonsai.sh"
# shellcheck source=lib/note.sh
. "$_sc_lib/note.sh"
# shellcheck source=lib/deidentify.sh
. "$_sc_lib/deidentify.sh"
# shellcheck source=lib/session.sh
. "$_sc_lib/session.sh"
unset _sc_lib
