/*
 * cairo_port: beam-hud's C renderer, run as an Erlang Port.
 *
 * A separate OS process: the BEAM writes requests to our stdin and reads
 * replies from our stdout, each framed by a 4-byte big-endian length
 * ({packet, 4} on the Elixir side). If this program crashes, only it dies;
 * the BEAM sees the port close and its supervisor starts a new one.
 *
 * Requests (first byte is the command; integers little-endian):
 *   1 INIT        len:u16 regular.ttf len:u16 bold.ttf
 *   2 PNG         len:u16 path, display list         -> us:u64
 *   3 OPEN_FB     width height stride:u32, direct:u8, path
 *   4 FB          display list                       -> us:u64 bands:u32
 *   5 INVALIDATE
 *   6 KD_MODE     graphics:u8, tty path
 *   7 ECHO        any bytes                          -> the same bytes
 *   8 CRASH       (only with --allow-crash) dereference NULL, for the demo
 * Replies: 0 then the results, or 1 then an error message.
 *
 * The display list format is documented in lib/beam_hud/render/display_list.ex.
 */
#include <cairo.h>
#include <cairo-ft.h>
#include <errno.h>
#include <fcntl.h>
#include <ft2build.h>
#include FT_FREETYPE_H
#include <linux/kd.h>
#include <math.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>

#define BAND_ROWS 16

/* ---------------------------------------------------------------- I/O */

static int read_exact(void *buf, size_t n) {
    uint8_t *p = buf;
    while (n > 0) {
        ssize_t r = read(0, p, n);
        if (r <= 0) return -1; /* EOF: the BEAM closed the port */
        p += r;
        n -= (size_t)r;
    }
    return 0;
}

static void write_exact(const void *buf, size_t n) {
    const uint8_t *p = buf;
    while (n > 0) {
        ssize_t w = write(1, p, n);
        if (w <= 0) exit(1);
        p += w;
        n -= (size_t)w;
    }
}

static void reply(const void *data, uint32_t len) {
    uint8_t head[4] = {len >> 24, len >> 16, len >> 8, len};
    write_exact(head, 4);
    write_exact(data, len);
}

static void reply_ok(const void *data, uint32_t len) {
    uint8_t *buf = malloc(len + 1);
    buf[0] = 0;
    if (len) memcpy(buf + 1, data, len);
    reply(buf, len + 1);
    free(buf);
}

static void reply_error(const char *fmt, ...) {
    char msg[512];
    va_list ap;
    va_start(ap, fmt);
    int n = vsnprintf(msg + 1, sizeof msg - 1, fmt, ap);
    va_end(ap);
    msg[0] = 1;
    reply(msg, (uint32_t)(1 + (n < (int)sizeof msg - 1 ? n : (int)sizeof msg - 2)));
}

/* A little-endian reader over one request. x86 and ARM are little-endian,
 * so memcpy into the native type is enough. */
typedef struct {
    const uint8_t *p, *end;
    int bad;
} reader;

static const uint8_t *take(reader *r, size_t n) {
    if (r->bad || (size_t)(r->end - r->p) < n) {
        r->bad = 1;
        return NULL;
    }
    const uint8_t *s = r->p;
    r->p += n;
    return s;
}
#define GETTER(name, type)                    \
    static type name(reader *r) {             \
        type v = 0;                           \
        const uint8_t *s = take(r, sizeof v); \
        if (s) memcpy(&v, s, sizeof v);       \
        return v;                             \
    }
GETTER(u8, uint8_t)
GETTER(u16, uint16_t)
GETTER(u32, uint32_t)
GETTER(f32, float)

/* A length-prefixed string, copied and NUL-terminated (caller frees). */
static char *str16(reader *r) {
    uint16_t n = u16(r);
    const uint8_t *s = take(r, n);
    if (!s) return NULL;
    char *out = malloc(n + 1u);
    memcpy(out, s, n);
    out[n] = 0;
    return out;
}

static uint64_t now_us(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return (uint64_t)t.tv_sec * 1000000u + (uint64_t)t.tv_nsec / 1000u;
}

/* ---------------------------------------------------------------- state */

static FT_Library ft;
static cairo_font_face_t *face_regular, *face_bold;

static struct {
    uint8_t *map;   /* the mmapped framebuffer (or stand-in file) */
    uint8_t *back;  /* offscreen frame in the same layout */
    uint8_t *prev;  /* last frame written, for the changed-band check */
    int width, height, stride, direct, valid;
    size_t len;
} fb;

static void done_face(void *face) { FT_Done_Face((FT_Face)face); }

