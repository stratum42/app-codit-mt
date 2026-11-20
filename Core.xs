/*
 * Core.xs - Pure C11 Tier-1 XS core engine for App::Codit::MT::Core
 */
#include "c/mt_compat.h"
#include "c/piece_table.h"
#include "c/syntax.h"
#include "c/search.h"
#include "c/minimap.h"

#include <stdlib.h>
#include <string.h>

static SV *
wrap_pt(pTHX_ codit_piece_table_t *pt)
{
    SV *rv = newSV(0);
    sv_setref_pv(rv, "App::Codit::MT::Core::PieceTable", (void *)pt);
    return rv;
}

static codit_piece_table_t *
unwrap_pt(pTHX_ SV *sv)
{
    if (!sv || !SvROK(sv) || !sv_derived_from(sv, "App::Codit::MT::Core::PieceTable")) {
        croak("Expected App::Codit::MT::Core::PieceTable object");
    }
    IV ptr = SvIV((SV *)SvRV(sv));
    if (!ptr) {
        croak("App::Codit::MT::Core::PieceTable object has been destroyed");
    }
    return INT2PTR(codit_piece_table_t *, ptr);
}

static SV *
wrap_syn(pTHX_ codit_syntax_t *syn)
{
    SV *rv = newSV(0);
    sv_setref_pv(rv, "App::Codit::MT::Core::Syntax", (void *)syn);
    return rv;
}

static codit_syntax_t *
unwrap_syn(pTHX_ SV *sv)
{
    if (!sv || !SvROK(sv) || !sv_derived_from(sv, "App::Codit::MT::Core::Syntax")) {
        croak("Expected App::Codit::MT::Core::Syntax object");
    }
    IV ptr = SvIV((SV *)SvRV(sv));
    if (!ptr) {
        croak("App::Codit::MT::Core::Syntax object has been destroyed");
    }
    return INT2PTR(codit_syntax_t *, ptr);
}

static AV *
search_results_to_av(pTHX_ const codit_search_results_t *res, int include_path)
{
    AV *av = newAV();
    if (res->count > 0) {
        av_extend(av, (SSize_t)(res->count - 1));
    }
    for (size_t i = 0; i < res->count; i++) {
        const codit_search_match_t *m = &res->items[i];
        HV *hv = newHV();
        if (include_path && m->path) {
            (void)hv_stores(hv, "path", newSVpv(m->path, 0));
        }
        (void)hv_stores(hv, "line", newSVuv((UV)m->line));
        (void)hv_stores(hv, "col",  newSVuv((UV)m->col));
        (void)hv_stores(hv, "len",  newSVuv((UV)m->len));
        (void)hv_stores(hv, "preview", newSVpv(m->preview ? m->preview : "", 0));
        av_push(av, newRV_noinc((SV *)hv));
    }
    return av;
}

static AV *
do_tokenize_range(pTHX_ codit_piece_table_t *pt, codit_syntax_t *syn,
                  size_t first_line, size_t count)
{
    size_t total = codit_pt_line_count(pt);
    AV *outer = newAV();
    if (first_line >= total || count == 0) {
        return outer;
    }
    size_t end_line = first_line + count;
    if (end_line > total) end_line = total;

    codit_syntax_sync(pt, syn, end_line);
    codit_lang_t lang = codit_syntax_get_lang(syn);

    av_extend(outer, (SSize_t)(end_line - first_line - 1));

    char stack_buf[4096];
    codit_token_t toks[1024];

    for (size_t line = first_line; line < end_line; line++) {
        size_t llen = codit_pt_get_line_buf(pt, line, stack_buf, sizeof(stack_buf));
        char *heap_buf = NULL;
        const char *lptr = stack_buf;
        if (llen >= sizeof(stack_buf)) {
            heap_buf = codit_pt_get_line_alloc(pt, line, &llen);
            if (heap_buf) lptr = heap_buf;
        }

        uint8_t start_state = (line == 0) ? CODIT_STATE_NORMAL : codit_syntax_end_state(syn, line - 1);
        size_t ntok = 0;
        codit_syntax_lex_line(lang, lptr, llen, start_state, toks, 1024, &ntok);
        free(heap_buf);

        AV *line_av = newAV();
        if (ntok > 0) {
            av_extend(line_av, (SSize_t)(ntok * 3 - 1));
            for (size_t j = 0; j < ntok; j++) {
                av_push(line_av, newSVuv((UV)toks[j].col));
                av_push(line_av, newSVuv((UV)toks[j].len));
                av_push(line_av, newSVuv((UV)toks[j].type));
            }
        }
        av_push(outer, newRV_noinc((SV *)line_av));
    }

    return outer;
}

