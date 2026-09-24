// The immediate-mode core. This is docs/tla/ImmediateMode.tla made executable;
// read that first, and its README for why each guard is here.
//
// Three words of retained state -- `hot`, `active` and `focus` -- and every
// button, row and field in the application runs through them.
module ui

import win32

pub alias widget-id = int

pub val no-widget : widget-id = 0

pub value struct rect
  x : int
  y : int
  w : int
  h : int

pub fun contains( r : rect, px : int, py : int ) : bool
  px >= r.x && px < r.x + r.w && py >= r.y && py < r.y + r.h

// A widget identity. Stable across frames and unique within one -- the
// assumption ImmediateMode.tla makes and does not itself check. Collisions
// here are the classic immediate-mode bug: two widgets sharing an id fight
// over the capture.
pub fun wid( s : string ) : widget-id
  s.list.foldl(2166136261) fn(h, c)
    ((h * 31 + c.int) % 4294967296)

// An identity for the n-th row of a repeated list.
pub fun wid-at( s : string, n : int ) : widget-id
  wid(s ++ "#" ++ n.show)

pub struct ui
  // the widget that captured the press and is owed the release
  active   : widget-id
  // the widget under the cursor this frame
  hot      : widget-id
  // the widget the keyboard is talking to
  focus    : widget-id
  // Caret and selection for the focused field. `caret` is a character index;
  // `anchor` is where a selection started. Equal means no selection.
  // `caret-owner` says whose they are, so switching fields does not inherit
  // the last one's caret position.
  caret       : int
  anchor      : int
  caret-owner : widget-id
  // Where the press that claimed the focus actually landed. A field placing
  // its caret must use THIS, not the current cursor position -- by the time
  // the frame runs the mouse may have moved, and the caret would land
  // somewhere the user never clicked. Same lesson as ImmediateMode.tla's
  // depth-5 counterexample, one layer up.
  press-x     : int
  mx       : int
  my       : int
  // mouse events latched since the last frame, hit-tested per widget
  events   : list<win32/event>
  // printable characters to deliver this frame
  chars    : list<int>
  // virtual key codes (backspace, arrows, enter) to deliver this frame
  keys     : list<int>
  // who those keystrokes belong to: the focus as it was when they were typed,
  // which is NOT the focus that a click later in the same batch moves to
  key-target : widget-id
  // keystrokes held back because a click in the same batch is about to move
  // the focus -- see frame-begin
  deferred : list<win32/event>
  // the ids this frame actually built. Without it there is no way to notice
  // that the captured or focused widget is gone.
  present  : list<widget-id>
  // set when any release arrives this frame, so a capture is dropped even
  // when the release lands on no widget at all
  released : bool
  // True while building widgets that a modal is covering. They still declare
  // themselves (so `present` stays honest and captures are not wrongly
  // dropped) but take no input and never light up.
  inert    : bool
  wheel    : int
  fonts    : (int, int, int)
  // the one oversized face, for the numbers the dashboard leads with
  hero-font : int
  quitting : bool

pub fun new-ui( body : int, semi : int, small : int, hero : int ) : ui
  Ui(no-widget, no-widget, no-widget, 0, 0, no-widget, 0, 0, 0, [], [], [], no-widget,
     [], [], False, False, 0, (body, semi, small), hero, False)

pub fun font-body( u : ui ) : int
  u.fonts.fst
pub fun font-semi( u : ui ) : int
  u.fonts.snd
pub fun font-small( u : ui ) : int
  u.fonts.thd
pub fun font-hero( u : ui ) : int
  u.hero-font

// --- the frame ----------------------------------------------------------

fun is-mouse( e : win32/event ) : bool
  e.kind == win32/ev-mouse-down || e.kind == win32/ev-mouse-up ||
  e.kind == win32/ev-mouse-move || e.kind == win32/ev-scroll

fun is-key( e : win32/event ) : bool
  e.kind == win32/ev-char || e.kind == win32/ev-key-down

// Everything up to, but not including, the first mouse press.
fun before-first-press( evs : list<win32/event> ) : list<win32/event>
  match evs
    Nil -> []
    Cons(e, rest) ->
      if e.kind == win32/ev-mouse-down then []
      else Cons(e, before-first-press(rest))

