/*
 * c/minimap.c - Syntax-colored pixel-density minimap RGBA8888 renderer
 */
#include "minimap.h"
#include "tkmt_thread.h"

#include <stdlib.h>
#include <string.h>

/* Tokyo-Night / One-Dark inspired RGBA palette */
typedef struct {
    uint8_t r, g, b;
} rgb_t;

static const rgb_t BG_COLOR = { 15, 17, 26 }; /* #0f111a */

static const rgb_t TOK_PALETTE[10] = {
    { 192, 202, 245 }, /* 0 NORMAL   #c0caf5 */
    { 187, 154, 247 }, /* 1 KEYWORD  #bb9af7 */
    { 158, 206, 106 }, /* 2 STRING   #9ece6a */
    {  86,  95, 137 }, /* 3 COMMENT  #565f89 */
    { 255, 158, 100 }, /* 4 NUMBER   #ff9e64 */
    { 224, 175, 104 }, /* 5 VAR      #e0af68 */
    { 122, 162, 247 }, /* 6 FUNC     #7aa2f7 */
    {  42, 195, 222 }, /* 7 TYPE     #2ac3de */
    { 137, 221, 255 }, /* 8 OPERATOR #89ddff */
    { 247, 118, 142 }  /* 9 PREPROC  #f7768e */
};

static inline uint8_t
blend_u8(uint8_t bg, uint8_t fg, uint8_t alpha)
{
    uint32_t inv = 255u - (uint32_t)alpha;
    return (uint8_t)(((uint32_t)fg * (uint32_t)alpha + (uint32_t)bg * inv + 127u) / 255u);
}

typedef struct {
    codit_piece_table_t *pt;
    codit_syntax_t      *syn;
    codit_lang_t         lang;
    size_t               total_lines;
    double               lines_per_row;
    uint32_t             width;
    uint32_t             height;
    uint32_t             vp_y0;
    uint32_t             vp_y1;
    uint8_t             *rgba;
} minimap_ctx_t;

typedef struct {
    const minimap_ctx_t *ctx;
    uint32_t             y_start;
    uint32_t             y_end;
} minimap_stripe_t;

static void
render_rows(const minimap_ctx_t *ctx, uint32_t y_start, uint32_t y_end)
{
    const uint32_t w = ctx->width;
    char line_buf[512];
    codit_token_t toks[256];

    for (uint32_t y = y_start; y < y_end; y++) {
        uint8_t *row = ctx->rgba + (size_t)y * (size_t)w * 4u;

        /* Fill row background */
        for (uint32_t x = 0; x < w; x++) {
            row[x * 4u + 0u] = BG_COLOR.r;
            row[x * 4u + 1u] = BG_COLOR.g;
            row[x * 4u + 2u] = BG_COLOR.b;
            row[x * 4u + 3u] = 255u;
        }

        size_t line = (size_t)((double)y * ctx->lines_per_row);
        if (line < ctx->total_lines) {
            size_t full_len = codit_pt_get_line_buf(ctx->pt, line, line_buf, sizeof(line_buf));
            size_t scan_len = (full_len < sizeof(line_buf) - 1) ? full_len : (sizeof(line_buf) - 1);
            if (scan_len > 0) {
                uint8_t start_state = (line > 0 && ctx->syn)
                    ? codit_syntax_end_state(ctx->syn, line - 1)
                    : CODIT_STATE_NORMAL;
                size_t ntok = 0;
                codit_syntax_lex_line(ctx->lang, line_buf, scan_len, start_state,
                                      toks, 256, &ntok);

                /* Plot non-whitespace characters mapped to pixel columns */
                uint32_t vcol = 0;
                size_t ti = 0;
                for (size_t ci = 0; ci < scan_len && vcol < w; ci++) {
                    char ch = line_buf[ci];
                    if (ch == '\t') {
                        vcol = (vcol + 4u) & ~3u;
                        continue;
                    }
                    if (ch == ' ') {
                        vcol++;
                        continue;
                    }
                    while (ti < ntok && (size_t)toks[ti].col + (size_t)toks[ti].len <= ci) {
                        ti++;
                    }
                    uint8_t ttype = CODIT_TOK_NORMAL;
                    if (ti < ntok && ci >= toks[ti].col && ci < (size_t)toks[ti].col + toks[ti].len) {
                        ttype = toks[ti].type;
                        if (ttype >= 10) ttype = CODIT_TOK_NORMAL;
                    }
                    rgb_t c = TOK_PALETTE[ttype];
                    uint8_t alpha = (ttype == CODIT_TOK_COMMENT) ? 130u : 180u;
                    row[vcol * 4u + 0u] = blend_u8(row[vcol * 4u + 0u], c.r, alpha);
                    row[vcol * 4u + 1u] = blend_u8(row[vcol * 4u + 1u], c.g, alpha);
                    row[vcol * 4u + 2u] = blend_u8(row[vcol * 4u + 2u], c.b, alpha);
                    vcol++;
                }
            }
        }

        /* Viewport highlight band overlay */
        if (y >= ctx->vp_y0 && y < ctx->vp_y1) {
            uint8_t is_border = (y == ctx->vp_y0 || y + 1u == ctx->vp_y1) ? 1u : 0u;
            uint8_t alpha = is_border ? 115u : 44u;
            const uint8_t vr = 88u, vg = 166u, vb = 255u; /* #58a6ff */
            for (uint32_t x = 0; x < w; x++) {
                row[x * 4u + 0u] = blend_u8(row[x * 4u + 0u], vr, alpha);
                row[x * 4u + 1u] = blend_u8(row[x * 4u + 1u], vg, alpha);
                row[x * 4u + 2u] = blend_u8(row[x * 4u + 2u], vb, alpha);
            }
        }
    }
}

