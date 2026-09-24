// Drawn widgets. All interaction goes through ui/behavior, which is the
// protocol ImmediateMode.tla verifies -- nothing here reimplements it.
module widgets

import win32
import ui
import theme
import util
import textfield

pub val radius = 6

// --- text ---------------------------------------------------------------

pub fun label( font : int, x : int, y : int, s : string, col : int ) : io ()
  win32/text(font, x, y + win32/font-ascent(font), s, col)
  ()

pub fun label-right( font : int, right : int, y : int, s : string, col : int ) : io ()
  label(font, right - win32/text-width(font, s), y, s, col)

pub fun label-center( font : int, x : int, w : int, y : int, s : string, col : int ) : io ()
  label(font, x + (w - win32/text-width(font, s)) / 2, y, s, col)

// Text cut to fit, with an ellipsis. A member's name must never bleed into
// the next column.
pub fun label-clipped( font : int, x : int, y : int, max-w : int, s : string, col : int ) : io ()
  if win32/text-width(font, s) <= max-w then label(font, x, y, s, col)
  else
    val e = "..."
    val budget = max-w - win32/text-width(font, e)
    label(font, x, y, fit(font, s, budget) ++ e, col)

// ponytail: drops one character at a time, so O(n) measurements per label.
// Fine for names and table cells; switch to a binary search if a long text
// column ever shows up in a profile.
fun fit( font : int, s : string, budget : int ) : io string
  fit-chars(font, s.list, budget)

fun fit-chars( font : int, cs : list<char>, budget : int ) : io string
  match cs
    Nil -> ""
    _ ->
      val t = cs.string
      if budget <= 0 then ""
      elif win32/text-width(font, t) <= budget then t
      else fit-chars(font, cs.init, budget)

// Vertically centre text in a box of height h, on the font's baseline.
pub fun label-in( font : int, x : int, y : int, h : int, s : string, col : int ) : io ()
  val line = win32/font-line(font)
  win32/text(font, x, y + (h - line) / 2 + win32/font-ascent(font), s, col)
  ()

// --- surfaces -----------------------------------------------------------

pub fun panel( p : theme/palette, b : rect ) : io ()
  win32/round-fill(b.x, b.y, b.w, b.h, radius, p.card)
  win32/round-border(b.x, b.y, b.w, b.h, radius, p.border)

pub fun separator( p : theme/palette, x : int, y : int, w : int ) : io ()
  win32/fill(x, y, w, 1, p.border)

// --- button -------------------------------------------------------------

pub fun button( r : ref<global,ui/ui>, p : theme/palette, b : rect,
                caption : string, id : ui/widget-id ) : io bool
  val act = ui/behavior(r, id, b)
  val bg = if act.held && act.hovered then p.btn-active
           elif act.hovered then p.btn-hover
           else p.btn
  win32/round-fill(b.x, b.y, b.w, b.h, radius, bg)
  win32/round-border(b.x, b.y, b.w, b.h, radius, p.border)
  val f = (!r).font-body
  label-center(f, b.x, b.w, b.y + (b.h - win32/font-line(f)) / 2, caption, p.text)
  act.clicked

// The one button on a dialog that commits. Accent fill, white text.
pub fun button-primary( r : ref<global,ui/ui>, p : theme/palette, b : rect,
                        caption : string, id : ui/widget-id ) : io bool
  val act = ui/behavior(r, id, b)
  val bg = if act.held && act.hovered then shade(p.accent, 78)
           elif act.hovered then shade(p.accent, 90)
           else p.accent
  win32/round-fill(b.x, b.y, b.w, b.h, radius, bg)
  val f = (!r).font-body
  label-center(f, b.x, b.w, b.y + (b.h - win32/font-line(f)) / 2, caption, 0xFFFFFFFF)
  act.clicked

// A destructive action reads as destructive before it is clicked, not after.
pub fun button-danger( r : ref<global,ui/ui>, p : theme/palette, b : rect,
                       caption : string, id : ui/widget-id ) : io bool
  val act = ui/behavior(r, id, b)
  val bg = if act.held && act.hovered then shade(theme/negative, 78)
           elif act.hovered then shade(theme/negative, 90)
           else theme/negative
  win32/round-fill(b.x, b.y, b.w, b.h, radius, bg)
  val f = (!r).font-body
  label-center(f, b.x, b.w, b.y + (b.h - win32/font-line(f)) / 2, caption, 0xFFFFFFFF)
  act.clicked

