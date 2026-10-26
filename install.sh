#!/usr/bin/env bash
# BetterBash 0.1.1 installer.
#   install.sh              install into ~/.betterbash, add one line to ~/.bashrc
#   install.sh --uninstall  remove that line and the install dir
#
# Silent fallback: if the compile/load prerequisites are missing (bash<5.1 or
# no g++/no loadable-builtin support) this still installs the pure-bash runtime
# and exits 0 without printing anything.
set -euo pipefail

BB_VERSION=0.1.1
BB_HOME=$HOME/.betterbash
BASHRC=$HOME/.bashrc
LINE='[ -f "$HOME/.betterbash/betterbash.bash" ] && source "$HOME/.betterbash/betterbash.bash"'
SRC_DIR=${BASH_SOURCE[0]%/*}
[[ $SRC_DIR == "${BASH_SOURCE[0]}" ]] && SRC_DIR=.
SRC_DIR=$(cd -- "$SRC_DIR" && pwd)

say() { printf '%s\n' "$*"; }
have() { command -v "$1" >/dev/null 2>&1; }

remove_line() {
  [[ -f $BASHRC ]] || return 0
  local tmp; tmp=$(mktemp)
  grep -vF -- "$LINE" "$BASHRC" >"$tmp" || true
  cat "$tmp" >"$BASHRC"
  rm -f "$tmp"
}

add_line() {
  [[ -f $BASHRC ]] || : >"$BASHRC"
  grep -qF -- "$LINE" "$BASHRC" && return 0
  printf '%s\n' "$LINE" >>"$BASHRC"
}

if [[ ${1-} == --uninstall ]]; then
  remove_line
  rm -rf -- "$BB_HOME"
  say "BetterBash $BB_VERSION uninstalled."
  exit 0
fi

# ---- probe: bash >= 5.1 ----------------------------------------------------
bash_ok=0
if [[ ${BASH_VERSINFO[0]} -gt 5 ]] || \
   { [[ ${BASH_VERSINFO[0]} -eq 5 ]] && [[ ${BASH_VERSINFO[1]} -ge 1 ]]; }; then
  bash_ok=1
fi

# ---- probe: g++ (or c++) ---------------------------------------------------
CXX=
if have g++; then CXX=g++
elif have c++; then CXX=c++
fi

# ---- install runtime -------------------------------------------------------
mkdir -p "$BB_HOME"
cp -f -- "$SRC_DIR/betterbash.bash" "$BB_HOME/betterbash.bash"
if [[ -d $SRC_DIR/modules ]]; then
  mkdir -p "$BB_HOME/modules"
  cp -f -- "$SRC_DIR/modules/"*.bash "$BB_HOME/modules/" 2>/dev/null || :
fi

# ---- optional ghost builtin ------------------------------------------------
ghost_ok=0
if [[ $bash_ok == 1 && -n $CXX ]]; then
  if "$CXX" -shared -fPIC -O2 -o "$BB_HOME/bbghost.so" \
             "$SRC_DIR/src/bbghost.cpp" >/dev/null 2>&1; then
    if bash -c 'enable -f "$1" bbghost' _ "$BB_HOME/bbghost.so" >/dev/null 2>&1; then
      ghost_ok=1
    else
      rm -f -- "$BB_HOME/bbghost.so"
    fi
  else
    rm -f -- "$BB_HOME/bbghost.so"
  fi
fi

add_line

if [[ $ghost_ok == 1 ]]; then
  say "BetterBash $BB_VERSION installed to $BB_HOME (ghost builtin enabled)."
  say "Open a new shell or run: source ~/.bashrc"
fi
# else: silent fallback -- print nothing, exit 0.
exit 0
