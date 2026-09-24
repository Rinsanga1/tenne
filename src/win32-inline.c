/*---------------------------------------------------------------------------
  Platform layer. Owns the window, the backbuffer, and the input ring.

  Everything above this file is Koka. This file exists because pixels and
  OS handles are the two things Koka cannot hold directly, and because a
  per-pixel FFI crossing would cost more than the drawing.

  Naming: Koka mangles module `win32` + function `f` to `kk_win32_f`, so the
  C side here is `kk_plat_*` and cannot collide.
---------------------------------------------------------------------------*/
#include <windows.h>
#include <windowsx.h>
#include <stdio.h>
#include <math.h>
#include <time.h>

#define PLAT_QCAP 512

/* Event kinds. Mirrored by the `ev-*` constants in win32.kk. */
enum {
  PLAT_NONE = 0,
  PLAT_MOUSEMOVE = 1,
  PLAT_MOUSEDOWN = 2,
  PLAT_MOUSEUP = 3,
  PLAT_CHAR = 4,
  PLAT_KEYDOWN = 5,
  PLAT_SCROLL = 6,
  PLAT_RESIZE = 7,
  PLAT_CLOSE = 8
};

/* Modifier bits OR-ed into a key event's code. */
#define PLAT_MOD_SHIFT 0x10000
#define PLAT_MOD_CTRL  0x20000

typedef struct PlatEvent {
  int kind;
  int x, y; /* where it happened -- see ImmediateMode.tla. Never GetCursorPos. */
  int a;    /* char code, virtual key, or wheel delta */
} PlatEvent;

static struct {
  HWND hwnd;
  BITMAPINFO bmi;
  void *pixels;
  int width, height;
  PlatEvent q[PLAT_QCAP];
  int qhead, qtail;
  PlatEvent cur;
  int running;
  /* clip rectangle, in pixels; all drawing is confined to it */
  int cx0, cy0, cx1, cy1;
} g;

/*-------------------------------------------------------------------------*/

static void plat_push(int kind, int x, int y, int a) {
  int next = (g.qtail + 1) % PLAT_QCAP;
  if (next == g.qhead) return; /* ring full: drop. Never block the wndproc. */
  g.q[g.qtail].kind = kind;
  g.q[g.qtail].x = x;
  g.q[g.qtail].y = y;
  g.q[g.qtail].a = a;
  g.qtail = next;
}

static void plat_resize(int w, int h) {
  if (w < 1) w = 1;
  if (h < 1) h = 1;
  if (g.pixels) VirtualFree(g.pixels, 0, MEM_RELEASE);
  g.width = w;
  g.height = h;
  ZeroMemory(&g.bmi, sizeof(g.bmi));
  g.bmi.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
  g.bmi.bmiHeader.biWidth = w;
  g.bmi.bmiHeader.biHeight = -h; /* negative = top-down, origin top-left */
  g.bmi.bmiHeader.biPlanes = 1;
  g.bmi.bmiHeader.biBitCount = 32;
  g.bmi.bmiHeader.biCompression = BI_RGB;
  g.pixels = VirtualAlloc(0, (SIZE_T)w * (SIZE_T)h * 4,
                          MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE);
  g.cx0 = 0; g.cy0 = 0; g.cx1 = w; g.cy1 = h;
}

static void plat_blit(HDC dc) {
  if (!g.pixels) return;
  StretchDIBits(dc, 0, 0, g.width, g.height, 0, 0, g.width, g.height,
                g.pixels, &g.bmi, DIB_RGB_COLORS, SRCCOPY);
}

