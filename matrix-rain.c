/* matrix-rain: 3D digital rain with glow. One source for Linux and Windows.
 *
 * Linux (X11, and Wayland through XWayland):
 *   matrix-rain --root          draw on the window xscreensaver hands over (how xscreensaver starts it)
 *   matrix-rain --fullscreen    open its own window over every monitor; it never closes by itself, kill it
 *   --density F   how many streams, 1 is the default      --size F      glyph size, 1 is the default
 *   --speed F     rain and camera speed, 1 is the default  --seconds N   quit after N seconds
 *
 * Windows: built as Matrix.scr, a screen saver. Windows starts it with /s; it covers every monitor and closes
 * on a key press, a click or mouse movement.
 *
 * macOS: compiled as Objective-C (install-macos.sh does it on the Mac itself).
 *   matrix-rain --fullscreen    a window over every screen, one process per screen; closes on a key press or
 *                               a click, and when whoever started it kills it (the idle watcher does)
 *   --density, --size, --speed, --seconds as on Linux
 *
 * Build: ./build.sh
 *
 * The scene is a box of vertical glyph streams that repeats in every horizontal direction, so the camera can
 * fly through it forever. It is drawn additively into a float framebuffer; whatever is brighter than plain
 * green (the white tips, mostly) is blurred and added back as glow.
 */
#ifdef _WIN32
#include <windows.h>
#include <GL/gl.h>
#include <GL/glext.h>
#elif defined(__APPLE__)
#define GL_SILENCE_DEPRECATION   /* Apple calls OpenGL deprecated; it is still there, and the one thing all three systems share */
#import <Cocoa/Cocoa.h>
#include <OpenGL/gl.h>
#include <OpenGL/glext.h>
#include <mach-o/dyld.h>
#include <signal.h>
#include <spawn.h>
#include <sys/wait.h>
#ifndef GL_RGBA16F
#define GL_RGBA16F 0x881A
#endif
#else
#define GL_GLEXT_PROTOTYPES
#include <GL/gl.h>
#include <GL/glext.h>
#include <GL/glx.h>
#include <X11/Xlib.h>
#include <X11/Xutil.h>
#include <X11/extensions/Xrandr.h>
#endif
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "glyphs.h"

#ifdef _WIN32
/* opengl32.dll only has OpenGL 1.1; everything newer is asked of the graphics driver once OpenGL is running. */
#define GL_FUNCTIONS \
    X(GLuint, glCreateProgram, (void)) \
    X(GLuint, glCreateShader, (GLenum)) \
    X(void, glShaderSource, (GLuint, GLsizei, const GLchar *const *, const GLint *)) \
    X(void, glCompileShader, (GLuint)) \
    X(void, glGetShaderiv, (GLuint, GLenum, GLint *)) \
    X(void, glGetShaderInfoLog, (GLuint, GLsizei, GLsizei *, GLchar *)) \
    X(void, glAttachShader, (GLuint, GLuint)) \
    X(void, glBindAttribLocation, (GLuint, GLuint, const GLchar *)) \
    X(void, glLinkProgram, (GLuint)) \
    X(void, glUseProgram, (GLuint)) \
    X(GLint, glGetUniformLocation, (GLuint, const GLchar *)) \
    X(void, glUniform1i, (GLint, GLint)) \
    X(void, glUniform2f, (GLint, GLfloat, GLfloat)) \
    X(void, glUniformMatrix4fv, (GLint, GLsizei, GLboolean, const GLfloat *)) \
    X(void, glGenFramebuffers, (GLsizei, GLuint *)) \
    X(void, glBindFramebuffer, (GLenum, GLuint)) \
    X(void, glFramebufferTexture2D, (GLenum, GLenum, GLenum, GLuint, GLint)) \
    X(GLenum, glCheckFramebufferStatus, (GLenum)) \
    X(void, glGenBuffers, (GLsizei, GLuint *)) \
    X(void, glBindBuffer, (GLenum, GLuint)) \
    X(void, glBufferData, (GLenum, GLsizeiptr, const void *, GLenum)) \
    X(void, glEnableVertexAttribArray, (GLuint)) \
    X(void, glDisableVertexAttribArray, (GLuint)) \
    X(void, glVertexAttribPointer, (GLuint, GLint, GLenum, GLboolean, GLsizei, const void *)) \
    X(void, glActiveTexture, (GLenum)) \
    X(void, glGenerateMipmap, (GLenum))
#define X(ret, name, args) static ret (APIENTRY *name) args;
GL_FUNCTIONS
#undef X
#endif

#define BOX 36.0f       /* the repeating box is BOX x BOX wide and deep, in world units */
#define HALF_H 15.0f    /* and reaches this far above and below the camera's rest height */
#define FOG_END (BOX * 0.5f)
#define FOG_START 0.7f
#define MAX_VIEWS 8
#define FLOATS 7        /* per vertex: x y z, u v, brightness, whiteness */

typedef struct { float x, z, head, speed; int len; unsigned seed; } Stream;
typedef struct { GLuint fbo, tex; int w, h; } Target;
typedef struct { int x, y, w, h; } View;

