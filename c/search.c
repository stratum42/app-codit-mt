/*
 * c/search.c - Multi-threaded directory & PieceTable search
 */
#if !defined(_WIN32) && !defined(__APPLE__)
#  if !defined(_POSIX_C_SOURCE) && !defined(_GNU_SOURCE) && !defined(_DEFAULT_SOURCE)
#    define _POSIX_C_SOURCE 200809L
#  endif
#endif

#include "search.h"
#include "tkmt_thread.h"

#include <ctype.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#if defined(_WIN32)
#  ifndef WIN32_LEAN_AND_MEAN
#    define WIN32_LEAN_AND_MEAN
#  endif
#  include <windows.h>
#else
#  include <dirent.h>
#  include <sys/stat.h>
#endif

#define CODIT_SEARCH_PREVIEW_MAX 200
#define CODIT_SEARCH_MAX_FILE_BYTES (32u * 1024u * 1024u)

static char *
xstrdup_n(const char *s, size_t n)
{
    char *p = (char *)malloc(n + 1);
    if (!p) return NULL;
    if (n > 0) memcpy(p, s, n);
    p[n] = '\0';
    return p;
}

static char *
make_preview(const char *line, size_t len)
{
    size_t s = 0;
    while (s < len && (line[s] == ' ' || line[s] == '\t')) s++;
    size_t e = len;
    while (e > s && (line[e - 1] == ' ' || line[e - 1] == '\t' ||
                     line[e - 1] == '\r' || line[e - 1] == '\n')) {
        e--;
    }
    size_t plen = e - s;
    if (plen > CODIT_SEARCH_PREVIEW_MAX) plen = CODIT_SEARCH_PREVIEW_MAX;
    return xstrdup_n(line + s, plen);
}

static int
results_push(codit_search_results_t *res, const char *path,
             size_t line, size_t col, size_t len, const char *line_text, size_t line_len)
{
    if (res->count + 1 > res->cap) {
        size_t ncap = res->cap ? res->cap * 2 : 32;
        codit_search_match_t *ni = (codit_search_match_t *)realloc(
            res->items, ncap * sizeof(codit_search_match_t));
        if (!ni) return 0;
        res->items = ni;
        res->cap = ncap;
    }
    codit_search_match_t *m = &res->items[res->count++];
    m->path    = path ? xstrdup_n(path, strlen(path)) : NULL;
    m->line    = line;
    m->col     = col;
    m->len     = len;
    m->preview = make_preview(line_text, line_len);
    return 1;
}

void
codit_search_results_free(codit_search_results_t *res)
{
    if (!res) return;
    for (size_t i = 0; i < res->count; i++) {
        free(res->items[i].path);
        free(res->items[i].preview);
    }
    free(res->items);
    res->items = NULL;
    res->count = 0;
    res->cap   = 0;
}

/* Fast literal / ASCII case-insensitive substring search */
static const char *
find_substr(const char *hay, size_t hlen, const char *needle, size_t nlen, int icase)
{
    if (nlen == 0 || nlen > hlen) return NULL;
    if (!icase) {
        const char *p = hay;
        size_t rem = hlen;
        unsigned char first = (unsigned char)needle[0];
        while (rem >= nlen) {
            const char *hit = (const char *)memchr(p, first, rem - nlen + 1);
            if (!hit) return NULL;
            if (nlen == 1 || memcmp(hit + 1, needle + 1, nlen - 1) == 0) {
                return hit;
            }
            size_t adv = (size_t)(hit - p) + 1;
            p += adv;
            rem -= adv;
        }
        return NULL;
    } else {
        unsigned char f_lo = (unsigned char)tolower((unsigned char)needle[0]);
        unsigned char f_hi = (unsigned char)toupper((unsigned char)needle[0]);
        size_t limit = hlen - nlen;
        for (size_t i = 0; i <= limit; i++) {
            unsigned char c = (unsigned char)hay[i];
            if (c != f_lo && c != f_hi) continue;
            size_t j = 1;
            while (j < nlen &&
                   tolower((unsigned char)hay[i + j]) == tolower((unsigned char)needle[j])) {
                j++;
            }
            if (j == nlen) return hay + i;
        }
        return NULL;
    }
}