MODULE = App::Codit::MT::Core  PACKAGE = App::Codit::MT::Core

PROTOTYPES: DISABLE

int
is_perl5_mt()
CODE:
    RETVAL = CODIT_IS_PERL5_MT;
OUTPUT:
    RETVAL

int
have_packed_av()
CODE:
    RETVAL = CODIT_HAVE_PACKED_AV;
OUTPUT:
    RETVAL

int
force_scalar()
CODE:
    RETVAL = codit_force_scalar_env();
OUTPUT:
    RETVAL

const char *
detect_language(path)
    const char *path
CODE:
    RETVAL = codit_lang_name(codit_detect_language(path));
OUTPUT:
    RETVAL

SV *
tokenize_range(pt_sv, syn_sv, first_line, count)
    SV *pt_sv
    SV *syn_sv
    IV  first_line
    IV  count
CODE:
    codit_piece_table_t *pt  = unwrap_pt(aTHX_ pt_sv);
    codit_syntax_t      *syn = unwrap_syn(aTHX_ syn_sv);
    if (first_line < 0) first_line = 0;
    if (count < 0) count = 0;
    AV *av = do_tokenize_range(aTHX_ pt, syn, (size_t)first_line, (size_t)count);
    RETVAL = newRV_noinc((SV *)av);
OUTPUT:
    RETVAL

SV *
search_dir(root_dir, query_sv, icase = 0, max_matches = 5000)
    const char *root_dir
    SV *query_sv
    int icase
    IV  max_matches
CODE:
    STRLEN qlen = 0;
    const char *q = SvPV(query_sv, qlen);
    if (max_matches <= 0) max_matches = 5000;
    codit_search_results_t res;
    int fs = codit_force_scalar_env();
    codit_search_dir(root_dir, q, (size_t)qlen, icase ? 1 : 0, (size_t)max_matches, fs, &res);
    AV *av = search_results_to_av(aTHX_ &res, 1);
    codit_search_results_free(&res);
    RETVAL = newRV_noinc((SV *)av);
OUTPUT:
    RETVAL

SV *
minimap_render_rgba8(pt_sv, syn_sv, width, height, top_line = 0, vis_lines = 40, target_sv = &PL_sv_undef)
    SV *pt_sv
    SV *syn_sv
    IV  width
    IV  height
    IV  top_line
    IV  vis_lines
    SV *target_sv
CODE:
    codit_piece_table_t *pt = unwrap_pt(aTHX_ pt_sv);
    codit_syntax_t *syn = NULL;
    if (syn_sv && SvOK(syn_sv)) {
        syn = unwrap_syn(aTHX_ syn_sv);
    }
    if (width <= 0 || height <= 0 || width > 4096 || height > 8192) {
        croak("minimap_render_rgba8: invalid dimensions (%ld x %ld)", (long)width, (long)height);
    }
    if (top_line < 0) top_line = 0;
    if (vis_lines < 0) vis_lines = 0;

    AV *target_av = NULL;
    if (target_sv && SvROK(target_sv) && SvTYPE(SvRV(target_sv)) == SVt_PVAV) {
        target_av = (AV *)SvRV(target_sv);
    }

    size_t nbytes = (size_t)width * (size_t)height * 4u;
    uint8_t *buf = NULL;
    int is_packed = 0;
    int reused = 0;
    AV *out_av = codit_av_u8_prepare(aTHX_ target_av, nbytes, &buf, &is_packed, &reused);
    if (!out_av || !buf) {
        croak("minimap_render_rgba8: failed to allocate output buffer");
    }

    int fs = codit_force_scalar_env();
    codit_minimap_render_rgba8(pt, syn, (uint32_t)width, (uint32_t)height,
                               (size_t)top_line, (size_t)vis_lines, fs, buf);

    codit_av_u8_finish(aTHX_ out_av, buf, nbytes, is_packed);
    RETVAL = reused ? newRV_inc((SV *)out_av) : newRV_noinc((SV *)out_av);
