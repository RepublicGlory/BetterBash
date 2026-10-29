# BetterBash 0.1.1 -- runtime library. Sourced from ~/.bashrc.
#
# Abstract status interface:
#     status_register <name> <check_fn> <render_fn>
#   check_fn  -> exit 0 = active, exit 1 = inactive
#   render_fn -> stdout = display text for PS1
#
# Generic prompt-hook registration:
#     __bb_install_prompt_hook <fnname>
#   fnname is run from the single core PROMPT_COMMAND hook before each prompt.
#
# BetterBash ships one concrete status (in modules/work.bash): a red (sudo)
# hint that stays visible for BB_SUDO_TTL seconds after you run a sudo command.
# State is in-memory only (BB_SUDO_AT); no files are written.

BB_VERSION=0.1.1

BB_HOME=${BB_HOME:-$HOME/.betterbash}
BB_SUDO_TTL=${BB_SUDO_TTL:-180}
BB_HISTORY_COUNT=${BB_HISTORY_COUNT:-10}
BB_ENABLED=${BB_ENABLED:-1}
BB_GHOST=${BB_GHOST:-1}
BB_SUDO_AT=

# ---------------------------------------------------------------------------
# status registry
# ---------------------------------------------------------------------------
declare -ag BB_STATUS_NAMES=()
declare -ag BB_STATUS_CHECKS=()
declare -ag BB_STATUS_RENDERS=()

status_register() {
  local name=${1-} check=${2-} render=${3-} i
  [[ -n $name && -n $check && -n $render ]] || return 2
  for i in "${!BB_STATUS_NAMES[@]}"; do
    if [[ ${BB_STATUS_NAMES[i]} == "$name" ]]; then
      BB_STATUS_CHECKS[i]=$check
      BB_STATUS_RENDERS[i]=$render
      return 0
    fi
  done
  BB_STATUS_NAMES+=("$name")
  BB_STATUS_CHECKS+=("$check")
  BB_STATUS_RENDERS+=("$render")
}

