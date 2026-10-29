/* BetterBash 0.1.1 ghost inline-hint builtin (loadable).
 *
 * Compiled with g++; the builtin surface is wrapped in extern "C" so the
 * `bbghost_struct` symbol is unmangled and `enable -f`'s dlsym finds it.
 *
 * Two readline hooks:
 *   1. rl_redisplay_function  -> optionally paint a faint suggestion suffix
 *      after the cursor (without mutating READLINE_LINE).
 *   2. Tab (bound via rl_add_defun + rl_bind_key) -> bb_accept_ghost: if the
 *      current word contains '/', delegate to native `complete`; otherwise
 *      accept (insert) the current ghost suggestion.
 *
 * Suggestion = the suffix of the most recent history entry that has the current
 * rl_line_buffer as a STRICT prefix:
 *     strncmp(history[i], rl_line_buffer, rl_end) == 0
 *     && strlen(history[i]) > rl_end
 *
 * Guards (any failure => no paint / delegate to native, never crash):
 *   - rl_line_buffer NULL or rl_end<0 or rl_point!=rl_end  => skip paint
 *   - any byte >= 0x80 in the buffer                      => skip paint
 *   - buffer contains '/' or '~'                          => skip paint
 *   - suggestion NULL/empty/non-ASCII                      => skip paint
 * No dynamic allocation (stack buffers + write()), so no leaks.
 *
 * Subcommands: on | off | text <s> | guard <txt> | prefix <line> <buf> | test
 */
#include <stddef.h>
#include <string.h>
#include <unistd.h>
#include <stdio.h>

/* ---- bash loadable-builtin ABI (mirrors bash 5.x builtins.h) ------------- */
struct word_desc { char *word; int flags; };
struct word_list { struct word_list *next; struct word_desc *word; };
typedef int sh_builtin_func_t(struct word_list *);
struct builtin {
    char *name;
    sh_builtin_func_t *function;
    int flags;
    char *const *long_doc;
    const char *short_doc;
    char *handle;
};

/* ---- readline / history externs (resolved from bash at dlopen time) ------- */
typedef int rl_command_func_t(int, int);
extern "C" {
extern char *rl_line_buffer;
extern int   rl_end;
extern int   rl_point;
extern void (*rl_redisplay_function)(void);
extern rl_command_func_t *rl_named_function(const char *);
extern int   rl_bind_key(int, rl_command_func_t *);
extern int   rl_add_defun(const char *, rl_command_func_t *, int);
extern int   rl_insert_text(const char *);
extern int   history_length;
struct hist_entry { char *line; char *timestamp; void *data; };
extern struct hist_entry **history_list(void);
}

static int    g_installed = 0;
static void (*g_orig)(void) = 0;
static char   g_text[256];        /* manual override (bbghost text)            */
static size_t g_text_len = 0;
static char   g_sug[512];         /* suggestion suffix buffer                   */
static int    g_tab_bound = 0;
static int    g_painted  = 0; /* ghost currently on screen (needs erase) */

/* returns 1 if any byte >= 0x80 (also "unsafe" for NULL input) */
static int has_highbit(const char *s, size_t n) {
    if (!s) return 1;
    for (size_t i = 0; i < n; i++)
        if ((unsigned char)s[i] >= 0x80) return 1;
    return 0;
}

/* returns 1 if the string contains a path indicator ('/' or '~') */
static int contains_path(const char *s, size_t n) {
    if (!s) return 0;
    for (size_t i = 0; i < n; i++)
        if (s[i] == '/' || s[i] == '~') return 1;
    return 0;
}

static void emit(const char *s, size_t n) {
    if (s && n) {
        ssize_t w = write(STDOUT_FILENO, s, n);
        (void)w;
    }
}

/* Find the suffix of the most recent history entry that has the current
 * rl_line_buffer as a strict prefix. Returns a pointer into g_sug, or 0. */
static const char *bb_suggest(void) {
    if (!rl_line_buffer || rl_end <= 0) return 0;
    if (has_highbit(rl_line_buffer, (size_t)rl_end)) return 0;   /* non-ASCII */
    if (contains_path(rl_line_buffer, (size_t)rl_end)) return 0; /* path */
    struct hist_entry **h = history_list();
    if (!h || history_length <= 0) return 0;
    for (int i = history_length - 1; i >= 0; i--) {
        if (!h[i] || !h[i]->line) continue;
        const char *line = h[i]->line;
        size_t ln = strlen(line);
        if (ln <= (size_t)rl_end) continue;                      /* not longer */
        if (strncmp(line, rl_line_buffer, (size_t)rl_end) != 0) continue;
        if (has_highbit(line, ln)) continue;                     /* non-ASCII */
        size_t rem = ln - (size_t)rl_end;
        if (rem >= sizeof g_sug) rem = sizeof g_sug - 1;        /* bound copy */
        memcpy(g_sug, line + rl_end, rem);
        g_sug[rem] = '\0';
        return g_sug;
    }
    return 0;
}

static int bb_native_complete(int count, int key) {
    rl_command_func_t *fn = rl_named_function("complete");
    if (fn) return fn(count, key);
    return 0;
}

