/*
 * c/piece_table.c - Zero-copy mmap piece table with fast line index and undo/redo
 */
#if !defined(_WIN32) && !defined(__APPLE__)
#  if !defined(_POSIX_C_SOURCE) && !defined(_GNU_SOURCE) && !defined(_DEFAULT_SOURCE)
#    define _POSIX_C_SOURCE 200809L
#  endif
#endif

#include "piece_table.h"

#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#if defined(_WIN32)
#  ifndef WIN32_LEAN_AND_MEAN
#    define WIN32_LEAN_AND_MEAN
#  endif
#  include <windows.h>
#  include <process.h>
#else
#  include <fcntl.h>
#  include <sys/mman.h>
#  include <sys/stat.h>
#  include <unistd.h>
#endif

enum {
    PT_SRC_ORIG = 0,
    PT_SRC_ADD  = 1
};

enum {
    PT_OP_INSERT = 1,
    PT_OP_DELETE = 2
};

typedef struct {
    uint8_t src;
    size_t  start;
    size_t  len;
} codit_piece_t;

typedef struct {
    uint8_t op;
    size_t  offset;
    size_t  len;
    size_t  add_off;
} codit_edit_t;

struct codit_piece_table {
    /* Original read-only buffer (mmap or heap) */
    const char *orig_buf;
    size_t      orig_len;
    int         orig_is_mmap;
    int         orig_is_heap;
#if defined(_WIN32)
    HANDLE      win_file;
    HANDLE      win_map;
#endif

    /* Append-only add buffer */
    char       *add_buf;
    size_t      add_len;
    size_t      add_cap;

    /* Piece sequence */
    codit_piece_t *pieces;
    size_t         piece_count;
    size_t         piece_cap;
    size_t         total_bytes;

    /* Contiguous line-start byte offset index (line_starts[0] == 0) */
    size_t     *line_starts;
    size_t      line_count;
    size_t      line_cap;
    int         line_index_dirty;

    /* Undo / Redo stacks */
    codit_edit_t *undo_stack;
    size_t        undo_count;
    size_t        undo_cap;

    codit_edit_t *redo_stack;
    size_t        redo_count;
    size_t        redo_cap;

    uint64_t    revision;
};

static void
set_err(char *errbuf, size_t errsz, const char *msg)
{
    if (!errbuf || errsz == 0) return;
    snprintf(errbuf, errsz, "%s", msg ? msg : "unknown error");
}

static int
pt_ensure_pieces(codit_piece_table_t *pt, size_t need)
{
    if (need <= pt->piece_cap) return 1;
    size_t ncap = pt->piece_cap ? pt->piece_cap * 2 : 16;
    while (ncap < need) ncap *= 2;
    codit_piece_t *np = (codit_piece_t *)realloc(pt->pieces, ncap * sizeof(codit_piece_t));
    if (!np) return 0;
    pt->pieces = np;
    pt->piece_cap = ncap;
    return 1;
}

static int
pt_ensure_add(codit_piece_table_t *pt, size_t extra)
{
    size_t need = pt->add_len + extra;
    if (need <= pt->add_cap) return 1;
    size_t ncap = pt->add_cap ? pt->add_cap * 2 : 4096;
    while (ncap < need) ncap *= 2;
    char *nb = (char *)realloc(pt->add_buf, ncap);
    if (!nb) return 0;
    pt->add_buf = nb;
    pt->add_cap = ncap;
    return 1;
}

static int
pt_ensure_lines(codit_piece_table_t *pt, size_t need)
{
    if (need <= pt->line_cap) return 1;
    size_t ncap = pt->line_cap ? pt->line_cap * 2 : 256;
    while (ncap < need) ncap *= 2;
    size_t *nl = (size_t *)realloc(pt->line_starts, ncap * sizeof(size_t));
    if (!nl) return 0;
    pt->line_starts = nl;
    pt->line_cap = ncap;
    return 1;
}

static int
pt_push_edit(codit_edit_t **stack, size_t *count, size_t *cap, codit_edit_t e)
{
    if (*count + 1 > *cap) {
        size_t ncap = *cap ? (*cap * 2) : 64;
        codit_edit_t *ns = (codit_edit_t *)realloc(*stack, ncap * sizeof(codit_edit_t));
        if (!ns) return 0;
        *stack = ns;
        *cap = ncap;
    }
    (*stack)[(*count)++] = e;
    return 1;
}

static inline const char *
piece_ptr(const codit_piece_table_t *pt, const codit_piece_t *p)
{
    return (p->src == PT_SRC_ORIG ? pt->orig_buf : pt->add_buf) + p->start;
}