// Scale a colour's channels by pct/100, keeping alpha. Used for the pressed
// and hover steps of a filled button.
pub fun shade( col : int, pct : int ) : int
  val a = (col / 16777216) % 256
  val r = (col / 65536) % 256
  val g = (col / 256) % 256
  val b = col % 256
  a * 16777216 + (r * pct / 100) * 65536 + (g * pct / 100) * 256 + (b * pct / 100)

// --- sidebar navigation -------------------------------------------------

pub fun nav-item( r : ref<global,ui/ui>, p : theme/palette, b : rect,
                  caption : string, selected : bool, id : ui/widget-id ) : io bool
  val act = ui/behavior(r, id, b)
  if selected then win32/fill(b.x, b.y, b.w, b.h, p.nav-selected)
  elif act.hovered then win32/fill(b.x, b.y, b.w, b.h, p.nav-selected)
  if selected then win32/fill(b.x, b.y, 2, b.h, p.accent)
  val f = (!r).font-body
  val col = if selected then p.text else p.text-muted
  label-in(f, b.x + 12, b.y, b.h, caption, col)
  act.clicked

// --- status pill --------------------------------------------------------

// Paid / Due / Inactive, the three words the members list reads by.
pub fun pill( font : int, x : int, y : int, text : string, col : int ) : io ()
  val w = win32/text-width(font, text) + 16
  val h = win32/font-line(font) + 6
  win32/round-fill(x, y, w, h, h / 2, tint(col, 38))
  label(font, x + 8, y + 3, text, col)

// The same hue at low opacity over the current surface, for pill backgrounds.
pub fun tint( col : int, alpha : int ) : int
  alpha * 16777216 + (col % 16777216)

// --- text field ---------------------------------------------------------

// An editable single-line field. The caller owns the text; this returns the
// new value, which is how an immediate-mode field stays stateless. The caret
// and selection live in `ui`, keyed to whichever widget holds the focus.
//
// The editing rules are in textfield.kk and tested there directly; this
// function is the part that has to touch pixels and the mouse.
pub fun text-field( r : ref<global,ui/ui>, p : theme/palette, b : rect,
                    value : string, id : ui/widget-id,
                    placeholder : string ) : io string
  val act = ui/behavior(r, id, b)
  val focused = ui/has-focus(r, id)
  val f = (!r).font-body
  val pad = 8
  val vis = b.w - 2 * pad

  // How far the text is scrolled left, so the caret is always on screen. It
  // is recomputed from the caret rather than stored, which is why a field
  // needs no per-widget state to scroll: the only offset that matters is the
  // smallest one that keeps the caret inside the box. Without this a value
  // longer than the box -- a licence key, a long address -- is edited blind,
  // with the caret somewhere off the right edge.
  val was-scrolled = if ui/owns-caret(r, id)
                       then scroll-off(f, value, ui/caret-of(r, id, value.count), vis)
                       else 0

  // A click inside the field puts the caret where it landed, rather than
  // always at the end -- otherwise a typo in the middle of a name can only be
  // fixed by deleting everything after it.
  // Placed from the PRESS position, not the cursor's position now, and on
  // every press rather than only the first -- a second click has to be able
  // to move the caret somewhere else. The press is measured against the text
  // as it was drawn last frame, so it is offset by the scroll that was on
  // screen at the time, not the one that comes out of this frame.
  if act.pressed || (focused && !ui/owns-caret(r, id)) then
    ui/set-caret(r, id, textfield/index-at(f, value, ui/press-at(r) - b.x - pad + was-scrolled))

  val caret0 = ui/caret-of(r, id, value.count)
  val anchor0 = ui/anchor-of(r, id, caret0)

  // keys first, then characters, in the order they arrived
  val after-keys = ui/typed-keys(r, id).foldl(Edit(value, caret0, anchor0)) fn(e, k)
    textfield/apply-key-io(e, k)
  val edited = ui/typed-chars(r, id).foldl(after-keys) fn(e, c)
    textfield/apply-char(e, c)
  if focused then
    val u = !r
    r := u(caret-owner = id, caret = edited.caret, anchor = edited.anchor)

  val next = edited.text

  win32/round-fill(b.x, b.y, b.w, b.h, radius, p.faint)
  win32/round-border(b.x, b.y, b.w, b.h, radius, if focused then p.accent else p.border)

  win32/clip(b.x + 1, b.y + 1, b.w - 2, b.h - 2)
  val ty = b.y + (b.h - win32/font-line(f)) / 2
  val off = if focused then scroll-off(f, next, edited.caret, vis) else 0
  val tx = b.x + pad - off
  if next == "" && !focused then
    label(f, b.x + pad, ty, placeholder, p.text-muted)
  else
    // the selection is painted under the text, so the glyphs stay readable
    val sa = textfield/sel-start(edited.caret, edited.anchor)
    val sb = textfield/sel-end(edited.caret, edited.anchor)
    if focused && sa != sb then
      val x0 = tx + win32/text-width(f, next.list.take(sa).string)
      val x1 = tx + win32/text-width(f, next.list.take(sb).string)
      win32/fill(x0, b.y + 4, x1 - x0, b.h - 8, tint(p.accent, 110))
    label(f, tx, ty, next, p.text)

  if focused then
    val cx = tx + win32/text-width(f, next.list.take(edited.caret).string)
    win32/fill(cx, b.y + 5, 1, b.h - 10, p.text)
  win32/clip-all()
  next

