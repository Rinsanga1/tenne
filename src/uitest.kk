// Executable form of the ImmediateMode.tla invariants. Each case below is a
// trace TLC either produced as a counterexample or proved impossible.
module uitest
import win32
import ui

fun check( fails : ref<global,int>, name : string, got : string, want : string ) : io ()
  val ok = got == want
  if !ok then fails := !fails + 1
  println((if ok then "  ok   " else "  FAIL ") ++ name.pad-right(52) ++ got.pad-right(10) ++
          (if ok then "" else "want " ++ want))

fun down( x : int, y : int ) : win32/event
  win32/Event(win32/ev-mouse-down, x, y, 0)
fun up( x : int, y : int ) : win32/event
  win32/Event(win32/ev-mouse-up, x, y, 0)
fun move( x : int, y : int ) : win32/event
  win32/Event(win32/ev-mouse-move, x, y, 0)
fun ch( c : char ) : win32/event
  win32/Event(win32/ev-char, 0, 0, c.int)

pub fun main() : io ()
  win32/offscreen(64, 64)
  val fails = ref(0)
  val r = ref(ui/new-ui(0, 0, 0, 0))
  val box = Rect(20, 20, 100, 24)
  val id = ui/wid("btn")

  // ---- the mouse protocol

  // NoPhantomFire, the depth-5 counterexample: press on empty space, drag
  // onto the button, release on it. Must not fire.
  ui/frame-begin(r, [down(5, 5), move(60, 30), up(60, 30)])
  val b1 = ui/behavior(r, id, box)
  ui/frame-end(r)
  check(fails, "press on empty, release on button fires", b1.clicked.show, "False")

  // The ordinary click.
  ui/frame-begin(r, [down(60, 30), up(60, 30)])
  val b2 = ui/behavior(r, id, box)
  ui/frame-end(r)
  check(fails, "press and release on button fires", b2.clicked.show, "True")

  // Bug="FireAnywhere": press the button, drag off, release. Must not fire,
  // and must not leave the widget captured.
  ui/frame-begin(r, [down(60, 30)])
  val b3a = ui/behavior(r, id, box)
  ui/frame-end(r)
  check(fails, "held while pressed", b3a.held.show, "True")
  ui/frame-begin(r, [up(5, 5)])
  val b3b = ui/behavior(r, id, box)
  ui/frame-end(r)
  check(fails, "drag off then release fires", b3b.clicked.show, "False")
  check(fails, "capture cleared by release on nothing", ((!r).active == ui/no-widget).show, "True")

  // Bug="KeepVanishedCapture": press, then the widget stops being built.
  ui/frame-begin(r, [down(60, 30)])
  ui/behavior(r, id, box)
  ui/frame-end(r)
  check(fails, "captured before navigating away", ((!r).active == id).show, "True")
  ui/frame-begin(r, [])
  ui/frame-end(r)                      // widget not built this frame
  check(fails, "capture dropped when widget vanishes", ((!r).active == ui/no-widget).show, "True")

  // ---- keyboard focus

  val name-box = Rect(0, 0, 100, 20)
  val phone-box = Rect(0, 40, 100, 20)
  val name = ui/wid("name")
  val phone = ui/wid("phone")

  fun two-fields() : io (list<int>, list<int>)
    ui/behavior(r, name, name-box)
    ui/behavior(r, phone, phone-box)
    val a = ui/typed-chars(r, name)
    val b = ui/typed-chars(r, phone)
    (a, b)

  // Clicking a field focuses it.
  ui/frame-begin(r, [down(10, 10), up(10, 10)])
  two-fields()
  ui/frame-end(r)
  check(fails, "clicking a field focuses it", ((!r).focus == name).show, "True")

  // Typing goes to the focused field, and only to it.
  ui/frame-begin(r, [ch('P'), ch('r')])
  val (n1, p1) = two-fields()
  ui/frame-end(r)
  check(fails, "typing reaches the focused field", n1.length.show, "2")
  check(fails, "and not the other one", p1.length.show, "0")

  // Clicking empty space lets the field go.
  ui/frame-begin(r, [down(300, 300), up(300, 300)])
  two-fields()
  ui/frame-end(r)
  check(fails, "clicking empty space clears focus", ((!r).focus == ui/no-widget).show, "True")
  ui/frame-begin(r, [ch('x')])
  val (n2, p2) = two-fields()
  ui/frame-end(r)
  check(fails, "and then typing reaches nobody", (n2.length + p2.length).show, "0")

  // Bug="KeepVanishedFocus": focus a field, then stop building it. The
  // keyboard must not keep talking to a field nobody can see.
  ui/frame-begin(r, [down(10, 10), up(10, 10)])
  two-fields()
  ui/frame-end(r)
  check(fails, "focused before the dialog closes", ((!r).focus == name).show, "True")
  ui/frame-begin(r, [])
  ui/behavior(r, phone, phone-box)     // name field no longer built
  ui/frame-end(r)
  check(fails, "focus dropped when the field vanishes", ((!r).focus == ui/no-widget).show, "True")

  // Bug="MouseThenKeys", the counterexample that shaped frame-begin:
  // type a character, then click into another field, both in one batch.
  // The character belongs to the field that had focus when it was typed,
  // and must reach exactly one field -- never both.
  ui/frame-begin(r, [down(10, 10), up(10, 10)])     // focus the name field
  two-fields()
  ui/frame-end(r)
  ui/frame-begin(r, [ch('a'), down(10, 50), up(10, 50)])
  val (n3, p3) = two-fields()
  ui/frame-end(r)
  check(fails, "the key reaches the field it was typed in", n3.length.show, "1")
  check(fails, "not the one clicked afterwards", p3.length.show, "0")
  check(fails, "the click still moved the focus", ((!r).focus == phone).show, "True")

  // The reverse order: click into a field, then type, in one batch. The
  // character belongs to the field just clicked. Held back one frame so the
  // focus can settle, then delivered -- never dropped, never doubled.
  ui/frame-begin(r, [down(10, 10), ch('Z'), up(10, 10)])
  val (n4, p4) = two-fields()
  ui/frame-end(r)
  check(fails, "a key after a click is not misdelivered", (n4.length + p4.length).show, "0")
  ui/frame-begin(r, [])
  val (n5, p5) = two-fields()
  ui/frame-end(r)
  check(fails, "it arrives on the next frame", n5.length.show, "1")
  check(fails, "in the field that was clicked", p5.length.show, "0")
  ui/frame-begin(r, [])
  val (n6, p6) = two-fields()
  ui/frame-end(r)
  check(fails, "and is not delivered twice", (n6.length + p6.length).show, "0")

  println(if !fails == 0 then "ALL PASS" else "FAILED: " ++ (!fails).show)
