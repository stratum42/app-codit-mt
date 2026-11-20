/*
 * c/piece_table.h - Zero-copy mmap piece table with fast line index and undo/redo
 */
#ifndef CODIT_PIECE_TABLE_H
#define CODIT_PIECE_TABLE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct codit_piece_table codit_piece_table_t;

/* Lifecycle */
codit_piece_table_t *codit_pt_new(void);
codit_piece_table_t *codit_pt_open_file(const char *path, char *errbuf, size_t errsz);
codit_piece_table_t *codit_pt_from_string(const char *data, size_t len);
void                 codit_pt_free(codit_piece_table_t *pt);

/* Mutations (0-based byte offsets) */
int codit_pt_insert(codit_piece_table_t *pt, size_t offset, const char *data, size_t len);
int codit_pt_delete(codit_piece_table_t *pt, size_t offset, size_t len);

/* Undo / Redo (returns 1 if an edit was undone/redone, 0 if stack empty, -1 on error) */
int codit_pt_undo(codit_piece_table_t *pt);
int codit_pt_redo(codit_piece_table_t *pt);
int codit_pt_can_undo(const codit_piece_table_t *pt);
int codit_pt_can_redo(const codit_piece_table_t *pt);

/* Queries (0-based line indices and byte offsets) */
size_t codit_pt_line_count(codit_piece_table_t *pt);
size_t codit_pt_byte_length(const codit_piece_table_t *pt);

/*
 * Copy bytes in [offset, offset + len) into dst (must be at least len bytes).
 * Returns actual number of bytes copied.
 */
size_t codit_pt_copy_range(const codit_piece_table_t *pt, size_t offset, size_t len, char *dst);

/*
 * Return byte start and byte length (excluding trailing \n and optional \r)
 * for 0-based line index `line`. Returns 1 on valid line, 0 if out of range.
 */
int codit_pt_line_bounds(codit_piece_table_t *pt, size_t line,
                         size_t *out_start, size_t *out_len);

/*
 * Fetch 0-based line text (without trailing \n or \r\n) into caller buffer or
 * newly malloc'd NUL-terminated buffer.
 * Returns malloc'd string (caller must free) and sets *out_len, or NULL if OOB/OOM.
 */
char *codit_pt_get_line_alloc(codit_piece_table_t *pt, size_t line, size_t *out_len);

/*
 * Fetch 0-based line text into caller-provided buffer (up to buf_cap bytes,
 * NUL-terminated if buf_cap > 0). Returns full line byte length (may exceed buf_cap-1).
 */
size_t codit_pt_get_line_buf(codit_piece_table_t *pt, size_t line,
                             char *buf, size_t buf_cap);

/* Coordinate conversion (0-based line, 0-based byte column within line) */
size_t codit_pt_line_col_to_offset(codit_piece_table_t *pt, size_t line, size_t col);
void   codit_pt_offset_to_line_col(codit_piece_table_t *pt, size_t offset,
                                   size_t *out_line, size_t *out_col);

/* Serialization */
int   codit_pt_save_file(const codit_piece_table_t *pt, const char *path,
                         char *errbuf, size_t errsz);
char *codit_pt_to_string(const codit_piece_table_t *pt, size_t *out_len);

/* Revision counter incremented on every mutation (insert/delete/undo/redo) */
uint64_t codit_pt_revision(const codit_piece_table_t *pt);

#ifdef __cplusplus
}
#endif

#endif /* CODIT_PIECE_TABLE_H */