/* ---- Directory walker ---- */

static int
should_skip_dir(const char *name)
{
    return (strcmp(name, ".") == 0 ||
            strcmp(name, "..") == 0 ||
            strcmp(name, ".git") == 0 ||
            strcmp(name, "blib") == 0 ||
            strcmp(name, "node_modules") == 0 ||
            strcmp(name, "_build") == 0 ||
            strcmp(name, ".svn") == 0 ||
            strcmp(name, ".hg") == 0);
}

typedef struct {
    char **paths;
    size_t count;
    size_t cap;
} file_list_t;

static int
file_list_push(file_list_t *fl, char *path)
{
    if (fl->count + 1 > fl->cap) {
        size_t ncap = fl->cap ? fl->cap * 2 : 128;
        char **np = (char **)realloc(fl->paths, ncap * sizeof(char *));
        if (!np) {
            free(path);
            return 0;
        }
        fl->paths = np;
        fl->cap = ncap;
    }
    fl->paths[fl->count++] = path;
    return 1;
}

static void
file_list_free(file_list_t *fl)
{
    for (size_t i = 0; i < fl->count; i++) free(fl->paths[i]);
    free(fl->paths);
    fl->paths = NULL;
    fl->count = 0;
    fl->cap   = 0;
}

static int
cmp_cstr_ptr(const void *a, const void *b)
{
    const char *sa = *(const char *const *)a;
    const char *sb = *(const char *const *)b;
    return strcmp(sa, sb);
}

static void
walk_dir(const char *dir, file_list_t *fl, int depth)
{
    if (depth > 32) return;
    size_t dlen = strlen(dir);

#if defined(_WIN32)
    char *pat = (char *)malloc(dlen + 4);
    if (!pat) return;
    snprintf(pat, dlen + 4, "%s\\*", dir);
    WIN32_FIND_DATAA fd;
    HANDLE h = FindFirstFileA(pat, &fd);
    free(pat);
    if (h == INVALID_HANDLE_VALUE) return;
    do {
        const char *name = fd.cFileName;
        if (should_skip_dir(name)) continue;
        size_t nlen = strlen(name);
        char *full = (char *)malloc(dlen + nlen + 2);
        if (!full) continue;
        snprintf(full, dlen + nlen + 2, "%s/%s", dir, name);
        if (fd.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) {
            if (!(fd.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT)) {
                walk_dir(full, fl, depth + 1);
            }
            free(full);
        } else {
            file_list_push(fl, full);
        }
    } while (FindNextFileA(h, &fd));
    FindClose(h);
#else
    DIR *dp = opendir(dir);
    if (!dp) return;
    struct dirent *ent;
    while ((ent = readdir(dp)) != NULL) {
        const char *name = ent->d_name;
        if (should_skip_dir(name)) continue;
        size_t nlen = strlen(name);
        char *full = (char *)malloc(dlen + nlen + 2);
        if (!full) continue;
        if (dlen > 0 && dir[dlen - 1] == '/') {
            snprintf(full, dlen + nlen + 2, "%s%s", dir, name);
        } else {
            snprintf(full, dlen + nlen + 2, "%s/%s", dir, name);
        }
        struct stat st;
        if (lstat(full, &st) != 0) {
            free(full);
            continue;
        }
        if (S_ISDIR(st.st_mode)) {
            walk_dir(full, fl, depth + 1);
            free(full);
        } else if (S_ISREG(st.st_mode)) {
            if ((size_t)st.st_size > 0 && (size_t)st.st_size <= CODIT_SEARCH_MAX_FILE_BYTES) {
                file_list_push(fl, full);
            } else {
                free(full);
            }
        } else {
            free(full);
        }
    }
    closedir(dp);
#endif
}

