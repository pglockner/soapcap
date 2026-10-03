# shellcheck shell=bash
# soapcap configuration — copy to ~/.config/soapcap/config.sh and edit.
# This file is sourced by bin/soapcap. Every setting is optional; flags on
# the command line win over anything set here.
#
# Every variable below is read by lib/common.sh after this file is sourced,
# not within this file itself — shellcheck can't see that across files.
# shellcheck disable=SC2034

# Speaker labels applied to the two audio sources.
SOAPCAP_MIC_LABEL="Therapist"     # your microphone
SOAPCAP_SYSTEM_LABEL="Client"     # the other party (call / system audio)

# Force a transcription locale, e.g. "en-US". Empty = macOS system default.
SOAPCAP_LOCALE=""

# Dedupe pass (drops mic-side audio bleed when not wearing headphones —
# see README "Without headphones"). Defaults shown; uncomment to tune.
# SOAPCAP_DEDUPE_WINDOW=3.5
# SOAPCAP_DEDUPE_THRESHOLD=0.7
# SOAPCAP_DEDUPE_MINWORDS=2

# `note` — local SOAP/DAP/BIRP generation. Defaults shown; uncomment to
# tune. Tested models: llama3.1:8b (Ollama, the default) and bonsai
# (tools/bonsai/install.sh). Any other Ollama tag works but is untested
# with soapcap's prompts — see README "Draft a note".
# SOAPCAP_MODEL="llama3.1:8b"       # or "bonsai"
# SOAPCAP_FORMAT="soap"             # soap | dap | birp
# SOAPCAP_STYLE="narrative"         # narrative | structured | combined —
#                                   # see README "Note style"; combined takes
#                                   # roughly twice as long, and the window
#                                   # app doesn't show its review yet
# SOAPCAP_OLLAMA_HOST="http://localhost:11434"   # any other machine gets the
#                                   # transcript over the network (soapcap
#                                   # warns when it isn't this Mac)

# `session` asks a few yes/no questions each time. Answer any of them here
# ("yes" or "no") and it stops asking that one; leave it out to be asked.
# SOAPCAP_SESSION_DEIDENTIFY="yes"        # de-identify the transcript and note
# SOAPCAP_SESSION_SAVE_TRANSCRIPT="no"    # save the de-identified transcript
# SOAPCAP_SESSION_SHOW_TRANSCRIPT="no"    # print the transcript
# SOAPCAP_SESSION_NOTE="yes"              # draft a note, in SOAPCAP_FORMAT

# The note's first line, e.g. "63 minutes, telehealth". session fills in
# the minutes from recording time (pauses excluded); note takes --duration.
# SOAPCAP_SESSION_TYPE="telehealth"

# Where session saves a de-identified transcript, if you choose to. Keep
# it out of any folder that syncs to a cloud service (iCloud Drive's
# "Desktop & Documents Folders", Dropbox, ...).
# SOAPCAP_SAVE_DIR="$HOME/soapcap/transcripts"

# Bonsai's install location (export it when running tools/bonsai/install.sh
# too, if you change it) — or instead point the two paths at a llama-server
# build of PrismML's llama.cpp fork and the PTQ1_0 GGUF you already have.
# SOAPCAP_BONSAI_DIR="$HOME/.local/share/soapcap/bonsai"
# SOAPCAP_BONSAI_SERVER="$HOME/somewhere/llama.cpp/build/bin/llama-server"
# SOAPCAP_BONSAI_GGUF="$HOME/somewhere/Ternary-Bonsai-2-27B-PTQ1_0.gguf"
# SOAPCAP_BONSAI_PORT=18080         # localhost port for its temporary server
