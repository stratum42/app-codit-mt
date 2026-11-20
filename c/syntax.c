/*
 * c/syntax.c - Fast incremental per-line syntax lexer
 */
#include "syntax.h"

#include <ctype.h>
#include <stdlib.h>
#include <string.h>

struct codit_syntax {
    codit_lang_t lang;
    uint8_t     *end_states;
    size_t       state_cap;
    size_t       valid_count;
    size_t       dirty_from;
    size_t       dirty_min_end;
    size_t       last_relex_lines;
};

/* ---- Language detection & naming ---- */

static int
ascii_strcasecmp(const char *a, const char *b)
{
    while (*a && *b) {
        int ca = tolower((unsigned char)*a++);
        int cb = tolower((unsigned char)*b++);
        if (ca != cb) return ca - cb;
    }
    return tolower((unsigned char)*a) - tolower((unsigned char)*b);
}

codit_lang_t
codit_lang_from_name(const char *name)
{
    if (!name || !name[0]) return CODIT_LANG_TEXT;
    if (ascii_strcasecmp(name, "perl") == 0 || ascii_strcasecmp(name, "pl") == 0 ||
        ascii_strcasecmp(name, "pm") == 0)
        return CODIT_LANG_PERL;
    if (ascii_strcasecmp(name, "c") == 0 || ascii_strcasecmp(name, "h") == 0 ||
        ascii_strcasecmp(name, "xs") == 0 || ascii_strcasecmp(name, "cpp") == 0 ||
        ascii_strcasecmp(name, "c++") == 0)
        return CODIT_LANG_C;
    if (ascii_strcasecmp(name, "tcl") == 0 || ascii_strcasecmp(name, "tk") == 0)
        return CODIT_LANG_TCL;
    if (ascii_strcasecmp(name, "python") == 0 || ascii_strcasecmp(name, "py") == 0)
        return CODIT_LANG_PYTHON;
    if (ascii_strcasecmp(name, "json") == 0)
        return CODIT_LANG_JSON;
    if (ascii_strcasecmp(name, "shell") == 0 || ascii_strcasecmp(name, "sh") == 0 ||
        ascii_strcasecmp(name, "bash") == 0 || ascii_strcasecmp(name, "zsh") == 0)
        return CODIT_LANG_SHELL;
    if (ascii_strcasecmp(name, "markdown") == 0 || ascii_strcasecmp(name, "md") == 0)
        return CODIT_LANG_MARKDOWN;
    return CODIT_LANG_TEXT;
}

const char *
codit_lang_name(codit_lang_t lang)
{
    switch (lang) {
    case CODIT_LANG_PERL:     return "perl";
    case CODIT_LANG_C:        return "c";
    case CODIT_LANG_TCL:      return "tcl";
    case CODIT_LANG_PYTHON:   return "python";
    case CODIT_LANG_JSON:     return "json";
    case CODIT_LANG_SHELL:    return "shell";
    case CODIT_LANG_MARKDOWN: return "markdown";
    default:                  return "text";
    }
}