OUTPUT:
    RETVAL


MODULE = App::Codit::MT::Core  PACKAGE = App::Codit::MT::Core::PieceTable

SV *
new(klass)
    const char *klass
CODE:
    (void)klass;
    codit_piece_table_t *pt = codit_pt_new();
    if (!pt) croak("App::Codit::MT::Core::PieceTable::new: out of memory");
    RETVAL = wrap_pt(aTHX_ pt);
OUTPUT:
    RETVAL

SV *
open_file(klass, path)
    const char *klass
    const char *path
CODE:
    (void)klass;
    char err[256];
    err[0] = '\0';
    codit_piece_table_t *pt = codit_pt_open_file(path, err, sizeof(err));
    if (!pt) {
        croak("App::Codit::MT::Core::PieceTable::open_file('%s'): %s", path, err);
    }
    RETVAL = wrap_pt(aTHX_ pt);
OUTPUT:
    RETVAL

SV *
from_string(klass, str_sv)
    const char *klass
    SV *str_sv
CODE:
    (void)klass;
    STRLEN len = 0;
    const char *s = SvOK(str_sv) ? SvPV(str_sv, len) : "";
    codit_piece_table_t *pt = codit_pt_from_string(s, (size_t)len);
    if (!pt) croak("App::Codit::MT::Core::PieceTable::from_string: out of memory");
    RETVAL = wrap_pt(aTHX_ pt);
OUTPUT:
    RETVAL

void
DESTROY(self)
    SV *self
CODE:
    if (self && SvROK(self)) {
        IV ptr = SvIV((SV *)SvRV(self));
        if (ptr) {
            codit_pt_free(INT2PTR(codit_piece_table_t *, ptr));
            sv_setiv((SV *)SvRV(self), 0);
        }
    }

int
insert(self, offset, text_sv)
    SV *self
    IV  offset
    SV *text_sv
CODE:
    codit_piece_table_t *pt = unwrap_pt(aTHX_ self);
    if (offset < 0) offset = 0;
    STRLEN len = 0;
    const char *s = SvOK(text_sv) ? SvPV(text_sv, len) : "";
    RETVAL = codit_pt_insert(pt, (size_t)offset, s, (size_t)len);
OUTPUT:
    RETVAL

int
delete(self, offset, len)
    SV *self
    IV  offset
    IV  len
CODE:
    codit_piece_table_t *pt = unwrap_pt(aTHX_ self);
    if (offset < 0) offset = 0;
    if (len < 0) len = 0;
    RETVAL = codit_pt_delete(pt, (size_t)offset, (size_t)len);
OUTPUT:
    RETVAL

int
undo(self)
    SV *self
CODE:
    codit_piece_table_t *pt = unwrap_pt(aTHX_ self);
    RETVAL = codit_pt_undo(pt);
OUTPUT:
    RETVAL

int
redo(self)
    SV *self
CODE:
    codit_piece_table_t *pt = unwrap_pt(aTHX_ self);
    RETVAL = codit_pt_redo(pt);
OUTPUT:
    RETVAL

int
can_undo(self)
    SV *self
CODE:
    codit_piece_table_t *pt = unwrap_pt(aTHX_ self);
    RETVAL = codit_pt_can_undo(pt);
OUTPUT:
    RETVAL

int
can_redo(self)
    SV *self
CODE:
    codit_piece_table_t *pt = unwrap_pt(aTHX_ self);
    RETVAL = codit_pt_can_redo(pt);
OUTPUT:
    RETVAL

UV
line_count(self)
    SV *self