static tkmt_thread_ret_t TKMT_THREAD_CALL
minimap_worker_fn(void *arg)
{
    minimap_stripe_t *s = (minimap_stripe_t *)arg;
    render_rows(s->ctx, s->y_start, s->y_end);
    TKMT_THREAD_RETURN_ZERO;
}

int
codit_minimap_render_rgba8(codit_piece_table_t *pt,
                           codit_syntax_t *syn,
                           uint32_t width,
                           uint32_t height,
                           size_t top_line,
                           size_t vis_lines,
                           int force_scalar,
                           uint8_t *rgba_out)
{
    if (!pt || !rgba_out || width == 0 || height == 0) return 0;

    /* Ensure line index and syntax states are materialized on main thread */
    size_t total_lines = codit_pt_line_count(pt);
    if (syn && total_lines > 0) {
        size_t sync_n = (total_lines <= 65536) ? total_lines : (top_line + vis_lines + 2048);
        if (sync_n > total_lines) sync_n = total_lines;
        codit_syntax_sync(pt, syn, sync_n);
    }

    double lines_per_row = (total_lines > (size_t)height)
        ? ((double)total_lines / (double)height)
        : 1.0;

    uint32_t vp_y0 = 0;
    uint32_t vp_y1 = 0;
    if (total_lines > 0 && vis_lines > 0) {
        double y0_d = (double)top_line / lines_per_row;
        double y1_d = (double)(top_line + vis_lines) / lines_per_row;
        if (y0_d < 0.0) y0_d = 0.0;
        if (y0_d > (double)height) y0_d = (double)height;
        if (y1_d < y0_d + 4.0) y1_d = y0_d + 4.0;
        if (y1_d > (double)height) y1_d = (double)height;
        vp_y0 = (uint32_t)y0_d;
        vp_y1 = (uint32_t)y1_d;
    }

    minimap_ctx_t ctx;
    ctx.pt            = pt;
    ctx.syn           = syn;
    ctx.lang          = syn ? codit_syntax_get_lang(syn) : CODIT_LANG_TEXT;
    ctx.total_lines   = total_lines;
    ctx.lines_per_row = lines_per_row;
    ctx.width         = width;
    ctx.height        = height;
    ctx.vp_y0         = vp_y0;
    ctx.vp_y1         = vp_y1;
    ctx.rgba          = rgba_out;

    int nthreads = 1;
    if (!force_scalar && height >= 128 && total_lines > 0) {
        int cpus = tkmt_cpu_count();
        if (cpus > 4) cpus = 4;
        if (cpus > 1) nthreads = cpus;
    }

    if (nthreads <= 1) {
        render_rows(&ctx, 0, height);
        return 1;
    }

    tkmt_thread_t threads[4];
    minimap_stripe_t stripes[4];
    uint32_t chunk = (height + (uint32_t)nthreads - 1u) / (uint32_t)nthreads;
    int spawned = 0;

    for (int t = 0; t < nthreads; t++) {
        uint32_t y0 = (uint32_t)t * chunk;
        uint32_t y1 = y0 + chunk;
        if (y0 >= height) break;
        if (y1 > height) y1 = height;
        stripes[t].ctx     = &ctx;
        stripes[t].y_start = y0;
        stripes[t].y_end   = y1;

        if (t == nthreads - 1 || y1 == height) {
            render_rows(&ctx, y0, y1);
        } else {
            if (tkmt_thread_create(&threads[spawned], minimap_worker_fn, &stripes[t]) == 0) {
                spawned++;
            } else {
                render_rows(&ctx, y0, y1);
            }
        }
    }

    for (int t = 0; t < spawned; t++) {
        tkmt_thread_join(threads[t]);
    }

    return 1;
}
