# Architecture

BetterBash = a core Bash runtime library + self-registering modules + one
optional compiled (C++) loadable builtin. A single `.bashrc` line sources the
core.

## Layering

```
~/.bashrc  (single idempotent line)
  +-- $BB_HOME/betterbash.bash              core runtime
        +-- config + status_register + __bb_status_render
        +-- __bb_install_prompt_hook        single PROMPT_COMMAND hook
        +-- betterbash dispatcher (on/off/history/version/register)
        +-- ghost load: enable -f bbghost.so  (silent -> BB_GHOST=0)
        +-- for f in "$BB_HOME"/modules/*.bash; do source "$f"; done
              +-- modules/sudo.bash   red (sudo) status, in-memory BB_SUDO_AT
              +-- modules/work.bash    work add|delete / pick->cd
```

## Status interface

`status_register <name> <check_fn> <render_fn>` appends into three parallel
ordered arrays; `__bb_status_render` walks them in registration order, calls
each `check_fn`, and concatenates the `render_fn` output of active statuses into
one PS1-ready string. PS1 is rewritten once to `$(...)`-prefix the original
(recorded in `__bb_ps1_orig`); `betterbash off` restores it.

## sudo hint (in-memory)

A PROMPT_COMMAND hook reads `history 1`; if the last command matches `sudo` it
sets the global `BB_SUDO_AT=$SECONDS` (no file, no cleanup). The check is
`(( SECONDS - BB_SUDO_AT <= BB_SUDO_TTL ))`. TTL default 180s (~3 min).

## work bookmarks

`$BB_HOME/var/work.paths` holds NUL-separated (`printf '%s\0'`) absolute paths,
read with `mapfile -d ''`. `work add` dedupes; `work delete` rewrites the file
without `$PWD`; `work` lists, reads a number, and `cd`s.

## ghost builtin (optional C++)

`src/bbghost.cpp` is a Bash loadable builtin. It is wrapped in `extern "C"` so
the `bbghost_struct` symbol stays unmangled for `enable -f`'s `dlsym`. It hooks
`rl_redisplay_function`: each redisplay calls the saved original, then — only when
`rl_line_buffer` is non-NULL, `rl_end >= 0`, contains no byte >= 0x80, and contains
no path character (`/` or `~`) — paints a faint suggestion and erases it on the
next redisplay. Any non-ASCII byte or path character => original redisplay only,
nothing painted (no width math, no crash). Tab completion is never intercepted;
it is native readline. The implementation uses stack buffers + `write()` only (no
malloc), and bounds every string op against `rl_end`, so there are no leaks or
overflows.

### Fallback

`install.sh` enables ghost only when `bash >= 5.1` AND `g++`/`c++` exist. It
compiles `src/bbghost.cpp` -> `$BB_HOME/bbghost.so`, then probes `enable -f`.
Any failure => `rm -f` the `.so`, `BB_GHOST=0`, print nothing, exit 0. The
pure-bash runtime is unaffected; ghost text is simply never painted.
