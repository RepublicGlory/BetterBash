# BetterBash 0.1.1

Tiny shell-status toolkit. Provides a small abstract **status interface** for the
prompt and ships a few concrete conveniences on top of it.

- **sudo hint** — red `(sudo)` shown before PS1 for `BB_SUDO_TTL` seconds
  (default 180, ~3 min) after you run a `sudo` command. State is in-memory only.
- **history picker** — `betterbash top` lists the last `BB_HISTORY_COUNT`
  (default 10) history entries numbered 1-10; type a number to re-run one.
- **work bookmarks** — `work add` saves `$PWD`; `work` lists saved paths and
  `cd`s into the one you pick; `work delete` removes `$PWD`.
- **ghost hints** *(optional)* — a loadable builtin that, when the readline line
  buffer is pure ASCII, faintly suggests a suffix from the most recent matching
  history entry. If the buffer contains **any** non-ASCII byte (>= 0x80) it
  paints nothing (misalignment guard — no column widths are ever computed).

## Requirements

- `bash >= 5.1` (pure-bash runtime uses the array form of `PROMPT_COMMAND`).
- `g++` (or `c++`) — **only** to build the optional ghost builtin. Without it,
  installation silently falls back to pure-bash mode (sudo hint, picker, and
  `work` still work). `fzf` is **not** required.

## Install

```sh
./install.sh               # installs into ~/.betterbash, appends one line to ~/.bashrc
./install.sh --uninstall   # removes that line and the install dir
```

The single line appended (idempotent — added only once):

```sh
[ -f "$HOME/.betterbash/betterbash.bash" ] && source "$HOME/.betterbash/betterbash.bash"
```

Open a new shell (or `source ~/.bashrc`). If you set a custom `PS1`, source
BetterBash **after** setting it so the status prefix is prepended correctly.

## Configuration

All variables are overridable **before** BetterBash is sourced:

| var | default | meaning |
|-----|---------|---------|
| `BB_SUDO_TTL`      | `180` | seconds the sudo hint stays after a sudo command |
| `BB_HISTORY_COUNT` | `10`  | entries listed by `betterbash top` |
| `BB_ENABLED`       | `1`   | master switch; `0` disables all rendering |
| `BB_GHOST`         | `1`   | try to load the ghost builtin; `0` to skip |
| `BB_HOME`          | `~/.betterbash` | install/state directory |

## Runtime commands

```sh
betterbash version                              # prints 0.1.1
betterbash status                               # list active statuses
betterbash top                                  # pick from last N history entries
betterbash on                                   # re-enable (after off)
betterbash off                                  # disable (no errors; prompt visually unchanged)
betterbash register NAME CHECK_FN RENDER_FN     # add your own status
work add                                        # save $PWD to ~/.betterbash/var/work.paths
work delete                                     # remove $PWD (alias: work -d)
work                                            # list saved paths, pick a number, cd there
```

## Abstract status interface

```sh
status_register <name> <check_fn> <render_fn>
```

`check_fn` exits `0` when active, non-zero otherwise. `render_fn` prints
PS1-ready text. Use PS1-safe escapes such as `\[\e[31m\]...\[\e[0m\]`.
`__bb_status_render` decodes `\[`/`\]` to the `\x01`/`\x02` non-printing markers
readline expects, because bash does **not** re-decode escapes coming out of
`$(...)` when expanding `PS1`.

PS1 is integrated once, non-destructively:

```sh
PS1='$(__bb_status_render)'"$PS1"   # original PS1 recorded in __bb_ps1_orig
```

`PROMPT_COMMAND` is appended to (string or array form), never clobbered.

## Ghost C++ fallback

`install.sh` enables the optional ghost builtin only when **both** prerequisites
hold: `bash >= 5.1` and a working `g++` (or `c++`). It compiles `src/bbghost.cpp`
into `$BB_HOME/bbghost.so` and verifies it loads via `enable -f`. If any step
fails (no g++, compile error, or load failure) the installer prints nothing,
removes any partial `.so`, sets `BB_GHOST=0`, and exits 0. The runtime then
skips `enable -f`; the pure-bash runtime (sudo hint, history picker, `work`
bookmarks) is unaffected — ghost text is simply never painted. The builtin never
computes display widths: if the readline line buffer contains any byte >= 0x80 it
calls only the original redisplay and paints nothing, so non-ASCII input cannot
crash or misalign the prompt.

