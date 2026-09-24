// An editable single-line field with a caret you can put where you like.
//
// Split out of widgets.kk because editing text is its own problem: the caret
// index, the selection, and the rule that every edit collapses a selection
// first. `widgets.kk` is layout and paint; this is the one widget with real
// behaviour behind it.
//
// Keyboard routing is ui/typed-chars and ui/typed-keys, which resolve focus
// centrally -- see ui.kk's frame-begin and ImmediateMode.tla's
// KeysGoWhereAimed for why a field must never scan the event list itself.
module textfield

import win32
import ui
import theme
import util

// Where a click at pixel `px` lands, as a character index. Walks the string
// measuring as it goes and takes the nearest boundary, so clicking the left
// half of a character puts the caret before it and the right half after --
// which is what every text box does and what people expect.
pub fun index-at( font : int, s : string, px : int ) : io int
  val cs = s.list
  nearest(font, cs, px, 0, 0, 0, 0)

fun nearest( font : int, cs : list<char>, px : int, i : int,
             prev-w : int, best-i : int, best-d : int ) : io int
  match cs
    Nil ->
      val d = int/abs(px - prev-w)
      if i == 0 || d < best-d then i else best-i
    Cons(c, rest) ->
      val d = int/abs(px - prev-w)
      val (bi, bd) = if i == 0 || d < best-d then (i, d) else (best-i, best-d)
      val w = prev-w + win32/text-width(font, c.string)
      nearest(font, rest, px, i + 1, w, bi, bd)

fun take-str( s : string, n : int ) : string
  s.list.take(n).string

fun drop-str( s : string, n : int ) : string
  s.list.drop(n).string

fun clamp-caret( c : int, len : int ) : int
  util/clamp(c, 0, len)

// The selected range as (from, to), ordered. Equal means no selection.
pub fun span( caret : int, anchor : int ) : (int, int)
  if caret < anchor then (caret, anchor) else (anchor, caret)

// --- the edit itself ----------------------------------------------------

// Applying one key or character to (text, caret, anchor).
//
// Every edit collapses a selection first: typing with text selected replaces
// it, which is the rule people rely on without thinking about it.
pub struct edit
  text   : string
  caret  : int
  anchor : int

fun cut-selection( e : edit ) : edit
  val (a, b) = span(e.caret, e.anchor)
  if a == b then e
  else Edit(take-str(e.text, a) ++ drop-str(e.text, b), a, a)

pub fun insert( e : edit, c : char ) : edit
  val g = cut-selection(e)
  val at = clamp-caret(g.caret, g.text.count)
  Edit(take-str(g.text, at) ++ c.string ++ drop-str(g.text, at), at + 1, at + 1)

// Paste. One insertion rather than a character at a time, so a pasted string
// is one edit and the caret lands after all of it.
pub fun insert-text( e : edit, s : string ) : edit
  if s == "" then e else
    val g = cut-selection(e)
    val at = clamp-caret(g.caret, g.text.count)
    val n = at + s.count
    Edit(take-str(g.text, at) ++ s ++ drop-str(g.text, at), n, n)

pub fun selected-text( e : edit ) : string
  val (a, b) = span(e.caret, e.anchor)
  e.text.list.drop(a).take(b - a).string

pub fun backspace( e : edit ) : edit
  val (a, b) = span(e.caret, e.anchor)
  if a != b then cut-selection(e)
  elif a == 0 then e
  else Edit(take-str(e.text, a - 1) ++ drop-str(e.text, a), a - 1, a - 1)

pub fun delete-forward( e : edit ) : edit
  val (a, b) = span(e.caret, e.anchor)
  if a != b then cut-selection(e)
  elif a >= e.text.count then e
  else Edit(take-str(e.text, a) ++ drop-str(e.text, a + 1), a, a)

