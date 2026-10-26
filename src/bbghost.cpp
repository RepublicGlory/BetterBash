/* BetterBash 0.1.1 -- ghost inline-hint builtin (loadable)
 *
 * Compiled with g++ (extern "C" so bash's dlopen finds the unmangled
 * `bbghost_struct` symbol). Hand-declares the bash loadable-builtin ABI and
 * the readline/history externs so NO bash/readline headers are required; the
 * referenced symbols (rl_*, history_list) are resolved at dlopen time from
 * bash's own export table (bash is linked with -rdynamic).
 *
 * Subcommands:
 *   bbghost on         install redisplay wrapper; save original
 *                      rl_redisplay_function and call it, then -- ONLY when
 *                      rl_line_buffer has NO byte >= 0x80 -- optionally paint
 *                      a faint ghost suggestion after the cursor. If the line
 *                      buffer contains ANY non-ASCII byte (>= 0x80), the
 *                      original redisplay is called and NOTHING is painted
 *                      (misalignment guard: we do not compute widths).
 *   bbghost off        restore the original redisplay function.
 *   bbghost guard TXT  simulate the guard on TXT; print PAINT (exit 0) when
 *                      TXT is pure ASCII, SKIP (exit 1) when it contains a
 *                      byte >= 0x80. Lets the guard be validated without a
 *                      live readline buffer.
 *   bbghost test       exercise the redisplay path minimally (install, call
 *                      the hook once with the current -- possibly NULL --
 *                      rl_line_buffer, restore). Never crashes: a NULL or
 *                      non-ASCII buffer is a no-op.
 */

#include <stddef.h>
#include <string.h>
#include <unistd.h>
#include <stdio.h>

/* ---- bash loadable-builtin ABI (mirrors bash 5.x builtins.h) ------------ */
struct word_desc { char *word; int flags; };
struct word_list { struct word_list *next; struct word_desc *word; };
typedef int sh_builtin_func_t (struct word_list *);

struct builtin {
  char              *name;
  sh_builtin_func_t *function;
  int                flags;
  char *const       *long_doc;
  const char        *short_doc;
  char              *handle;
};
#define BUILTIN_ENABLED 0x01

/* ---- readline / history externs (resolved from bash at dlopen) ---------- */
extern "C" {

extern char *rl_line_buffer;
extern int   rl_point;
extern int   rl_end;
extern void (*rl_redisplay_function)(void);

typedef struct { char *line; char *data; } HIST_ENTRY;
extern HIST_ENTRY **history_list(void);

static int has_highbit(const char *s, size_t n) {
  for (size_t i = 0; i < n; i++)
    if ((unsigned char)s[i] >= 0x80) return 1;
  return 0;
}

static void emit(const char *s) { ssize_t r = write(1, s, strlen(s)); (void)r; }

/* most-recent history entry whose line is a strict extension of the current
 * buffer prefix; returns pointer into it at offset rl_end, or NULL. */
static const char *suggest(void) {
  HIST_ENTRY **hl = history_list();
  if (!hl || !rl_line_buffer) return 0;
  int i;
  for (i = 0; hl[i]; i++) ;
  for (i--; i >= 0; i--) {
    char *l = hl[i]->line;
    if (!l) continue;
    if (strncmp(l, rl_line_buffer, (size_t)rl_end) == 0 && l[rl_end]) return l + rl_end;
  }
  return 0;
}

static int  g_installed = 0;
static int  g_painted    = 0;
static void (*g_orig)(void) = 0;

static void bb_redisplay(void) {
  if (g_painted) { emit("\x1b[K"); g_painted = 0; }       /* erase prior ghost */
  if (g_orig) g_orig();                                    /* always draw line  */
  if (!rl_line_buffer) return;
  if (has_highbit(rl_line_buffer, (size_t)rl_end)) return; /* non-ASCII guard */
  if (rl_point != rl_end) return;                          /* only at EOL */
  if (rl_end <= 0) return;                                 /* no suggestion on empty line */
  const char *s = suggest();
  if (!s || !*s) return;
  if (has_highbit(s, strlen(s))) return;                   /* ASCII-only paint */
  emit("\x1b[2m"); emit(s); emit("\x1b[0m");
  char buf[24]; int n = snprintf(buf, sizeof buf, "\x1b[%dD", (int)strlen(s));
  if (n > 0) { ssize_t r = write(1, buf, (size_t)n); (void)r; }
  g_painted = 1;
}

static char *g_doc[] = { (char *)"bbghost on|off|guard|test", (char *)0 };

static int bbghost_fn(struct word_list *list) {
  const char *sub = (list && list->word && list->word->word) ? list->word->word : "";
  if (strcmp(sub, "on") == 0) {
    if (!g_installed) { g_orig = rl_redisplay_function; rl_redisplay_function = bb_redisplay; g_installed = 1; }
    return 0;
  }
  if (strcmp(sub, "off") == 0) {
    if (g_installed) { rl_redisplay_function = g_orig ? g_orig : rl_redisplay_function; g_installed = 0; g_painted = 0; }
    return 0;
  }
  if (strcmp(sub, "guard") == 0) {
    /* join remaining words */
    char buf[4096]; size_t off = 0; buf[0] = 0;
    struct word_list *w = list ? list->next : 0;
    while (w && w->word && w->word->word) {
      const char *t = w->word->word; size_t k = strlen(t);
      if (off + k + 2 > sizeof buf) break;
      if (off) buf[off++] = ' ';
      memcpy(buf + off, t, k); off += k; w = w->next;
    }
    buf[off] = 0;
    if (has_highbit(buf, off)) { emit("SKIP\n"); return 1; }
    emit("PAINT\n"); return 0;
  }
  if (strcmp(sub, "test") == 0) {
    if (!g_installed) { g_orig = rl_redisplay_function; rl_redisplay_function = bb_redisplay; g_installed = 1; }
    bb_redisplay();
    if (g_installed) { rl_redisplay_function = g_orig ? g_orig : rl_redisplay_function; g_installed = 0; g_painted = 0; }
    return 0;
  }
  emit("bbghost: usage: bbghost on|off|guard TXT|test\n");
  return 1;
}

struct builtin bbghost_struct = {
  (char *)"bbghost",
  bbghost_fn,
  BUILTIN_ENABLED,
  g_doc,
  "bbghost on|off|guard|test",
  (char *)0
};

}  /* extern "C" */