// The smallest leftward shift that keeps the caret inside a field `vis` wide.
// Zero whenever the text up to the caret already fits, so a short value never
// scrolls and the field looks exactly as it did before.
fun scroll-off( font : int, s : string, caret : int, vis : int ) : io int
  val cx = win32/text-width(font, s.list.take(caret).string)
  int/max(0, cx - vis)

// Did the user press Enter in this field this frame?
pub fun submitted( r : ref<global,ui/ui>, id : ui/widget-id ) : io bool
  ui/typed-keys(r, id).any(fn(k) { ui/key-code(k) == win32/key-enter })

// Did the user press Escape anywhere this frame?
pub fun escaped( r : ref<global,ui/ui> ) : io bool
  (!r).keys.any(fn(k) { ui/key-code(k) == win32/key-escape })

// --- scroll area --------------------------------------------------------

pub val scrollbar-w = 10

// A vertically scrolling region. The caller owns the offset, as it owns every
// other piece of view state; `draw` is handed the y translation to apply.
//
// Returns the new offset, clamped so the content cannot be scrolled past
// either end however hard the wheel is spun.
pub fun scroll-area( r : ref<global,ui/ui>, p : theme/palette, b : rect,
                     content-h : int, offset : int,
                     draw : (int) -> io () ) : io int
  val over = b.contains((!r).mx, (!r).my)
  val max-off = int/max(0, content-h - b.h)
  val wheel = if over then ui/wheel-notches(r) * 48 else 0
  val next = util/clamp(offset - wheel, 0, max-off)

  win32/clip(b.x, b.y, b.w, b.h)
  draw(0 - next)
  win32/clip-all()

  // The bar is drawn only when there is something to scroll, so a short list
  // does not carry a decoration that implies hidden rows.
  if max-off > 0 then
    val track-h = b.h
    val thumb-h = int/max(24, track-h * b.h / content-h)
    val travel = track-h - thumb-h
    val ty = b.y + (if max-off == 0 then 0 else travel * next / max-off)
    val tx = b.x + b.w - scrollbar-w
    win32/round-fill(tx + 3, b.y, 4, track-h, 2, p.faint)
    win32/round-fill(tx + 2, ty, 6, thumb-h, 3, p.border-strong)
  next

// --- table --------------------------------------------------------------

// A column: its heading, its x offset within the table, and how wide the
// text may run before it is clipped with an ellipsis.
pub value struct column
  title : string
  x     : int
  w     : int

pub fun table-header( r : ref<global,ui/ui>, p : theme/palette,
                      ox : int, oy : int, w : int, cols : list<column> ) : io ()
  val f = (!r).font-small
  cols.foreach fn(c : column)
    label(f, ox + c.x, oy, c.title, p.text-muted)
  separator(p, ox, oy + 20, w)

pub val row-h = 40

// One table row. Returns its behaviour so the caller can react to a click,
// and stripes alternate rows so a wide row stays readable across the table.
pub fun table-row( r : ref<global,ui/ui>, p : theme/palette, b : rect,
                   n : int, id : ui/widget-id ) : io ui/behavior
  val act = ui/behavior(r, id, b)
  if act.hovered then win32/fill(b.x, b.y, b.w, b.h, p.btn-hover)
  elif n % 2 == 1 then win32/fill(b.x, b.y, b.w, b.h, p.faint)
  act

