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

# `note` — local SOAP/DAP/BIRP generation via Ollama. Defaults shown;
# uncomment to tune. See README "note" for why llama3.1:8b (~5GB) is the
# default over the smaller/faster llama3.2:3b (~2GB) despite the memory
# cost — real testing found 3b unreliable at not fabricating clinical
# Objective-section content.
# SOAPCAP_MODEL="llama3.1:8b"
# SOAPCAP_FORMAT="soap"             # soap | dap | birp
# SOAPCAP_OLLAMA_HOST="http://localhost:11434"
