# BetterBash work module: bookmark working directories.
#   work add          save $PWD to $BB_HOME/var/work.paths (NUL-separated, printf '%s\0')
#   work delete (|-d) remove $PWD from work.paths (NUL-safe rewrite)
#   work              read work.paths (mapfile -d ''), print numbered list, pick, cd

__bb_work_file() { printf '%s/var/work.paths' "${BB_HOME:-$HOME/.betterbash}"; }

work() {
  local f n i sel p
  local -a paths kept
  f=$(__bb_work_file)
  case ${1:-} in
    add|-a)
      mkdir -p "${f%/*}" 2>/dev/null || { printf 'betterbash: cannot create %s\n' "${f%/*}" >&2; return 1; }
      [[ -f $f ]] && mapfile -d '' -t paths < "$f"
      for p in "${paths[@]}"; do [[ $p == "$PWD" ]] && { printf 'already saved: %s\n' "$PWD"; return 0; }; done
      printf '%s\0' "$PWD" >> "$f"
      printf 'saved: %s\n' "$PWD"
      ;;
    delete|-d)
      [[ -f $f ]] || return 0
      mapfile -d '' -t paths < "$f"
      for p in "${paths[@]}"; do [[ $p == "$PWD" ]] || kept+=("$p"); done
      : > "$f"
      ((${#kept[@]})) && printf '%s\0' "${kept[@]}" >> "$f"
      printf 'deleted: %s\n' "$PWD"
      ;;
    "")
      if [[ ! -s $f ]]; then printf 'betterbash: no saved paths (use: work add)\n' >&2; return 1; fi
      mapfile -d '' -t paths < "$f"
      n=${#paths[@]}
      (( n > 0 )) || { printf 'betterbash: no saved paths\n' >&2; return 1; }
      for ((i=0;i<n;i++)); do printf '%2d  %s\n' "$((i+1))" "${paths[i]}"; done
      printf 'select 1-%d (Enter to cancel): ' "$n"
      read -r sel || { printf '\n'; return 0; }
      [[ -n $sel ]] || return 0
      [[ $sel =~ ^[0-9]+$ ]] || { printf 'betterbash: invalid selection: %s\n' "$sel" >&2; return 1; }
      (( sel >= 1 && sel <= n )) || { printf 'betterbash: out of range: %s\n' "$sel" >&2; return 1; }
      cd -- "${paths[sel-1]}" || return 1
      printf '%s\n' "$PWD"
      ;;
    *)
      printf 'usage: work [add|delete]\n' >&2
      return 2
      ;;
  esac
}
