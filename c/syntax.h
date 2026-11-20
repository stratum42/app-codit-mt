/*
 * c/syntax.h - Incremental per-line syntax lexer for App::Codit::MT::Core
 */
#ifndef CODIT_SYNTAX_H
#define CODIT_SYNTAX_H

#include "piece_table.h"
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Supported language identifiers */
typedef enum {
    CODIT_LANG_TEXT     = 0,
    CODIT_LANG_PERL     = 1,
    CODIT_LANG_C        = 2,
    CODIT_LANG_TCL      = 3,
    CODIT_LANG_PYTHON   = 4,
    CODIT_LANG_JSON     = 5,
    CODIT_LANG_SHELL    = 6,
    CODIT_LANG_MARKDOWN = 7
} codit_lang_t;

/* Token type codes */
enum {
    CODIT_TOK_NORMAL   = 0,
    CODIT_TOK_KEYWORD  = 1,
    CODIT_TOK_STRING   = 2,
    CODIT_TOK_COMMENT  = 3,
    CODIT_TOK_NUMBER   = 4,
    CODIT_TOK_VAR      = 5,
    CODIT_TOK_FUNC     = 6,
    CODIT_TOK_TYPE     = 7,
    CODIT_TOK_OPERATOR = 8,
    CODIT_TOK_PREPROC  = 9
};

/* Compact per-line end-of-line lexer state */
enum {
    CODIT_STATE_NORMAL        = 0,
    CODIT_STATE_BLOCK_COMMENT = 1,
    CODIT_STATE_PERL_POD      = 2,
    CODIT_STATE_PY_TRIPLE_DQ  = 3,
    CODIT_STATE_PY_TRIPLE_SQ  = 4,
    CODIT_STATE_MD_FENCE      = 5
};

typedef struct {
    uint32_t col;
    uint32_t len;
    uint8_t  type;
} codit_token_t;

typedef struct codit_syntax codit_syntax_t;

/* Language helpers */
codit_lang_t codit_lang_from_name(const char *name);
const char  *codit_lang_name(codit_lang_t lang);
codit_lang_t codit_detect_language(const char *path);

/* Syntax state lifecycle */
codit_syntax_t *codit_syntax_new(codit_lang_t lang);
void            codit_syntax_free(codit_syntax_t *syn);
codit_lang_t    codit_syntax_get_lang(const codit_syntax_t *syn);
void            codit_syntax_set_lang(codit_syntax_t *syn, codit_lang_t lang);

/*
 * Notify incremental lexer that an edit occurred starting at `from_line`,
 * adding or removing `line_delta` lines.
 */
void codit_syntax_invalidate(codit_syntax_t *syn, size_t from_line, int64_t line_delta);

/*
 * Ensure per-line end_states are valid through `up_to_line` (exclusive).
 * Re-lexes incrementally from dirty_from until state stabilizes.
 */
void codit_syntax_sync(codit_piece_table_t *pt, codit_syntax_t *syn, size_t up_to_line);

/* Query cached end state for 0-based line (0 if not yet computed) */
uint8_t codit_syntax_end_state(const codit_syntax_t *syn, size_t line);

/* Diagnostic: number of lines re-lexed in the most recent codit_syntax_sync */
size_t codit_syntax_last_relex_lines(const codit_syntax_t *syn);

/*
 * Lex a single line with given `start_state`, emitting token runs into
 * `out_tokens` (may be NULL to compute end_state only).
 * Returns the end_state for the line.
 */
uint8_t codit_syntax_lex_line(codit_lang_t lang, const char *line, size_t len,
                              uint8_t start_state,
                              codit_token_t *out_tokens, size_t max_tokens,
                              size_t *out_count);

#ifdef __cplusplus
}
#endif

#endif /* CODIT_SYNTAX_H */