CODE:
    codit_piece_table_t *pt = unwrap_pt(aTHX_ self);
    RETVAL = (UV)codit_pt_line_count(pt);
OUTPUT:
    RETVAL

UV
byte_length(self)
    SV *self
CODE:
    codit_piece_table_t *pt = unwrap_pt(aTHX_ self);
    RETVAL = (UV)codit_pt_byte_length(pt);
OUTPUT:
    RETVAL

UV
revision(self)
    SV *self
CODE:
    codit_piece_table_t *pt = unwrap_pt(aTHX_ self);
    RETVAL = (UV)codit_pt_revision(pt);
OUTPUT:
    RETVAL

SV *
get_line(self, line)
    SV *self
    IV  line
CODE:
    codit_piece_table_t *pt = unwrap_pt(aTHX_ self);
    if (line < 0 || (size_t)line >= codit_pt_line_count(pt)) {
        RETVAL = &PL_sv_undef;
    } else {
        size_t len = 0;
        char *buf = codit_pt_get_line_alloc(pt, (size_t)line, &len);
        if (!buf) {
            RETVAL = &PL_sv_undef;
        } else {
            RETVAL = newSVpvn(buf, (STRLEN)len);
            free(buf);
        }
    }
OUTPUT:
    RETVAL

SV *
get_lines(self, start_line, count)
    SV *self
    IV  start_line
    IV  count
CODE:
    codit_piece_table_t *pt = unwrap_pt(aTHX_ self);
    AV *av = newAV();
    size_t total = codit_pt_line_count(pt);
    if (start_line < 0) start_line = 0;
    if (count > 0 && (size_t)start_line < total) {
        size_t end_line = (size_t)start_line + (size_t)count;
        if (end_line > total) end_line = total;
        av_extend(av, (SSize_t)(end_line - (size_t)start_line - 1));
        char stack_buf[4096];
        for (size_t i = (size_t)start_line; i < end_line; i++) {
            size_t llen = codit_pt_get_line_buf(pt, i, stack_buf, sizeof(stack_buf));
            if (llen < sizeof(stack_buf)) {
                av_push(av, newSVpvn(stack_buf, (STRLEN)llen));
            } else {
                size_t alloc_len = 0;
                char *buf = codit_pt_get_line_alloc(pt, i, &alloc_len);
                av_push(av, buf ? newSVpvn(buf, (STRLEN)alloc_len) : newSVpvn("", 0));
                free(buf);
            }
        }
    }
    RETVAL = newRV_noinc((SV *)av);
OUTPUT:
    RETVAL

UV
line_col_to_offset(self, line, col)
    SV *self
    IV  line
    IV  col
CODE:
    codit_piece_table_t *pt = unwrap_pt(aTHX_ self);
    if (line < 0) line = 0;
    if (col < 0)  col  = 0;
    RETVAL = (UV)codit_pt_line_col_to_offset(pt, (size_t)line, (size_t)col);
OUTPUT:
    RETVAL

void
offset_to_line_col(self, offset)
    SV *self
    IV  offset
PPCODE:
    codit_piece_table_t *pt = unwrap_pt(aTHX_ self);
    if (offset < 0) offset = 0;
    size_t line = 0, col = 0;
    codit_pt_offset_to_line_col(pt, (size_t)offset, &line, &col);
    if (GIMME_V == G_ARRAY) {
        EXTEND(SP, 2);
        mPUSHu((UV)line);
        mPUSHu((UV)col);
    } else {
        AV *pair = newAV();
        av_extend(pair, 1);
        av_push(pair, newSVuv((UV)line));
        av_push(pair, newSVuv((UV)col));
        EXTEND(SP, 1);
        mPUSHs(newRV_noinc((SV *)pair));
    }

int
save_file(self, path)
    SV *self
    const char *path
CODE:
    codit_piece_table_t *pt = unwrap_pt(aTHX_ self);
    char err[256];
    err[0] = '\0';
    if (!codit_pt_save_file(pt, path, err, sizeof(err))) {
        croak("App::Codit::MT::Core::PieceTable::save_file('%s'): %s", path, err);
    }
    RETVAL = 1;