static LRESULT CALLBACK plat_wndproc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
  switch (msg) {
    case WM_CLOSE:
      plat_push(PLAT_CLOSE, 0, 0, 0);
      return 0;

    case WM_DESTROY:
      g.running = 0;
      PostQuitMessage(0);
      return 0;

    case WM_SIZE: {
      int w = LOWORD(lp), h = HIWORD(lp);
      plat_resize(w, h);
      plat_push(PLAT_RESIZE, w, h, 0);
      return 0;
    }

    case WM_MOUSEMOVE:
      plat_push(PLAT_MOUSEMOVE, GET_X_LPARAM(lp), GET_Y_LPARAM(lp), 0);
      return 0;

    /* SetCapture so a drag that leaves the window still delivers its release.
       Without it the capture in ui.kk is never cleared and the widget stays
       active forever -- ActiveIsPresent, from the far side. */
    case WM_LBUTTONDOWN:
      SetCapture(hwnd);
      plat_push(PLAT_MOUSEDOWN, GET_X_LPARAM(lp), GET_Y_LPARAM(lp), 0);
      return 0;

    case WM_LBUTTONUP:
      ReleaseCapture();
      plat_push(PLAT_MOUSEUP, GET_X_LPARAM(lp), GET_Y_LPARAM(lp), 0);
      return 0;

    case WM_CHAR:
      plat_push(PLAT_CHAR, 0, 0, (int)wp);
      return 0;

    /* The modifier state is captured HERE, with the key, not polled when the
       frame drains the queue. Same principle as the mouse position in lParam:
       by drain time the user may have let go of shift, and the keystroke would
       be interpreted against a world that no longer exists. */
    case WM_KEYDOWN: {
      int mods = 0;
      if (GetKeyState(VK_SHIFT)   & 0x8000) mods |= PLAT_MOD_SHIFT;
      if (GetKeyState(VK_CONTROL) & 0x8000) mods |= PLAT_MOD_CTRL;
      plat_push(PLAT_KEYDOWN, 0, 0, (int)wp | mods);
      return 0;
    }

    /* WM_MOUSEWHEEL reports in screen coordinates, unlike every other mouse
       message. Convert, or scrolling targets the wrong panel. */
    case WM_MOUSEWHEEL: {
      POINT p;
      p.x = GET_X_LPARAM(lp);
      p.y = GET_Y_LPARAM(lp);
      ScreenToClient(hwnd, &p);
      plat_push(PLAT_SCROLL, p.x, p.y, GET_WHEEL_DELTA_WPARAM(wp));
      return 0;
    }

    /* Below this the header controls start to overlap, and overlapping
       widgets mean overlapping hit areas -- a click lands on whichever was
       built first, not the one under the cursor. Rather than degrade into
       something that misbehaves, refuse to get that small. */
    case WM_GETMINMAXINFO: {
      MINMAXINFO *mmi = (MINMAXINFO *)lp;
      mmi->ptMinTrackSize.x = 900;
      mmi->ptMinTrackSize.y = 560;
      return 0;
    }

    case WM_ERASEBKGND:
      return 1; /* we paint every pixel ourselves; let Windows skip it */

    case WM_PAINT: {
      PAINTSTRUCT ps;
      HDC dc = BeginPaint(hwnd, &ps);
      plat_blit(dc);
      EndPaint(hwnd, &ps);
      return 0;
    }
  }
  return DefWindowProcA(hwnd, msg, wp, lp);
}

/*--- exported to Koka -----------------------------------------------------*/

static bool kk_plat_open(kk_string_t title, kk_integer_t w, kk_integer_t h,
                         kk_context_t *ctx) {
  WNDCLASSEXA wc;
  kk_ssize_t len;
  const char *cs;
  int iw = kk_integer_clamp32(w, ctx);
  int ih = kk_integer_clamp32(h, ctx);
  RECT r;
  HINSTANCE inst = GetModuleHandleA(0);

  SetProcessDPIAware();

  ZeroMemory(&wc, sizeof(wc));
  wc.cbSize = sizeof(wc);
  wc.style = CS_HREDRAW | CS_VREDRAW | CS_OWNDC;
  wc.lpfnWndProc = plat_wndproc;
  wc.hInstance = inst;
  wc.hCursor = LoadCursorA(0, IDC_ARROW);
  wc.lpszClassName = "TenneKokaWindow";
  if (!RegisterClassExA(&wc)) { kk_string_drop(title, ctx); return false; }

  cs = kk_string_cbuf_borrow(title, &len, ctx);

  r.left = 0; r.top = 0; r.right = iw; r.bottom = ih;
  AdjustWindowRect(&r, WS_OVERLAPPEDWINDOW, FALSE);

  g.hwnd = CreateWindowExA(0, "TenneKokaWindow", cs, WS_OVERLAPPEDWINDOW,
                           CW_USEDEFAULT, CW_USEDEFAULT,
                           r.right - r.left, r.bottom - r.top,
                           0, 0, inst, 0);
  kk_string_drop(title, ctx);
  if (!g.hwnd) return false;

  plat_resize(iw, ih);
  g.running = 1;
  ShowWindow(g.hwnd, SW_SHOW);
  return true;
}

/* Drain the OS queue into our ring. Returns false once the app should stop. */
static bool kk_plat_pump(kk_context_t *ctx) {
  MSG msg;
  kk_unused(ctx);
  while (PeekMessageA(&msg, 0, 0, 0, PM_REMOVE)) {
    if (msg.message == WM_QUIT) g.running = 0;
    TranslateMessage(&msg);
    DispatchMessageA(&msg);
  }
  return g.running != 0;
}

/* Pop one event into `cur`; returns its kind, or 0 when the ring is empty. */
static kk_integer_t kk_plat_next(kk_context_t *ctx) {
  if (g.qhead == g.qtail) {
    g.cur.kind = PLAT_NONE;
    return kk_integer_from_int(PLAT_NONE, ctx);
  }
  g.cur = g.q[g.qhead];
  g.qhead = (g.qhead + 1) % PLAT_QCAP;
  return kk_integer_from_int(g.cur.kind, ctx);
}

static kk_integer_t kk_plat_ev_x(kk_context_t *ctx) { return kk_integer_from_int(g.cur.x, ctx); }
static kk_integer_t kk_plat_ev_y(kk_context_t *ctx) { return kk_integer_from_int(g.cur.y, ctx); }
static kk_integer_t kk_plat_ev_a(kk_context_t *ctx) { return kk_integer_from_int(g.cur.a, ctx); }
static kk_integer_t kk_plat_width(kk_context_t *ctx)  { return kk_integer_from_int(g.width, ctx); }
static kk_integer_t kk_plat_height(kk_context_t *ctx) { return kk_integer_from_int(g.height, ctx); }

