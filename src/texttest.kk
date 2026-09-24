// Caret and selection: the editing rules directly, then the same rules driven
// through the real widget with synthetic clicks and keystrokes.
module texttest

import win32
import ui
import theme
import widgets
import textfield
import util

fun chk( name : string, got : string, want : string ) : io int
  val ok = got == want
  println((if ok then "  ok   " else "  FAIL ") ++ name.pad-right(50) ++ got.pad-right(16) ++
          (if ok then "" else "want " ++ want))
  if ok then 0 else 1

// Render an edit as text with the caret as | and a selection in [brackets],
// so a failure reads as the thing a person would see.
fun draw( e : textfield/edit ) : string
  val (a, b) = textfield/span(e.caret, e.anchor)
  val cs = e.text.list
  if a == b then cs.take(a).string ++ "|" ++ cs.drop(a).string
  else cs.take(a).string ++ "[" ++ cs.drop(a).take(b - a).string ++ "]" ++ cs.drop(b).string

fun keys( e : textfield/edit, ks : list<int> ) : textfield/edit
  ks.foldl(e, fn(acc, k) { textfield/apply-key(acc, k, "").fst })

// The same, with something on the clipboard, and reporting what was put back
// onto it. The clipboard is a value here, not the machine's.
fun keys-clip( e : textfield/edit, ks : list<int>, clip : string ) : (textfield/edit, string)
  ks.foldl((e, clip)) fn(acc : (textfield/edit, string), k)
    val (g, copied) = textfield/apply-key(acc.fst, k, acc.snd)
    (g, if copied != "" then copied else acc.snd)

fun ctrl( k : int ) : int
  k + ui/mod-ctrl

fun types( e : textfield/edit, s : string ) : textfield/edit
  s.list.foldl(e, fn(acc, c) { textfield/apply-char(acc, c.int) })

val k-left = win32/key-left
val k-right = win32/key-right
val k-home = win32/key-home
val k-end = win32/key-end
val k-back = win32/key-backspace
val k-del = win32/key-delete
fun shift( k : int ) : int
  k + ui/mod-shift

pub fun main() : io ()
  val f = rules() + clipboard-rules() + through-the-widget()
  println(if f == 0 then "ALL PASS" else "FAILED: " ++ f.show)

// Ctrl+C, Ctrl+X and Ctrl+V. Their absence is why the licence dialog needed a
// Paste button: a 133-character key cannot be typed, and without these it
// could not be pasted either.
//
// The machine's own clipboard is deliberately never touched here. An earlier
// version of these cases used it and failed halfway through a verify run,
// because the person running it copied something -- and its tidy-up would
// have overwritten what they copied.
fun clipboard-rules() : io int
  println("-- the clipboard")
  val at-end = Edit("Priya", 5, 5)

  // copy the last two characters, then paste them at the end
  val (copied, board) = keys-clip(at-end, [shift(k-left), shift(k-left), ctrl('C'.int)], "")
  val x1 = chk("ctrl+C leaves the text alone", draw(copied), "Pri[ya]")
  val x2 = chk("and offers the selection to the clipboard", board, "ya")
  val x3 = chk("ctrl+V pastes over the selection",
               draw(keys-clip(copied, [ctrl('V'.int)], board).fst), "Priya|")
  val x4 = chk("ctrl+V at the caret inserts",
               draw(keys-clip(at-end, [ctrl('V'.int)], "ya").fst), "Priyaya|")

  val (cut, board2) = keys-clip(at-end, [shift(k-home), ctrl('X'.int)], "")
  val x5 = chk("ctrl+X removes the selection", draw(cut), "|")
  val x6 = chk("and offers it to the clipboard", board2, "Priya")
  val x7 = chk("ctrl+V puts it back", draw(keys-clip(cut, [ctrl('V'.int)], board2).fst), "Priya|")

  // Ctrl+C with nothing selected must not wipe the clipboard -- that is what
  // it does in every other program, and losing a copy to a stray keypress is
  // the kind of thing people never forgive. The rule returns "" for the copy,
  // and the shell only writes when it is not "".
  val x8 = chk("ctrl+C with no selection copies nothing",
               textfield/apply-key(Edit("Priya", 2, 2), ctrl('C'.int), "").snd, "")
  val x9 = chk("ctrl+X with no selection copies nothing",
               textfield/apply-key(Edit("Priya", 2, 2), ctrl('X'.int), "").snd, "")
  val x10 = chk("and ctrl+X with no selection changes nothing",
                draw(textfield/apply-key(Edit("Priya", 2, 2), ctrl('X'.int), "").fst), "Pr|iya")

  // Pasting into a selection replaces it, like typing does.
  val x11 = chk("paste replaces a selection",
                draw(keys-clip(textfield/select-all(at-end), [ctrl('V'.int)], "Zo").fst), "Zo|")
  val x12 = chk("pasting nothing does nothing",
                draw(keys-clip(at-end, [ctrl('V'.int)], "").fst), "Priya|")

  x1+x2+x3+x4+x5+x6+x7+x8+x9+x10+x11+x12