static float glyph_size = 0.17f, density = 1, speed = 1;
static Stream *streams;
static int stream_count, cells;
static float *verts;
static int vert_count, vert_max;
static unsigned rng = 0x1234567;

static void die(const char *what)
{
#ifdef _WIN32
    MessageBoxA(NULL, what, "Matrix screen saver", MB_OK | MB_ICONERROR);
#else
    fprintf(stderr, "matrix-rain: %s\n", what);
#endif
    exit(1);
}

static unsigned hash(unsigned a)
{
    a ^= a >> 16; a *= 0x7feb352dU; a ^= a >> 15; a *= 0x846ca68bU; a ^= a >> 16;
    return a;
}
static float rnd(void) { rng = hash(rng + 0x9e3779b9U); return (rng >> 8) / 16777216.0f; }
static float smooth(float a, float b, float x)
{
    x = (x - a) / (b - a);
    x = x < 0 ? 0 : x > 1 ? 1 : x;
    return x * x * (3 - 2 * x);
}

/* ---- the rain ---- */

static void respawn(Stream *s, int anywhere)
{
    float r = rnd();
    s->x = rnd() * BOX;
    s->z = rnd() * BOX;
    /* Cells per second, from a crawl (4) to a streak (70). Slow streams stay on screen longer, so new ones
       are drawn evenly over that range, which leaves the screen with as many between 4 and 8 as between
       35 and 70; the first fill is drawn the way the screen ends up, so the look does not drift. */
    s->speed = anywhere ? 4 * powf(17.5f, r) : 4 + 66 * r;
    s->len = 12 + (int)(rnd() * 44);
    s->seed = hash(rng);
    s->head = anywhere ? rnd() * (cells + s->len) : -rnd() * 12;
}

static void rain_init(void)
{
    cells = (int)(2 * HALF_H / glyph_size);
    stream_count = (int)(9000 * density);
    streams = malloc(sizeof(Stream) * stream_count);
    for (int i = 0; i < stream_count; i++) respawn(&streams[i], 1);
    vert_max = 4 * 400000;
    verts = malloc(sizeof(float) * FLOATS * vert_max);
    if (!streams || !verts) die("out of memory");
}

static void rain_step(float dt)
{
    for (int i = 0; i < stream_count; i++) {
        Stream *s = &streams[i];
        s->head += s->speed * speed * dt;
        if (s->head - s->len > cells) respawn(s, 0);
    }
}

static void vertex(float x, float y, float z, float u, float v, float bright, float white)
{
    float *p = verts + FLOATS * vert_count++;
    p[0] = x; p[1] = y; p[2] = z; p[3] = u; p[4] = v; p[5] = bright; p[6] = white;
}

/* Fills verts with one quad per lit glyph, each turned about its vertical axis to face a camera at
   (cx, cz) looking along yaw. */
static void rain_build(float cx, float cz, float yaw, float t)
{
    float fx = sinf(yaw), fz = -cosf(yaw);        /* forward */
    float rx = cosf(yaw), rz = sinf(yaw);         /* right */
    float hw = glyph_size * 0.5f * GLYPHS_W / GLYPH_COLS / (GLYPHS_H / GLYPH_ROWS);
    unsigned tick = (unsigned)(t * 7);
    vert_count = 0;
    for (int n = 0; n < stream_count; n++) {
        Stream *s = &streams[n];
        float x = s->x + BOX * floorf((cx - s->x) / BOX + 0.5f);   /* the copy of this stream nearest the camera */
        float z = s->z + BOX * floorf((cz - s->z) / BOX + 0.5f);
        float dx = x - cx, dz = z - cz, d = sqrtf(dx * dx + dz * dz);
        if (d > FOG_END || d < FOG_START) continue;
        if (dx * fx + dz * fz < -0.3f * d - 1) continue;           /* well behind the camera */
        float fog = smooth(FOG_END, FOG_END * 0.45f, d) * smooth(FOG_START, 2.2f, d);
        int head = (int)floorf(s->head);
        for (int k = 0; k < s->len; k++) {
            int i = head - k;
            if (i < 0) break;
            if (i >= cells) continue;
            unsigned g = hash(s->seed ^ (unsigned)i * 2654435761U);
            float behind = s->head - i, fade = 1 - behind / s->len, bright, white = 0;
            if (k == 0) { bright = 2.6f; white = 1; }                               /* the tip */
            else if (k < 3) { bright = 1.5f; white = 0.55f - 0.2f * k; }
            else {
                bright = fade * sqrtf(fade) * (0.45f + 0.55f * ((g >> 20 & 255) / 255.0f));
                if ((g >> 12 & 63) == 0) { bright *= 2.2f; white = 0.3f; }          /* the odd glyph that flares */
            }
            bright *= fog;
            if (bright < 0.012f) continue;
            if ((g & 7) == 0) g = hash(g + tick + (g >> 8 & 7));                    /* one in eight keeps changing */
            int glyph = (g >> 3) % (GLYPH_COLS * GLYPH_ROWS);
            float u = (float)(glyph % GLYPH_COLS) / GLYPH_COLS, v = (float)(glyph / GLYPH_COLS) / GLYPH_ROWS;
            float u1 = u + 1.0f / GLYPH_COLS, v1 = v + 1.0f / GLYPH_ROWS;
            float top = HALF_H - i * glyph_size, bottom = top - glyph_size;
            if (vert_count + 4 > vert_max) return;
            vertex(x - rx * hw, top, z - rz * hw, u, v, bright, white);
            vertex(x + rx * hw, top, z + rz * hw, u1, v, bright, white);
            vertex(x + rx * hw, bottom, z + rz * hw, u1, v1, bright, white);
            vertex(x - rx * hw, bottom, z - rz * hw, u, v1, bright, white);
        }
    }
}