/* Search a single file into `out` */
static void
search_single_file(const char *path, const char *query, size_t qlen,
                   int icase, size_t max_per_file, codit_search_results_t *out)
{
    FILE *fp = fopen(path, "rb");
    if (!fp) return;

    if (fseek(fp, 0, SEEK_END) != 0) {
        fclose(fp);
        return;
    }
    long fsz_l = ftell(fp);
    if (fsz_l <= 0 || (size_t)fsz_l > CODIT_SEARCH_MAX_FILE_BYTES) {
        fclose(fp);
        return;
    }
    size_t fsz = (size_t)fsz_l;
    rewind(fp);

    /* Quick binary check on first 4096 bytes */
    char probe[4096];
    size_t probe_len = (fsz < sizeof(probe)) ? fsz : sizeof(probe);
    size_t got = fread(probe, 1, probe_len, fp);
    if (got == 0 || memchr(probe, '\0', got) != NULL) {
        fclose(fp);
        return;
    }

    char *buf = (char *)malloc(fsz);
    if (!buf) {
        fclose(fp);
        return;
    }
    memcpy(buf, probe, got);
    if (got < fsz) {
        size_t rest = fread(buf + got, 1, fsz - got, fp);
        fsz = got + rest;
    }
    fclose(fp);

    /* Fast whole-buffer pre-check: skip line splitting if query isn't present at all */
    if (!find_substr(buf, fsz, query, qlen, icase)) {
        free(buf);
        return;
    }

    /* Scan line-by-line (1-based line numbers) */
    size_t line_no = 1;
    size_t pos = 0;
    while (pos < fsz && out->count < max_per_file) {
        const char *nl = (const char *)memchr(buf + pos, '\n', fsz - pos);
        size_t line_end = nl ? (size_t)(nl - buf) : fsz;
        size_t line_len = line_end - pos;
        if (line_len > 0 && buf[pos + line_len - 1] == '\r') {
            line_len--;
        }
        const char *lptr = buf + pos;
        size_t search_off = 0;
        while (search_off + qlen <= line_len && out->count < max_per_file) {
            const char *hit = find_substr(lptr + search_off, line_len - search_off,
                                          query, qlen, icase);
            if (!hit) break;
            size_t col = (size_t)(hit - lptr);
            results_push(out, path, line_no, col, qlen, lptr, line_len);
            search_off = col + qlen;
        }
        pos = nl ? (line_end + 1) : fsz;
        line_no++;
    }

    free(buf);
}

typedef struct {
    char                   **paths;
    size_t                   nfiles;
    const char              *query;
    size_t                   qlen;
    int                      icase;
    size_t                   max_matches;
    codit_search_results_t  *per_file;
    atomic_size_t            next_idx;
} search_pool_ctx_t;

static tkmt_thread_ret_t TKMT_THREAD_CALL
search_worker_fn(void *arg)
{
    search_pool_ctx_t *ctx = (search_pool_ctx_t *)arg;
    for (;;) {
        size_t idx = atomic_fetch_add(&ctx->next_idx, 1);
        if (idx >= ctx->nfiles) break;
        search_single_file(ctx->paths[idx], ctx->query, ctx->qlen,
                           ctx->icase, ctx->max_matches, &ctx->per_file[idx]);
    }
    TKMT_THREAD_RETURN_ZERO;
}

