# shellcheck shell=bash
# soapcap model — the tested-model catalog and the default-model chooser.

# sc_model_catalog — one "tag|size|note" line per model soapcap has been
# tested with (the baselines behind README "Draft a note"). Any other
# Ollama tag still works via --model or SOAPCAP_MODEL, with a warning.
sc_model_catalog() {
  cat <<'EOF'
llama3.1:8b|~5GB|Default. Fast (usually under a minute). Often assumes a client's pronoun from their name; proofread pronouns and the Objective section.
bonsai|~6GB (16GB+ Mac)|More careful: best at pronouns and at not inventing in-session reactions. Slower (a few minutes a note). Set up with tools/bonsai/install.sh.
EOF
}

# sc_installed_models HOST DEFAULT — prints the tags that are ready to use
# right now, one per line, DEFAULT first (so bare Enter keeps it): DEFAULT
# itself, Bonsai if it's set up, then every model pulled into Ollama
# (tested or not).
sc_installed_models() {
  local host="$1" default="$2" tag
  {
    printf '%s\n' "$default"
    sc_bonsai_installed && printf 'bonsai\n'
    sc_ollama_models "$host"
  } | awk 'NF && !seen[$0]++'
}

# sc_model_table HOST — prints sc_model_catalog as an aligned, wrapped
# table (~86 columns) with a live STATUS column, one line at a time to
# stdout for the caller to route through sc_info.
sc_model_table() {
  local host="$1" tag size note status
  local pulled
  pulled=$(sc_ollama_models "$host")
  {
    while IFS='|' read -r tag size note; do
      [ -z "$tag" ] && continue
      if [ "$tag" = bonsai ]; then
        status="not set up"
        sc_bonsai_installed && status="installed"
      else
        status="not pulled"
        printf '%s\n' "$pulled" | grep -qx "$tag" && status="pulled"
      fi
      printf '%s\t%s\t%s\t%s\n' "$tag" "$size" "$status" "$note"
    done <<CATALOG
$(sc_model_catalog)
CATALOG
    # Anything else pulled into Ollama: usable, just untested.
    local gb
    while IFS=$'\t' read -r tag gb; do
      [ -z "$tag" ] && continue
      sc_model_catalog | cut -d'|' -f1 | grep -qx "$tag" && continue
      printf '%s\t~%sGB\tpulled\tUntested with soapcap'"'"'s prompts — proofread its notes closely.\n' \
        "$tag" "$(awk -v b="$gb" 'BEGIN { printf "%.0f", b / 1e9 }')"
    done <<EXTRAS
$(curl -s --max-time 3 "$host/api/tags" 2>/dev/null | jq -r '.models[]? | "\(.name)\t\(.size)"' 2>/dev/null)
EXTRAS
  } | awk -F'\t' -v tagw=13 -v sizew=17 -v statw=11 -v notew=42 '
    function pad(s, w) { return sprintf("%-" w "s", s) }
    BEGIN {
      printf "%s %s %s %s\n", pad("MODEL",tagw), pad("SIZE",sizew), pad("STATUS",statw), "NOTES"
      printf "%s %s %s %s\n", pad("-----",tagw), pad("----",sizew), pad("------",statw), "-----"
    }
    {
      n = split($4, words, " ")
      line = ""; first = 1
      for (i = 1; i <= n; i++) {
        cand = (line == "") ? words[i] : line " " words[i]
        if (length(cand) > notew && line != "") {
          if (first) { printf "%s %s %s %s\n", pad($1,tagw), pad($2,sizew), pad($3,statw), line; first = 0 }
          else       { printf "%s %s %s %s\n", pad("",tagw), pad("",sizew), pad("",statw), line }
          line = words[i]
        } else line = cand
      }
      if (first) printf "%s %s %s %s\n", pad($1,tagw), pad($2,sizew), pad($3,statw), line
      else       printf "%s %s %s %s\n", pad("",tagw), pad("",sizew), pad("",statw), line
    }
  '
}