/* ---- matrices (column-major, as OpenGL takes them) ---- */

static void camera_matrix(float *m, const float *eye, float yaw, float pitch, float roll, float fovy, float aspect)
{
    float f[3] = { sinf(yaw) * cosf(pitch), sinf(pitch), -cosf(yaw) * cosf(pitch) };
    float r[3] = { cosf(yaw), 0, sinf(yaw) };
    float u[3] = { r[1] * f[2] - r[2] * f[1], r[2] * f[0] - r[0] * f[2], r[0] * f[1] - r[1] * f[0] };
    float cr = cosf(roll), sr = sinf(roll), R[3], U[3];
    for (int i = 0; i < 3; i++) { R[i] = r[i] * cr + u[i] * sr; U[i] = u[i] * cr - r[i] * sr; }
    float view[16] = {
        R[0], U[0], -f[0], 0,
        R[1], U[1], -f[1], 0,
        R[2], U[2], -f[2], 0,
        -(R[0] * eye[0] + R[1] * eye[1] + R[2] * eye[2]),
        -(U[0] * eye[0] + U[1] * eye[1] + U[2] * eye[2]),
        f[0] * eye[0] + f[1] * eye[1] + f[2] * eye[2], 1 };
    float h = 1 / tanf(fovy / 2), n = 0.1f, zfar = 100;
    float proj[16] = { h / aspect, 0, 0, 0,   0, h, 0, 0,   0, 0, (zfar + n) / (n - zfar), -1,   0, 0, 2 * zfar * n / (n - zfar), 0 };
    for (int c = 0; c < 4; c++)
        for (int row = 0; row < 4; row++) {
            float sum = 0;
            for (int k = 0; k < 4; k++) sum += proj[k * 4 + row] * view[c * 4 + k];
            m[c * 4 + row] = sum;
        }
}

/* ---- OpenGL ---- */

static const char *scene_vs =
    "attribute vec3 pos; attribute vec2 uv; attribute vec2 lum; uniform mat4 mvp; varying vec2 v_uv; varying vec2 v_lum;\n"
    "void main() { v_uv = uv; v_lum = lum; gl_Position = mvp * vec4(pos, 1.0); }\n";
static const char *scene_fs =
    "uniform sampler2D tex; varying vec2 v_uv; varying vec2 v_lum;\n"
    "void main() {\n"
    "  vec3 colour = mix(vec3(0.05, 1.0, 0.30), vec3(0.80, 1.0, 0.88), v_lum.y);\n"
    "  gl_FragColor = vec4(colour * texture2D(tex, v_uv, -0.6).r * v_lum.x, 1.0);\n"
    "}\n";
static const char *post_vs =
    "attribute vec2 pos; varying vec2 v_uv;\n"
    "void main() { v_uv = pos * 0.5 + 0.5; gl_Position = vec4(pos, 0.0, 1.0); }\n";
static const char *bright_fs =   /* keeps what is brighter than plain green */
    "uniform sampler2D tex; varying vec2 v_uv;\n"
    "void main() { vec3 c = texture2D(tex, v_uv).rgb; gl_FragColor = vec4(c * smoothstep(0.75, 1.6, max(c.r, max(c.g, c.b))), 1.0); }\n";
static const char *blur_fs =
    "uniform sampler2D tex; uniform vec2 step; varying vec2 v_uv;\n"
    "void main() {\n"
    "  vec3 c = texture2D(tex, v_uv).rgb * 0.227027;\n"
    "  c += (texture2D(tex, v_uv + step * 1.3846).rgb + texture2D(tex, v_uv - step * 1.3846).rgb) * 0.316216;\n"
    "  c += (texture2D(tex, v_uv + step * 3.2308).rgb + texture2D(tex, v_uv - step * 3.2308).rgb) * 0.070270;\n"
    "  gl_FragColor = vec4(c, 1.0);\n"
    "}\n";
static const char *final_fs =
    "uniform sampler2D tex; uniform sampler2D glow; uniform sampler2D haze; varying vec2 v_uv;\n"
    "void main() {\n"
    "  vec3 c = texture2D(tex, v_uv).rgb + texture2D(glow, v_uv).rgb * 0.9 + texture2D(haze, v_uv).rgb * 0.8;\n"
    "  c = 1.0 - exp(-c * 1.25);\n"
    "  vec2 q = v_uv - 0.5;\n"
    "  gl_FragColor = vec4(c * (1.0 - 0.55 * dot(q, q)), 1.0);\n"
    "}\n";