# Translate PS1-safe literals (\[ \] \e) into the raw bytes readline needs.
# Necessary because bash does NOT re-decode \[..\] coming out of $(...).
__bb_ps1_decode() {
  local s=$1
  s=${s//\\[/$'\001'}
  s=${s//\\]/$'\002'}
  s=${s//\\033/$'\033'}
  s=${s//\\e/$'\033'}
  printf '%s' "$s"
}

__bb_status_render() {
  [[ ${BB_ENABLED:-1} == 0 ]] && return 0
  local i out='' txt
  for i in "${!BB_STATUS_NAMES[@]}"; do
    "${BB_STATUS_CHECKS[i]}" >/dev/null 2>&1 || continue
    txt=$("${BB_STATUS_RENDERS[i]}" 2>/dev/null) || continue
    out+=$txt
  done
  [[ -z $out ]] && return 0
  __bb_ps1_decode "$out"
}

# ---------------------------------------------------------------------------
# prompt-hook registry + single core hook
# ---------------------------------------------------------------------------
declare -ag __BB_PROMPT_HOOKS=()

# Append <fnname> to the core hook list (modules self-register via this).
__bb_install_prompt_hook() {
  [[ -n ${1-} ]] || return 1
  local fn=$1 i
  for i in "${!__BB_PROMPT_HOOKS[@]}"; do
    [[ ${__BB_PROMPT_HOOKS[i]} == "$fn" ]] && return 0
  done
  __BB_PROMPT_HOOKS+=("$fn")
}

__bb_ghost_ready=0
__bb_prompt_hook() {
  local i
  for i in "${!__BB_PROMPT_HOOKS[@]}"; do
    "${__BB_PROMPT_HOOKS[i]}" 2>/dev/null
  done
  if [[ ${BB_GHOST:-1} != 0 && $__bb_ghost_ready == 0 ]]; then
    if type -t bbghost >/dev/null 2>&1; then
      bbghost on >/dev/null 2>&1 && __bb_ghost_ready=1
    fi
  fi
  if [[ ${__bb_tab_native:-0} != 0 ]]; then
    __bb_tab_native=0
    __bb_bash_bind_tab
  fi
  return 0
}

# ---------------------------------------------------------------------------
# optional ghost builtin (silent: missing -> BB_GHOST=0)
# ---------------------------------------------------------------------------
  __bb_ghost_want=${BB_GHOST:-1}
if [[ ${BB_GHOST:-1} != 0 && -r $BB_HOME/bbghost.so ]]; then
  enable -f "$BB_HOME/bbghost.so" bbghost 2>/dev/null || BB_GHOST=0
else
  BB_GHOST=0
fi

# ---------------------------------------------------------------------------
# bash fallback for the ghost builtin (used only when bbghost.so is absent):
# Tab accepts the strict-prefix history suffix; path words defer to native
# completion. No painting possible without a readline redisplay hook.
# ---------------------------------------------------------------------------
__bb_tab_native=0

__bb_bash_suggest() {
  local line=$1 h
  [[ -n $line ]] || return 1
  local -a hist=()
  mapfile -t hist < <(HISTTIMEFORMAT= builtin history 2>/dev/null |
    sed 's/^[[:space:]]*[0-9]\+[[:space:]]\+//')
  local i
  for ((i = ${#hist[@]} - 1; i >= 0; i--)); do
    h=${hist[i]}
    [[ ${#h} -gt ${#line} && ${h:0:${#line}} == "$line" ]] || continue
    printf '%s' "${h:${#line}}"
    return 0
  done
  return 1
}

__bb_bash_accept() {
  local line=$READLINE_LINE word=${READLINE_LINE:0:READLINE_POINT}
  word=${word##*[[:space:]]}
  if [[ $word == */* || $word == *~* ]]; then
    # defer to readline's native completion on the next Tab
    bind '"\C-i": complete' 2>/dev/null && __bb_tab_native=1
    return 0
  fi
  local sug
  sug=$(__bb_bash_suggest "$line")
  if [[ -z $sug ]]; then
    bind '"\C-i": complete' 2>/dev/null && __bb_tab_native=1
    return 0
  fi
  READLINE_LINE=$line$sug
  READLINE_POINT=${#READLINE_LINE}
}

__bb_bash_bind_tab() {
  [[ $__bb_ghost_want != 0 ]] || return 0
  [[ $- == *i* ]] || return 0
  bind -x '"\C-i": __bb_bash_accept' 2>/dev/null
}

# no native ghost builtin? arm the bash Tab fallback once.
if ! type -t bbghost >/dev/null 2>&1; then
  __bb_bash_bind_tab
fi

# ---------------------------------------------------------------------------
# source self-registering modules (they call status_register /
# __bb_install_prompt_hook). Done BEFORE installing the prompt hook so every
# module has had a chance to register.
# ---------------------------------------------------------------------------
for __bb_m in "$BB_HOME"/modules/*.bash; do
  [[ -e $__bb_m ]] || continue
  source "$__bb_m"
done
unset __bb_m

# ---------------------------------------------------------------------------
# install the single core PROMPT_COMMAND hook AFTER sourcing modules.
# Handles both bash>=5.1 array form and legacy string form.
# ---------------------------------------------------------------------------
__bb_install_prompt_command() {
  if [[ $(declare -p PROMPT_COMMAND 2>/dev/null) == "declare -a"* ]]; then
    local e
    for e in "${PROMPT_COMMAND[@]}"; do
      [[ $e == __bb_prompt_hook ]] && return 0
    done
    PROMPT_COMMAND+=(__bb_prompt_hook)
  else
    case ";${PROMPT_COMMAND-};" in
      *";__bb_prompt_hook;"*) ;;
      *) PROMPT_COMMAND="${PROMPT_COMMAND:+$PROMPT_COMMAND; }__bb_prompt_hook" ;;
    esac
  fi
}
__bb_install_prompt_command

# ---------------------------------------------------------------------------
# PS1 integration (never clobbers the user's PS1; applied once)
# ---------------------------------------------------------------------------
unset __bb_ps1_orig
__bb_ps1_apply() {
  [[ -z ${__bb_ps1_orig+set} ]] && __bb_ps1_orig=${PS1-}
  case ${PS1-} in
    '$(__bb_status_render)'*) ;;
    *) PS1='$(__bb_status_render)'"${PS1-}" ;;
  esac
}
__bb_ps1_restore() {
  [[ -z ${__bb_ps1_orig+set} ]] || PS1=$__bb_ps1_orig
}
__bb_ps1_apply

# ---------------------------------------------------------------------------
# history picker
# ---------------------------------------------------------------------------
__bb_history() {
  local max=${BB_HISTORY_COUNT:-10} line i=0 choice cmd
  local cmds=()
  while IFS= read -r line; do
    cmds+=("$line")
  done < <(HISTTIMEFORMAT= builtin history "$max" 2>/dev/null |
           sed 's/^[[:space:]]*[0-9]\+[[:space:]]\+//')
  if ((${#cmds[@]} == 0)); then
    printf 'betterbash: history empty\n' >&2
    return 1
  fi
  for line in "${cmds[@]}"; do
    i=$((i+1))
    printf '%2d %s\n' "$i" "$line"
  done
  printf 'select 1-%d> ' "${#cmds[@]}"
  IFS= read -r choice || choice=
  [[ -z $choice ]] && return 0
  if [[ ! $choice =~ ^[0-9]+$ ]] || ((choice < 1 || choice > ${#cmds[@]})); then
    printf 'betterbash: invalid selection: %s\n' "${choice:-<empty>}" >&2
    return 1
  fi
  cmd=${cmds[choice-1]}
  if [[ -t 0 ]]; then
    local edited=
    IFS= read -e -i "$cmd" -p 'edit (Enter=run, empty=cancel): ' edited || edited=
    [[ -n $edited ]] && eval "$edited"
  else
    printf '%s\n' "$cmd"
  fi
}

__bb_search() {
  local q=${1-} line i=0 choice cmd edited
  [[ -n $q ]] || { printf 'usage: betterbash search <query>\n' >&2; return 2; }
  local -a hits=()
  while IFS= read -r line; do
    hits+=("$line")
  done < <(HISTTIMEFORMAT= builtin history 2>/dev/null |
    sed 's/^[[:space:]]*[0-9]\+[[:space:]]\+//' |
    grep -F -- "$q" | awk '!seen[$0]++' |
    tail -n "${BB_SEARCH_COUNT:-20}")
  ((${#hits[@]})) || { printf 'betterbash: no history matches: %s\n' "$q" >&2; return 1; }
  for line in "${hits[@]}"; do
    i=$((i+1))
    printf '%2d %s\n' "$i" "$line"
  done
  printf 'select 1-%d (Enter to cancel): ' "${#hits[@]}"
  IFS= read -r choice || { printf '\n'; return 0; }
  [[ -n $choice ]] || return 0
  [[ $choice =~ ^[0-9]+$ ]] && ((choice >= 1 && choice <= ${#hits[@]})) || {
    printf 'betterbash: invalid selection: %s\n' "$choice" >&2; return 1; }
  cmd=${hits[choice-1]}
  IFS= read -r -e -i "$cmd" -p 'edit (Enter=run, empty=cancel): ' edited
  [[ -n $edited ]] && eval "$edited"
  return 0
}

# ---------------------------------------------------------------------------
# dispatcher
# ---------------------------------------------------------------------------
betterbash() {
  local sub=${1-}
  case $sub in
    version)
      printf '%s\n' "$BB_VERSION" ;;
    on)
      BB_ENABLED=1
      __bb_ps1_apply
      __bb_install_prompt_command ;;
    off)
      BB_ENABLED=0
      __bb_status_render >/dev/null 2>&1
      __bb_ps1_restore ;;
    status)
      local i
      for i in "${!BB_STATUS_NAMES[@]}"; do
        "${BB_STATUS_CHECKS[i]}" >/dev/null 2>&1 && \
          printf '%s: %s\n' \
      "${BB_STATUS_NAMES[i]}" "$(__bb_ps1_decode "$("${BB_STATUS_RENDERS[i]}")")"
      done ;;
    history)
      __bb_history ;;
    search)
      shift
      __bb_search "$@" ;;
    register)
      shift
      status_register "$@" ;;
    *)
      printf 'usage: betterbash {version|status|history|on|off|search <query>|register <name> <check> <render>}\n' >&2
      return 2 ;;
  esac
}
