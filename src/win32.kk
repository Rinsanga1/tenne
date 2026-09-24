// The platform layer, as Koka sees it: a window, a backbuffer, and a queue of
// input events that each remember where they happened.
module win32

extern import
  c file "win32-inline.c"

// An input event. `x`/`y` are where the event occurred -- taken from the
// Win32 message, not from the cursor's position when we got round to reading
// it. ImmediateMode.tla shows why: a press applied at the cursor's *current*
// position fires buttons the user dragged onto but never pressed.
pub struct event
  kind : int
  x    : int
  y    : int
  code : int   // char, virtual key, or wheel delta

pub val ev-mouse-move = 1
pub val ev-mouse-down = 2
pub val ev-mouse-up   = 3
pub val ev-char       = 4
pub val ev-key-down   = 5
pub val ev-scroll     = 6
pub val ev-resize     = 7
pub val ev-close      = 8

pub val key-escape    = 27
pub val key-enter     = 13
pub val key-backspace = 8
pub val key-tab       = 9
pub val key-left      = 37
pub val key-up        = 38
pub val key-right     = 39
pub val key-down      = 40
pub val key-delete    = 46
pub val key-home      = 36
pub val key-end       = 35

extern open-window( title : string, w : int, h : int ) : io bool
  c "kk_plat_open"

// Drain the OS message queue into our ring. False once the app should stop.
pub extern pump() : io bool
  c "kk_plat_pump"

extern next-kind() : io int
  c "kk_plat_next"

extern ev-x() : io int
  c "kk_plat_ev_x"

extern ev-y() : io int
  c "kk_plat_ev_y"

extern ev-a() : io int
  c "kk_plat_ev_a"

pub extern width() : io int
  c "kk_plat_width"

pub extern height() : io int
  c "kk_plat_height"

pub extern quit() : io ()
  c "kk_plat_quit"

// Blit the backbuffer to the window.
pub extern present() : io ()
  c "kk_plat_present"

// Confine all subsequent drawing to this rectangle.
pub extern clip( x : int, y : int, w : int, h : int ) : io ()
  c "kk_plat_clip"

// Fill a rectangle. `col` is 0xAARRGGBB; alpha < 255 blends.
pub extern fill( x : int, y : int, w : int, h : int, col : int ) : io ()
  c "kk_plat_fill"

pub fun open( title : string, w : int, h : int ) : io bool
  open-window(title, w, h)

// Pop one event, or Nothing when the ring is empty.
pub fun next-event() : io maybe<event>
  val k = next-kind()
  if k == 0 then Nothing
  else Just(Event(k, ev-x(), ev-y(), ev-a()))

// Everything the platform latched since the last frame, in order. This is
// `pending` in ImmediateMode.tla, and the frame drains all of it.
pub fun drain() : io list<event>
  match next-event()
    Nothing -> []
    Just(e) -> Cons(e, drain())

pub fun clip-all() : io ()
  clip(0, 0, width(), height())

// Allocate a backbuffer with no window, so the renderer can be drawn and
// inspected without a screen. This is what makes the pixel tests runnable.
pub extern offscreen( w : int, h : int ) : io ()
  c "kk_plat_offscreen"

// Dump the backbuffer to a 24-bit BMP.
pub extern save-bmp( path : string ) : io bool
  c "kk_plat_save_bmp"

// --- text ---------------------------------------------------------------
// We do not parse TTF. Windows rasterises each glyph once; we own the atlas
// and do the blitting. Same bargain Handmade Hero struck.

// Make a font file usable without installing it system-wide.
pub extern font-file( path : string ) : io bool
  c "kk_plat_font_file"
  c "kk_plat_font_file"

// Open a font at a pixel size. weight 400 = regular, 600 = semibold.
pub extern font( family : string, px : int, weight : int ) : io int
  c "kk_plat_font"

// The face GDI actually gave us. Windows substitutes silently when a family
// name is wrong, so callers can compare and shout rather than ship the
// fallback font without noticing.
pub extern font-face( id : int ) : io string
  c "kk_plat_font_face"

pub extern font-ascent( id : int ) : io int
  c "kk_plat_font_ascent"

pub extern font-line( id : int ) : io int
  c "kk_plat_font_line"

pub extern text-width( id : int, s : string ) : io int
  c "kk_plat_text_width"

// Draw a string with its baseline at `y`. Returns the advance.
pub extern text( id : int, x : int, y : int, s : string, col : int ) : io int
  c "kk_plat_text"

// A rounded rectangle. `t` of 0 fills; anything else strokes a border of that
// width inwards. Corners are antialiased.
pub extern round-rect( x : int, y : int, w : int, h : int, r : int, t : int, col : int ) : io ()
  c "kk_plat_round_rect"

pub fun round-fill( x : int, y : int, w : int, h : int, r : int, col : int ) : io ()
  round-rect(x, y, w, h, r, 0, col)

pub fun round-border( x : int, y : int, w : int, h : int, r : int, col : int ) : io ()
  round-rect(x, y, w, h, r, 1, col)

// Local wall-clock time as "YYYY-MM-DD HH:MM:SS". The only impure part of
// dates; all the calendar arithmetic is pure Koka in dates.kk.
pub extern now-string() : io string
  c "kk_plat_now"

// --- files --------------------------------------------------------------

// The folder holding the running .exe. The database lives beside it, which
// is what makes the app portable.
pub extern exe-dir() : io string
  c "kk_plat_exe_dir"

pub extern mkdir( path : string ) : io bool
  c "kk_plat_mkdir"

pub extern rename( from : string, to : string ) : io bool
  c "kk_plat_rename"

extern listdir-raw( dir : string, pattern : string ) : io string
  c "kk_plat_listdir"

// File names in `dir` matching `pattern`, unsorted.
pub fun listdir( dir : string, pattern : string ) : io list<string>
  val names = listdir-raw(dir, pattern)
  if names == "" then [] else names.split(newline)

pub val newline : string = "\n"

pub extern copy-file( from : string, to : string ) : io bool
  c "kk_plat_copy"

// Size in bytes, or -1 if absent.
pub extern file-size( path : string ) : io int
  c "kk_plat_filesize"

pub extern write-text( path : string, body : string ) : io bool
  c "kk_plat_write_text"

pub extern read-text( path : string ) : io string
  c "kk_plat_read_text"

// Sleep until input arrives or `ms` elapses. Costs nothing while idle and
// adds no latency to a click.
pub extern wait( ms : int ) : io ()
  c "kk_plat_wait"

pub extern ticks() : io int
  c "kk_plat_ticks"

// Whatever is on the clipboard, with everything but printable ASCII stripped
// out. Empty if the clipboard holds no text, or is held open by another app.
//
// ASCII is not a shortcut here: the glyph atlas is built over 32..126 and
// draws nothing for anything outside it, so text this returns is exactly the
// text the renderer can show. The filter also takes out the newlines and tabs
// that would otherwise arrive in a single-line field.
pub extern clipboard() : io string
  c "kk_plat_clipboard"

pub extern set-clipboard( s : string ) : io bool
  c "kk_plat_set_clipboard"