static GLuint program(const char *vs, const char *fs)
{
    GLuint p = glCreateProgram();
    const char *src[2] = { vs, fs };
    GLenum type[2] = { GL_VERTEX_SHADER, GL_FRAGMENT_SHADER };
    for (int i = 0; i < 2; i++) {
        GLuint s = glCreateShader(type[i]);
        GLint ok;
        char log[1024];
        glShaderSource(s, 1, &src[i], NULL);
        glCompileShader(s);
        glGetShaderiv(s, GL_COMPILE_STATUS, &ok);
        if (!ok) { glGetShaderInfoLog(s, sizeof log, NULL, log); die(log); }
        glAttachShader(p, s);
    }
    glBindAttribLocation(p, 0, "pos");
    glBindAttribLocation(p, 1, "uv");
    glBindAttribLocation(p, 2, "lum");
    glLinkProgram(p);
    return p;
}

static GLenum colour_format = GL_RGBA16F;

static void target(Target *t, int w, int h)
{
    if (t->fbo && t->w == w && t->h == h) return;
    if (!t->fbo) { glGenFramebuffers(1, &t->fbo); glGenTextures(1, &t->tex); }
    t->w = w; t->h = h;
    glBindTexture(GL_TEXTURE_2D, t->tex);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    glBindFramebuffer(GL_FRAMEBUFFER, t->fbo);
    for (;;) {
        glTexImage2D(GL_TEXTURE_2D, 0, colour_format, w, h, 0, GL_RGBA, GL_UNSIGNED_BYTE, NULL);
        glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, t->tex, 0);
        if (glCheckFramebufferStatus(GL_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE) break;
        if (colour_format == GL_RGBA8) die("this graphics driver cannot render to a texture");
        colour_format = GL_RGBA8;   /* no float textures: the glow is weaker but everything still works */
    }
}

static GLuint quad_vbo;

/* Runs a full-frame shader from one texture into a target (or the window, when to is NULL). */
static void pass(GLuint prog, GLuint from, Target *to, int w, int h, float step_x, float step_y)
{
    static const float corners[] = { -1, -1, 1, -1, 1, 1, -1, 1 };
    if (!quad_vbo) {
        glGenBuffers(1, &quad_vbo);
        glBindBuffer(GL_ARRAY_BUFFER, quad_vbo);
        glBufferData(GL_ARRAY_BUFFER, sizeof corners, corners, GL_STATIC_DRAW);
    }
    glBindFramebuffer(GL_FRAMEBUFFER, to ? to->fbo : 0);
    glViewport(0, 0, w, h);
    glUseProgram(prog);
    glUniform2f(glGetUniformLocation(prog, "step"), step_x, step_y);
    glActiveTexture(GL_TEXTURE0);
    glBindTexture(GL_TEXTURE_2D, from);
    glBindBuffer(GL_ARRAY_BUFFER, quad_vbo);
    glEnableVertexAttribArray(0);
    glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 0, 0);
    glDrawArrays(GL_QUADS, 0, 4);
}

/* ---- the window: X11 ---- */
#if !defined(_WIN32) && !defined(__APPLE__)

static Display *dpy;
static Window win;
static int screen, own_window;

static double now(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec * 1e-9;
}

static void nap(double seconds)
{
    struct timespec ts = { 0, (long)(seconds * 1e9) };
    nanosleep(&ts, NULL);
}