fun from-first-press( evs : list<win32/event> ) : list<win32/event>
  match evs
    Nil -> []
    Cons(e, rest) ->
      if e.kind == win32/ev-mouse-down then evs
      else from-first-press(rest)

// Start a frame. `hot` and `present` are forgotten entirely; `active` and
// `focus` are the only things that survive.
//
// Keyboard input is resolved HERE, centrally, and never inside a widget.
// That is not a tidiness choice. Widgets each scan the whole event list, so a
// keystroke that arrives in the same batch as a click moving the focus would
// be delivered twice -- once by the field losing focus and once by the field
// gaining it. TLC finds the misdelivery as KeysGoWhereAimed under
// Bug="MouseThenKeys"; the double delivery is the same bug seen from the
// implementation side.
//
// The fix is to hold back any keystroke that follows a press in the same
// batch and deliver it on the next frame, once the focus has settled. It goes
// to the same field either way, just a frame later, and only in the rare case
// where a click and a keystroke land between the same two frames.
pub fun frame-begin( r : ref<global,ui>, latched : list<win32/event> ) : io ()
  val u = !r
  val evs = u.deferred ++ latched
  val safe = before-first-press(evs).filter(is-key)
  val held = from-first-press(evs).filter(is-key)
  val mice = evs.filter(is-mouse)
  val mx = mice.foldl(u.mx) fn(acc, e) { if e.kind == win32/ev-mouse-move then e.x else acc }
  val my = mice.foldl(u.my) fn(acc, e) { if e.kind == win32/ev-mouse-move then e.y else acc }
  val wheel = mice.foldl(0) fn(acc, e) { if e.kind == win32/ev-scroll then acc + e.code else acc }
  // A press anywhere clears the focus; a widget containing it claims it back
  // during the build. That is how clicking empty space lets a field go.
  val pressed = mice.any(fn(e) { e.kind == win32/ev-mouse-down })
  r := u(hot = no-widget, present = [], events = mice,
         chars = safe.filter(fn(e) { e.kind == win32/ev-char }).map(fn(e) { e.code }),
         keys = safe.filter(fn(e) { e.kind == win32/ev-key-down }).map(fn(e) { e.code }),
         // these were typed before any click in this batch, so they belong to
         // the focus on the way in -- not to whatever the click moves it to
         key-target = u.focus,
         deferred = held,
         focus = if pressed then no-widget else u.focus,
         mx = mx, my = my, wheel = wheel, released = False, inert = False,
         quitting = u.quitting || latched.any(fn(e) { e.kind == win32/ev-close }))

// End a frame. Three guards, all of which TLC showed are load-bearing:
//
//   - a release ends the capture even if it landed on nothing, or the widget
//     stays active forever;
//   - a capture whose widget was not built this frame is dropped, or the next
//     widget to reuse that id inherits a press the user never made
//     (ActiveIsPresent);
//   - a focus whose widget was not built this frame is dropped, or the next
//     frame's keystrokes are typed into a field nobody can see
//     (FocusIsPresent).
pub fun frame-end( r : ref<global,ui> ) : io ()
  val u = !r
  fun built( id : widget-id ) : bool
    u.present.any(fn(i) { i == id })
  val a = if u.released then no-widget
          elif u.active != no-widget && !built(u.active) then no-widget
          else u.active
  val f = if u.focus != no-widget && !built(u.focus) then no-widget else u.focus
  r := u(active = a, focus = f)

// --- the protocol -------------------------------------------------------

pub value struct behavior
  hovered : bool
  held    : bool
  clicked : bool
  // a press landed on this widget this frame, wherever it is released. A text
  // field places its caret on this, not on `clicked`, so dragging to select
  // starts from where the press went down.
  pressed : bool

// Apply() from the spec, for one widget. Mouse only -- keyboard is resolved
// centrally in frame-begin.
//
// Every event is hit-tested against the position IT carries, never against
// the cursor's current position. ImmediateMode.tla fails at depth 5 if you
// use the latter: press on empty space, drag onto a button, release, and the
// button fires.
pub fun behavior( r : ref<global,ui>, id : widget-id, box : rect ) : io behavior
  val u0 = !r
  r := u0(present = Cons(id, u0.present))
  if u0.inert then return Behavior(False, False, False, False)

  // hot is recomputed from scratch every frame
  if box.contains(u0.mx, u0.my) then
    val u = !r
    r := u(hot = id)

  var clicked := False
  var pressed := False
  u0.events.foreach fn(e)
    val u = !r
    if e.kind == win32/ev-mouse-down && box.contains(e.x, e.y) then
      // the press claims the keyboard too, which is how clicking into a
      // field focuses it, and records WHERE it landed so a text field can
      // put its caret there
      pressed := True
      r := u(focus = id, press-x = e.x,
             active = if u.active == no-widget then id else u.active)
    elif e.kind == win32/ev-mouse-up then
      r := u(released = True)
      // fires only if the release landed on the widget that took the press
      if u.active == id && box.contains(e.x, e.y) then clicked := True

  val u = !r
  Behavior(u.hot == id, u.active == id, clicked, pressed)