codit_lang_t
codit_detect_language(const char *path)
{
    if (!path || !path[0]) return CODIT_LANG_TEXT;

    /* Find basename */
    const char *base = path;
    for (const char *p = path; *p; p++) {
        if (*p == '/' || *p == '\\') base = p + 1;
    }

    if (ascii_strcasecmp(base, "Makefile") == 0 ||
        ascii_strcasecmp(base, "GNUmakefile") == 0) {
        return CODIT_LANG_SHELL;
    }
    if (ascii_strcasecmp(base, "Makefile.PL") == 0 ||
        ascii_strcasecmp(base, "Build.PL") == 0 ||
        ascii_strcasecmp(base, "cpanfile") == 0) {
        return CODIT_LANG_PERL;
    }

    const char *dot = strrchr(base, '.');
    if (!dot || dot == base) return CODIT_LANG_TEXT;
    const char *ext = dot + 1;

    if (ascii_strcasecmp(ext, "pl") == 0 || ascii_strcasecmp(ext, "pm") == 0 ||
        ascii_strcasecmp(ext, "t") == 0  || ascii_strcasecmp(ext, "pod") == 0 ||
        ascii_strcasecmp(ext, "psgi") == 0 || ascii_strcasecmp(ext, "cgi") == 0)
        return CODIT_LANG_PERL;

    if (ascii_strcasecmp(ext, "c") == 0  || ascii_strcasecmp(ext, "h") == 0 ||
        ascii_strcasecmp(ext, "xs") == 0 || ascii_strcasecmp(ext, "m") == 0 ||
        ascii_strcasecmp(ext, "cc") == 0 || ascii_strcasecmp(ext, "cpp") == 0 ||
        ascii_strcasecmp(ext, "hpp") == 0 || ascii_strcasecmp(ext, "metal") == 0)
        return CODIT_LANG_C;

    if (ascii_strcasecmp(ext, "tcl") == 0 || ascii_strcasecmp(ext, "tk") == 0 ||
        ascii_strcasecmp(ext, "itcl") == 0)
        return CODIT_LANG_TCL;

    if (ascii_strcasecmp(ext, "py") == 0 || ascii_strcasecmp(ext, "pyw") == 0 ||
        ascii_strcasecmp(ext, "pyi") == 0)
        return CODIT_LANG_PYTHON;

    if (ascii_strcasecmp(ext, "json") == 0 || ascii_strcasecmp(ext, "jsonl") == 0)
        return CODIT_LANG_JSON;

    if (ascii_strcasecmp(ext, "sh") == 0 || ascii_strcasecmp(ext, "bash") == 0 ||
        ascii_strcasecmp(ext, "zsh") == 0 || ascii_strcasecmp(ext, "ksh") == 0 ||
        ascii_strcasecmp(ext, "mk") == 0)
        return CODIT_LANG_SHELL;

    if (ascii_strcasecmp(ext, "md") == 0 || ascii_strcasecmp(ext, "markdown") == 0 ||
        ascii_strcasecmp(ext, "mkd") == 0)
        return CODIT_LANG_MARKDOWN;

    return CODIT_LANG_TEXT;
}

/* ---- Keyword tables ---- */

static int
word_in_list(const char *w, size_t len, const char *const *list)
{
    for (size_t i = 0; list[i] != NULL; i++) {
        if (strlen(list[i]) == len && memcmp(w, list[i], len) == 0) {
            return 1;
        }
    }
    return 0;
}

static const char *const KW_PERL[] = {
    "my", "our", "local", "state", "sub", "package", "use", "require", "no",
    "if", "elsif", "else", "unless", "while", "until", "for", "foreach", "do",
    "next", "last", "redo", "return", "die", "warn", "eval", "try", "catch",
    "given", "when", "default", "bless", "BEGIN", "END", "INIT", "CHECK",
    "and", "or", "not", "xor", "eq", "ne", "lt", "gt", "le", "ge", "cmp",
    "defined", "undef", "exists", "delete", "scalar", "ref", "wantarray",
    "shift", "unshift", "push", "pop", "splice", "keys", "values", "each",
    "map", "grep", "sort", "join", "split", "print", "say", "printf", "sprintf",
    "open", "close", "read", "write", "chomp", "chop", "length", "substr",
    "index", "rindex", "pack", "unpack", "caller", "goto", "continue",
    NULL
};

static const char *const KW_C[] = {
    "auto", "break", "case", "const", "continue", "default", "do", "else",
    "enum", "extern", "for", "goto", "if", "inline", "register", "restrict",
    "return", "sizeof", "static", "struct", "switch", "typedef", "union",
    "volatile", "while", "_Atomic", "_Bool", "_Alignas", "_Alignof",
    "_Static_assert", "NULL", "true", "false",
    NULL
};

static const char *const TYPE_C[] = {
    "void", "char", "short", "int", "long", "float", "double", "signed",
    "unsigned", "bool", "size_t", "ssize_t", "ptrdiff_t", "intptr_t",
    "uintptr_t", "int8_t", "int16_t", "int32_t", "int64_t", "uint8_t",
    "uint16_t", "uint32_t", "uint64_t", "FILE", "SV", "AV", "HV", "IV", "UV", "NV", "U8",
    NULL
};

static const char *const KW_TCL[] = {
    "proc", "set", "unset", "global", "variable", "upvar", "uplevel",
    "if", "elseif", "else", "while", "for", "foreach", "switch", "break",
    "continue", "return", "catch", "try", "finally", "throw", "error",
    "package", "namespace", "expr", "eval", "list", "lindex", "llength",
    "lappend", "lrange", "lsearch", "lsort", "dict", "array", "string",
    "regexp", "regsub", "format", "puts", "open", "close", "read", "source",
    "after", "vwait", "update", "bind", "pack", "grid", "place", "winfo", "wm",
    NULL
};