static cairo_font_face_t *load_face(const char *path) {
    FT_Face face;
    if (FT_New_Face(ft, path, 0, &face)) return NULL;
    cairo_font_face_t *cf = cairo_ft_font_face_create_for_ft_face(face, 0);
    /* Free the FT_Face when cairo is done with the font face. */
    static const cairo_user_data_key_t key;
    cairo_font_face_set_user_data(cf, &key, face, done_face);
    return cf;
}

/* ---------------------------------------------------------------- drawing */

static void set_rgb(cairo_t *cr, uint32_t c) {
    cairo_set_source_rgb(cr, ((c >> 16) & 255) / 255.0, ((c >> 8) & 255) / 255.0, (c & 255) / 255.0);
}

static void stroke_with(cairo_t *cr, float width, uint32_t c) {
    set_rgb(cr, c);
    cairo_set_line_width(cr, width);
    cairo_stroke(cr);
}

static void set_font(cairo_t *cr, float size, int bold) {
    cairo_set_font_face(cr, bold ? face_bold : face_regular);
    cairo_set_font_size(cr, size);
}

/* TEXT: a run of parts placed as a whole (see the display list docs). */
static void text_run(cairo_t *cr, reader *r) {
    float x = f32(r), y = f32(r);
    uint8_t halign = u8(r), valign = u8(r), n = u8(r);
    struct { float size; int bold; uint32_t rgb; char *text; } parts[256];
    float width = 0, big = 0;
    int bigbold = 0;
    for (int i = 0; i < n; i++) {
        parts[i].size = f32(r);
        parts[i].bold = u8(r);
        parts[i].rgb = u32(r);
        parts[i].text = str16(r);
        if (r->bad) {
            for (int j = 0; j < i; j++) free(parts[j].text);
            return;
        }
        cairo_text_extents_t te;
        set_font(cr, parts[i].size, parts[i].bold);
        cairo_text_extents(cr, parts[i].text, &te);
        width += (float)te.x_advance;
        if (parts[i].size > big) big = parts[i].size, bigbold = parts[i].bold;
    }
    if (n == 0) return;
    cairo_font_extents_t fe;
    set_font(cr, big, bigbold);
    cairo_font_extents(cr, &fe); /* ascent and descent, both positive */
    double pen = halign == 1 ? x - width / 2 : halign == 2 ? x - width : x;
    double base = valign == 1 ? y + (fe.ascent - fe.descent) / 2 : valign == 2 ? y - fe.descent : y + fe.ascent;
    for (int i = 0; i < n; i++) {
        cairo_text_extents_t te;
        set_font(cr, parts[i].size, parts[i].bold);
        cairo_text_extents(cr, parts[i].text, &te);
        set_rgb(cr, parts[i].rgb);
        cairo_move_to(cr, pen, base);
        cairo_show_text(cr, parts[i].text);
        pen += te.x_advance;
        free(parts[i].text);
    }
}