static kk_unit_t kk_plat_quit(kk_context_t *ctx) {
  kk_unused(ctx);
  g.running = 0;
  return kk_Unit;
}

static kk_unit_t kk_plat_present(kk_context_t *ctx) {
  HDC dc;
  kk_unused(ctx);
  if (!g.hwnd) return kk_Unit;
  dc = GetDC(g.hwnd);
  plat_blit(dc);
  ReleaseDC(g.hwnd, dc);
  return kk_Unit;
}

/* Allocate a backbuffer with no window, so the renderer and the whole UI can
   be drawn and inspected without a screen. This is what makes the pixel tests
   runnable in CI, and the only reason it exists. */
static kk_unit_t kk_plat_offscreen(kk_integer_t w, kk_integer_t h,
                                   kk_context_t *ctx) {
  plat_resize(kk_integer_clamp32(w, ctx), kk_integer_clamp32(h, ctx));
  return kk_Unit;
}

/* Dump the backbuffer as a 24-bit BMP. Bottom-up, rows padded to 4 bytes. */
static bool kk_plat_save_bmp(kk_string_t path, kk_context_t *ctx) {
  kk_ssize_t len;
  const char *cs = kk_string_cbuf_borrow(path, &len, ctx);
  int stride = ((g.width * 3) + 3) & ~3;
  int imgsize = stride * g.height;
  int filesize = 54 + imgsize;
  unsigned char hdr[54];
  unsigned char *row;
  FILE *f;
  int x, y;

  if (!g.pixels) { kk_string_drop(path, ctx); return false; }
  f = fopen(cs, "wb");
  kk_string_drop(path, ctx);
  if (!f) return false;

  memset(hdr, 0, sizeof(hdr));
  hdr[0] = 'B'; hdr[1] = 'M';
  hdr[2] = (unsigned char)(filesize);       hdr[3] = (unsigned char)(filesize >> 8);
  hdr[4] = (unsigned char)(filesize >> 16); hdr[5] = (unsigned char)(filesize >> 24);
  hdr[10] = 54;
  hdr[14] = 40;
  hdr[18] = (unsigned char)(g.width);        hdr[19] = (unsigned char)(g.width >> 8);
  hdr[20] = (unsigned char)(g.width >> 16);  hdr[21] = (unsigned char)(g.width >> 24);
  hdr[22] = (unsigned char)(g.height);       hdr[23] = (unsigned char)(g.height >> 8);
  hdr[24] = (unsigned char)(g.height >> 16); hdr[25] = (unsigned char)(g.height >> 24);
  hdr[26] = 1;
  hdr[28] = 24;
  hdr[34] = (unsigned char)(imgsize);        hdr[35] = (unsigned char)(imgsize >> 8);
  hdr[36] = (unsigned char)(imgsize >> 16);  hdr[37] = (unsigned char)(imgsize >> 24);
  fwrite(hdr, 1, 54, f);

  row = (unsigned char *)calloc(1, (size_t)stride);
  if (!row) { fclose(f); return false; }
  for (y = g.height - 1; y >= 0; y--) {
    uint32_t *src = (uint32_t *)g.pixels + (size_t)y * (size_t)g.width;
    for (x = 0; x < g.width; x++) {
      uint32_t c = src[x];
      row[x * 3 + 0] = (unsigned char)(c & 0xFF);         /* B */
      row[x * 3 + 1] = (unsigned char)((c >> 8) & 0xFF);  /* G */
      row[x * 3 + 2] = (unsigned char)((c >> 16) & 0xFF); /* R */
    }
    fwrite(row, 1, (size_t)stride, f);
  }
  free(row);
  fclose(f);
  return true;
}

/*--- drawing --------------------------------------------------------------*/

static kk_unit_t kk_plat_clip(kk_integer_t x, kk_integer_t y,
                              kk_integer_t w, kk_integer_t h,
                              kk_context_t *ctx) {
  int x0 = kk_integer_clamp32(x, ctx), y0 = kk_integer_clamp32(y, ctx);
  int x1 = x0 + kk_integer_clamp32(w, ctx), y1 = y0 + kk_integer_clamp32(h, ctx);
  if (x0 < 0) x0 = 0;
  if (y0 < 0) y0 = 0;
  if (x1 > g.width) x1 = g.width;
  if (y1 > g.height) y1 = g.height;
  g.cx0 = x0; g.cy0 = y0; g.cx1 = x1; g.cy1 = y1;
  return kk_Unit;
}