static void window_open(int argc, char **argv, double *seconds)
{
    int root = 0;
    for (int i = 1; i < argc; i++) {
        const char *a = argv[i] + (argv[i][0] == '-' && argv[i][1] == '-');   /* -root and --root are the same */
        float *number = !strcmp(a, "-density") ? &density : !strcmp(a, "-speed") ? &speed : !strcmp(a, "-size") ? &glyph_size : NULL;
        if (!strcmp(a, "-root")) root = 1;
        else if (!strcmp(a, "-fullscreen")) own_window = 1;
        else if (!strcmp(a, "-window-id") && i + 1 < argc) win = strtoul(argv[++i], NULL, 0);
        else if (!strcmp(a, "-seconds") && i + 1 < argc) *seconds = atof(argv[++i]);
        else if (number && i + 1 < argc) *number *= atof(argv[++i]);
        else die("usage: matrix-rain [--root | --fullscreen | --window-id ID] [--density F] [--size F] [--speed F] [--seconds N]");
    }
    if (density <= 0 || density > 8 || glyph_size < 0.02f || speed <= 0) die("--density, --size and --speed are factors around 1");

    dpy = XOpenDisplay(NULL);
    if (!dpy) die("cannot open the X display");
    screen = DefaultScreen(dpy);
    const char *given = getenv("XSCREENSAVER_WINDOW");
    if (!win && !own_window && given) win = strtoul(given, NULL, 0);
    if (!win && root) win = RootWindow(dpy, screen);

    XVisualInfo *vi;
    if (win) {
        XWindowAttributes wa;
        XVisualInfo want;
        int n;
        XGetWindowAttributes(dpy, win, &wa);
        want.visualid = XVisualIDFromVisual(wa.visual);
        vi = XGetVisualInfo(dpy, VisualIDMask, &want, &n);
    } else {
        int wanted[] = { GLX_RGBA, GLX_DOUBLEBUFFER, GLX_RED_SIZE, 8, GLX_GREEN_SIZE, 8, GLX_BLUE_SIZE, 8, None };
        vi = glXChooseVisual(dpy, screen, wanted);
        if (!vi) die("no OpenGL on this display");
        XSetWindowAttributes at;
        char none[1] = { 0 };
        XColor black = { 0 };
        Pixmap blank = XCreateBitmapFromData(dpy, RootWindow(dpy, screen), none, 1, 1);
        at.override_redirect = True;     /* no window manager involved: straight on top, borderless */
        at.colormap = XCreateColormap(dpy, RootWindow(dpy, screen), vi->visual, AllocNone);
        at.background_pixel = at.border_pixel = 0;
        at.cursor = XCreatePixmapCursor(dpy, blank, blank, &black, &black, 0, 0);
        win = XCreateWindow(dpy, RootWindow(dpy, screen), 0, 0, DisplayWidth(dpy, screen), DisplayHeight(dpy, screen), 0,
                            vi->depth, InputOutput, vi->visual,
                            CWOverrideRedirect | CWColormap | CWBackPixel | CWBorderPixel | CWCursor, &at);
        XMapRaised(dpy, win);
        own_window = 1;
    }
    GLXContext ctx = vi ? glXCreateContext(dpy, vi, NULL, True) : NULL;
    if (!ctx || !glXMakeCurrent(dpy, win, ctx)) die("cannot start OpenGL on the window");
    if (strstr(glXQueryExtensionsString(dpy, screen), "GLX_EXT_swap_control")) {
        void (*interval)(Display *, GLXDrawable, int) =
            (void (*)(Display *, GLXDrawable, int))glXGetProcAddressARB((const GLubyte *)"glXSwapIntervalEXT");
        if (interval) interval(dpy, win, 1);
    }
}

static void window_size(int *width, int *height)
{
    XWindowAttributes wa;
    XGetWindowAttributes(dpy, win, &wa);
    *width = wa.width;
    *height = wa.height;
}

/* The monitors the window covers, as views in OpenGL's bottom-up coordinates; none when it is not our window. */
static int window_monitors(View *views, int height)
{
    int count = 0, n = 0;
    if (!own_window) return 0;
    XRRMonitorInfo *m = XRRGetMonitors(dpy, RootWindow(dpy, screen), True, &n);
    for (int i = 0; m && i < n && count < MAX_VIEWS; i++)
        if (m[i].width > 0 && m[i].height > 0)
            views[count++] = (View){ m[i].x, height - m[i].y - m[i].height, m[i].width, m[i].height };
    if (m) XRRFreeMonitors(m);
    return count;
}

static int window_alive(void) { return 1; }   /* whoever started it kills it */
static void window_show(void) { glXSwapBuffers(dpy, win); }

/* ---- the window: Windows ---- */
#elif defined(_WIN32)

static HWND window;
static HDC window_dc;
static int origin_x, origin_y, closing, mouse_seen;
static POINT mouse_start;

static double now(void)
{
    LARGE_INTEGER ticks, per_second;
    QueryPerformanceCounter(&ticks);
    QueryPerformanceFrequency(&per_second);
    return (double)ticks.QuadPart / (double)per_second.QuadPart;
}

static void nap(double seconds) { Sleep((DWORD)(seconds * 1000)); }

static LRESULT CALLBACK window_event(HWND w, UINT message, WPARAM wp, LPARAM lp)
{
    switch (message) {
    case WM_KEYDOWN: case WM_SYSKEYDOWN: case WM_LBUTTONDOWN: case WM_RBUTTONDOWN: case WM_MBUTTONDOWN:
    case WM_CLOSE: case WM_DESTROY:
        closing = 1;
        return 0;
    case WM_MOUSEMOVE: {   /* a window gets one of these just for appearing under the pointer, so only real movement counts */
        POINT p;
        GetCursorPos(&p);
        if (!mouse_seen) { mouse_start = p; mouse_seen = 1; }
        else if (abs(p.x - mouse_start.x) > 8 || abs(p.y - mouse_start.y) > 8) closing = 1;
        return 0;
    }
    case WM_SETCURSOR:
        SetCursor(NULL);
        return TRUE;
    case WM_ERASEBKGND:
        return 1;
    case WM_SYSCOMMAND:
        if ((wp & 0xFFF0) == SC_SCREENSAVE) return 0;   /* already running */
        break;
    }
    return DefWindowProcA(w, message, wp, lp);
}