static const char *const KW_PYTHON[] = {
    "and", "as", "assert", "async", "await", "break", "class", "continue",
    "def", "del", "elif", "else", "except", "False", "finally", "for", "from",
    "global", "if", "import", "in", "is", "lambda", "None", "nonlocal", "not",
    "or", "pass", "raise", "return", "True", "try", "while", "with", "yield",
    "match", "case",
    NULL
};

static const char *const TYPE_PYTHON[] = {
    "int", "float", "str", "bytes", "bool", "list", "dict", "set", "tuple",
    "object", "type", "Exception", "ValueError", "TypeError", "KeyError",
    NULL
};

static const char *const KW_SHELL[] = {
    "if", "then", "else", "elif", "fi", "for", "in", "do", "done", "while",
    "until", "case", "esac", "function", "return", "exit", "export", "local",
    "readonly", "unset", "shift", "break", "continue", "set", "trap", "exec",
    "eval", "source", "echo", "printf", "test", "true", "false",
    NULL
};

static const char *const KW_JSON[] = {
    "true", "false", "null", NULL
};

/* ---- Token emitter with adjacent same-type coalescing ---- */

static inline void
emit_tok(codit_token_t *out, size_t max_tok, size_t *cnt,
         size_t col, size_t len, uint8_t type)
{
    if (!out || len == 0) return;
    if (*cnt > 0) {
        codit_token_t *prev = &out[*cnt - 1];
        if (prev->type == type && (size_t)prev->col + (size_t)prev->len == col) {
            prev->len += (uint32_t)len;
            return;
        }
    }
    if (*cnt < max_tok) {
        out[*cnt].col  = (uint32_t)col;
        out[*cnt].len  = (uint32_t)len;
        out[*cnt].type = type;
        (*cnt)++;
    }
}

static inline int
is_ident_start(unsigned char c)
{
    return isalpha(c) || c == '_';
}

static inline int
is_ident_cont(unsigned char c)
{
    return isalnum(c) || c == '_';
}

/* ---- Single-line lexer ---- */

