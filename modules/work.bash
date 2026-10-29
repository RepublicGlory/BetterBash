# BetterBash work module: bookmark working directories.
#    work add          save $PWD to $BB_HOME/var/work.paths (NUL-separated, printf '%s\0')
#    work delete (|-d) remove $PWD from work.paths (NUL-safe rewrite)
#    work              read work.paths (mapfile -d ''), print numbered list, pick, cd
#    work -> 0         delete mode: batch delete by space-separated indices (0/empty exits)

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
      for p in "${paths[@]}"; do [[ $p != "$PWD" ]] && kept+=("$p"); done
      : > "$f"
      (( ${#kept[@]} )) && printf '%s\0' "${kept[@]}" > "$f"
      printf 'deleted: %s\n' "$PWD"
      ;;
    "")
      [[ -f $f ]] || { printf 'betterbash: no saved paths (use: work add)\n' >&2; return 1; }
      mapfile -d '' -t paths < "$f"
      n=${#paths[@]}
      (( n == 0 )) && { printf 'betterbash: no saved paths\n' >&2; return 1; }
      printf '=== Saved Workspaces ===\n\n'
      local w=${#n} tag
      for ((i=0;i<n;i++)); do
        p=${paths[i]}
        [[ -d $p ]] && tag='' || tag=$'\033[31m[MISSING]\033[0m'
        printf '[%*d] %s%s\n' "$w" "$((i+1))" "$p" "$tag"
      done
      printf '\nSelect workspace (1-%d, 0 delete, Enter to cancel): ' "$n"
      read -r sel || { printf '\n'; return 0; }
      [[ -n $sel ]] || return 0
      if [[ $sel == 0 ]]; then
        # delete mode: two-phase atomic batch delete.
        # phase 1 validates every token (numeric, in 1..N, no dupes);
        # only when all tokens are valid does phase 2 resolve paths and delete.
        while :; do
          printf 'delete which? (space-separated, 0 exit): '
          read -r sel || { printf '\n'; return 0; }
          [[ -n $sel ]] || return 0
          [[ $sel == 0 ]] && return 0
          local -a toks del idxs
          read -r -a toks <<< "$sel"
          # phase 1: validate all tokens, reject entire batch on any failure
          local bad='' t d
          for t in "${toks[@]}"; do
            [[ $t =~ ^[0-9]+$ ]] || { printf 'betterbash: not a number: %s\n' "$t" >&2; bad=1; break; }
            (( t >= 1 && t <= n )) || { printf 'betterbash: out of range: %s (1-%d)\n' "$t" "$n" >&2; bad=1; break; }
            for d in "${idxs[@]}"; do
              [[ $d == "$t" ]] && { printf 'betterbash: duplicate index: %s\n' "$t" >&2; bad=1; break; }
            done
            (( bad )) && break
            idxs+=("$t")
          done
          (( bad )) && continue
          # phase 2: resolve all indices to paths first, then remove once
          del=()
          for t in "${idxs[@]}"; do del+=("${paths[t-1]}"); done
          kept=()
          for p in "${paths[@]}"; do
            local skip=''
            for g in "${del[@]}"; do [[ $p == "$g" ]] && { skip=1; break; }; done
            [[ -n $skip ]] || kept+=("$p")
          done
          : > "$f"
          (( ${#kept[@]} )) && printf '%s\0' "${kept[@]}" > "$f"
          for g in "${del[@]}"; do printf 'deleted: %s\n' "$g"; done
          mapfile -d '' -t paths < "$f"
          n=${#paths[@]}
          (( n == 0 )) && { printf 'betterbash: no saved paths\n' >&2; return 0; }
        done
      fi
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