// Text in a table cell, clipped to the column so a long name never bleeds
// into the next column.
pub fun cell( r : ref<global,ui/ui>, c : column, ox : int, oy : int,
              s : string, col : int ) : io ()
  val f = (!r).font-body
  label-clipped(f, ox + c.x, oy + (row-h - win32/font-line(f)) / 2, c.w, s, col)

// What to show when a list is empty. An empty table with headings and no
// rows reads as broken; a sentence reads as "nothing here yet".
pub fun empty-state( r : ref<global,ui/ui>, p : theme/palette, b : rect,
                     title : string, hint : string ) : io ()
  val semi = (!r).font-semi
  val small = (!r).font-small
  label-center(semi, b.x, b.w, b.y + b.h / 2 - 18, title, p.text-muted)
  label-center(small, b.x, b.w, b.y + b.h / 2 + 6, hint, p.text-muted)

// --- modal --------------------------------------------------------------

// A centred dialog over a dimmed backdrop. The caller draws the background
// view first, wrapped in ui/begin-inert .. ui/end-inert, so nothing behind
// the dialog reacts to the mouse.
//
// Returns the dialog's content rectangle: title bar above, buttons below are
// the caller's to place.
pub fun modal-frame( r : ref<global,ui/ui>, p : theme/palette,
                     want-w : int, want-h : int, title : string ) : io rect
  val sw = win32/width()
  val sh = win32/height()
  // Clamp to the window. A dialog larger than the window hangs off the edge
  // with its Cancel button below the bottom, so there is no way to dismiss it
  // except Escape -- and nothing on screen says Escape works. Shrinking it
  // may crowd the content, which is a far smaller problem than a dialog the
  // user cannot close.
  val bw = int/min(want-w, sw - 24)
  val bh = int/min(want-h, sh - 24)
  win32/clip-all()
  win32/fill(0, 0, sw, sh, 0xA0000000)          // dim the app behind it
  val x = int/max(12, (sw - bw) / 2)
  val y = int/max(12, (sh - bh) / 2)
  win32/round-fill(x, y, bw, bh, 10, p.card)
  win32/round-border(x, y, bw, bh, 10, p.border-strong)
  label((!r).font-semi, x + 20, y + 18, title, p.text)
  separator(p, x + 1, y + 50, bw - 2)
  Rect(x, y, bw, bh)

// A row of buttons along the bottom of a dialog: cancel on the left of the
// commit, which is the Windows order.
pub fun modal-buttons( r : ref<global,ui/ui>, p : theme/palette, box : rect,
                       commit : string, id : string,
                       can-commit : bool ) : io (bool, bool)
  val by = box.y + box.h - 52
  separator(p, box.x + 1, by - 1, box.w - 2)
  val cancelled = button(r, p, Rect(box.x + box.w - 210, by + 10, 90, 32),
                         "Cancel", ui/wid(id ++ ":cancel"))
  val done = if can-commit
               then button-primary(r, p, Rect(box.x + box.w - 110, by + 10, 90, 32),
                                   commit, ui/wid(id ++ ":ok"))
               else
                 // A disabled commit says why it is disabled by staying put
                 // rather than vanishing, so the dialog does not reflow.
                 val b = Rect(box.x + box.w - 110, by + 10, 90, 32)
                 win32/round-fill(b.x, b.y, b.w, b.h, radius, p.btn)
                 label-center((!r).font-body, b.x, b.w,
                              b.y + (b.h - win32/font-line((!r).font-body)) / 2,
                              commit, p.text-muted)
                 False
  (done, cancelled)

// A labelled form row: caption on the left, control area returned.
// A tab in a strip. The chosen one is a raised card with a rule under it, so
// which list you are looking at is visible without reading the captions.
pub fun tab( r : ref<global,ui/ui>, p : theme/palette, b : rect, caption : string,
             chosen : bool, id : string ) : io bool
  val act = ui/behavior(r, ui/wid(id), b)
  if chosen then win32/round-fill(b.x, b.y, b.w, b.h, radius, p.card)
  elif act.hovered then win32/round-fill(b.x, b.y, b.w, b.h, radius, p.btn-hover)
  if chosen then win32/fill(b.x + 8, b.y + b.h - 2, b.w - 16, 2, p.accent)
  label-center((!r).font-body, b.x, b.w,
               b.y + (b.h - win32/font-line((!r).font-body)) / 2, caption,
               if chosen then p.text else p.text-muted)
  act.clicked

