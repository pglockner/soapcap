# shellcheck shell=bash
# soapcap doctor — environment and permission checks.

sc_cmd_doctor() {
  local fail=0 v maj
  v=$(sw_vers -productVersion 2>/dev/null); maj=${v%%.*}
  if [ "${maj:-0}" -ge 26 ] 2>/dev/null; then
    sc_info "  ok    macOS $v"
  else
    sc_info "  FAIL  macOS ${v:-unknown} — yap needs macOS 26 (Tahoe) or newer"
    fail=1
  fi

  local chip mem_bytes mem_gb ncpu
  chip=$(sysctl -n machdep.cpu.brand_string 2>/dev/null)
  ncpu=$(sysctl -n hw.ncpu 2>/dev/null)
  mem_bytes=$(sysctl -n hw.memsize 2>/dev/null)
  mem_gb=$(( ${mem_bytes:-0} / 1073741824 ))
  if printf '%s' "$chip" | grep -qi apple; then
    sc_info "  ok    $chip, ${mem_gb}GB unified memory, ${ncpu:-?} cores"
  else
    sc_info "  FAIL  $chip — yap's distributed build and SpeechAnalyzer's on-device"
    sc_info "        model both target Apple silicon; an Intel Mac is not expected to work"
    fail=1
  fi
  if [ "$mem_gb" -ge 32 ] 2>/dev/null; then
    sc_info "        ${mem_gb}GB: comfortable for 'note' with either gemma4-e4b or bonsai"
  elif [ "$mem_gb" -ge 16 ] 2>/dev/null; then
    sc_info "        ${mem_gb}GB: gemma4-e4b (default) works; close memory-heavy apps"
    sc_info "        (browsers, other local models) first. bonsai fits too, but uses"
    sc_info "        most of this memory while it drafts"
  elif [ "$mem_gb" -gt 0 ] 2>/dev/null; then
    sc_info "        ${mem_gb}GB: tight for local note drafting — gemma4-e4b takes ~6.5GB,"
    sc_info "        so close other apps before 'note'; bonsai needs 16GB+"
  fi

  local disk_avail_kb disk_avail_gb
  disk_avail_kb=$(df -k "$HOME" 2>/dev/null | awk 'NR==2{print $4}')
  disk_avail_gb=$(( ${disk_avail_kb:-0} / 1048576 ))
  if [ "$disk_avail_gb" -lt 6 ] 2>/dev/null; then
    sc_info "  WARN  only ${disk_avail_gb}GB free on $HOME's volume — note models run"
    sc_info "        5–6GB each (gemma4-e4b is ~5GB)"
  fi

  if command -v yap >/dev/null 2>&1; then
    local yv
    yv=$(brew list --versions yap 2>/dev/null | awk '{print $2}')
    sc_info "  ok    yap ${yv:-(installed)} ($(command -v yap))"
  else
    sc_info "  FAIL  yap not found — install with: brew install yap"
    fail=1
  fi

  if command -v jq >/dev/null 2>&1; then
    sc_info "  ok    jq $(jq --version 2>/dev/null | sed 's/^jq-//') ($(command -v jq))"
  else
    sc_info "  FAIL  jq not found — install with: brew install jq"
    fail=1
  fi

  if [ "$fail" -eq 0 ]; then
    sc_info "  ..    probing Microphone + Screen Recording permission (3s)…"
    if sc_capture "MicProbe" "SysProbe" "" 3 \
        && printf '%s' "$SC_JSON" | jq -e '.segments' >/dev/null 2>&1; then
      sc_info "  ok    yap ran and returned valid JSON — permissions look granted"
    else
      sc_info "  WARN  yap did not return usable output."
      sc_info "        Grant BOTH Microphone and Screen Recording to your terminal"
      sc_info "        app in System Settings > Privacy & Security, then re-run."
      fail=1
    fi
  fi

  sc_info ""
  # The tested models: a missing one is WARN only when it's the default.
  local tag label pulled
  while IFS='|' read -r tag _; do
    label=$(sc_engine_label "$tag")
    if sc_engine_installed "$tag"; then
      if [ "$tag" = "$SOAPCAP_MODEL" ]; then
        sc_info "  ok    $label set up — 'note' is ready"
      else
        sc_info "  ok    $label set up — 'note --model $tag' is ready"
      fi
    elif [ "$tag" = "$SOAPCAP_MODEL" ]; then
      sc_info "  WARN  your default model, $label, isn't set up"
      sc_info "        set up with: $SC_ROOT/tools/models/install.sh $tag   (install.sh offers it too)"
    else
      sc_info "  --    $label not set up — optional note model"
      sc_info "        set up with: $SC_ROOT/tools/models/install.sh $tag"
    fi
  done <<CATALOG
$(sc_model_catalog)
CATALOG

  # Ollama only matters when the default is a model it serves.
  if [ "$(sc_backend "$SOAPCAP_MODEL")" = ollama ]; then
    if ! command -v ollama >/dev/null 2>&1; then
      sc_info "  WARN  your default model, $SOAPCAP_MODEL, needs Ollama, which isn't installed"
      sc_info "        install with: brew install ollama"
    elif ! pulled=$(sc_ollama_models "$SOAPCAP_OLLAMA_HOST"); then
      sc_info "  WARN  ollama installed but not running — needed for $SOAPCAP_MODEL"
      sc_info "        run: brew services start ollama   (or: ollama serve)"
    elif printf '%s\n' "$pulled" | sc_ollama_has "$SOAPCAP_MODEL"; then
      sc_info "  ok    ollama running, $SOAPCAP_MODEL pulled — 'note' is ready (untested model)"
    else
      sc_info "  WARN  ollama running, but $SOAPCAP_MODEL is not pulled — needed for 'note'"
      sc_info "        run: ollama pull $SOAPCAP_MODEL"
    fi
  fi

  # The retired default, in use or just taking up space.
  if [ "$SOAPCAP_MODEL" = "$SC_RETIRED_MODEL" ]; then
    sc_info "  WARN  your default model, llama3.1:8b, is retired — Gemma 4 E4B replaces it"
    sc_info "        replace it with: $SC_ROOT/install.sh (strongly recommended),"
    sc_info "        which sets up Gemma 4 E4B, makes it the default, and removes llama3.1:8b"
  elif sc_retired_pulled; then
    sc_info "  WARN  llama3.1:8b is still on this Mac (~5GB), but retired — Gemma 4 E4B"
    sc_info "        replaces it. Swap them with: $SC_ROOT/install.sh   (or just: ollama rm llama3.1:8b)"
  fi

  case "$SOAPCAP_STYLE" in
    narrative) sc_info "  ok    note style: narrative (the default)" ;;
    structured|combined)
      sc_info "  ok    note style: $SOAPCAP_STYLE (experimental — see docs/notes.md \"Note style\")" ;;
    *) sc_info "  WARN  SOAPCAP_STYLE='$SOAPCAP_STYLE' isn't a style — use narrative, structured, or combined" ;;
  esac

  if command -v gum >/dev/null 2>&1; then
    sc_info "  ok    gum present — 'session' prompts use it for arrow-key choose/confirm"
  else
    sc_info "  --    gum not installed — 'session' falls back to plain [Y/n] prompts"
    sc_info "        install with: brew install gum"
  fi
  if command -v fzf >/dev/null 2>&1; then
    sc_info "  ok    fzf present — 'note' with no FILE can browse for one"
  else
    sc_info "  --    fzf not installed — 'note' with no FILE needs one piped in instead"
    sc_info "        install with: brew install fzf"
  fi
  if [ -x "$SOAPCAP_DEIDENTIFY_BIN" ] && "$SOAPCAP_DEIDENTIFY_BIN" --version >/dev/null 2>&1; then
    sc_info "  ok    de-identify helper set up and runs ($SOAPCAP_DEIDENTIFY_BIN)"
  else
    sc_info "  --    de-identify helper not set up — only needed for 'soapcap deidentify'"
    sc_info "        (and the optional note de-identify offer in 'soapcap session')"
    sc_info "        set up with: tools/deidentify/install.sh   (install.sh offers it too)"
  fi

  sc_info ""
  if [ "$fail" -eq 0 ]; then
    sc_info "Ready."
  else
    sc_info "One or more checks failed — see above."
  fi
  return "$fail"
}
