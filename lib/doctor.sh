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
    sc_info "        ${mem_gb}GB: comfortable for 'note' with either llama3.1:8b or bonsai"
  elif [ "$mem_gb" -ge 16 ] 2>/dev/null; then
    sc_info "        ${mem_gb}GB: llama3.1:8b (default) works; close memory-heavy apps"
    sc_info "        (browsers, other local models) first. bonsai fits too, but uses"
    sc_info "        most of this memory while it drafts"
  elif [ "$mem_gb" -gt 0 ] 2>/dev/null; then
    sc_info "        ${mem_gb}GB: tight for local note drafting — close other apps before"
    sc_info "        'note'; bonsai needs 16GB+"
  fi

  local disk_avail_kb disk_avail_gb
  disk_avail_kb=$(df -k "$HOME" 2>/dev/null | awk 'NR==2{print $4}')
  disk_avail_gb=$(( ${disk_avail_kb:-0} / 1048576 ))
  if [ "$disk_avail_gb" -lt 6 ] 2>/dev/null; then
    sc_info "  WARN  only ${disk_avail_gb}GB free on $HOME's volume — Ollama models run"
    sc_info "        several GB each (llama3.1:8b is ~5GB)"
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
  # With bonsai as the default, Ollama is optional: its gaps are "--"
  # (informational), not WARN, so removing llama3.1:8b on purpose to free
  # space doesn't read as a problem.
  local omodel="$SOAPCAP_MODEL" olevel="WARN" oneed="needed for 'note'"
  if [ "$omodel" = bonsai ]; then
    omodel="llama3.1:8b"; olevel="--  "; oneed="only needed to switch back to llama3.1:8b"
  fi
  if command -v ollama >/dev/null 2>&1; then
    local tags
    if tags=$(curl -s --max-time 3 "$SOAPCAP_OLLAMA_HOST/api/tags" 2>/dev/null) && [ -n "$tags" ]; then
      if printf '%s' "$tags" | jq -e --arg m "$omodel" \
           '[.models[]?.name] | any(. == $m or startswith($m + ":"))' >/dev/null 2>&1; then
        if [ "$omodel" = "$SOAPCAP_MODEL" ]; then
          sc_info "  ok    ollama running, $omodel pulled — 'note' is ready"
        else
          sc_info "  ok    ollama running, $omodel pulled — 'note --model $omodel' is ready"
        fi
      else
        sc_info "  $olevel  ollama running, but $omodel is not pulled — $oneed"
        sc_info "        run: ollama pull $omodel"
      fi
    else
      sc_info "  $olevel  ollama installed but not running — $oneed"
      sc_info "        run: brew services start ollama   (or: ollama serve)"
    fi
  else
    sc_info "  --    ollama not installed — only needed for llama3.1:8b notes"
    sc_info "        install with: brew install ollama"
  fi

  if sc_bonsai_installed; then
    sc_info "  ok    Bonsai set up — 'note --model bonsai' is ready"
  elif [ "$SOAPCAP_MODEL" = bonsai ]; then
    sc_info "  WARN  your default model is bonsai, but Bonsai isn't set up"
    sc_info "        set up with: $SC_ROOT/tools/bonsai/install.sh"
  else
    sc_info "  --    Bonsai not set up — optional, slower but more careful note model"
    sc_info "        set up with: $SC_ROOT/tools/bonsai/install.sh"
  fi

  case "$SOAPCAP_STYLE" in
    narrative) sc_info "  ok    note style: narrative (the default)" ;;
    structured|combined)
      sc_info "  ok    note style: $SOAPCAP_STYLE (experimental — see README \"Note style\")" ;;
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
    sc_info "  ok    de-identify helper built and runs ($SOAPCAP_DEIDENTIFY_BIN)"
  else
    sc_info "  --    de-identify helper not built — only needed for 'soapcap deidentify'"
    sc_info "        (and the optional note de-identify offer in 'soapcap session')"
    sc_info "        build with: cd tools/deidentify-helper && swift build -c release"
    sc_info "        (or re-run install.sh)"
  fi

  sc_info ""
  if [ "$fail" -eq 0 ]; then
    sc_info "Ready."
  else
    sc_info "One or more checks failed — see above."
  fi
  return "$fail"
}