OUTPUT:
    RETVAL

SV *
to_string(self)
    SV *self
CODE:
    codit_piece_table_t *pt = unwrap_pt(aTHX_ self);
    size_t len = 0;
    char *buf = codit_pt_to_string(pt, &len);
    if (!buf) croak("App::Codit::MT::Core::PieceTable::to_string: out of memory");
    RETVAL = newSVpvn(buf, (STRLEN)len);
    free(buf);
OUTPUT:
    RETVAL

SV *
search(self, query_sv, icase = 0, max_matches = 10000)
    SV *self
    SV *query_sv
    int icase
    IV  max_matches
CODE:
    codit_piece_table_t *pt = unwrap_pt(aTHX_ self);
    STRLEN qlen = 0;
    const char *q = SvPV(query_sv, qlen);
    if (max_matches <= 0) max_matches = 10000;
    codit_search_results_t res;
    codit_search_piece_table(pt, q, (size_t)qlen, icase ? 1 : 0, (size_t)max_matches, &res);
    AV *av = search_results_to_av(aTHX_ &res, 0);
    codit_search_results_free(&res);
    RETVAL = newRV_noinc((SV *)av);
OUTPUT:
    RETVAL


MODULE = App::Codit::MT::Core  PACKAGE = App::Codit::MT::Core::Syntax

SV *
new(klass, lang_name = "text")
    const char *klass
    const char *lang_name
CODE:
    (void)klass;
    codit_syntax_t *syn = codit_syntax_new(codit_lang_from_name(lang_name));
    if (!syn) croak("App::Codit::MT::Core::Syntax::new: out of memory");
    RETVAL = wrap_syn(aTHX_ syn);
OUTPUT:
    RETVAL

void
DESTROY(self)
    SV *self
CODE:
    if (self && SvROK(self)) {
        IV ptr = SvIV((SV *)SvRV(self));
        if (ptr) {
            codit_syntax_free(INT2PTR(codit_syntax_t *, ptr));
            sv_setiv((SV *)SvRV(self), 0);
        }
    }

const char *
language(self)
    SV *self
CODE:
    codit_syntax_t *syn = unwrap_syn(aTHX_ self);
    RETVAL = codit_lang_name(codit_syntax_get_lang(syn));
OUTPUT:
    RETVAL

void
set_language(self, lang_name)
    SV *self
    const char *lang_name
CODE:
    codit_syntax_t *syn = unwrap_syn(aTHX_ self);
    codit_syntax_set_lang(syn, codit_lang_from_name(lang_name));

void
invalidate(self, from_line, line_delta = 0)
    SV *self
    IV  from_line
    IV  line_delta
CODE:
    codit_syntax_t *syn = unwrap_syn(aTHX_ self);
    if (from_line < 0) from_line = 0;
    codit_syntax_invalidate(syn, (size_t)from_line, (int64_t)line_delta);

SV *
tokenize_range(self, pt_sv, first_line, count)
    SV *self
    SV *pt_sv
    IV  first_line
    IV  count
CODE:
    codit_syntax_t      *syn = unwrap_syn(aTHX_ self);
    codit_piece_table_t *pt  = unwrap_pt(aTHX_ pt_sv);
    if (first_line < 0) first_line = 0;
    if (count < 0) count = 0;
    AV *av = do_tokenize_range(aTHX_ pt, syn, (size_t)first_line, (size_t)count);
    RETVAL = newRV_noinc((SV *)av);
OUTPUT:
    RETVAL

UV
end_state(self, line)
    SV *self
    IV  line
CODE:
    codit_syntax_t *syn = unwrap_syn(aTHX_ self);
    if (line < 0) line = 0;
    RETVAL = (UV)codit_syntax_end_state(syn, (size_t)line);
OUTPUT:
    RETVAL

UV
last_relex_lines(self)
    SV *self
CODE:
    codit_syntax_t *syn = unwrap_syn(aTHX_ self);
    RETVAL = (UV)codit_syntax_last_relex_lines(syn);
OUTPUT:
    RETVAL