uint8_t
codit_syntax_lex_line(codit_lang_t lang, const char *line, size_t len,
                      uint8_t start_state,
                      codit_token_t *out_tokens, size_t max_tokens,
                      size_t *out_count)
{
    size_t cnt = 0;
    if (out_count) *out_count = 0;
    if (!line || len == 0) {
        return start_state;
    }

    if (lang == CODIT_LANG_TEXT) {
        emit_tok(out_tokens, max_tokens, &cnt, 0, len, CODIT_TOK_NORMAL);
        if (out_count) *out_count = cnt;
        return CODIT_STATE_NORMAL;
    }

    /* Markdown */
    if (lang == CODIT_LANG_MARKDOWN) {
        size_t i = 0;
        while (i < len && (line[i] == ' ' || line[i] == '\t')) i++;
        if (i + 2 < len && line[i] == '`' && line[i + 1] == '`' && line[i + 2] == '`') {
            emit_tok(out_tokens, max_tokens, &cnt, 0, len, CODIT_TOK_PREPROC);
            if (out_count) *out_count = cnt;
            return (start_state == CODIT_STATE_MD_FENCE) ? CODIT_STATE_NORMAL : CODIT_STATE_MD_FENCE;
        }
        if (start_state == CODIT_STATE_MD_FENCE) {
            emit_tok(out_tokens, max_tokens, &cnt, 0, len, CODIT_TOK_STRING);
            if (out_count) *out_count = cnt;
            return CODIT_STATE_MD_FENCE;
        }
        if (i < len && line[i] == '#') {
            emit_tok(out_tokens, max_tokens, &cnt, 0, len, CODIT_TOK_KEYWORD);
            if (out_count) *out_count = cnt;
            return CODIT_STATE_NORMAL;
        }
        if (i < len && line[i] == '>') {
            emit_tok(out_tokens, max_tokens, &cnt, 0, len, CODIT_TOK_COMMENT);
            if (out_count) *out_count = cnt;
            return CODIT_STATE_NORMAL;
        }
        /* Inline code spans `...` */
        size_t pos = 0;
        while (pos < len) {
            if (line[pos] == '`') {
                size_t s = pos++;
                while (pos < len && line[pos] != '`') pos++;
                if (pos < len) pos++;
                emit_tok(out_tokens, max_tokens, &cnt, s, pos - s, CODIT_TOK_STRING);
            } else {
                size_t s = pos++;
                while (pos < len && line[pos] != '`') pos++;
                emit_tok(out_tokens, max_tokens, &cnt, s, pos - s, CODIT_TOK_NORMAL);
            }
        }
        if (out_count) *out_count = cnt;
        return CODIT_STATE_NORMAL;
    }

    /* Perl POD handling */
    if (lang == CODIT_LANG_PERL) {
        if (start_state == CODIT_STATE_PERL_POD) {
            emit_tok(out_tokens, max_tokens, &cnt, 0, len, CODIT_TOK_COMMENT);
            if (out_count) *out_count = cnt;
            if (len >= 4 && memcmp(line, "=cut", 4) == 0 &&
                (len == 4 || isspace((unsigned char)line[4]))) {
                return CODIT_STATE_NORMAL;
            }
            return CODIT_STATE_PERL_POD;
        }
        if (line[0] == '=' && len > 1 && isalpha((unsigned char)line[1])) {
            emit_tok(out_tokens, max_tokens, &cnt, 0, len, CODIT_TOK_COMMENT);
            if (out_count) *out_count = cnt;
            if (len >= 4 && memcmp(line, "=cut", 4) == 0 &&
                (len == 4 || isspace((unsigned char)line[4]))) {
                return CODIT_STATE_NORMAL;
            }
            return CODIT_STATE_PERL_POD;
        }
    }

    size_t i = 0;
    uint8_t state = start_state;

    /* Continue C block comment */
    if (lang == CODIT_LANG_C && state == CODIT_STATE_BLOCK_COMMENT) {
        size_t s = 0;
        while (i + 1 < len) {
            if (line[i] == '*' && line[i + 1] == '/') {
                i += 2;
                state = CODIT_STATE_NORMAL;
                break;
            }
            i++;
        }
        if (state == CODIT_STATE_BLOCK_COMMENT) {
            i = len;
        }
        emit_tok(out_tokens, max_tokens, &cnt, s, i - s, CODIT_TOK_COMMENT);
        if (i >= len) {
            if (out_count) *out_count = cnt;
            return state;
        }
    }

    /* Continue Python triple-quoted strings */
    if (lang == CODIT_LANG_PYTHON &&
        (state == CODIT_STATE_PY_TRIPLE_DQ || state == CODIT_STATE_PY_TRIPLE_SQ)) {
        char q = (state == CODIT_STATE_PY_TRIPLE_DQ) ? '"' : '\'';
        size_t s = 0;
        while (i < len) {
            if (line[i] == '\\' && i + 1 < len) {
                i += 2;
                continue;
            }
            if (i + 2 < len && line[i] == q && line[i + 1] == q && line[i + 2] == q) {
                i += 3;
                state = CODIT_STATE_NORMAL;
                break;
            }
            i++;
        }
        emit_tok(out_tokens, max_tokens, &cnt, s, i - s, CODIT_TOK_STRING);
        if (i >= len) {
            if (out_count) *out_count = cnt;
            return state;
        }
    }

    /* C preprocessor line */
    if (lang == CODIT_LANG_C && state == CODIT_STATE_NORMAL && i == 0) {
        size_t ws = 0;
        while (ws < len && (line[ws] == ' ' || line[ws] == '\t')) ws++;
        if (ws < len && line[ws] == '#') {
            emit_tok(out_tokens, max_tokens, &cnt, 0, len, CODIT_TOK_PREPROC);
            if (out_count) *out_count = cnt;
            return CODIT_STATE_NORMAL;
        }
    }

    /* Main character scan */
    while (i < len) {
        unsigned char c = (unsigned char)line[i];

        /* Whitespace */
        if (c == ' ' || c == '\t') {
            size_t s = i++;
            while (i < len && (line[i] == ' ' || line[i] == '\t')) i++;
            emit_tok(out_tokens, max_tokens, &cnt, s, i - s, CODIT_TOK_NORMAL);
            continue;
        }

        /* Comments */
        if (lang == CODIT_LANG_C) {
            if (c == '/' && i + 1 < len && line[i + 1] == '/') {
                emit_tok(out_tokens, max_tokens, &cnt, i, len - i, CODIT_TOK_COMMENT);
                i = len;
                break;
            }
            if (c == '/' && i + 1 < len && line[i + 1] == '*') {
                size_t s = i;
                i += 2;
                state = CODIT_STATE_BLOCK_COMMENT;
                while (i + 1 < len) {
                    if (line[i] == '*' && line[i + 1] == '/') {
                        i += 2;
                        state = CODIT_STATE_NORMAL;
                        break;
                    }
                    i++;
                }
                if (state == CODIT_STATE_BLOCK_COMMENT) i = len;
                emit_tok(out_tokens, max_tokens, &cnt, s, i - s, CODIT_TOK_COMMENT);
                continue;
            }
        } else if (lang == CODIT_LANG_PERL || lang == CODIT_LANG_PYTHON ||
                   lang == CODIT_LANG_TCL  || lang == CODIT_LANG_SHELL) {
            if (c == '#') {
                emit_tok(out_tokens, max_tokens, &cnt, i, len - i, CODIT_TOK_COMMENT);
                i = len;
                break;
            }
        }

        /* Python triple quotes */
        if (lang == CODIT_LANG_PYTHON && (c == '"' || c == '\'') &&
            i + 2 < len && line[i + 1] == (char)c && line[i + 2] == (char)c) {
            char q = (char)c;
            size_t s = i;
            i += 3;
            state = (q == '"') ? CODIT_STATE_PY_TRIPLE_DQ : CODIT_STATE_PY_TRIPLE_SQ;
            while (i < len) {
                if (line[i] == '\\' && i + 1 < len) {
                    i += 2;
                    continue;
                }
                if (i + 2 < len && line[i] == q && line[i + 1] == q && line[i + 2] == q) {
                    i += 3;
                    state = CODIT_STATE_NORMAL;
                    break;
                }
                i++;
            }
            emit_tok(out_tokens, max_tokens, &cnt, s, i - s, CODIT_TOK_STRING);
            continue;
        }

        /* Quoted strings */
        if (c == '"' || (c == '\'' && lang != CODIT_LANG_JSON && lang != CODIT_LANG_TCL)) {
            char q = (char)c;
            size_t s = i++;
            while (i < len) {
                if (line[i] == '\\' && i + 1 < len) {
                    i += 2;
                    continue;
                }
                if (line[i] == q) {
                    i++;
                    break;
                }
                i++;
            }
            /* JSON object key detection: string followed by optional ws and ':' */
            uint8_t ttype = CODIT_TOK_STRING;
            if (lang == CODIT_LANG_JSON) {
                size_t k = i;
                while (k < len && (line[k] == ' ' || line[k] == '\t')) k++;
                if (k < len && line[k] == ':') ttype = CODIT_TOK_VAR;
            }
            emit_tok(out_tokens, max_tokens, &cnt, s, i - s, ttype);
            continue;
        }

        /* Sigil variables ($foo, @bar, %baz in Perl; $var in Tcl/Shell) */
        if ((lang == CODIT_LANG_PERL && (c == '$' || c == '@' || c == '%')) ||
            ((lang == CODIT_LANG_TCL || lang == CODIT_LANG_SHELL) && c == '$')) {
            size_t s = i++;
            if (i < len && line[i] == '{') {
                i++;
                while (i < len && line[i] != '}') i++;
                if (i < len) i++;
            } else if (i < len && (is_ident_start((unsigned char)line[i]) ||
                                   line[i] == '_' || line[i] == '^' ||
                                   line[i] == '!' || line[i] == '?' ||
                                   isdigit((unsigned char)line[i]))) {
                i++;
                while (i < len && (is_ident_cont((unsigned char)line[i]) || line[i] == ':')) {
                    i++;
                }
            }
            emit_tok(out_tokens, max_tokens, &cnt, s, i - s, CODIT_TOK_VAR);
            continue;
        }

        /* Numbers */
        if (isdigit(c) || (c == '.' && i + 1 < len && isdigit((unsigned char)line[i + 1]))) {
            size_t s = i++;
            if (c == '0' && i < len && (line[i] == 'x' || line[i] == 'X' || line[i] == 'b' || line[i] == 'B')) {
                i++;
                while (i < len && (isxdigit((unsigned char)line[i]) || line[i] == '_')) i++;
            } else {
                while (i < len && (isdigit((unsigned char)line[i]) || line[i] == '.' ||
                                   line[i] == '_' || line[i] == 'e' || line[i] == 'E')) {
                    if ((line[i] == 'e' || line[i] == 'E') && i + 1 < len &&
                        (line[i + 1] == '+' || line[i + 1] == '-')) {
                        i += 2;
                        continue;
                    }
                    i++;
                }
            }
            while (i < len && (line[i] == 'u' || line[i] == 'U' || line[i] == 'l' ||
                               line[i] == 'L' || line[i] == 'f' || line[i] == 'F')) {
                i++;
            }
            emit_tok(out_tokens, max_tokens, &cnt, s, i - s, CODIT_TOK_NUMBER);
            continue;
        }

        /* Identifiers / keywords / types / functions */
        if (is_ident_start(c)) {
            size_t s = i++;
            while (i < len && is_ident_cont((unsigned char)line[i])) i++;
            size_t wlen = i - s;
            uint8_t ttype = CODIT_TOK_NORMAL;

            switch (lang) {
            case CODIT_LANG_PERL:
                if (word_in_list(line + s, wlen, KW_PERL)) ttype = CODIT_TOK_KEYWORD;
                break;
            case CODIT_LANG_C:
                if (word_in_list(line + s, wlen, KW_C)) ttype = CODIT_TOK_KEYWORD;
                else if (word_in_list(line + s, wlen, TYPE_C)) ttype = CODIT_TOK_TYPE;
                break;
            case CODIT_LANG_TCL:
                if (word_in_list(line + s, wlen, KW_TCL)) ttype = CODIT_TOK_KEYWORD;
                break;
            case CODIT_LANG_PYTHON:
                if (word_in_list(line + s, wlen, KW_PYTHON)) ttype = CODIT_TOK_KEYWORD;
                else if (word_in_list(line + s, wlen, TYPE_PYTHON)) ttype = CODIT_TOK_TYPE;
                break;
            case CODIT_LANG_SHELL:
                if (word_in_list(line + s, wlen, KW_SHELL)) ttype = CODIT_TOK_KEYWORD;
                break;
            case CODIT_LANG_JSON:
                if (word_in_list(line + s, wlen, KW_JSON)) ttype = CODIT_TOK_KEYWORD;
                break;
            default:
                break;
            }

            if (ttype == CODIT_TOK_NORMAL && i < len && line[i] == '(') {
                ttype = CODIT_TOK_FUNC;
            }

            emit_tok(out_tokens, max_tokens, &cnt, s, wlen, ttype);
            continue;
        }

        /* Operators & punctuation */
        if (strchr("+-*/%=<>!&|^~?:;,.()[]{}", (int)c) != NULL) {
            size_t s = i++;
            emit_tok(out_tokens, max_tokens, &cnt, s, 1, CODIT_TOK_OPERATOR);
            continue;
        }

        /* Anything else */
        emit_tok(out_tokens, max_tokens, &cnt, i, 1, CODIT_TOK_NORMAL);
        i++;
    }

    if (out_count) *out_count = cnt;
    return state;
}