/* Draw a display list onto a surface. Returns 0, or -1 if it is malformed. */
static int draw(cairo_surface_t *surface, reader *r) {
    cairo_t *cr = cairo_create(surface);
    cairo_set_line_cap(cr, CAIRO_LINE_CAP_BUTT);
    /* Unhinted, greyscale text: the closest match to fontdue's output. */
    cairo_font_options_t *fo = cairo_font_options_create();
    cairo_font_options_set_antialias(fo, CAIRO_ANTIALIAS_GRAY);
    cairo_font_options_set_hint_style(fo, CAIRO_HINT_STYLE_NONE);
    cairo_font_options_set_hint_metrics(fo, CAIRO_HINT_METRICS_OFF);
    cairo_set_font_options(cr, fo);
    cairo_font_options_destroy(fo);

    while (r->p < r->end && !r->bad) {
        uint8_t op = u8(r);
        switch (op) {
        case 0x01: set_rgb(cr, u32(r)); cairo_paint(cr); break;
        case 0x02: {
            uint32_t n = u32(r);
            for (uint32_t i = 0; i < n && !r->bad; i++) {
                float x = f32(r), y = f32(r), w = f32(r), h = f32(r);
                set_rgb(cr, u32(r));
                cairo_rectangle(cr, x, y, w, h);
                cairo_fill(cr);
            }
            break;
        }
        case 0x03: {
            float x0 = f32(r), y0 = f32(r), x1 = f32(r), y1 = f32(r), w = f32(r);
            cairo_move_to(cr, x0, y0);
            cairo_line_to(cr, x1, y1);
            stroke_with(cr, w, u32(r));
            break;
        }
        case 0x04: {
            uint32_t n = u32(r);
            for (uint32_t i = 0; i < n && !r->bad; i++) {
                float cx = f32(r), cy = f32(r), rad = f32(r);
                set_rgb(cr, u32(r));
                cairo_new_sub_path(cr);
                cairo_arc(cr, cx, cy, rad, 0, 2 * M_PI);
                cairo_fill(cr);
            }
            break;
        }
        case 0x05: {
            float cx = f32(r), cy = f32(r), rad = f32(r), w = f32(r);
            cairo_new_sub_path(cr);
            cairo_arc(cr, cx, cy, rad, 0, 2 * M_PI);
            stroke_with(cr, w, u32(r));
            break;
        }
        case 0x06: {
            float cx = f32(r), cy = f32(r), rad = f32(r), a0 = f32(r), a1 = f32(r), w = f32(r);
            cairo_new_sub_path(cr);
            cairo_arc(cr, cx, cy, rad, a0, a1); /* cairo angles run clockwise on screen too */
            stroke_with(cr, w, u32(r));
            break;
        }
        case 0x07: {
            float x0 = f32(r), y0 = f32(r), x1 = f32(r), y1 = f32(r), rad = f32(r);
            double rr = fmin(rad, fmin((x1 - x0) / 2, (y1 - y0) / 2));
            cairo_new_sub_path(cr);
            cairo_arc(cr, x1 - rr, y0 + rr, rr, -M_PI / 2, 0);
            cairo_arc(cr, x1 - rr, y1 - rr, rr, 0, M_PI / 2);
            cairo_arc(cr, x0 + rr, y1 - rr, rr, M_PI / 2, M_PI);
            cairo_arc(cr, x0 + rr, y0 + rr, rr, M_PI, 3 * M_PI / 2);
            cairo_close_path(cr);
            set_rgb(cr, u32(r));
            cairo_fill(cr);
            break;
        }
        case 0x08: text_run(cr, r); break;
        case 0x09: {
            float w = f32(r);
            uint32_t c = u32(r), n = u32(r);
            for (uint32_t i = 0; i < n && !r->bad; i++) {
                float x = f32(r), y = f32(r);
                if (i == 0) cairo_move_to(cr, x, y); else cairo_line_to(cr, x, y);
            }
            stroke_with(cr, w, c);
            break;
        }
        case 0x0A: {
            float w = f32(r);
            uint32_t n = u32(r);
            for (uint32_t i = 0; i < n && !r->bad; i++) {
                float x0 = f32(r), y0 = f32(r), x1 = f32(r), y1 = f32(r);
                cairo_move_to(cr, x0, y0);
                cairo_line_to(cr, x1, y1);
                stroke_with(cr, w, u32(r));
            }
            break;
        }
        default: r->bad = 1;
        }
    }
    cairo_destroy(cr);
    return r->bad ? -1 : 0;
}

static int header(reader *r, int *w, int *h) {
    const uint8_t *magic = take(r, 4);
    *w = (int)u32(r);
    *h = (int)u32(r);
    return (!magic || memcmp(magic, "HUD1", 4) || r->bad || *w <= 0 || *h <= 0 || *w > 16384 || *h > 16384) ? -1 : 0;
}

/* ---------------------------------------------------------------- commands */

static void cmd_init(reader *r) {
    char *regular = str16(r), *bold = str16(r);
    if (!regular || !bold) return reply_error("bad INIT");
    if (!ft && FT_Init_FreeType(&ft)) return reply_error("FreeType init failed");
    face_regular = load_face(regular);
    face_bold = load_face(bold);
    if (!face_regular || !face_bold) reply_error("can't load fonts %s, %s", regular, bold);
    else reply_ok(NULL, 0);
    free(regular);
    free(bold);
}

static void cmd_png(reader *r) {
    char *path = str16(r);
    int w, h;
    if (!path || header(r, &w, &h)) { free(path); return reply_error("bad PNG request"); }
    uint64_t t = now_us();
    cairo_surface_t *s = cairo_image_surface_create(CAIRO_FORMAT_RGB24, w, h);
    if (draw(s, r)) { cairo_surface_destroy(s); free(path); return reply_error("malformed display list"); }
    uint64_t us = now_us() - t;
    cairo_status_t st = cairo_surface_write_to_png(s, path);
    cairo_surface_destroy(s);
    if (st != CAIRO_STATUS_SUCCESS) reply_error("%s: %s", path, cairo_status_to_string(st));
    else reply_ok(&us, sizeof us);
    free(path);
}

static void close_fb(void) {
    if (fb.map) munmap(fb.map, fb.len);
    free(fb.back);
    free(fb.prev);
    memset(&fb, 0, sizeof fb);
}

