#ifndef AIO_ASS_BLEND_H
#define AIO_ASS_BLEND_H

#include <stdint.h>

/**
 * One of libass's pieces, an alpha mask `w` by `h` (rows `stride` bytes apart) in one ASS colour
 * (`RRGGBBAA`, the alpha byte as transparency), laid over a premultiplied RGBA picture (bytes R, G, B, A)
 * at `dst`, whose rows are `dstRowBytes` apart. As the Android app's blend.c, with its NEON paths.
 */
void aio_ass_blend(const uint8_t *mask, int w, int h, int stride, uint32_t color, uint8_t *dst, int dstRowBytes);

#endif