/* ---- Incremental state management ---- */

static int
syn_ensure_cap(codit_syntax_t *syn, size_t need)
{
    if (need <= syn->state_cap) return 1;
    size_t ncap = syn->state_cap ? syn->state_cap * 2 : 256;
    while (ncap < need) ncap *= 2;
    uint8_t *ns = (uint8_t *)realloc(syn->end_states, ncap);
    if (!ns) return 0;
    syn->end_states = ns;
    syn->state_cap = ncap;
    return 1;
}

codit_syntax_t *
codit_syntax_new(codit_lang_t lang)
{
    codit_syntax_t *syn = (codit_syntax_t *)calloc(1, sizeof(*syn));
    if (!syn) return NULL;
    syn->lang       = lang;
    syn->dirty_from = SIZE_MAX;
    return syn;
}

void
codit_syntax_free(codit_syntax_t *syn)
{
    if (!syn) return;
    free(syn->end_states);
    free(syn);
}

codit_lang_t
codit_syntax_get_lang(const codit_syntax_t *syn)
{
    return syn ? syn->lang : CODIT_LANG_TEXT;
}

void
codit_syntax_set_lang(codit_syntax_t *syn, codit_lang_t lang)
{
    if (!syn) return;
    if (syn->lang != lang) {
        syn->lang          = lang;
        syn->valid_count   = 0;
        syn->dirty_from    = 0;
        syn->dirty_min_end = 0;
    }
}