static void cmd_open_fb(reader *r) {
    int w = (int)u32(r), h = (int)u32(r), stride = (int)u32(r), direct = u8(r);
    size_t n = (size_t)(r->end - r->p);
    if (r->bad || stride < w * 4) return reply_error("bad OPEN_FB");
    char *path = strndup((const char *)r->p, n);
    close_fb();
    int fd = open(path, O_RDWR);
    if (fd < 0) { reply_error("%s: %s", path, strerror(errno)); free(path); return; }
    fb.len = (size_t)stride * (size_t)h;
    fb.map = mmap(NULL, fb.len, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    close(fd); /* the mapping stays valid */
    if (fb.map == MAP_FAILED) { fb.map = NULL; reply_error("mmap %s: %s", path, strerror(errno)); free(path); return; }
    fb.width = w, fb.height = h, fb.stride = stride, fb.direct = direct;
    fb.back = calloc(1, fb.len);
    fb.prev = calloc(1, fb.len);
    free(path);
    reply_ok(NULL, 0);
}

/*
 * FB: cairo's RGB24 format is XRGB8888 in native byte order, exactly the
 * framebuffer's layout, so cairo draws straight into framebuffer-format
 * memory with no conversion:
 *  - direct: the surface IS the mmapped framebuffer (fewest copies, but the
 *    half-drawn frame is visible for a moment: flicker);
 *  - default: the surface is an offscreen buffer with the same stride, and
 *    only 16-row bands that changed are copied to the framebuffer.
 */
static void cmd_fb(reader *r) {
    int w, h;
    if (!fb.map) return reply_error("no framebuffer open");
    if (header(r, &w, &h)) return reply_error("bad display list");
    if (w > fb.width) w = fb.width;
    if (h > fb.height) h = fb.height;
    uint64_t t = now_us();
    uint8_t *target = fb.direct ? fb.map : fb.back;
    cairo_surface_t *s = cairo_image_surface_create_for_data(target, CAIRO_FORMAT_RGB24, w, h, fb.stride);
    int bad = draw(s, r);
    cairo_surface_flush(s);
    cairo_surface_destroy(s);
    if (bad) return reply_error("malformed display list");
    uint32_t bands = 0;
    if (!fb.direct) {
        size_t band = (size_t)fb.stride * BAND_ROWS, len = (size_t)fb.stride * (size_t)h;
        for (size_t off = 0; off < len; off += band) {
            size_t n = off + band > len ? len - off : band;
            if (!fb.valid || memcmp(fb.prev + off, fb.back + off, n)) {
                memcpy(fb.map + off, fb.back + off, n);
                memcpy(fb.prev + off, fb.back + off, n);
                bands++;
            }
        }
        fb.valid = 1;
    }
    uint8_t out[12];
    uint64_t us = now_us() - t;
    memcpy(out, &us, 8);
    memcpy(out + 8, &bands, 4);
    reply_ok(out, sizeof out);
}

static void cmd_kd_mode(reader *r) {
    int graphics = u8(r);
    char *tty = strndup((const char *)r->p, (size_t)(r->end - r->p));
    int fd = open(tty, O_RDWR);
    if (fd < 0) reply_error("%s: %s", tty, strerror(errno));
    else if (ioctl(fd, KDSETMODE, graphics ? KD_GRAPHICS : KD_TEXT)) reply_error("KDSETMODE on %s: %s", tty, strerror(errno));
    else reply_ok(NULL, 0);
    if (fd >= 0) close(fd);
    free(tty);
}

int main(int argc, char **argv) {
    int allow_crash = argc > 1 && strcmp(argv[1], "--allow-crash") == 0;
    for (;;) {
        uint8_t head[4];
        if (read_exact(head, 4)) return 0;
        uint32_t len = (uint32_t)head[0] << 24 | head[1] << 16 | head[2] << 8 | head[3];
        uint8_t *msg = malloc(len ? len : 1);
        if (read_exact(msg, len)) return 0;
        reader r = {msg + 1, msg + len, len == 0};
        switch (len ? msg[0] : 0) {
        case 1: cmd_init(&r); break;
        case 2: cmd_png(&r); break;
        case 3: cmd_open_fb(&r); break;
        case 4: cmd_fb(&r); break;
        case 5: fb.valid = 0; reply_ok(NULL, 0); break;
        case 6: cmd_kd_mode(&r); break;
        case 7: reply_ok(msg + 1, len - 1); break;
        case 8:
            if (allow_crash) {
                volatile int *null = NULL;
                *null = 42; /* SIGSEGV: the demo of a crashing port */
            }
            reply_error("CRASH needs --allow-crash");
            break;
        default: reply_error("unknown command %d", len ? msg[0] : -1);
        }
        free(msg);
    }
}