int
codit_search_dir(const char *root_dir, const char *query, size_t qlen,
                 int icase, size_t max_matches, int force_scalar,
                 codit_search_results_t *out)
{
    if (!out) return 0;
    out->items = NULL;
    out->count = 0;
    out->cap   = 0;

    if (!root_dir || !root_dir[0] || !query || qlen == 0) return 1;
    if (max_matches == 0) max_matches = 5000;

    file_list_t fl;
    memset(&fl, 0, sizeof(fl));
    walk_dir(root_dir, &fl, 0);
    if (fl.count == 0) {
        file_list_free(&fl);
        return 1;
    }

    /* Deterministic lexicographic ordering by path */
    qsort(fl.paths, fl.count, sizeof(char *), cmp_cstr_ptr);

    codit_search_results_t *per_file = (codit_search_results_t *)calloc(
        fl.count, sizeof(codit_search_results_t));
    if (!per_file) {
        file_list_free(&fl);
        return 0;
    }

    int nthreads = 1;
    if (!force_scalar) {
        int cpus = tkmt_cpu_count();
        if (cpus > 8) cpus = 8;
        if (cpus < 1) cpus = 1;
        if ((size_t)cpus > fl.count) cpus = (int)fl.count;
        nthreads = cpus;
    }

    if (nthreads <= 1) {
        for (size_t i = 0; i < fl.count; i++) {
            search_single_file(fl.paths[i], query, qlen, icase, max_matches, &per_file[i]);
        }
    } else {
        search_pool_ctx_t ctx;
        ctx.paths       = fl.paths;
        ctx.nfiles      = fl.count;
        ctx.query       = query;
        ctx.qlen        = qlen;
        ctx.icase       = icase;
        ctx.max_matches = max_matches;
        ctx.per_file    = per_file;
        atomic_init(&ctx.next_idx, 0);

        tkmt_thread_t threads[8];
        int spawned = 0;
        for (int t = 0; t < nthreads; t++) {
            if (tkmt_thread_create(&threads[t], search_worker_fn, &ctx) == 0) {
                spawned++;
            } else {
                break;
            }
        }
        /* If some threads failed to spawn, participate on main thread */
        if (spawned == 0) {
            search_worker_fn(&ctx);
        }
        for (int t = 0; t < spawned; t++) {
            tkmt_thread_join(threads[t]);
        }
    }

    /* Merge per-file results in exact sorted file order */
    size_t total = 0;
    for (size_t i = 0; i < fl.count; i++) {
        total += per_file[i].count;
        if (total >= max_matches) {
            total = max_matches;
            break;
        }
    }

    if (total > 0) {
        out->items = (codit_search_match_t *)malloc(total * sizeof(codit_search_match_t));
        if (out->items) {
            out->cap = total;
            for (size_t i = 0; i < fl.count && out->count < max_matches; i++) {
                codit_search_results_t *pf = &per_file[i];
                for (size_t j = 0; j < pf->count && out->count < max_matches; j++) {
                    out->items[out->count++] = pf->items[j];
                    pf->items[j].path    = NULL;
                    pf->items[j].preview = NULL;
                }
            }
        }
    }

    for (size_t i = 0; i < fl.count; i++) {
        codit_search_results_free(&per_file[i]);
    }
    free(per_file);
    file_list_free(&fl);
    return 1;
}

int
codit_search_piece_table(codit_piece_table_t *pt, const char *query, size_t qlen,
                         int icase, size_t max_matches,
                         codit_search_results_t *out)
{
    if (!out) return 0;
    out->items = NULL;
    out->count = 0;
    out->cap   = 0;

    if (!pt || !query || qlen == 0) return 1;
    if (max_matches == 0) max_matches = 10000;

    size_t nlines = codit_pt_line_count(pt);
    char stack_buf[4096];

    for (size_t line = 0; line < nlines && out->count < max_matches; line++) {
        size_t llen = codit_pt_get_line_buf(pt, line, stack_buf, sizeof(stack_buf));
        if (llen < qlen) continue;
        char *heap_buf = NULL;
        const char *lptr = stack_buf;
        if (llen >= sizeof(stack_buf)) {
            heap_buf = codit_pt_get_line_alloc(pt, line, &llen);
            if (!heap_buf) continue;
            lptr = heap_buf;
        }

        size_t off = 0;
        while (off + qlen <= llen && out->count < max_matches) {
            const char *hit = find_substr(lptr + off, llen - off, query, qlen, icase);
            if (!hit) break;
            size_t col = (size_t)(hit - lptr);
            results_push(out, NULL, line, col, qlen, lptr, llen);
            off = col + qlen;
        }
        free(heap_buf);
    }

    return 1;
}