fun rules() : io int
  println("-- the editing rules")
  val at-end = Edit("Priya", 5, 5)

  val e1 = chk("caret starts at the end", draw(at-end), "Priya|")
  val e2 = chk("left moves back one", draw(keys(at-end, [k-left])), "Priy|a")
  val e3 = chk("home goes to the start", draw(keys(at-end, [k-home])), "|Priya")
  val e4 = chk("end goes back to the end", draw(keys(at-end, [k-home, k-end])), "Priya|")
  val e5 = chk("left stops at the start", draw(keys(at-end, [k-home, k-left, k-left])), "|Priya")
  val e6 = chk("right stops at the end", draw(keys(at-end, [k-right, k-right])), "Priya|")

  // The point of the whole feature: fix a typo in the middle without
  // destroying everything after it.
  val typo = Edit("Priyya", 6, 6)
  val e7 = chk("insert in the middle",
               draw(types(keys(Edit("Prya", 4, 4), [k-left, k-left]), "i")), "Pri|ya")
  // one left puts the caret between the two y's; backspace removes the stray
  val e8 = chk("backspace in the middle",
               draw(keys(typo, [k-left, k-back])), "Priy|a")
  val e9 = chk("delete forward in the middle",
               draw(keys(typo, [k-home, k-right, k-right, k-right, k-del])), "Pri|ya")
  val e10 = chk("backspace at the start does nothing",
                draw(keys(at-end, [k-home, k-back])), "|Priya")
  val e11 = chk("delete at the end does nothing",
                draw(keys(at-end, [k-del])), "Priya|")

  println("-- selection")
  val e12 = chk("shift+left selects backwards",
                draw(keys(at-end, [shift(k-left), shift(k-left)])), "Pri[ya]")
  val e13 = chk("shift+home selects to the start",
                draw(keys(at-end, [shift(k-home)])), "[Priya]")
  val e14 = chk("ctrl+A selects everything",
                draw(textfield/select-all(at-end)), "[Priya]")
  val e15 = chk("typing replaces the selection",
                draw(types(keys(at-end, [shift(k-left), shift(k-left)]), "sha")), "Prisha|")
  val e16 = chk("backspace deletes the selection",
                draw(keys(at-end, [shift(k-left), shift(k-left), k-back])), "Pri|")
  val e17 = chk("delete deletes the selection",
                draw(keys(at-end, [shift(k-home), k-del])), "|")
  // Left with a selection collapses to its START, not one back from the caret.
  val e18 = chk("left collapses a selection to its start",
                draw(keys(at-end, [shift(k-left), shift(k-left), k-left])), "Pri|ya")
  val e19 = chk("right collapses a selection to its end",
                draw(keys(at-end, [shift(k-home), k-right])), "Priya|")
  val e20 = chk("select all then type replaces everything",
                draw(types(textfield/select-all(at-end), "Zo")), "Zo|")

  e1+e2+e3+e4+e5+e6+e7+e8+e9+e10+e11+e12+e13+e14+e15+e16+e17+e18+e19+e20