/* Tab handler: accept ghost suggestion, or delegate to native completion. */
extern "C" int bb_accept_ghost(int count, int key) {
    if (!g_installed) return bb_native_complete(count, key);
    if (!rl_line_buffer || rl_end <= 0) return bb_native_complete(count, key);
    /* current word = [start, rl_end) */
    int start = rl_end;
    while (start > 0 && rl_line_buffer[start - 1] != ' ' &&
           rl_line_buffer[start - 1] != '\t')
        start--;
    /* path being typed -> native completion, never ghost */
    if (memchr(rl_line_buffer + start, '/', (size_t)(rl_end - start)) != NULL)
        return bb_native_complete(count, key);
    if (memchr(rl_line_buffer + start, '~', (size_t)(rl_end - start)) != NULL)
        return bb_native_complete(count, key);
    /* only accept when the cursor is at the end of the line */
    if (rl_point != rl_end) return bb_native_complete(count, key);
    const char *sug = (g_text_len > 0) ? g_text : bb_suggest();
    if (!sug || !*sug) return bb_native_complete(count, key);
    if (has_highbit(sug, strlen(sug))) return bb_native_complete(count, key);
    /* Erase the painted ghost before inserting real text, so the faint
     * suffix doesn't linger beside the now-real suffix (redisplay flash). */
    if (g_painted) { emit("\x1b[K", sizeof("\x1b[K") - 1); g_painted = 0; }
    rl_insert_text(sug);
    return 0;
}

static void bb_redisplay(void) {
if (g_painted) { emit("\x1b[K", sizeof("\x1b[K") - 1); g_painted = 0; }  /* erase prior ghost */
    if (g_orig) g_orig();                        /* always run the real one   */
    if (!g_installed || !g_orig) return;
    if (!rl_line_buffer || rl_end < 0) return;   /* NULL / bounds guard       */
    if (rl_point != rl_end) return;              /* only paint when cursor at end */
    size_t end = (size_t)rl_end;
    if (has_highbit(rl_line_buffer, end)) return;             /* non-ASCII   */
    if (contains_path(rl_line_buffer, end)) return;          /* path        */
    const char *sug = (g_text_len > 0) ? g_text : bb_suggest();
    if (!sug || !*sug) return;
    size_t sl = strlen(sug);
    if (has_highbit(sug, sl)) return;             /* non-ASCII suggestion */
    /* paint faint ghost after the cursor, then move the cursor back.
     * ASCII-only => byte count == column count, so the move is exact.       */
    char buf[576];
    int m = snprintf(buf, sizeof buf, "\x1b[2m%.*s\x1b[0m", (int)sl, sug);
    if (m < 0) return;
    if ((size_t)m >= sizeof buf) m = (int)sizeof buf - 1;     /* bounded */
    emit(buf, (size_t)m);
    char mv[16];
    int k = snprintf(mv, sizeof mv, "\x1b[%zuD", sl);
    if (k > 0 && (size_t)k < sizeof mv) emit(mv, (size_t)k);
    g_painted = 1;
}

static char *const bbghost_doc[] = {
    (char *)"bbghost on|off|text <s>|guard <txt>|prefix <line> <buf>|test",
    (char *)0
};


extern "C" int bbghost_builtin(struct word_list *list) {
    if (!list || !list->word || !list->word->word) {
        fprintf(stderr, "usage: bbghost on|off|text <s>|guard <txt>|prefix <line> <buf>|test\n");
        return 1;
    }
    const char *cmd = list->word->word;
    const char *a1 = (list->next && list->next->word && list->next->word->word)
                     ? list->next->word->word : "";
    const char *a2 = (list->next && list->next->next &&
                      list->next->next->word && list->next->next->word->word)
                     ? list->next->next->word->word : "";

    if (strcmp(cmd, "on") == 0) {
        if (!g_installed) {
            g_orig = rl_redisplay_function;          /* may be NULL */
            rl_redisplay_function = bb_redisplay;
            g_installed = 1;
        }
        if (!g_tab_bound) {
            rl_add_defun("bb-accept-ghost", &bb_accept_ghost, -1);
            rl_bind_key('\t', &bb_accept_ghost);
            g_tab_bound = 1;
        }
        return 0;
    }
    if (strcmp(cmd, "off") == 0) {
        if (g_installed) {
            rl_redisplay_function = g_orig;            /* restore (NULL ok) */
            g_orig = 0;
            g_installed = 0;
            g_painted = 0;
        }
        /* Tab stays bound to bb_accept_ghost, which now delegates to native */
        return 0;
    }
    if (strcmp(cmd, "text") == 0) {
        size_t n = strlen(a1);
        if (n >= sizeof g_text) n = sizeof g_text - 1;
        memcpy(g_text, a1, n);
        g_text[n] = '\0';
        g_text_len = n;
        return 0;
    }
    if (strcmp(cmd, "guard") == 0) {
        size_t n = strlen(a1);
        if (has_highbit(a1, n)) { printf("SKIP\n"); return 1; }
        if (contains_path(a1, n)) { printf("SKIP\n"); return 1; }
        printf("PAINT\n");
        return 0;
    }
    if (strcmp(cmd, "prefix") == 0) {
        /* verify strict prefix matching: line strictly longer and buf==prefix */
        const char *line = a1, *buf = a2;
        if (!*buf) { printf("NOMATCH\n"); return 1; }
        size_t bl = strlen(buf);
        if (strlen(line) > bl && strncmp(line, buf, bl) == 0) {
            printf("MATCH\n"); return 0;
        }
        printf("NOMATCH\n"); return 1;
    }
    if (strcmp(cmd, "test") == 0) {
        bb_redisplay();                     /* exercise path, possibly NULL */
        return 0;
    }
    fprintf(stderr, "bbghost: unknown subcommand: %s\n", cmd);
    return 1;
}

extern "C" {
struct builtin bbghost_struct = {
    (char *)"bbghost",
    bbghost_builtin,
    1,                              /* BUILTIN_ENABLED */
    bbghost_doc,
    (char *)"bbghost on|off|text <s>|guard <txt>|prefix <line> <buf>|test",
    (char *)0
};
}