void
codit_syntax_invalidate(codit_syntax_t *syn, size_t from_line, int64_t line_delta)
{
    if (!syn) return;

    if (line_delta > 0 && from_line < syn->valid_count) {
        size_t add = (size_t)line_delta;
        if (syn_ensure_cap(syn, syn->valid_count + add)) {
            memmove(syn->end_states + from_line + add,
                    syn->end_states + from_line,
                    syn->valid_count - from_line);
            memset(syn->end_states + from_line, 0xFF, add);
            syn->valid_count += add;
        } else {
            syn->valid_count = from_line;
        }
    } else if (line_delta < 0 && from_line < syn->valid_count) {
        size_t rem = (size_t)(-line_delta);
        if (from_line + rem >= syn->valid_count) {
            syn->valid_count = from_line;
        } else {
            memmove(syn->end_states + from_line,
                    syn->end_states + from_line + rem,
                    syn->valid_count - (from_line + rem));
            syn->valid_count -= rem;
        }
    }

    if (from_line < syn->dirty_from) {
        syn->dirty_from = from_line;
    }
    size_t min_end = from_line + (line_delta > 0 ? (size_t)line_delta + 1 : 1);
    if (min_end > syn->dirty_min_end) {
        syn->dirty_min_end = min_end;
    }
}