static kk_unit_t kk_plat_fill(kk_integer_t x, kk_integer_t y,
                              kk_integer_t w, kk_integer_t h,
                              kk_integer_t col, kk_context_t *ctx) {
  int x0 = kk_integer_clamp32(x, ctx), y0 = kk_integer_clamp32(y, ctx);
  int x1 = x0 + kk_integer_clamp32(w, ctx), y1 = y0 + kk_integer_clamp32(h, ctx);
  uint32_t c = (uint32_t)(kk_integer_clamp64(col, ctx) & 0xFFFFFFFFll);
  uint32_t a = (c >> 24) & 0xFF;
  int px, py;

  if (!g.pixels) return kk_Unit;
  if (x0 < g.cx0) x0 = g.cx0;
  if (y0 < g.cy0) y0 = g.cy0;
  if (x1 > g.cx1) x1 = g.cx1;
  if (y1 > g.cy1) y1 = g.cy1;
  if (x0 >= x1 || y0 >= y1 || a == 0) return kk_Unit;

  for (py = y0; py < y1; py++) {
    uint32_t *row = (uint32_t *)g.pixels + (size_t)py * (size_t)g.width;
    if (a == 0xFF) {
      for (px = x0; px < x1; px++) row[px] = c;
    } else {
      uint32_t sr = (c >> 16) & 0xFF, sg = (c >> 8) & 0xFF, sb = c & 0xFF;
      for (px = x0; px < x1; px++) {
        uint32_t d = row[px];
        uint32_t dr = (d >> 16) & 0xFF, dg = (d >> 8) & 0xFF, db = d & 0xFF;
        uint32_t rr = (sr * a + dr * (255 - a)) / 255;
        uint32_t rg = (sg * a + dg * (255 - a)) / 255;
        uint32_t rb = (sb * a + db * (255 - a)) / 255;
        row[px] = 0xFF000000u | (rr << 16) | (rg << 8) | rb;
      }
    }
  }
  return kk_Unit;
}

/*--- text -----------------------------------------------------------------
  We do not parse TTF. Windows rasterises each glyph once into a scratch DIB;
  we keep the coverage in an atlas and do all the blitting ourselves. Same
  bargain Handmade Hero struck: let the OS do outline filling and hinting,
  own everything after that.
--------------------------------------------------------------------------*/

#define PLAT_G0 32
#define PLAT_G1 127
#define PLAT_NGLYPH (PLAT_G1 - PLAT_G0)
#define PLAT_MAXFONT 8

typedef struct PlatGlyph {
  int w, h, ox, oy, adv;
  unsigned char *cov; /* w*h coverage, 0..255 */
} PlatGlyph;

typedef struct PlatFont {
  HFONT hf;
  int height, ascent, linegap;
  char face[64];
  PlatGlyph g[PLAT_NGLYPH];
} PlatFont;

static PlatFont g_font[PLAT_MAXFONT];
static int g_nfont = 0;

static void plat_bake(PlatFont *f) {
  int pad = 4;
  int dim = f->height * 3 + pad * 4;
  HDC dc = CreateCompatibleDC(0);
  BITMAPINFO bi;
  void *bits = 0;
  HBITMAP bm;
  HGDIOBJ oldbm, oldfont;
  TEXTMETRICA tm;
  int ci;

  ZeroMemory(&bi, sizeof(bi));
  bi.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
  bi.bmiHeader.biWidth = dim;
  bi.bmiHeader.biHeight = -dim;
  bi.bmiHeader.biPlanes = 1;
  bi.bmiHeader.biBitCount = 32;
  bi.bmiHeader.biCompression = BI_RGB;
  bm = CreateDIBSection(dc, &bi, DIB_RGB_COLORS, &bits, 0, 0);
  oldbm = SelectObject(dc, bm);
  oldfont = SelectObject(dc, f->hf);
  SetBkMode(dc, OPAQUE);
  SetBkColor(dc, RGB(0, 0, 0));
  SetTextColor(dc, RGB(255, 255, 255));

  GetTextMetricsA(dc, &tm);
  f->ascent = tm.tmAscent;
  f->linegap = tm.tmHeight + tm.tmExternalLeading;
  GetTextFaceA(dc, sizeof(f->face), f->face);

  for (ci = 0; ci < PLAT_NGLYPH; ci++) {
    char ch = (char)(ci + PLAT_G0);
    SIZE sz;
    int x, y, minx = dim, miny = dim, maxx = -1, maxy = -1;
    PlatGlyph *gl = &f->g[ci];

    memset(bits, 0, (size_t)dim * (size_t)dim * 4);
    TextOutA(dc, pad, pad, &ch, 1);
    GetTextExtentPoint32A(dc, &ch, 1, &sz);
    gl->adv = sz.cx;

    for (y = 0; y < dim; y++) {
      uint32_t *row = (uint32_t *)bits + (size_t)y * (size_t)dim;
      for (x = 0; x < dim; x++) {
        if ((row[x] & 0xFF) != 0) {
          if (x < minx) minx = x;
          if (x > maxx) maxx = x;
          if (y < miny) miny = y;
          if (y > maxy) maxy = y;
        }
      }
    }
    if (maxx < 0) { gl->w = gl->h = 0; gl->cov = 0; gl->ox = gl->oy = 0; continue; }

    gl->w = maxx - minx + 1;
    gl->h = maxy - miny + 1;
    gl->ox = minx - pad;
    gl->oy = miny - pad;
    gl->cov = (unsigned char *)malloc((size_t)gl->w * (size_t)gl->h);
    for (y = 0; y < gl->h; y++) {
      uint32_t *row = (uint32_t *)bits + (size_t)(y + miny) * (size_t)dim;
      for (x = 0; x < gl->w; x++)
        gl->cov[y * gl->w + x] = (unsigned char)(row[x + minx] & 0xFF);
    }
  }

  SelectObject(dc, oldfont);
  SelectObject(dc, oldbm);
  DeleteObject(bm);
  DeleteDC(dc);
}

