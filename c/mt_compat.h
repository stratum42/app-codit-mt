/*
 * c/mt_compat.h - perl5-mt Tier-1 XS compatibility & packed-AV zero-copy layer
 *
 * Pure C11 (no C++). Works cleanly on both perl5-mt (emitting
 * _mt_threadsafe_boot_App__Codit__MT__Core and using zero-copy SVf_PACKED_AV)
 * and stock Perl 5 (falling back gracefully to standard AV operations).
 */
#ifndef CODIT_MT_COMPAT_H
#define CODIT_MT_COMPAT_H

#ifdef __cplusplus
#  error "App::Codit::MT XS modules must be compiled as pure C11, not C++"
#endif

#ifndef PERL_NO_GET_CONTEXT
#  define PERL_NO_GET_CONTEXT
#endif

#ifndef PERL_XS_THREADSAFE
#  define PERL_XS_THREADSAFE 1
#endif

#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"

#include <stdint.h>
#include <stddef.h>
#include <stdlib.h>

/* Detect perl5-mt thread-safe XS marker support */
#ifdef PERL_MT_XS_MARKER
#  define CODIT_IS_PERL5_MT 1
#else
#  define CODIT_IS_PERL5_MT 0
#endif

/* Detect perl5-mt packed AV support (SVf_PACKED_AV / AvPACKED_TYPE / AvPACKED_DATA) */
#if defined(SVf_PACKED_AV) && defined(AvPACKED_TYPE) && defined(AvPACKED_DATA)
#  define CODIT_HAVE_PACKED_AV 1
#else
#  define CODIT_HAVE_PACKED_AV 0
#  ifndef AV_PACKED_NONE
#    define AV_PACKED_NONE 0
#    define AV_PACKED_IV   1
#    define AV_PACKED_NV   2
#    define AV_PACKED_U8   3
#  endif
#  ifndef AvPACKED_TYPE
#    define AvPACKED_TYPE(av) ((U8)AV_PACKED_NONE)
#  endif
#  ifndef AvPACKED_DATA
#    define AvPACKED_DATA(av) ((void *)NULL)
#  endif
#endif

/*
 * Allocate or reuse a U8 packed AV of length `nbytes` for zero-copy C writes.
 *
 * On perl5-mt:
 *   - If `target_av` is non-NULL, packed as AV_PACKED_U8, and has capacity >= nbytes,
 *     reuses it in place (zero allocation, zero copy).
 *   - Otherwise creates a new AV_PACKED_U8 AV via Perl_av_new_packed().
 *   - Sets *out_buf to the direct U8 backing pointer and *out_is_packed = 1.
 *   - Caller MUST call codit_av_u8_finish() after writing all `nbytes` bytes.
 *
 * On stock Perl 5:
 *   - Allocates a temporary malloc buffer of `nbytes` bytes, sets *out_is_packed = 0,
 *     and codit_av_u8_finish() populates the AV and frees the temporary buffer.
 */
static inline AV *
codit_av_u8_prepare(pTHX_ AV *target_av, size_t nbytes,
                    uint8_t **out_buf, int *out_is_packed, int *out_reused)
{
    *out_buf = NULL;
    *out_is_packed = 0;
    *out_reused = 0;

#if CODIT_HAVE_PACKED_AV
    if (target_av && AvPACKED_TYPE(target_av) == AV_PACKED_U8 &&
        !SvREADONLY(target_av) &&
        (size_t)(AvMAX(target_av) + 1) >= nbytes) {
        *out_buf = (uint8_t *)AvPACKED_DATA(target_av);
        *out_is_packed = 1;
        *out_reused = 1;
        return target_av;
    }
    {
        AV *av = Perl_av_new_packed(aTHX_ AV_PACKED_U8, (SSize_t)nbytes);
        if (!av) return NULL;
        *out_buf = (uint8_t *)AvPACKED_DATA(av);
        *out_is_packed = 1;
        *out_reused = 0;
        return av;
    }
#else
    {
        uint8_t *tmp = (uint8_t *)malloc(nbytes > 0 ? nbytes : 1);
        if (!tmp) return NULL;
        AV *av = target_av ? target_av : newAV();
        *out_buf = tmp;
        *out_is_packed = 0;
        *out_reused = (target_av != NULL) ? 1 : 0;
        return av;
    }
#endif
}

static inline void
codit_av_u8_finish(pTHX_ AV *av, uint8_t *buf, size_t nbytes, int is_packed)
{
#if CODIT_HAVE_PACKED_AV
    if (is_packed) {
        AvFILLp(av) = (nbytes > 0) ? (SSize_t)(nbytes - 1) : -1;
        return;
    }
#endif
    (void)is_packed;
    av_clear(av);
    if (nbytes > 0) {
        av_extend(av, (SSize_t)(nbytes - 1));
        for (size_t i = 0; i < nbytes; i++) {
            av_store(av, (SSize_t)i, newSVuv((UV)buf[i]));
        }
    }
    free(buf);
}

/*
 * Check whether PERL_FORCE_SCALAR=1 is set in the environment.
 */
static inline int
codit_force_scalar_env(void)
{
    const char *v = getenv("PERL_FORCE_SCALAR");
    return (v && v[0] == '1' && v[1] == '\0') ? 1 : 0;
}

#endif /* CODIT_MT_COMPAT_H */