pub fun field-row( r : ref<global,ui/ui>, p : theme/palette, box : rect,
                   n : int, caption : string ) : io rect
  val y = box.y + 68 + n * 52
  label((!r).font-small, box.x + 20, y, caption, p.text-muted)
  Rect(box.x + 20, y + 18, box.w - 40, 30)

// --- dropdown -----------------------------------------------------------

// A closed dropdown shows the selection; an open one lists the options
// beneath it. The caller owns both the selection and the open flag, as it
// owns every other piece of view state.
//
// Returns (selected index, open). Drawn last by the caller so the open list
// paints over whatever is below it.
pub fun dropdown( r : ref<global,ui/ui>, p : theme/palette, b : rect,
                  options : list<string>, selected : int,
                  open : bool, id : string ) : io (int, bool)
  val act = ui/behavior(r, ui/wid(id), b)
  win32/round-fill(b.x, b.y, b.w, b.h, radius, if act.hovered then p.btn-hover else p.btn)
  win32/round-border(b.x, b.y, b.w, b.h, radius, if open then p.accent else p.border)
  val f = (!r).font-body
  val shown = options.drop(selected).head.default("")
  label(f, b.x + 10, b.y + (b.h - win32/font-line(f)) / 2, shown, p.text)
  chevron(b.x + b.w - 18, b.y + b.h / 2, p.text-muted)

  var pick := selected
  var still-open := if act.clicked then !open else open
  if still-open then
    val n = options.length
    val item-h = 28
    val list-h = n * item-h + 8
    val ly = b.y + b.h + 4
    win32/round-fill(b.x, ly, b.w, list-h, radius, p.card)
    win32/round-border(b.x, ly, b.w, list-h, radius, p.border-strong)
    options.foreach-indexed fn(i, opt)
      val ib = Rect(b.x + 4, ly + 4 + i * item-h, b.w - 8, item-h)
      val ia = ui/behavior(r, ui/wid(id ++ ":opt" ++ i.show), ib)
      if ia.hovered then win32/round-fill(ib.x, ib.y, ib.w, ib.h, 4, p.btn-hover)
      label(f, ib.x + 6, ib.y + (ib.h - win32/font-line(f)) / 2, opt,
            if i == selected then p.text else p.text-muted)
      if ia.clicked then
        pick := i
        still-open := False
  (pick, still-open)

fun chevron( vx : int, vy : int, col : int ) : io ()
  list(0, 3).foreach fn(i)
    win32/fill(vx - 3 + i, vy - 1 + (if i < 2 then i else 3 - i), 1, 1, col)
    win32/fill(vx - 3 + i, vy + (if i < 2 then i else 3 - i), 1, 1, col)

// --- checkbox -----------------------------------------------------------

pub fun checkbox( r : ref<global,ui/ui>, p : theme/palette, cx : int, cy : int,
                  caption : string, on : bool, id : string ) : io bool
  val f = (!r).font-body
  val cw = 18 + 8 + win32/text-width(f, caption)
  val b = Rect(cx, cy, cw, 20)
  val act = ui/behavior(r, ui/wid(id), b)
  val box = Rect(cx, cy + 1, 18, 18)
  if on then
    win32/round-fill(box.x, box.y, 18, 18, 4, p.accent)
    tick(box.x + 4, box.y + 9, 0xFFFFFFFF)
  else
    win32/round-fill(box.x, box.y, 18, 18, 4, p.faint)
    win32/round-border(box.x, box.y, 18, 18, 4, if act.hovered then p.border-strong else p.border)
  label(f, cx + 26, cy + (20 - win32/font-line(f)) / 2, caption, p.text)
  if act.clicked then !on else on

fun tick( tx : int, ty : int, col : int ) : io ()
  list(0, 2).foreach fn(i) { win32/fill(tx + i, ty + i, 2, 2, col) }
  list(0, 4).foreach fn(i) { win32/fill(tx + 2 + i, ty + 2 - i, 2, 2, col) }