/* Make a private font file available without installing it system-wide. */
static bool kk_plat_font_file(kk_string_t path, kk_context_t *ctx) {
  kk_ssize_t len;
  const char *cs = kk_string_cbuf_borrow(path, &len, ctx);
  int n = AddFontResourceExA(cs, FR_PRIVATE, 0);
  kk_string_drop(path, ctx);
  return n > 0;
}

static kk_integer_t kk_plat_font(kk_string_t family, kk_integer_t px,
                                 kk_integer_t weight, kk_context_t *ctx) {
  kk_ssize_t len;
  const char *cs = kk_string_cbuf_borrow(family, &len, ctx);
  int id = g_nfont;
  PlatFont *f;

  if (id >= PLAT_MAXFONT) { kk_string_drop(family, ctx); return kk_integer_from_int(-1, ctx); }
  f = &g_font[id];
  memset(f, 0, sizeof(*f));
  f->height = kk_integer_clamp32(px, ctx);
  f->hf = CreateFontA(-f->height, 0, 0, 0, kk_integer_clamp32(weight, ctx),
                      FALSE, FALSE, FALSE, DEFAULT_CHARSET, OUT_TT_PRECIS,
                      CLIP_DEFAULT_PRECIS, ANTIALIASED_QUALITY,
                      DEFAULT_PITCH | FF_DONTCARE, cs);
  kk_string_drop(family, ctx);
  if (!f->hf) return kk_integer_from_int(-1, ctx);
  plat_bake(f);
  g_nfont++;
  return kk_integer_from_int(id, ctx);
}

/* The face GDI actually gave us. If a family name is wrong Windows silently
   substitutes, so the caller can compare and shout instead of shipping the
   fallback font. */
static kk_string_t kk_plat_font_face(kk_integer_t id, kk_context_t *ctx) {
  int i = kk_integer_clamp32(id, ctx);
  if (i < 0 || i >= g_nfont) return kk_string_empty();
  return kk_string_alloc_from_utf8(g_font[i].face, ctx);
}

static kk_integer_t kk_plat_font_ascent(kk_integer_t id, kk_context_t *ctx) {
  int i = kk_integer_clamp32(id, ctx);
  return kk_integer_from_int((i < 0 || i >= g_nfont) ? 0 : g_font[i].ascent, ctx);
}

static kk_integer_t kk_plat_font_line(kk_integer_t id, kk_context_t *ctx) {
  int i = kk_integer_clamp32(id, ctx);
  return kk_integer_from_int((i < 0 || i >= g_nfont) ? 0 : g_font[i].linegap, ctx);
}

static int plat_measure(PlatFont *f, const char *s, kk_ssize_t len) {
  int w = 0;
  kk_ssize_t i;
  for (i = 0; i < len; i++) {
    unsigned char c = (unsigned char)s[i];
    if (c < PLAT_G0 || c >= PLAT_G1) continue;
    w += f->g[c - PLAT_G0].adv;
  }
  return w;
}

static kk_integer_t kk_plat_text_width(kk_integer_t id, kk_string_t s,
                                       kk_context_t *ctx) {
  kk_ssize_t len;
  const char *cs = kk_string_cbuf_borrow(s, &len, ctx);
  int i = kk_integer_clamp32(id, ctx);
  int w = (i < 0 || i >= g_nfont) ? 0 : plat_measure(&g_font[i], cs, len);
  kk_string_drop(s, ctx);
  return kk_integer_from_int(w, ctx);
}

/* Draw a string with its baseline at `y`. Returns the advance. */
static kk_integer_t kk_plat_text(kk_integer_t id, kk_integer_t xi, kk_integer_t yi,
                                 kk_string_t s, kk_integer_t col,
                                 kk_context_t *ctx) {
  kk_ssize_t len, ci;
  const char *cs = kk_string_cbuf_borrow(s, &len, ctx);
  int i = kk_integer_clamp32(id, ctx);
  int pen = kk_integer_clamp32(xi, ctx);
  int base = kk_integer_clamp32(yi, ctx);
  uint32_t c = (uint32_t)(kk_integer_clamp64(col, ctx) & 0xFFFFFFFFll);
  uint32_t ca = (c >> 24) & 0xFF;
  uint32_t sr = (c >> 16) & 0xFF, sg = (c >> 8) & 0xFF, sb = c & 0xFF;
  int start = pen;

  if (i < 0 || i >= g_nfont || !g.pixels) { kk_string_drop(s, ctx); return kk_integer_from_int(0, ctx); }

  for (ci = 0; ci < len; ci++) {
    unsigned char ch = (unsigned char)cs[ci];
    PlatGlyph *gl;
    int gx, gy;
    if (ch < PLAT_G0 || ch >= PLAT_G1) continue;
    gl = &g_font[i].g[ch - PLAT_G0];
    if (gl->cov) {
      int ox = pen + gl->ox;
      int oy = base - g_font[i].ascent + gl->oy;
      for (gy = 0; gy < gl->h; gy++) {
        int py = oy + gy;
        uint32_t *row;
        if (py < g.cy0 || py >= g.cy1) continue;
        row = (uint32_t *)g.pixels + (size_t)py * (size_t)g.width;
        for (gx = 0; gx < gl->w; gx++) {
          int px = ox + gx;
          uint32_t a, d, dr, dg, db;
          if (px < g.cx0 || px >= g.cx1) continue;
          a = gl->cov[gy * gl->w + gx];
          if (a == 0) continue;
          a = (a * ca) / 255;
          if (a == 0) continue;
          d = row[px];
          dr = (d >> 16) & 0xFF; dg = (d >> 8) & 0xFF; db = d & 0xFF;
          row[px] = 0xFF000000u
                  | ((((sr * a + dr * (255 - a)) / 255) & 0xFF) << 16)
                  | ((((sg * a + dg * (255 - a)) / 255) & 0xFF) << 8)
                  | (((sb * a + db * (255 - a)) / 255) & 0xFF);
        }
      }
    }
    pen += gl->adv;
  }
  kk_string_drop(s, ctx);
  return kk_integer_from_int(pen - start, ctx);
}