// Arrow keys. Without shift, a collapse moves to the edge of the selection
// rather than one character from the caret -- pressing Left with text
// selected should land at the start of it, not inside it.
pub fun move-left( e : edit, extend : bool ) : edit
  val (a, b) = span(e.caret, e.anchor)
  if extend then Edit(e.text, clamp-caret(e.caret - 1, e.text.count), e.anchor)
  elif a != b then Edit(e.text, a, a)
  else
    val c = clamp-caret(e.caret - 1, e.text.count)
    Edit(e.text, c, c)

pub fun move-right( e : edit, extend : bool ) : edit
  val (a, b) = span(e.caret, e.anchor)
  if extend then Edit(e.text, clamp-caret(e.caret + 1, e.text.count), e.anchor)
  elif a != b then Edit(e.text, b, b)
  else
    val c = clamp-caret(e.caret + 1, e.text.count)
    Edit(e.text, c, c)

pub fun move-home( e : edit, extend : bool ) : edit
  Edit(e.text, 0, if extend then e.anchor else 0)

pub fun move-end( e : edit, extend : bool ) : edit
  val n = e.text.count
  Edit(e.text, n, if extend then e.anchor else n)

pub fun select-all( e : edit ) : edit
  Edit(e.text, e.text.count, 0)

// Does this key need the clipboard read before it can be applied? Asked so
// that a paste is the only keystroke that touches the platform clipboard --
// opening it on every letter typed would be absurd, and it can fail.
pub fun wants-paste( k : int ) : bool
  ui/has-ctrl(k) && ui/key-code(k) == 'V'.int

// Apply one key event. Unknown keys leave the edit untouched.
//
// Returns the new edit and whatever the key asked to be put on the clipboard,
// which is "" for every key but a copy or a cut. The clipboard is passed in
// and handed back rather than read and written here, so this whole module
// stays a pure function of its inputs: the machine's clipboard is global
// mutable state shared with every other program on the computer, and a test
// that reads it is a test that fails when the person running it copies
// something.
pub fun apply-key( e : edit, k : int, clip : string ) : (edit, string)
  val code = ui/key-code(k)
  val shift = ui/has-shift(k)
  val ctrl = ui/has-ctrl(k)
  if ctrl && code == 'A'.int then (select-all(e), "")
  elif ctrl && code == 'C'.int then
    // Copying an empty selection must not wipe what is already on the
    // clipboard -- Ctrl+C with nothing selected is a no-op everywhere else.
    (e, selected-text(e))
  elif ctrl && code == 'X'.int then
    val sel = selected-text(e)
    if sel == "" then (e, "") else (cut-selection(e), sel)
  elif ctrl && code == 'V'.int then (insert-text(e, clip), "")
  elif code == win32/key-backspace then (backspace(e), "")
  elif code == win32/key-delete then (delete-forward(e), "")
  elif code == win32/key-left then (move-left(e, shift), "")
  elif code == win32/key-right then (move-right(e, shift), "")
  elif code == win32/key-home then (move-home(e, shift), "")
  elif code == win32/key-end then (move-end(e, shift), "")
  else (e, "")

// The same rule, wired to the real clipboard. This is the thin shell that the
// widget calls; everything above it is testable without a machine.
pub fun apply-key-io( e : edit, k : int ) : io edit
  val clip = if wants-paste(k) then win32/clipboard() else ""
  val (g, copy) = apply-key(e, k, clip)
  if copy != "" then win32/set-clipboard(copy).ignore
  g

// WM_CHAR delivers control codes too; backspace and delete are handled as
// keys above, and Enter/Tab are the caller's business.
pub fun apply-char( e : edit, c : int ) : edit
  if c >= 32 && c != 127 then insert(e, c.char) else e

// span() as two plain functions. Destructuring its tuple inside a nested
// branch that also touches outer values tripped a Koka 3.2.3 miscompilation
// (a segfault while drawing the selection), so the widget uses these.
pub fun sel-start( caret : int, anchor : int ) : int
  if caret < anchor then caret else anchor

pub fun sel-end( caret : int, anchor : int ) : int
  if caret < anchor then anchor else caret
