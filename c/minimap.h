/*
 * c/minimap.h - Syntax-colored pixel-density minimap RGBA8888 renderer
 */
#ifndef CODIT_MINIMAP_H
#define CODIT_MINIMAP_H

#include "piece_table.h"
#include "syntax.h"
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/*
 * Render a syntax-colored pixel-density minimap of (pt, syn) into `rgba_out`
 * (must be at least width * height * 4 bytes, packed RGBA8888).
 *
 * Highlights the visible viewport band [top_line, top_line + vis_lines).
 * Honors `force_scalar` (exact bit-identical output vs multi-threaded stripes).
 * Returns 1 on success, 0 on invalid arguments.
 */
int codit_minimap_render_rgba8(codit_piece_table_t *pt,
                               codit_syntax_t *syn,
                               uint32_t width,
                               uint32_t height,
                               size_t top_line,
                               size_t vis_lines,
                               int force_scalar,
                               uint8_t *rgba_out);

#ifdef __cplusplus
}
#endif

#endif /* CODIT_MINIMAP_H */
