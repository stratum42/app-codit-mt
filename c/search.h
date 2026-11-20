/*
 * c/search.h - Multi-threaded directory & buffer search
 */
#ifndef CODIT_SEARCH_H
#define CODIT_SEARCH_H

#include "piece_table.h"
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    char  *path;    /* NULL for in-buffer search */
    size_t line;    /* 1-based for search_dir; 0-based for search_piece_table */
    size_t col;     /* 0-based byte column */
    size_t len;     /* matched byte length */
    char  *preview; /* trimmed line excerpt */
} codit_search_match_t;

typedef struct {
    codit_search_match_t *items;
    size_t                count;
    size_t                cap;
} codit_search_results_t;

void codit_search_results_free(codit_search_results_t *res);

/*
 * Multi-threaded recursive directory search.
 * Skips .git, blib, node_modules, _build, .svn, .hg, and binary files.
 * Honors force_scalar (or PERL_FORCE_SCALAR=1) for exact single-threaded parity.
 * Results are deterministically sorted by (path, line, col).
 * Match line numbers are 1-based; col is 0-based.
 */
int codit_search_dir(const char *root_dir, const char *query, size_t qlen,
                     int icase, size_t max_matches, int force_scalar,
                     codit_search_results_t *out);

/*
 * Literal / case-insensitive search inside a PieceTable.
 * Match line numbers are 0-based; col is 0-based.
 */
int codit_search_piece_table(codit_piece_table_t *pt, const char *query, size_t qlen,
                             int icase, size_t max_matches,
                             codit_search_results_t *out);

#ifdef __cplusplus
}
#endif

#endif /* CODIT_SEARCH_H */