## Edge-case behavior

- `BB_ENABLED=0` / `betterbash off` -> `__bb_status_render` prints nothing; PS1
  visually unchanged; no errors.
- ghost `.so` missing or `enable -f` fails -> `BB_GHOST=0` silently; everything
  else works.
- `install.sh` without bash >= 5.1 and/or without `g++` -> installs the pure-bash
  runtime (or nothing), prints nothing, exits 0.
- ghost never computes display widths. Any byte >= 0x80 in the line buffer =>
  only the original redisplay is called, ghost text is not painted.

## Files

| path | role |
|------|------|
| `install.sh`        | installer + `--uninstall` |
| `betterbash.bash`   | runtime library (sourced from `~/.bashrc`) |
| `modules/sudo.bash` | sudo status module: red `(sudo)` hint (in-memory `BB_SUDO_AT`) |
| `modules/work.bash` | `work` dir-bookmark module (`add`/`delete`/pick->`cd`) |
| `src/bbghost.cpp`   | loadable ghost builtin (g++, `extern "C"`) |
| `docs/architecture.md` | layering + ghost C++ fallback notes |
| `.gitignore`        | ignores `*.so`, `*.o`, `dist/`, `BetterBash-*.tar.gz` |

## Packaging

Release artifacts are built in the repo root:

- `BetterBash-0.1.1.tar.gz` — top-level `BetterBash/` directory
- `BetterBash-0.1.1.tar.gz.sha256` — `sha256sum` sidecar

Built from a clean checkout via a staging dir (deterministic; excludes `.git`,
the tarball, and the checksum):

```sh
rm -rf /tmp/BetterBash-stage && mkdir -p /tmp/BetterBash-stage/BetterBash
cp -a README.md install.sh betterbash.bash modules src docs .gitignore \
      /tmp/BetterBash-stage/BetterBash/
tar -czf BetterBash-0.1.1.tar.gz -C /tmp/BetterBash-stage BetterBash
sha256sum BetterBash-0.1.1.tar.gz > BetterBash-0.1.1.tar.gz.sha256
```

## Install from the release tarball

```sh
# unpack (creates ./BetterBash/)
tar xzf BetterBash-0.1.1.tar.gz
cd BetterBash

# verify checksum (run from the dir holding the sidecar)
sha256sum -c ../BetterBash-0.1.1.tar.gz.sha256

# install: appends one line to ~/.bashrc; silent fallback if no g++
./install.sh

# smoke-test the pure-bash core (works regardless of g++/ghost)
bash -c 'source ~/.betterbash/betterbash.bash; betterbash version; type work; type status_register'

# exercise features interactively
bash --noprofile --norc -i <<'INNEREOF'
source ~/.betterbash/betterbash.bash
sudo apt update    # red (sudo) then prefixes the next prompts
betterbash top     # pick from last N history entries
cd /tmp && work add
work               # pick a saved dir to cd into
INNEREOF

# uninstall
./install.sh --uninstall
```

## Acceptance tests

1. `bash -c 'source ~/.betterbash/betterbash.bash; type status_register; betterbash version'`
   -> `status_register is a function` and `0.1.1`.
2. sudo hint: after `sudo apt update` the next prompt is prefixed with red
   `(sudo)` for ~`BB_SUDO_TTL` seconds; expired -> not shown.
3. `history -s ...; printf '1\n' | betterbash top` -> prints and runs entry 1.
4. `work add` from two dirs, then `printf '1\n' | work` -> `cd`s into entry 1;
   `work delete` removes the current dir; re-`work add` is deduped.
5. `enable -f ~/.betterbash/bbghost.so bbghost; bbghost on` in `bash -c` -> exit
   0, no crash; `bbghost guard "cafe"` (with accent) -> `SKIP` (guard in place).
6. `install.sh` with `g++` absent from `PATH` -> exits 0, no stderr, installs the
   pure-bash runtime.

After `sudo apt update`, red `(sudo)` appears before the next prompt and
persists ~3 minutes (`BB_SUDO_TTL`).