static int
pt_rebuild_lines(codit_piece_table_t *pt)
{
    /* Heuristic pre-allocation: ~48 bytes per line */
    size_t est = (pt->total_bytes / 48) + 64;
    if (est > pt->line_cap) {
        if (!pt_ensure_lines(pt, est)) return 0;
    } else if (pt->line_cap == 0) {
        if (!pt_ensure_lines(pt, 64)) return 0;
    }

    pt->line_count = 0;
    pt->line_starts[pt->line_count++] = 0;

    size_t doc_off = 0;
    for (size_t i = 0; i < pt->piece_count; i++) {
        const codit_piece_t *pc = &pt->pieces[i];
        const char *base = piece_ptr(pt, pc);
        const char *cur  = base;
        size_t rem       = pc->len;

        while (rem > 0) {
            const char *nl = (const char *)memchr(cur, '\n', rem);
            if (!nl) break;
            size_t adv = (size_t)(nl - cur) + 1;
            size_t next_line_off = doc_off + (size_t)(nl - base) + 1;
            if (pt->line_count >= pt->line_cap) {
                if (!pt_ensure_lines(pt, pt->line_count + 1)) return 0;
            }
            pt->line_starts[pt->line_count++] = next_line_off;
            cur += adv;
            rem -= adv;
        }
        doc_off += pc->len;
    }

    pt->line_index_dirty = 0;
    return 1;
}

static inline void
pt_ensure_line_index(codit_piece_table_t *pt)
{
    if (pt->line_index_dirty || pt->line_count == 0) {
        pt_rebuild_lines(pt);
    }
}

/* Binary search: largest line index L such that line_starts[L] <= offset */
static size_t
pt_find_line_for_offset(const codit_piece_table_t *pt, size_t offset)
{
    size_t lo = 0;
    size_t hi = pt->line_count;
    while (lo + 1 < hi) {
        size_t mid = lo + (hi - lo) / 2;
        if (pt->line_starts[mid] <= offset) {
            lo = mid;
        } else {
            hi = mid;
        }
    }
    return lo;
}

/* Incremental line index update after inserting data[0..len) at offset */
static void
pt_lines_on_insert(codit_piece_table_t *pt, size_t offset, const char *data, size_t len)
{
    if (pt->line_index_dirty || pt->line_count == 0 || len == 0) return;

    /* Count newlines in inserted slice */
    size_t nl_count = 0;
    const char *p = data;
    size_t rem = len;
    while (rem > 0) {
        const char *nl = (const char *)memchr(p, '\n', rem);
        if (!nl) break;
        nl_count++;
        size_t adv = (size_t)(nl - p) + 1;
        p += adv;
        rem -= adv;
    }

    size_t line_idx = pt_find_line_for_offset(pt, offset);
    size_t tail_start = line_idx + 1;
    size_t tail_cnt = pt->line_count - tail_start;

    if (nl_count > 0) {
        if (!pt_ensure_lines(pt, pt->line_count + nl_count)) {
            pt->line_index_dirty = 1;
            return;
        }
        if (tail_cnt > 0) {
            memmove(&pt->line_starts[tail_start + nl_count],
                    &pt->line_starts[tail_start],
                    tail_cnt * sizeof(size_t));
        }
        /* Fill newly created line starts */
        size_t wr = tail_start;
        p = data;
        rem = len;
        while (rem > 0) {
            const char *nl = (const char *)memchr(p, '\n', rem);
            if (!nl) break;
            pt->line_starts[wr++] = offset + (size_t)(nl - data) + 1;
            size_t adv = (size_t)(nl - p) + 1;
            p += adv;
            rem -= adv;
        }
        pt->line_count += nl_count;
    }

    /* Shift all subsequent line starts by +len */
    size_t shift_from = tail_start + nl_count;
    size_t *ls = pt->line_starts;
    size_t lc = pt->line_count;
    for (size_t i = shift_from; i < lc; i++) {
        ls[i] += len;
    }
}