// The same behaviour, but driven the way a person drives it: a click to place
// the caret, then keys. This is what proves the widget wires the rules up.
fun through-the-widget() : io int
  println("-- through the real widget")
  win32/offscreen(400, 100)
  win32/font-file("assets/fonts/Geist-Regular.ttf").ignore
  val font = win32/font("Geist", 14, 400)
  val r = ref(ui/new-ui(font, font, font, font))
  val p = theme/palette-of("dark")
  val box = Rect(10, 10, 300, 32)
  val id = ui/wid("f")

  // click at the far right to focus and put the caret at the end
  val v1 = run(r, p, box, id, "Priyya", [down(300, 26), up(300, 26)])
  val c1 = chk("clicking past the text puts the caret at the end",
               ui/caret-of(r, id, -1).show, "6")

  // now click between the two y's. Measure where that is.
  val px = 10 + 8 + win32/text-width(font, "Priy")
  val v2 = run(r, p, box, id, "Priyya", [down(px, 26), up(px, 26)])
  val c2 = chk("clicking mid-string puts the caret there",
               ui/caret-of(r, id, -1).show, "4")

  // one backspace removes the stray y and leaves the rest alone
  val v3 = run(r, p, box, id, "Priyya", [key(k-back)])
  val c3 = chk("backspace removes only the character before the caret", v3, "Priya")
  val c4 = chk("and the caret stayed where it was", ui/caret-of(r, id, -1).show, "3")

  // typing inserts at the caret rather than appending
  val v4 = run(r, p, box, id, v3, [ch('n')])
  val c5 = chk("typing inserts at the caret", v4, "Prinya")

  // select to the start and replace
  val v5 = run(r, p, box, id, v4, [key(shift(k-home))])
  val c6 = chk("shift+home selected to the start", ui/anchor-of(r, id, -1).show, "4")
  val v6 = run(r, p, box, id, v5, [ch('Z')])
  // the selection was "Prin" (0..4), so replacing it leaves "Zya"
  val c7 = chk("typing replaced the selection", v6, "Zya")

  // --- a value longer than the box
  //
  // The field is 300 wide with 8 of padding, so 284 pixels of text are
  // visible and a 100-character value is several times that. Before the
  // field scrolled, everything past the first ~40 characters was unreachable:
  // the caret ran off the right edge and clicks could only ever land in the
  // head of the string. A licence key is exactly this case.
  val long = list(1, 10).map(fn(_i) { "abcdefghij" }).join("")
  val pad = 8
  val vis = box.w - 2 * pad
  run(r, p, box, id, long, [down(300, 26), up(300, 26)]).ignore   // focus it
  run(r, p, box, id, long, [key(k-end)]).ignore                   // caret to the end
  val c8 = chk("the caret can reach the end", ui/caret-of(r, id, -1).show, "100")

  // With the caret at the end the text is scrolled by exactly enough to hold
  // it, so the last character boundary sits at the right inside edge.
  run(r, p, box, id, long, [down(box.x + pad + vis, 26), up(box.x + pad + vis, 26)]).ignore
  val c9 = chk("clicking the right edge lands at the end",
               ui/caret-of(r, id, -1).show, "100")

  // ...and the left edge is no longer character zero, which is what proves
  // the view moved rather than the string being silently truncated.
  run(r, p, box, id, long, [down(box.x + pad, 26), up(box.x + pad, 26)]).ignore
  val scrolled-to = ui/caret-of(r, id, -1)
  val c10 = chk("and the left edge is well into the string",
                (scrolled-to > 0 && scrolled-to < 100).show, "True")

  // A value that fits is not scrolled at all: the field looks as it always did.
  run(r, p, box, id, "Priya", [down(box.x + pad, 26), up(box.x + pad, 26)]).ignore
  val c11 = chk("a short value still starts at character zero",
                ui/caret-of(r, id, -1).show, "0")

  win32/save-bmp("out/textfield.bmp").ignore
  c1+c2+c3+c4+c5+c6+c7+c8+c9+c10+c11

fun run( r : ref<global,ui/ui>, p : theme/palette, box : rect, id : ui/widget-id,
         value : string, evs : list<win32/event> ) : io string
  ui/frame-begin(r, evs)
  win32/clip-all()
  win32/fill(0, 0, 400, 100, p.main)
  val out = widgets/text-field(r, p, box, value, id, "type here")
  ui/frame-end(r)
  out

fun down( x : int, y : int ) : win32/event
  win32/Event(win32/ev-mouse-down, x, y, 0)
fun up( x : int, y : int ) : win32/event
  win32/Event(win32/ev-mouse-up, x, y, 0)
fun key( k : int ) : win32/event
  win32/Event(win32/ev-key-down, 0, 0, k)
fun ch( c : char ) : win32/event
  win32/Event(win32/ev-char, 0, 0, c.int)