# sc_save_model_config TAG — persists TAG as SOAPCAP_MODEL in config.sh
# (creating ~/.config/soapcap/config.sh if it doesn't exist yet), so
# session/note pick it up as the new default without needing --model. An
# existing SOAPCAP_MODEL line is replaced where it stands; the file is
# rewritten in place, so a config.sh that is a symlink stays one. Also used
# by install.sh, which sources this file for it.
sc_save_model_config() {
  local tag="$1" cfg="${SOAPCAP_CONFIG:-$HOME/.config/soapcap/config.sh}" body
  mkdir -p "$(dirname "$cfg")"
  if [ -f "$cfg" ] && grep -q '^SOAPCAP_MODEL=' "$cfg"; then
    body=$(awk -v line="SOAPCAP_MODEL=\"$tag\"" '/^SOAPCAP_MODEL=/ { print line; next } { print }' "$cfg")
    printf '%s\n' "$body" > "$cfg"
  else
    printf 'SOAPCAP_MODEL="%s"\n' "$tag" >> "$cfg"
  fi
}

# soapcap model [--host URL]
#
# Shows the tested models as a table (with live status) and, with a real
# terminal, offers to pick one — pulling an Ollama model if needed — and
# saves the pick as the new default for session/note (still overridable
# per-run with --model). Read-only when not interactive.
sc_cmd_model() {
  local host="$SOAPCAP_OLLAMA_HOST"
  while [ $# -gt 0 ]; do
    case "$1" in
      --host)    host="${2:?}"; shift 2 ;;
      -h|--help) sc_usage; return 0 ;;
      *) sc_die "model: unknown option: $1" ;;
    esac
  done

  sc_need curl; sc_need jq
  sc_info "Current default: $SOAPCAP_MODEL"
  if ! sc_model_catalog | cut -d'|' -f1 | grep -qx "$SOAPCAP_MODEL"; then
    sc_info "  (a custom model — untested with soapcap's prompts)"
  fi
  sc_info ""
  while IFS= read -r line; do sc_info "$line"; done <<TABLE
$(sc_model_table "$host")
TABLE
  sc_info ""
  sc_info "Models not in the tested list work too, untested — see 'soapcap help' (OTHER MODELS)."
  sc_info ""

  [ -t 0 ] || return 0

  # $SOAPCAP_MODEL always leads the choices (and is the bare-Enter
  # default), so hitting Enter here never silently changes anything —
  # including when it's a custom model set in config.sh.
  local tag tags=("$SOAPCAP_MODEL")
  while IFS='|' read -r tag _ _; do
    [ -z "$tag" ] || [ "$tag" = "$SOAPCAP_MODEL" ] && continue
    tags+=("$tag")
  done <<CATALOG
$(sc_model_catalog)
CATALOG
  # Plus every other model already pulled into Ollama (untested).
  while IFS= read -r tag; do
    [ -z "$tag" ] && continue
    case " ${tags[*]} " in *" $tag "*) continue ;; esac
    tags+=("$tag")
  done <<PULLED
$(sc_ollama_models "$host")
PULLED

  local chosen
  chosen=$(sc_choose "Pick a model:" "${tags[@]}")

  if [ "$chosen" = "$SOAPCAP_MODEL" ]; then
    sc_info "Default unchanged ($SOAPCAP_MODEL)."
    return 0
  fi

  if [ "$chosen" = bonsai ]; then
    if ! sc_bonsai_installed; then
      sc_err "Bonsai isn't set up yet — run: $SC_ROOT/tools/bonsai/install.sh"
      sc_info "Default unchanged ($SOAPCAP_MODEL)."
      return 1
    fi
  else
    local pulled
    pulled=$(sc_ollama_models "$host")
    if ! printf '%s\n' "$pulled" | grep -qx "$chosen"; then
      sc_confirm "$chosen isn't pulled yet — pull it now?" || { sc_info "Not pulled — default unchanged ($SOAPCAP_MODEL)."; return 1; }
      if ! command -v ollama >/dev/null 2>&1; then
        sc_err "ollama CLI not found on PATH — install with: brew install ollama"
        return 1
      fi
      ollama pull "$chosen" || { sc_err "pull failed — default unchanged ($SOAPCAP_MODEL)"; return 1; }
    fi
  fi

  sc_save_model_config "$chosen"
  sc_info "Saved — session/note will use $chosen by default (override any time with --model)."
}
