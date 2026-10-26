# BetterBash sudo module: red (sudo) status hint.
# Self-registers its status + prompt hook with the core runtime.
# State is in-memory only (BB_SUDO_AT); no files are written.

__bb_sudo_record() {
  local cmd h
  h=$(HISTTIMEFORMAT= builtin history 1 2>/dev/null) || return 0
  [[ $h =~ ^[[:space:]]*[0-9]+[[:space:]]+(.*)$ ]] || return 0
  cmd=${BASH_REMATCH[1]}
  [[ $cmd =~ (^|[[:space:]])(sudo)([[:space:]]|$) ]] || return 0
  [[ $cmd == *"__bb_sudo_record"* ]] && return 0
  BB_SUDO_AT=$SECONDS
  return 0
}

__bb_sudo_check() {
  [[ ${BB_SUDO_AT-} =~ ^[0-9]+$ ]] || return 1
  (( SECONDS - BB_SUDO_AT <= BB_SUDO_TTL ))
}

__bb_sudo_render() {
  printf '\[\e[31m\](sudo)\[\e[0m\] '
}

status_register sudo __bb_sudo_check __bb_sudo_render
__bb_install_prompt_hook __bb_sudo_record