/* Incremental line index update after deleting [offset, offset + len) */
static void
pt_lines_on_delete(codit_piece_table_t *pt, size_t offset, size_t len)
{
    if (pt->line_index_dirty || pt->line_count == 0 || len == 0) return;

    size_t end_off = offset + len;
    /* First line_start strictly greater than offset */
    size_t line_idx = pt_find_line_for_offset(pt, offset);
    size_t first_rm = line_idx + 1;

    /* Find first line_start strictly greater than end_off */
    size_t lo = first_rm;
    size_t hi = pt->line_count;
    while (lo < hi) {
        size_t mid = lo + (hi - lo) / 2;
        if (pt->line_starts[mid] <= end_off) {
            lo = mid + 1;
        } else {
            hi = mid;
        }
    }
    size_t after_rm = lo;
    size_t removed = after_rm - first_rm;
    size_t tail_cnt = pt->line_count - after_rm;

    if (removed > 0 && tail_cnt > 0) {
        memmove(&pt->line_starts[first_rm],
                &pt->line_starts[after_rm],
                tail_cnt * sizeof(size_t));
    }
    pt->line_count -= removed;

    size_t *ls = pt->line_starts;
    size_t lc = pt->line_count;
    for (size_t i = first_rm; i < lc; i++) {
        ls[i] -= len;
    }
}

static int
pt_insert_raw(codit_piece_table_t *pt, size_t offset, size_t add_off, size_t len)
{
    if (len == 0) return 1;
    if (offset > pt->total_bytes) offset = pt->total_bytes;

    /* Find piece containing offset */
    size_t pos = 0;
    size_t idx = 0;
    while (idx < pt->piece_count && pos + pt->pieces[idx].len < offset) {
        pos += pt->pieces[idx].len;
        idx++;
    }

    /* Case 1: inserting at boundary right after pieces[idx] (when pos + len == offset) */
    if (idx < pt->piece_count && pos + pt->pieces[idx].len == offset) {
        /* Coalesce sequential typing into the same ADD piece */
        if (pt->pieces[idx].src == PT_SRC_ADD &&
            pt->pieces[idx].start + pt->pieces[idx].len == add_off) {
            pt->pieces[idx].len += len;
            pt->total_bytes += len;
            return 1;
        }
        /* Insert new piece after idx */
        if (!pt_ensure_pieces(pt, pt->piece_count + 1)) return 0;
        size_t ins = idx + 1;
        if (ins < pt->piece_count) {
            memmove(&pt->pieces[ins + 1], &pt->pieces[ins],
                    (pt->piece_count - ins) * sizeof(codit_piece_t));
        }
        pt->pieces[ins].src   = PT_SRC_ADD;
        pt->pieces[ins].start = add_off;
        pt->pieces[ins].len   = len;
        pt->piece_count++;
        pt->total_bytes += len;
        return 1;
    }

    /* Case 2: inserting at beginning of pieces[idx] or at end of empty/all pieces */
    if (idx == pt->piece_count || pos == offset) {
        if (idx > 0 &&
            pt->pieces[idx - 1].src == PT_SRC_ADD &&
            pt->pieces[idx - 1].start + pt->pieces[idx - 1].len == add_off) {
            pt->pieces[idx - 1].len += len;
            pt->total_bytes += len;
            return 1;
        }
        if (!pt_ensure_pieces(pt, pt->piece_count + 1)) return 0;
        if (idx < pt->piece_count) {
            memmove(&pt->pieces[idx + 1], &pt->pieces[idx],
                    (pt->piece_count - idx) * sizeof(codit_piece_t));
        }
        pt->pieces[idx].src   = PT_SRC_ADD;
        pt->pieces[idx].start = add_off;
        pt->pieces[idx].len   = len;
        pt->piece_count++;
        pt->total_bytes += len;
        return 1;
    }

    /* Case 3: strictly inside pieces[idx] -> split into left, new, right */
    size_t split = offset - pos;
    if (!pt_ensure_pieces(pt, pt->piece_count + 2)) return 0;

    codit_piece_t orig = pt->pieces[idx];
    if (idx + 1 < pt->piece_count) {
        memmove(&pt->pieces[idx + 3], &pt->pieces[idx + 1],
                (pt->piece_count - (idx + 1)) * sizeof(codit_piece_t));
    }

    pt->pieces[idx].src     = orig.src;
    pt->pieces[idx].start   = orig.start;
    pt->pieces[idx].len     = split;

    pt->pieces[idx + 1].src   = PT_SRC_ADD;
    pt->pieces[idx + 1].start = add_off;
    pt->pieces[idx + 1].len   = len;

    pt->pieces[idx + 2].src   = orig.src;
    pt->pieces[idx + 2].start = orig.start + split;
    pt->pieces[idx + 2].len   = orig.len - split;

    pt->piece_count += 2;
    pt->total_bytes += len;
    return 1;
}