/*--- rounded rectangles ---------------------------------------------------
  Signed-distance coverage: the distance from the pixel to the rect's inner
  core, minus the radius, antialiased over one pixel. `thick` of 0 fills;
  anything else strokes a border of that width inwards.
--------------------------------------------------------------------------*/

static double plat_rr_cov(double px, double py, double x0, double y0,
                          double x1, double y1, double r) {
  double cx = px < x0 + r ? x0 + r : (px > x1 - r ? x1 - r : px);
  double cy = py < y0 + r ? y0 + r : (py > y1 - r ? y1 - r : py);
  double dx = px - cx, dy = py - cy;
  double d = (dx == 0.0 && dy == 0.0) ? 0.0 : sqrt(dx * dx + dy * dy);
  double c = r - d + 0.5;
  if (x1 - x0 <= 0 || y1 - y0 <= 0) return 0.0;
  return c < 0.0 ? 0.0 : (c > 1.0 ? 1.0 : c);
}

static kk_unit_t kk_plat_round_rect(kk_integer_t xi, kk_integer_t yi,
                                    kk_integer_t wi, kk_integer_t hi,
                                    kk_integer_t ri, kk_integer_t ti,
                                    kk_integer_t col, kk_context_t *ctx) {
  int x = kk_integer_clamp32(xi, ctx), y = kk_integer_clamp32(yi, ctx);
  int w = kk_integer_clamp32(wi, ctx), h = kk_integer_clamp32(hi, ctx);
  int t = kk_integer_clamp32(ti, ctx);
  double r = (double)kk_integer_clamp32(ri, ctx);
  uint32_t c = (uint32_t)(kk_integer_clamp64(col, ctx) & 0xFFFFFFFFll);
  uint32_t ca = (c >> 24) & 0xFF;
  uint32_t sr = (c >> 16) & 0xFF, sg = (c >> 8) & 0xFF, sb = c & 0xFF;
  double x0 = x, y0 = y, x1 = x + w, y1 = y + h;
  double ir = r - (double)t;
  int px, py;
  int bx0 = x, by0 = y, bx1 = x + w, by1 = y + h;

  if (!g.pixels || ca == 0 || w <= 0 || h <= 0) return kk_Unit;
  if (r * 2.0 > (double)w) r = w / 2.0;
  if (r * 2.0 > (double)h) r = h / 2.0;
  if (ir < 0.0) ir = 0.0;
  if (bx0 < g.cx0) bx0 = g.cx0;
  if (by0 < g.cy0) by0 = g.cy0;
  if (bx1 > g.cx1) bx1 = g.cx1;
  if (by1 > g.cy1) by1 = g.cy1;

  for (py = by0; py < by1; py++) {
    uint32_t *row = (uint32_t *)g.pixels + (size_t)py * (size_t)g.width;
    for (px = bx0; px < bx1; px++) {
      double fx = px + 0.5, fy = py + 0.5;
      double cov = plat_rr_cov(fx, fy, x0, y0, x1, y1, r);
      uint32_t a, d, dr, dg, db;
      if (t > 0) {
        double inner = plat_rr_cov(fx, fy, x0 + t, y0 + t, x1 - t, y1 - t, ir);
        cov -= inner;
        if (cov < 0.0) cov = 0.0;
      }
      if (cov <= 0.0) continue;
      a = (uint32_t)(cov * (double)ca);
      if (a == 0) continue;
      d = row[px];
      dr = (d >> 16) & 0xFF; dg = (d >> 8) & 0xFF; db = d & 0xFF;
      row[px] = 0xFF000000u
              | ((((sr * a + dr * (255 - a)) / 255) & 0xFF) << 16)
              | ((((sg * a + dg * (255 - a)) / 255) & 0xFF) << 8)
              | (((sb * a + db * (255 - a)) / 255) & 0xFF);
    }
  }
  return kk_Unit;
}

/* Local wall-clock time as "YYYY-MM-DD HH:MM:SS". Everything else about
   dates is pure arithmetic in dates.kk; this is the only impure part. */