void
codit_syntax_sync(codit_piece_table_t *pt, codit_syntax_t *syn, size_t up_to_line)
{
    if (!pt || !syn) return;
    syn->last_relex_lines = 0;

    size_t total = codit_pt_line_count(pt);
    if (up_to_line > total) up_to_line = total;
    if (up_to_line == 0) return;

    if (!syn_ensure_cap(syn, up_to_line)) return;
    if (syn->valid_count > total) syn->valid_count = total;

    char stack_buf[4096];

    /* Re-lex dirty region until state stabilizes */
    if (syn->dirty_from < up_to_line) {
        size_t prev_valid = syn->valid_count;
        size_t line = syn->dirty_from;
        uint8_t state = (line == 0) ? CODIT_STATE_NORMAL : syn->end_states[line - 1];

        while (line < up_to_line) {
            size_t llen = codit_pt_get_line_buf(pt, line, stack_buf, sizeof(stack_buf));
            char *heap_buf = NULL;
            const char *lptr = stack_buf;
            if (llen >= sizeof(stack_buf)) {
                heap_buf = codit_pt_get_line_alloc(pt, line, &llen);
                if (heap_buf) lptr = heap_buf;
            }
            uint8_t new_state = codit_syntax_lex_line(syn->lang, lptr, llen, state, NULL, 0, NULL);
            free(heap_buf);
            syn->last_relex_lines++;

            uint8_t old_state = (line < prev_valid) ? syn->end_states[line] : 0xFF;
            syn->end_states[line] = new_state;
            state = new_state;
            line++;

            if (line >= syn->dirty_min_end && line <= prev_valid && new_state == old_state) {
                /* State converged; remaining valid lines need no re-lex */
                syn->dirty_from    = SIZE_MAX;
                syn->dirty_min_end = 0;
                break;
            }
        }

        if (line > syn->valid_count) {
            syn->valid_count = line;
        }
        if (syn->dirty_from != SIZE_MAX) {
            if (line >= up_to_line) {
                syn->dirty_from = line;
            }
        }
    }

    /* Extend valid_count up to up_to_line if needed */
    if (syn->valid_count < up_to_line) {
        size_t line = syn->valid_count;
        uint8_t state = (line == 0) ? CODIT_STATE_NORMAL : syn->end_states[line - 1];
        while (line < up_to_line) {
            size_t llen = codit_pt_get_line_buf(pt, line, stack_buf, sizeof(stack_buf));
            char *heap_buf = NULL;
            const char *lptr = stack_buf;
            if (llen >= sizeof(stack_buf)) {
                heap_buf = codit_pt_get_line_alloc(pt, line, &llen);
                if (heap_buf) lptr = heap_buf;
            }
            state = codit_syntax_lex_line(syn->lang, lptr, llen, state, NULL, 0, NULL);
            free(heap_buf);
            syn->end_states[line] = state;
            syn->last_relex_lines++;
            line++;
        }
        syn->valid_count = line;
    }
}

uint8_t
codit_syntax_end_state(const codit_syntax_t *syn, size_t line)
{
    if (!syn || line >= syn->valid_count) return CODIT_STATE_NORMAL;
    return syn->end_states[line];
}

size_t
codit_syntax_last_relex_lines(const codit_syntax_t *syn)
{
    return syn ? syn->last_relex_lines : 0;
}