static int
pt_delete_raw(codit_piece_table_t *pt, size_t offset, size_t len)
{
    if (len == 0 || offset >= pt->total_bytes) return 1;
    if (offset + len > pt->total_bytes) {
        len = pt->total_bytes - offset;
    }
    size_t end_off = offset + len;

    /* Find first affected piece */
    size_t pos = 0;
    size_t first = 0;
    while (first < pt->piece_count && pos + pt->pieces[first].len <= offset) {
        pos += pt->pieces[first].len;
        first++;
    }
    if (first >= pt->piece_count) return 1;

    size_t first_off = offset - pos;

    /* Single-piece strictly interior deletion -> split into 2 pieces */
    if (first_off > 0 && first_off + len < pt->pieces[first].len) {
        if (!pt_ensure_pieces(pt, pt->piece_count + 1)) return 0;
        codit_piece_t orig = pt->pieces[first];
        if (first + 1 < pt->piece_count) {
            memmove(&pt->pieces[first + 2], &pt->pieces[first + 1],
                    (pt->piece_count - (first + 1)) * sizeof(codit_piece_t));
        }
        pt->pieces[first].len = first_off;
        pt->pieces[first + 1].src   = orig.src;
        pt->pieces[first + 1].start = orig.start + first_off + len;
        pt->pieces[first + 1].len   = orig.len - first_off - len;
        pt->piece_count++;
        pt->total_bytes -= len;
        return 1;
    }

    /* General multi-piece or boundary deletion */
    size_t p_pos    = pos;
    size_t idx      = first;
    size_t rm_start = first;
    size_t rm_end   = first;

    /* If deletion starts mid-piece, keep its left prefix */
    if (first_off > 0) {
        size_t orig_len = pt->pieces[idx].len;
        pt->pieces[idx].len = first_off;
        p_pos += orig_len;
        idx++;
        rm_start = idx;
        rm_end   = idx;
    }

    /* Skip all pieces completely covered by [offset, end_off) */
    while (idx < pt->piece_count && p_pos + pt->pieces[idx].len <= end_off) {
        p_pos += pt->pieces[idx].len;
        idx++;
        rm_end = idx;
    }

    /* If deletion ends mid-piece, trim its left prefix */
    if (idx < pt->piece_count && p_pos < end_off) {
        size_t trim = end_off - p_pos;
        pt->pieces[idx].start += trim;
        pt->pieces[idx].len   -= trim;
    }

    /* Remove completely covered pieces [rm_start, rm_end) */
    if (rm_end > rm_start) {
        size_t tail = pt->piece_count - rm_end;
        if (tail > 0) {
            memmove(&pt->pieces[rm_start], &pt->pieces[rm_end],
                    tail * sizeof(codit_piece_t));
        }
        pt->piece_count -= (rm_end - rm_start);
    }

    pt->total_bytes -= len;
    return 1;
}

/* ---- Public API ---- */

codit_piece_table_t *
codit_pt_new(void)
{
    codit_piece_table_t *pt = (codit_piece_table_t *)calloc(1, sizeof(*pt));
    if (!pt) return NULL;
#if defined(_WIN32)
    pt->win_file = INVALID_HANDLE_VALUE;
    pt->win_map  = NULL;
#endif
    if (!pt_ensure_lines(pt, 16)) {
        free(pt);
        return NULL;
    }
    pt->line_starts[0]   = 0;
    pt->line_count       = 1;
    pt->line_index_dirty = 0;
    return pt;
}

codit_piece_table_t *
codit_pt_from_string(const char *data, size_t len)
{
    codit_piece_table_t *pt = codit_pt_new();
    if (!pt) return NULL;
    if (data && len > 0) {
        char *copy = (char *)malloc(len);
        if (!copy) {
            codit_pt_free(pt);
            return NULL;
        }
        memcpy(copy, data, len);
        pt->orig_buf     = copy;
        pt->orig_len     = len;
        pt->orig_is_heap = 1;
        if (!pt_ensure_pieces(pt, 4)) {
            codit_pt_free(pt);
            return NULL;
        }
        pt->pieces[0].src   = PT_SRC_ORIG;
        pt->pieces[0].start = 0;
        pt->pieces[0].len   = len;
        pt->piece_count     = 1;
        pt->total_bytes     = len;
        pt->line_index_dirty = 1;
        pt_rebuild_lines(pt);
    }
    return pt;
}