// A widget that only needs to exist and be hoverable -- a table row, say.
pub fun declare( r : ref<global,ui>, id : widget-id, box : rect ) : io behavior
  behavior(r, id, box)

pub fun is-hot( r : ref<global,ui>, id : widget-id ) : io bool
  (!r).hot == id

pub fun has-focus( r : ref<global,ui>, id : widget-id ) : io bool
  (!r).focus == id

pub fun set-focus( r : ref<global,ui>, id : widget-id ) : io ()
  val u = !r
  r := u(focus = id)

// The printable characters typed at this widget this frame. Empty unless it
// has focus, so a field can simply ask.
pub fun typed-chars( r : ref<global,ui>, id : widget-id ) : io list<int>
  val u = !r
  if u.key-target == id then u.chars else []

// The special keys (backspace, arrows, enter) aimed at this widget.
pub fun typed-keys( r : ref<global,ui>, id : widget-id ) : io list<int>
  val u = !r
  if u.key-target == id then u.keys else []

// Wheel movement this frame, in notches. Positive is away from the user.
pub fun wheel-notches( r : ref<global,ui> ) : io int
  val u = !r
  if u.inert then 0 else u.wheel / 120

// Everything drawn between these two takes no input: it is behind a modal.
// The widgets still declare themselves, so a capture or focus belonging to
// something underneath is not mistaken for a vanished widget.
pub fun begin-inert( r : ref<global,ui> ) : io ()
  val u = !r
  r := u(inert = True)

pub fun end-inert( r : ref<global,ui> ) : io ()
  val u = !r
  r := u(inert = False)

// Keystrokes reach a field only if it also has focus, so a modal's field is
// safe; but Escape is read globally, and must not fire while a modal is up
// unless the modal wants it.
pub fun escape-pressed( r : ref<global,ui> ) : io bool
  val u = !r
  if u.inert then False else u.keys.any(fn(k) { k == win32/key-escape })

// Are keystrokes being held back for the next frame? The loop must not go to
// sleep while any are owed.
pub fun has-deferred( r : ref<global,ui> ) : io bool
  !(!r).deferred.is-nil

// --- caret and selection ------------------------------------------------

pub val mod-shift = 0x10000
pub val mod-ctrl  = 0x20000

pub fun key-code( k : int ) : int
  k % 65536

pub fun has-shift( k : int ) : bool
  (k / mod-shift) % 2 == 1

pub fun has-ctrl( k : int ) : bool
  (k / mod-ctrl) % 2 == 1

pub fun caret-of( r : ref<global,ui>, id : widget-id, dflt : int ) : io int
  val u = !r
  if u.caret-owner == id then u.caret else dflt

pub fun anchor-of( r : ref<global,ui>, id : widget-id, dflt : int ) : io int
  val u = !r
  if u.caret-owner == id then u.anchor else dflt

// Give the caret to this widget, at `c`, collapsing any selection.
pub fun set-caret( r : ref<global,ui>, id : widget-id, c : int ) : io ()
  val u = !r
  r := u(caret-owner = id, caret = c, anchor = c)

// Move the caret, keeping the anchor if the selection is being extended.
pub fun move-caret( r : ref<global,ui>, id : widget-id, c : int, extend : bool ) : io ()
  val u = !r
  val a = if extend && u.caret-owner == id then u.anchor else c
  r := u(caret-owner = id, caret = c, anchor = a)

// Does this widget currently own the caret?
pub fun owns-caret( r : ref<global,ui>, id : widget-id ) : io bool
  (!r).caret-owner == id

// Where the press that claimed the focus landed, in screen pixels.
pub fun press-at( r : ref<global,ui> ) : io int
  (!r).press-x