static kk_string_t kk_plat_now(kk_context_t *ctx) {
  time_t t = time(0);
  struct tm lt;
  char buf[32];
  localtime_s(&lt, &t);
  strftime(buf, sizeof(buf), "%Y-%m-%d %H:%M:%S", &lt);
  return kk_string_alloc_from_utf8(buf, ctx);
}

/*--- files ---------------------------------------------------------------*/

/* The folder holding the running .exe. The database lives beside it, which is
   what makes the app portable -- and is also why moving the .exe leaves the
   data behind. See docs/tla/README.md. */
static kk_string_t kk_plat_exe_dir(kk_context_t *ctx) {
  char buf[MAX_PATH];
  DWORD n = GetModuleFileNameA(0, buf, MAX_PATH);
  char *slash;
  if (n == 0 || n >= MAX_PATH) return kk_string_alloc_from_utf8(".", ctx);
  buf[n] = 0;
  slash = strrchr(buf, 92);  /* backslash */
  if (slash) *slash = 0;
  return kk_string_alloc_from_utf8(buf, ctx);
}

static bool kk_plat_mkdir(kk_string_t path, kk_context_t *ctx) {
  kk_ssize_t len;
  const char *cs = kk_string_cbuf_borrow(path, &len, ctx);
  BOOL ok = CreateDirectoryA(cs, 0);
  DWORD e = GetLastError();
  kk_string_drop(path, ctx);
  return ok || e == ERROR_ALREADY_EXISTS;
}

static bool kk_plat_rename(kk_string_t from, kk_string_t to, kk_context_t *ctx) {
  kk_ssize_t l1, l2;
  const char *a = kk_string_cbuf_borrow(from, &l1, ctx);
  const char *b = kk_string_cbuf_borrow(to, &l2, ctx);
  BOOL ok = MoveFileExA(a, b, MOVEFILE_REPLACE_EXISTING);
  kk_string_drop(from, ctx);
  kk_string_drop(to, ctx);
  return ok != 0;
}

/* Names matching `dir\pattern`, newline separated. A list<string> across the
   FFI would cost more code than splitting a string on the Koka side. */
static kk_string_t kk_plat_listdir(kk_string_t dir, kk_string_t pattern,
                                   kk_context_t *ctx) {
  kk_ssize_t l1, l2;
  const char *d = kk_string_cbuf_borrow(dir, &l1, ctx);
  const char *p = kk_string_cbuf_borrow(pattern, &l2, ctx);
  char glob[MAX_PATH];
  WIN32_FIND_DATAA fd;
  HANDLE h;
  char *out;
  size_t cap = 4096, used = 0;
  kk_string_t res;

  /* forward slash on purpose: Win32 accepts it, and it cannot be mangled by a
     shell heredoc the way an escaped backslash silently was. */
  snprintf(glob, sizeof(glob), "%s/%s", d, p);
  kk_string_drop(dir, ctx);
  kk_string_drop(pattern, ctx);
  out = (char *)malloc(cap);
  if (!out) return kk_string_empty();
  out[0] = 0;

  h = FindFirstFileA(glob, &fd);
  if (h != INVALID_HANDLE_VALUE) {
    do {
      size_t n = strlen(fd.cFileName);
      if (used + n + 2 > cap) {
        cap = (used + n + 2) * 2;
        out = (char *)realloc(out, cap);
        if (!out) return kk_string_empty();
      }
      if (used > 0) out[used++] = '\n';
      memcpy(out + used, fd.cFileName, n);
      used += n;
      out[used] = 0;
    } while (FindNextFileA(h, &fd));
    FindClose(h);
  }
  res = kk_string_alloc_from_utf8(out, ctx);
  free(out);
  return res;
}

static bool kk_plat_copy(kk_string_t from, kk_string_t to, kk_context_t *ctx) {
  kk_ssize_t l1, l2;
  const char *a = kk_string_cbuf_borrow(from, &l1, ctx);
  const char *b = kk_string_cbuf_borrow(to, &l2, ctx);
  BOOL ok = CopyFileA(a, b, FALSE);
  kk_string_drop(from, ctx);
  kk_string_drop(to, ctx);
  return ok != 0;
}

/* Size in bytes, or -1 if absent. Lets the UI show a backup's size, and lets a
   test tell an honest backup from an empty one. */
static kk_integer_t kk_plat_filesize(kk_string_t path, kk_context_t *ctx) {
  kk_ssize_t len;
  const char *cs = kk_string_cbuf_borrow(path, &len, ctx);
  WIN32_FILE_ATTRIBUTE_DATA fad;
  BOOL ok = GetFileAttributesExA(cs, GetFileExInfoStandard, &fad);
  kk_string_drop(path, ctx);
  if (!ok) return kk_integer_from_int(-1, ctx);
  return kk_integer_from_int64(((int64_t)fad.nFileSizeHigh << 32) | fad.nFileSizeLow, ctx);
}