static void window_open(int argc, char **argv, double *seconds)
{
    (void)seconds;
    /* Windows starts a screen saver with /s to run, /p <window> for the small preview, /c to configure */
    for (int i = 1; i < argc; i++) {
        const char *a = argv[i] + (argv[i][0] == '/' || argv[i][0] == '-');
        if (*a == 'p' || *a == 'P') exit(0);
        if (*a == 'c' || *a == 'C') {
            MessageBoxA(NULL, "Matrix has no settings.", "Matrix screen saver", MB_OK);
            exit(0);
        }
    }
    SetProcessDPIAware();
    WNDCLASSA wc = { 0 };
    wc.style = CS_OWNDC;
    wc.lpfnWndProc = window_event;
    wc.hInstance = GetModuleHandleA(NULL);
    wc.hbrBackground = (HBRUSH)GetStockObject(BLACK_BRUSH);
    wc.lpszClassName = "MatrixRain";
    RegisterClassA(&wc);
    origin_x = GetSystemMetrics(SM_XVIRTUALSCREEN);   /* one window over all the monitors */
    origin_y = GetSystemMetrics(SM_YVIRTUALSCREEN);
    window = CreateWindowExA(WS_EX_TOPMOST | WS_EX_TOOLWINDOW, "MatrixRain", "Matrix", WS_POPUP | WS_VISIBLE, origin_x, origin_y,
                             GetSystemMetrics(SM_CXVIRTUALSCREEN), GetSystemMetrics(SM_CYVIRTUALSCREEN), NULL, NULL, wc.hInstance, NULL);
    if (!window) die("cannot open a window");
    window_dc = GetDC(window);
    PIXELFORMATDESCRIPTOR want = { 0 };
    want.nSize = sizeof want;
    want.nVersion = 1;
    want.dwFlags = PFD_DRAW_TO_WINDOW | PFD_SUPPORT_OPENGL | PFD_DOUBLEBUFFER;
    want.iPixelType = PFD_TYPE_RGBA;
    want.cColorBits = 32;
    HGLRC gl = NULL;
    if (SetPixelFormat(window_dc, ChoosePixelFormat(window_dc, &want), &want)) gl = wglCreateContext(window_dc);
    if (!gl || !wglMakeCurrent(window_dc, gl)) die("cannot start OpenGL on the window");
#define X(ret, name, args) \
    name = (ret (APIENTRY *) args)(void *)wglGetProcAddress(#name); \
    if (!name) die("The graphics driver on this machine is too old for the Matrix screen saver (it needs OpenGL 3).");
    GL_FUNCTIONS
#undef X
    BOOL (WINAPI *interval)(int) = (BOOL (WINAPI *)(int))(void *)wglGetProcAddress("wglSwapIntervalEXT");
    if (interval) interval(1);
    SetForegroundWindow(window);
    SetFocus(window);
    ShowCursor(FALSE);
}

static void window_size(int *width, int *height)
{
    RECT r;
    GetClientRect(window, &r);
    *width = r.right;
    *height = r.bottom;
}

static View *found_views;
static int found_count, found_height;

static BOOL CALLBACK found_monitor(HMONITOR monitor, HDC dc, LPRECT r, LPARAM unused)
{
    (void)monitor; (void)dc; (void)unused;
    if (found_count < MAX_VIEWS && r->right > r->left && r->bottom > r->top)
        found_views[found_count++] = (View){ r->left - origin_x, found_height - (r->bottom - origin_y), r->right - r->left, r->bottom - r->top };
    return TRUE;
}

static int window_monitors(View *views, int height)
{
    found_views = views;
    found_count = 0;
    found_height = height;
    EnumDisplayMonitors(NULL, NULL, found_monitor, 0);
    return found_count;
}

static int window_alive(void)
{
    MSG m;
    while (PeekMessageA(&m, NULL, 0, 0, PM_REMOVE)) {
        if (m.message == WM_QUIT) closing = 1;
        TranslateMessage(&m);
        DispatchMessageA(&m);
    }
    return !closing;
}

static void window_show(void) { SwapBuffers(window_dc); }

/* ---- the window: macOS ---- */
#else

/* A window stays on the screen it was opened on, so every screen gets a process of its own: the first one
   starts a copy of itself, with --screen N, for each of the others, and they all end together. */
@interface RainWindow : NSWindow
@end
@implementation RainWindow
- (BOOL)canBecomeKeyWindow { return YES; }   /* a borderless window gets no key presses otherwise */
@end

static RainWindow *window;
static NSOpenGLContext *gl;
static pid_t others[MAX_VIEWS];
static int other_count;
extern char **environ;

static double now(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec * 1e-9;
}

static void nap(double seconds)
{
    struct timespec ts = { 0, (long)(seconds * 1e9) };
    nanosleep(&ts, NULL);
}

static void stop_others(void)
{
    for (int i = 0; i < other_count; i++) kill(others[i], SIGTERM);
}

static void stopped(int signal)
{
    (void)signal;
    stop_others();
    _exit(0);
}

static void window_open(int argc, char **argv, double *seconds)
{
    int which = -1;
    for (int i = 1; i < argc; i++) {
        const char *a = argv[i] + (argv[i][0] == '-' && argv[i][1] == '-');
        float *number = !strcmp(a, "-density") ? &density : !strcmp(a, "-speed") ? &speed : !strcmp(a, "-size") ? &glyph_size : NULL;
        if (!strcmp(a, "-fullscreen")) continue;
        else if (!strcmp(a, "-screen") && i + 1 < argc) which = atoi(argv[++i]);
        else if (!strcmp(a, "-seconds") && i + 1 < argc) *seconds = atof(argv[++i]);
        else if (number && i + 1 < argc) *number *= atof(argv[++i]);
        else die("usage: matrix-rain [--fullscreen] [--density F] [--size F] [--speed F] [--seconds N]");
    }
    if (density <= 0 || density > 8 || glyph_size < 0.02f || speed <= 0) die("--density, --size and --speed are factors around 1");

    [NSApplication sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];   /* no Dock icon, no menu bar */
    NSArray<NSScreen *> *screens = [NSScreen screens];
    if (screens.count == 0) die("no screen");
    if (which < 0) {
        char self[4096];
        uint32_t size = sizeof self;
        which = 0;
        if (_NSGetExecutablePath(self, &size) == 0) {
            for (int n = 1; n < (int)screens.count && other_count < MAX_VIEWS; n++) {
                char number[16], *args[64];
                int count = 0;
                snprintf(number, sizeof number, "%d", n);
                args[count++] = self;
                for (int i = 1; i < argc && count < 60; i++) args[count++] = argv[i];
                args[count++] = "--screen";
                args[count++] = number;
                args[count] = NULL;
                if (posix_spawn(&others[other_count], self, NULL, NULL, args, environ) == 0) other_count++;
            }
        }
        atexit(stop_others);
        signal(SIGTERM, stopped);
        signal(SIGINT, stopped);
    }
    if (which >= (int)screens.count) exit(0);

    window = [[RainWindow alloc] initWithContentRect:screens[which].frame styleMask:NSWindowStyleMaskBorderless
                                             backing:NSBackingStoreBuffered defer:NO];
    window.level = NSScreenSaverWindowLevel;
    window.opaque = YES;
    window.backgroundColor = [NSColor blackColor];
    window.hidesOnDeactivate = NO;
    window.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces | NSWindowCollectionBehaviorStationary |
                                NSWindowCollectionBehaviorFullScreenAuxiliary;
    [window setFrame:screens[which].frame display:YES];

    NSOpenGLPixelFormatAttribute wanted[] = { NSOpenGLPFADoubleBuffer, NSOpenGLPFAAccelerated, NSOpenGLPFAColorSize, 24, 0 };
    NSOpenGLPixelFormat *format = [[NSOpenGLPixelFormat alloc] initWithAttributes:wanted];
    if (!format) die("no OpenGL on this screen");
    gl = [[NSOpenGLContext alloc] initWithFormat:format shareContext:nil];
    if (!gl) die("cannot start OpenGL");
    NSView *view = window.contentView;
    [view setWantsBestResolutionOpenGLSurface:YES];   /* real pixels on a Retina screen, not doubled ones */
    [NSApp finishLaunching];
    [window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
    [gl setView:view];
    [gl makeCurrentContext];
    [gl update];
    GLint one = 1;
    [gl setValues:&one forParameter:NSOpenGLCPSwapInterval];
    [NSCursor hide];
}

static void window_size(int *width, int *height)
{
    NSView *view = window.contentView;
    NSRect pixels = [view convertRectToBacking:view.bounds];
    *width = (int)pixels.size.width;
    *height = (int)pixels.size.height;
    [gl update];   /* the surface follows the window, also when the screen changes resolution */
}

static int window_monitors(View *views, int height)
{
    (void)views; (void)height;
    return 0;   /* this process has one screen, and the window is exactly it */
}

static int window_alive(void)
{
    int status;
    @autoreleasepool {
        NSEvent *event;
        while ((event = [NSApp nextEventMatchingMask:NSEventMaskAny untilDate:nil inMode:NSDefaultRunLoopMode dequeue:YES])) {
            NSEventType type = event.type;
            if (type == NSEventTypeKeyDown || type == NSEventTypeLeftMouseDown || type == NSEventTypeRightMouseDown) return 0;
            [NSApp sendEvent:event];
        }
    }
    if (other_count && waitpid(-1, &status, WNOHANG) > 0) return 0;   /* closed on another screen: close here too */
    return 1;
}

static void window_show(void)
{
    @autoreleasepool { [gl flushBuffer]; }
}

#endif

int main(int argc, char **argv)
{
    double seconds = 0;
    window_open(argc, argv, &seconds);

    GLuint scene = program(scene_vs, scene_fs), bright = program(post_vs, bright_fs), blur = program(post_vs, blur_fs),
           final = program(post_vs, final_fs);
    glUseProgram(final);
    glUniform1i(glGetUniformLocation(final, "glow"), 1);
    glUniform1i(glGetUniformLocation(final, "haze"), 2);

    GLuint sheet, vbo;
    glGenTextures(1, &sheet);
    glBindTexture(GL_TEXTURE_2D, sheet);
    glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_LUMINANCE, GLYPHS_W, GLYPHS_H, 0, GL_LUMINANCE, GL_UNSIGNED_BYTE, glyphs);
    glGenerateMipmap(GL_TEXTURE_2D);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR_MIPMAP_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAX_LEVEL, 3);   /* smaller levels would smear neighbouring glyphs together */
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    glGenBuffers(1, &vbo);

    double start = now(), last = start;
    rng = hash((unsigned)time(NULL) ^ (unsigned)(start * 1e6));
    rain_init();

    Target full = { 0 }, half[2] = { { 0 } }, eighth[2] = { { 0 } };
    View views[MAX_VIEWS];
    int view_count = 0, width = 0, height = 0;
    float eye[3] = { 0, 0, 0 }, yaw = rnd() * 6.28f;

    for (int frame = 0; window_alive(); frame++) {
        if (frame % 120 == 0) {   /* the window may be resized, or monitors come and go */
            window_size(&width, &height);
            if (width < 1) width = 1;
            if (height < 1) height = 1;
            view_count = window_monitors(views, height);   /* its own picture on each monitor, not one stretched across them */
            if (!view_count) views[view_count++] = (View){ 0, 0, width, height };
            target(&full, width, height);
            for (int i = 0; i < 2; i++) {
                target(&half[i], (width + 1) / 2, (height + 1) / 2);
                target(&eighth[i], (width + 7) / 8, (height + 7) / 8);
            }
        }

        double t_now = now();
        float dt = (float)(t_now - last), t = (float)(t_now - start);
        last = t_now;
        if (dt > 0.1f) dt = 0.1f;
        if (seconds > 0 && t > seconds) return 0;

        /* The camera glides slowly straight ahead, level: no turning, tilting or bobbing. */
        const float pitch = 0, roll = 0;
        eye[0] += sinf(yaw) * 1.0f * speed * dt;
        eye[2] -= cosf(yaw) * 1.0f * speed * dt;
        rain_step(dt);

        glBindFramebuffer(GL_FRAMEBUFFER, full.fbo);
        glViewport(0, 0, width, height);
        glDisable(GL_SCISSOR_TEST);
        glClearColor(0, 0, 0, 1);
        glClear(GL_COLOR_BUFFER_BIT);
        glEnable(GL_BLEND);
        glBlendFunc(GL_ONE, GL_ONE);
        glEnable(GL_SCISSOR_TEST);
        glUseProgram(scene);
        glActiveTexture(GL_TEXTURE0);
        glBindTexture(GL_TEXTURE_2D, sheet);
        glBindBuffer(GL_ARRAY_BUFFER, vbo);
        for (int i = 0; i < 3; i++) glEnableVertexAttribArray(i);
        for (int v = 0; v < view_count; v++) {
            float m[16], view_yaw = yaw + v * 1.1f;   /* each monitor looks a different way from the same spot */
            camera_matrix(m, eye, view_yaw, pitch, roll, 1.15f, (float)views[v].w / views[v].h);
            rain_build(eye[0], eye[2], view_yaw, t);
            glBufferData(GL_ARRAY_BUFFER, sizeof(float) * FLOATS * vert_count, verts, GL_STREAM_DRAW);
            glVertexAttribPointer(0, 3, GL_FLOAT, GL_FALSE, sizeof(float) * FLOATS, (void *)0);
            glVertexAttribPointer(1, 2, GL_FLOAT, GL_FALSE, sizeof(float) * FLOATS, (void *)(sizeof(float) * 3));
            glVertexAttribPointer(2, 2, GL_FLOAT, GL_FALSE, sizeof(float) * FLOATS, (void *)(sizeof(float) * 5));
            glUniformMatrix4fv(glGetUniformLocation(scene, "mvp"), 1, GL_FALSE, m);
            glViewport(views[v].x, views[v].y, views[v].w, views[v].h);
            glScissor(views[v].x, views[v].y, views[v].w, views[v].h);
            glDrawArrays(GL_QUADS, 0, vert_count);
        }
        for (int i = 1; i < 3; i++) glDisableVertexAttribArray(i);
        glDisable(GL_SCISSOR_TEST);
        glDisable(GL_BLEND);

        /* glow: a tight blur at half size, and a wide soft one at an eighth */
        pass(bright, full.tex, &half[0], half[0].w, half[0].h, 0, 0);
        pass(blur, half[0].tex, &half[1], half[0].w, half[0].h, 1.0f / half[0].w, 0);
        pass(blur, half[1].tex, &half[0], half[0].w, half[0].h, 0, 1.0f / half[0].h);
        pass(blur, half[0].tex, &eighth[1], eighth[0].w, eighth[0].h, 1.0f / eighth[0].w, 0);
        pass(blur, eighth[1].tex, &eighth[0], eighth[0].w, eighth[0].h, 0, 1.0f / eighth[0].h);
        glActiveTexture(GL_TEXTURE1);
        glBindTexture(GL_TEXTURE_2D, half[0].tex);
        glActiveTexture(GL_TEXTURE2);
        glBindTexture(GL_TEXTURE_2D, eighth[0].tex);
        pass(final, full.tex, NULL, width, height, 0, 0);
        window_show();

        double spare = 1.0 / 60 - (now() - t_now);   /* where the driver does not wait for the monitor, do not spin */
        if (spare > 0.001) nap(spare);
    }
    return 0;
}