static codit_piece_table_t *
pt_open_fread_fallback(const char *path, char *errbuf, size_t errsz)
{
    FILE *fp = fopen(path, "rb");
    if (!fp) {
        set_err(errbuf, errsz, strerror(errno));
        return NULL;
    }
    size_t cap = 65536;
    size_t len = 0;
    char *buf = (char *)malloc(cap);
    if (!buf) {
        fclose(fp);
        set_err(errbuf, errsz, "out of memory");
        return NULL;
    }
    for (;;) {
        if (len + 32768 > cap) {
            cap *= 2;
            char *nb = (char *)realloc(buf, cap);
            if (!nb) {
                free(buf);
                fclose(fp);
                set_err(errbuf, errsz, "out of memory");
                return NULL;
            }
            buf = nb;
        }
        size_t got = fread(buf + len, 1, cap - len, fp);
        len += got;
        if (got == 0) break;
    }
    int f_err = ferror(fp);
    fclose(fp);
    if (f_err) {
        free(buf);
        set_err(errbuf, errsz, "read error");
        return NULL;
    }
    codit_piece_table_t *pt = codit_pt_new();
    if (!pt) {
        free(buf);
        set_err(errbuf, errsz, "out of memory");
        return NULL;
    }
    if (len > 0) {
        pt->orig_buf     = buf;
        pt->orig_len     = len;
        pt->orig_is_heap = 1;
        if (!pt_ensure_pieces(pt, 4)) {
            codit_pt_free(pt);
            set_err(errbuf, errsz, "out of memory");
            return NULL;
        }
        pt->pieces[0].src    = PT_SRC_ORIG;
        pt->pieces[0].start  = 0;
        pt->pieces[0].len    = len;
        pt->piece_count      = 1;
        pt->total_bytes      = len;
        pt->line_index_dirty = 1;
        pt_rebuild_lines(pt);
    } else {
        free(buf);
    }
    return pt;
}