static bool kk_plat_write_text(kk_string_t path, kk_string_t body, kk_context_t *ctx) {
  kk_ssize_t l1, l2;
  const char *p = kk_string_cbuf_borrow(path, &l1, ctx);
  const char *b = kk_string_cbuf_borrow(body, &l2, ctx);
  FILE *fp = fopen(p, "wb");
  bool ok = false;
  if (fp) {
    ok = (fwrite(b, 1, (size_t)l2, fp) == (size_t)l2);
    fclose(fp);
  }
  kk_string_drop(path, ctx);
  kk_string_drop(body, ctx);
  return ok;
}

static kk_string_t kk_plat_read_text(kk_string_t path, kk_context_t *ctx) {
  kk_ssize_t len;
  const char *p = kk_string_cbuf_borrow(path, &len, ctx);
  FILE *fp = fopen(p, "rb");
  char *buf;
  long n;
  kk_string_t res;
  kk_string_drop(path, ctx);
  if (!fp) return kk_string_empty();
  fseek(fp, 0, SEEK_END);
  n = ftell(fp);
  fseek(fp, 0, SEEK_SET);
  if (n < 0) { fclose(fp); return kk_string_empty(); }
  buf = (char *)malloc((size_t)n + 1);
  if (!buf) { fclose(fp); return kk_string_empty(); }
  n = (long)fread(buf, 1, (size_t)n, fp);
  buf[n] = 0;
  fclose(fp);
  res = kk_string_alloc_from_utf8(buf, ctx);
  free(buf);
  return res;
}

/* Sleep until input arrives or `ms` elapses, whichever comes first.
   MsgWaitForMultipleObjectsEx returns the instant a message is posted, so
   this costs nothing while idle and adds no latency to a click -- unlike a
   plain Sleep, which would trade one for the other. */
static kk_unit_t kk_plat_wait(kk_integer_t ms, kk_context_t *ctx) {
  DWORD t = (DWORD)kk_integer_clamp32(ms, ctx);
  /* No MWMO_INPUTAVAILABLE: that flag returns immediately when anything is
     already in the queue, which after a PeekMessage drain means it returns at
     once, every time, and the loop spins. We want to block until something
     NEW arrives. */
  MsgWaitForMultipleObjectsEx(0, NULL, t, QS_ALLINPUT, 0);
  return kk_Unit;
}

/* Milliseconds since boot, for frame pacing. */
static kk_integer_t kk_plat_ticks(kk_context_t *ctx) {
  return kk_integer_from_int64((int64_t)GetTickCount64(), ctx);
}

/* The clipboard, restricted to the printable ASCII a licence key is made of.
   Filtered rather than returned raw for two reasons: whatever the user last
   copied is arbitrary bytes, and handing invalid UTF-8 to Koka's string
   allocator is not something the caller can defend against. */
/* The clipboard is a single global lock, and any other program holding it --
   a clipboard manager, Explorer, the browser the key was copied from -- makes
   OpenClipboard fail outright. One attempt is not enough: a paste that
   silently does nothing is what the user sees. Retry briefly, then give up.

   ponytail: fixed 10x5ms ceiling, which is far longer than any real holder
   keeps it; if that is ever not true, the answer is a message loop, not a
   longer sleep. */
static bool kk_plat_clip_open(void) {
  int i;
  for (i = 0; i < 10; i++) {
    if (OpenClipboard(0)) return true;
    Sleep(5);
  }
  return false;
}

static kk_string_t kk_plat_clipboard(kk_context_t *ctx) {
  HANDLE h;
  const char *p;
  char buf[512];
  int n = 0;
  kk_string_t res;

  if (!kk_plat_clip_open()) return kk_string_empty();
  h = GetClipboardData(CF_TEXT);
  if (!h) { CloseClipboard(); return kk_string_empty(); }
  p = (const char *)GlobalLock(h);
  if (p) {
    int i;
    for (i = 0; p[i] && n < (int)sizeof(buf) - 1; i++) {
      unsigned char c = (unsigned char)p[i];
      if (c >= 0x20 && c < 0x7F) buf[n++] = (char)c;
    }
    GlobalUnlock(h);
  }
  buf[n] = 0;
  CloseClipboard();
  res = kk_string_alloc_from_utf8(buf, ctx);
  return res;
}

/* Put text on the clipboard, for Ctrl+C and Ctrl+X. The clipboard takes
   ownership of the handle on success, so it is only freed on the failure
   paths -- freeing it after a successful SetClipboardData is a double free
   that survives until some other program pastes. */
static bool kk_plat_set_clipboard(kk_string_t s, kk_context_t *ctx) {
  kk_ssize_t len;
  const char *cs = kk_string_cbuf_borrow(s, &len, ctx);
  HGLOBAL h;
  char *dst;
  bool ok = false;

  h = GlobalAlloc(GMEM_MOVEABLE, (SIZE_T)len + 1);
  if (h) {
    dst = (char *)GlobalLock(h);
    if (dst) {
      memcpy(dst, cs, (size_t)len);
      dst[len] = 0;
      GlobalUnlock(h);
      if (kk_plat_clip_open()) {
        EmptyClipboard();
        ok = (SetClipboardData(CF_TEXT, h) != 0);
        CloseClipboard();
      }
    }
    if (!ok) GlobalFree(h);
  }
  kk_string_drop(s, ctx);
  return ok;
}