codit_piece_table_t *
codit_pt_open_file(const char *path, char *errbuf, size_t errsz)
{
    if (!path || !path[0]) {
        set_err(errbuf, errsz, "empty path");
        return NULL;
    }

#if defined(_WIN32)
    HANDLE hFile = CreateFileA(path, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE,
                               NULL, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
    if (hFile == INVALID_HANDLE_VALUE) {
        return pt_open_fread_fallback(path, errbuf, errsz);
    }
    LARGE_INTEGER fsz;
    if (!GetFileSizeEx(hFile, &fsz)) {
        CloseHandle(hFile);
        return pt_open_fread_fallback(path, errbuf, errsz);
    }
    if (fsz.QuadPart == 0) {
        CloseHandle(hFile);
        return codit_pt_new();
    }
    HANDLE hMap = CreateFileMappingA(hFile, NULL, PAGE_READONLY, 0, 0, NULL);
    if (!hMap) {
        CloseHandle(hFile);
        return pt_open_fread_fallback(path, errbuf, errsz);
    }
    void *view = MapViewOfFile(hMap, FILE_MAP_READ, 0, 0, 0);
    if (!view) {
        CloseHandle(hMap);
        CloseHandle(hFile);
        return pt_open_fread_fallback(path, errbuf, errsz);
    }
    codit_piece_table_t *pt = codit_pt_new();
    if (!pt) {
        UnmapViewOfFile(view);
        CloseHandle(hMap);
        CloseHandle(hFile);
        set_err(errbuf, errsz, "out of memory");
        return NULL;
    }
    pt->orig_buf     = (const char *)view;
    pt->orig_len     = (size_t)fsz.QuadPart;
    pt->orig_is_mmap = 1;
    pt->win_file     = hFile;
    pt->win_map      = hMap;
    if (!pt_ensure_pieces(pt, 4)) {
        codit_pt_free(pt);
        set_err(errbuf, errsz, "out of memory");
        return NULL;
    }
    pt->pieces[0].src    = PT_SRC_ORIG;
    pt->pieces[0].start  = 0;
    pt->pieces[0].len    = pt->orig_len;
    pt->piece_count      = 1;
    pt->total_bytes      = pt->orig_len;
    pt->line_index_dirty = 1;
    pt_rebuild_lines(pt);
    return pt;
#else
    int fd = open(path, O_RDONLY);
    if (fd < 0) {
        set_err(errbuf, errsz, strerror(errno));
        return NULL;
    }
    struct stat st;
    if (fstat(fd, &st) != 0) {
        int saved = errno;
        close(fd);
        set_err(errbuf, errsz, strerror(saved));
        return NULL;
    }
    if (S_ISDIR(st.st_mode)) {
        close(fd);
        set_err(errbuf, errsz, "is a directory");
        return NULL;
    }
    if (!S_ISREG(st.st_mode)) {
        close(fd);
        return pt_open_fread_fallback(path, errbuf, errsz);
    }
    if (st.st_size == 0) {
        close(fd);
        return codit_pt_new();
    }
    size_t fsize = (size_t)st.st_size;
    void *mapped = mmap(NULL, fsize, PROT_READ, MAP_PRIVATE, fd, 0);
    close(fd);
    if (mapped == MAP_FAILED) {
        return pt_open_fread_fallback(path, errbuf, errsz);
    }

    codit_piece_table_t *pt = codit_pt_new();
    if (!pt) {
        munmap(mapped, fsize);
        set_err(errbuf, errsz, "out of memory");
        return NULL;
    }
    pt->orig_buf     = (const char *)mapped;
    pt->orig_len     = fsize;
    pt->orig_is_mmap = 1;
    if (!pt_ensure_pieces(pt, 4)) {
        codit_pt_free(pt);
        set_err(errbuf, errsz, "out of memory");
        return NULL;
    }
    pt->pieces[0].src    = PT_SRC_ORIG;
    pt->pieces[0].start  = 0;
    pt->pieces[0].len    = fsize;
    pt->piece_count      = 1;
    pt->total_bytes      = fsize;
    pt->line_index_dirty = 1;
    pt_rebuild_lines(pt);
    return pt;
#endif
}

void
codit_pt_free(codit_piece_table_t *pt)
{
    if (!pt) return;
    if (pt->orig_buf) {
        if (pt->orig_is_mmap) {
#if defined(_WIN32)
            UnmapViewOfFile((LPCVOID)pt->orig_buf);
            if (pt->win_map) CloseHandle(pt->win_map);
            if (pt->win_file != INVALID_HANDLE_VALUE) CloseHandle(pt->win_file);
#else
            munmap((void *)pt->orig_buf, pt->orig_len);
#endif
        } else if (pt->orig_is_heap) {
            free((void *)pt->orig_buf);
        }
    }
    free(pt->add_buf);
    free(pt->pieces);
    free(pt->line_starts);
    free(pt->undo_stack);
    free(pt->redo_stack);
    free(pt);
}

int
codit_pt_insert(codit_piece_table_t *pt, size_t offset, const char *data, size_t len)
{
    if (!pt) return 0;
    if (!data || len == 0) return 1;
    if (offset > pt->total_bytes) offset = pt->total_bytes;

    if (!pt_ensure_add(pt, len)) return 0;
    size_t add_off = pt->add_len;
    memcpy(pt->add_buf + add_off, data, len);
    pt->add_len += len;

    if (!pt_insert_raw(pt, offset, add_off, len)) return 0;
    pt_lines_on_insert(pt, offset, pt->add_buf + add_off, len);

    codit_edit_t e;
    e.op      = PT_OP_INSERT;
    e.offset  = offset;
    e.len     = len;
    e.add_off = add_off;
    pt_push_edit(&pt->undo_stack, &pt->undo_count, &pt->undo_cap, e);
    pt->redo_count = 0;
    pt->revision++;
    return 1;
}

int
codit_pt_delete(codit_piece_table_t *pt, size_t offset, size_t len)
{
    if (!pt) return 0;
    if (len == 0 || offset >= pt->total_bytes) return 1;
    if (offset + len > pt->total_bytes) {
        len = pt->total_bytes - offset;
    }

    if (!pt_ensure_add(pt, len)) return 0;
    size_t add_off = pt->add_len;
    codit_pt_copy_range(pt, offset, len, pt->add_buf + add_off);
    pt->add_len += len;

    if (!pt_delete_raw(pt, offset, len)) return 0;
    pt_lines_on_delete(pt, offset, len);

    codit_edit_t e;
    e.op      = PT_OP_DELETE;
    e.offset  = offset;
    e.len     = len;
    e.add_off = add_off;
    pt_push_edit(&pt->undo_stack, &pt->undo_count, &pt->undo_cap, e);
    pt->redo_count = 0;
    pt->revision++;
    return 1;
}

int
codit_pt_undo(codit_piece_table_t *pt)
{
    if (!pt || pt->undo_count == 0) return 0;
    codit_edit_t e = pt->undo_stack[pt->undo_count - 1];
    pt->undo_count--;

    if (e.op == PT_OP_INSERT) {
        if (!pt_delete_raw(pt, e.offset, e.len)) return -1;
        pt_lines_on_delete(pt, e.offset, e.len);
    } else {
        if (!pt_insert_raw(pt, e.offset, e.add_off, e.len)) return -1;
        pt_lines_on_insert(pt, e.offset, pt->add_buf + e.add_off, e.len);
    }

    pt_push_edit(&pt->redo_stack, &pt->redo_count, &pt->redo_cap, e);
    pt->revision++;
    return 1;
}

int
codit_pt_redo(codit_piece_table_t *pt)
{
    if (!pt || pt->redo_count == 0) return 0;
    codit_edit_t e = pt->redo_stack[pt->redo_count - 1];
    pt->redo_count--;

    if (e.op == PT_OP_INSERT) {
        if (!pt_insert_raw(pt, e.offset, e.add_off, e.len)) return -1;
        pt_lines_on_insert(pt, e.offset, pt->add_buf + e.add_off, e.len);
    } else {
        if (!pt_delete_raw(pt, e.offset, e.len)) return -1;
        pt_lines_on_delete(pt, e.offset, e.len);
    }

    pt_push_edit(&pt->undo_stack, &pt->undo_count, &pt->undo_cap, e);
    pt->revision++;
    return 1;
}

int
codit_pt_can_undo(const codit_piece_table_t *pt)
{
    return (pt && pt->undo_count > 0) ? 1 : 0;
}

int
codit_pt_can_redo(const codit_piece_table_t *pt)
{
    return (pt && pt->redo_count > 0) ? 1 : 0;
}

size_t
codit_pt_line_count(codit_piece_table_t *pt)
{
    if (!pt) return 0;
    pt_ensure_line_index(pt);
    return pt->line_count;
}

size_t
codit_pt_byte_length(const codit_piece_table_t *pt)
{
    return pt ? pt->total_bytes : 0;
}

size_t
codit_pt_copy_range(const codit_piece_table_t *pt, size_t offset, size_t len, char *dst)
{
    if (!pt || !dst || len == 0 || offset >= pt->total_bytes) return 0;
    if (offset + len > pt->total_bytes) {
        len = pt->total_bytes - offset;
    }

    size_t copied = 0;
    size_t pos = 0;
    for (size_t i = 0; i < pt->piece_count && copied < len; i++) {
        const codit_piece_t *pc = &pt->pieces[i];
        size_t pc_end = pos + pc->len;
        if (pc_end <= offset) {
            pos = pc_end;
            continue;
        }
        size_t rel_start = (offset > pos) ? (offset - pos) : 0;
        size_t avail     = pc->len - rel_start;
        size_t take      = (len - copied < avail) ? (len - copied) : avail;
        memcpy(dst + copied, piece_ptr(pt, pc) + rel_start, take);
        copied += take;
        pos = pc_end;
    }
    return copied;
}

int
codit_pt_line_bounds(codit_piece_table_t *pt, size_t line,
                     size_t *out_start, size_t *out_len)
{
    if (!pt) return 0;
    pt_ensure_line_index(pt);
    if (line >= pt->line_count) return 0;

    size_t start = pt->line_starts[line];
    size_t end   = (line + 1 < pt->line_count) ? pt->line_starts[line + 1] : pt->total_bytes;
    size_t len   = end - start;

    /* Strip trailing \n (and optional preceding \r) */
    if (len > 0 && line + 1 < pt->line_count) {
        len--; /* strip '\n' */
        if (len > 0) {
            char last = 0;
            codit_pt_copy_range(pt, start + len - 1, 1, &last);
            if (last == '\r') len--;
        }
    } else if (len > 0) {
        char last = 0;
        codit_pt_copy_range(pt, start + len - 1, 1, &last);
        if (last == '\r') len--;
    }

    if (out_start) *out_start = start;
    if (out_len)   *out_len   = len;
    return 1;
}

char *
codit_pt_get_line_alloc(codit_piece_table_t *pt, size_t line, size_t *out_len)
{
    size_t start = 0, len = 0;
    if (!codit_pt_line_bounds(pt, line, &start, &len)) {
        if (out_len) *out_len = 0;
        return NULL;
    }
    char *buf = (char *)malloc(len + 1);
    if (!buf) {
        if (out_len) *out_len = 0;
        return NULL;
    }
    if (len > 0) {
        codit_pt_copy_range(pt, start, len, buf);
    }
    buf[len] = '\0';
    if (out_len) *out_len = len;
    return buf;
}

size_t
codit_pt_get_line_buf(codit_piece_table_t *pt, size_t line, char *buf, size_t buf_cap)
{
    size_t start = 0, len = 0;
    if (!codit_pt_line_bounds(pt, line, &start, &len)) {
        if (buf && buf_cap > 0) buf[0] = '\0';
        return 0;
    }
    if (buf && buf_cap > 0) {
        size_t copy_n = (len < buf_cap - 1) ? len : (buf_cap - 1);
        if (copy_n > 0) {
            codit_pt_copy_range(pt, start, copy_n, buf);
        }
        buf[copy_n] = '\0';
    }
    return len;
}

size_t
codit_pt_line_col_to_offset(codit_piece_table_t *pt, size_t line, size_t col)
{
    if (!pt) return 0;
    pt_ensure_line_index(pt);
    if (pt->line_count == 0) return 0;
    if (line >= pt->line_count) {
        return pt->total_bytes;
    }
    size_t start = 0, len = 0;
    codit_pt_line_bounds(pt, line, &start, &len);
    if (col > len) col = len;
    return start + col;
}

void
codit_pt_offset_to_line_col(codit_piece_table_t *pt, size_t offset,
                            size_t *out_line, size_t *out_col)
{
    if (!pt) {
        if (out_line) *out_line = 0;
        if (out_col)  *out_col  = 0;
        return;
    }
    pt_ensure_line_index(pt);
    if (offset > pt->total_bytes) offset = pt->total_bytes;
    size_t line = pt_find_line_for_offset(pt, offset);
    size_t col  = offset - pt->line_starts[line];
    if (out_line) *out_line = line;
    if (out_col)  *out_col  = col;
}

int
codit_pt_save_file(const codit_piece_table_t *pt, const char *path,
                   char *errbuf, size_t errsz)
{
    if (!pt || !path || !path[0]) {
        set_err(errbuf, errsz, "invalid arguments");
        return 0;
    }

    /* Atomic write via sibling temp file to protect any active mmap */
    size_t plen = strlen(path);
    char *tmp_path = (char *)malloc(plen + 48);
    if (!tmp_path) {
        set_err(errbuf, errsz, "out of memory");
        return 0;
    }
#if defined(_WIN32)
    snprintf(tmp_path, plen + 48, "%s.codit.tmp.%d", path, _getpid());
#else
    snprintf(tmp_path, plen + 48, "%s.codit.tmp.%ld", path, (long)getpid());
#endif

    FILE *fp = fopen(tmp_path, "wb");
    int used_tmp = 1;
    if (!fp) {
        used_tmp = 0;
        fp = fopen(path, "wb");
        if (!fp) {
            set_err(errbuf, errsz, strerror(errno));
            free(tmp_path);
            return 0;
        }
    }

    for (size_t i = 0; i < pt->piece_count; i++) {
        const codit_piece_t *pc = &pt->pieces[i];
        if (pc->len == 0) continue;
        const char *ptr = piece_ptr(pt, pc);
        if (fwrite(ptr, 1, pc->len, fp) != pc->len) {
            set_err(errbuf, errsz, strerror(errno));
            fclose(fp);
            if (used_tmp) remove(tmp_path);
            free(tmp_path);
            return 0;
        }
    }

    if (fclose(fp) != 0) {
        set_err(errbuf, errsz, strerror(errno));
        if (used_tmp) remove(tmp_path);
        free(tmp_path);
        return 0;
    }

    if (used_tmp) {
#if defined(_WIN32)
        if (!MoveFileExA(tmp_path, path, MOVEFILE_REPLACE_EXISTING)) {
            remove(tmp_path);
            set_err(errbuf, errsz, "failed to replace target file");
            free(tmp_path);
            return 0;
        }
#else
        if (rename(tmp_path, path) != 0) {
            set_err(errbuf, errsz, strerror(errno));
            remove(tmp_path);
            free(tmp_path);
            return 0;
        }
#endif
    }

    free(tmp_path);
    return 1;
}

char *
codit_pt_to_string(const codit_piece_table_t *pt, size_t *out_len)
{
    if (!pt) {
        if (out_len) *out_len = 0;
        return NULL;
    }
    char *buf = (char *)malloc(pt->total_bytes + 1);
    if (!buf) {
        if (out_len) *out_len = 0;
        return NULL;
    }
    if (pt->total_bytes > 0) {
        codit_pt_copy_range(pt, 0, pt->total_bytes, buf);
    }
    buf[pt->total_bytes] = '\0';
    if (out_len) *out_len = pt->total_bytes;
    return buf;
}

uint64_t
codit_pt_revision(const codit_piece_table_t *pt)
{
    return pt ? pt->revision : 0;
}

