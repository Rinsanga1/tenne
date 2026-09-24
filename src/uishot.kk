// Renders frames of the real UI offscreen and dumps them, so the look can be
// checked without a screen.
module uishot
import win32
import ui
import theme
import widgets

val cols = [Column("NAME", 20, 190), Column("PHONE", 230, 120),
            Column("JOINED", 370, 110), Column("STATUS", 500, 90)]

val people = [("Priya Lalthanmawii", "9862011234", "2024-11-03", "Paid"),
              ("Zonunsanga", "9436152200", "2025-02-17", "Due"),
              ("Lalrinpuia", "-", "2023-07-21", "Inactive"),
              ("Vanlalruati Chhangte", "9612440099", "2025-06-02", "Paid"),
              ("Lalhmingliana Ralte", "9856120044", "2025-01-08", "Paid"),
              ("Zothansangi", "9774005512", "2024-09-30", "Due"),
              ("Malsawmtluanga", "9615003388", "2025-03-14", "Paid"),
              ("Rosangliani", "9862774411", "2025-05-19", "Paid")]

pub fun main() : io ()
  win32/offscreen(900, 470)
  win32/font-file("assets/fonts/Geist-Regular.ttf")
  win32/font-file("assets/fonts/Geist-SemiBold.ttf")
  val body  = win32/font("Geist", 14, 400)
  val semi  = win32/font("Geist SemiBold", 15, 600)
  val small = win32/font("Geist", 12, 400)
  val r = ref(ui/new-ui(body, semi, small, win32/font("Geist SemiBold", 30, 600)))
  val p = theme/palette-of("dark")

  // Frame 1: cursor over the fourth row, list scrolled down a little.
  ui/frame-begin(r, [win32/Event(win32/ev-mouse-move, 500, 250, 0)])
  win32/clip-all()
  draw(r, p, 40, "")
  ui/frame-end(r)
  println(if win32/save-bmp("out/ui.bmp") then "wrote out/ui.bmp" else "FAILED")

  // Frame 2: the search box focused, with text typed into it.
  ui/frame-begin(r, [win32/Event(win32/ev-mouse-down, 300, 78, 0),
                     win32/Event(win32/ev-mouse-up, 300, 78, 0)])
  win32/clip-all()
  draw(r, p, 0, "")
  ui/frame-end(r)
  ui/frame-begin(r, "Zonun".list.map(fn(c) { win32/Event(win32/ev-char, 0, 0, c.int) }))
  win32/clip-all()
  val typed = draw(r, p, 0, "")
  ui/frame-end(r)
  println("search box now holds: '" ++ typed ++ "'")
  println(if win32/save-bmp("out/ui-typing.bmp") then "wrote out/ui-typing.bmp" else "FAILED")

fun draw( r : ref<global,ui/ui>, p : theme/palette, scroll : int,
          search : string ) : io string
  val sw = win32/width()
  val sh = win32/height()
  win32/fill(0, 0, sw, sh, p.main)
  win32/fill(0, 0, 210, sh, p.sidebar)
  widgets/separator(p, 210, 0, 1)

  widgets/label((!r).font-semi, 16, 18, "TenneCRM", p.text)
  widgets/label((!r).font-small, 16, 38, "Bright Star Gym", p.text-muted)

  ["Dashboard", "Members", "Shop", "Expenses", "Transactions", "Settings"]
    .foreach-indexed fn(i, name)
      widgets/nav-item(r, p, Rect(0, 74 + i * 34, 210, 32), name,
                       name == "Members", ui/wid-at("nav", i))
      ()

  widgets/label((!r).font-small, 16, sh - 28, "tmp_crmtest", p.text-muted)

  widgets/label((!r).font-semi, 240, 22, "Members", p.text)
  widgets/button(r, p, Rect(672, 16, 84, 30), "Export", ui/wid("export"))
  widgets/button-primary(r, p, Rect(764, 16, 112, 30), "Add member", ui/wid("add"))

  // search box
  val typed = widgets/text-field(r, p, Rect(240, 64, 280, 30), search,
                                 ui/wid("search"), "Search name or phone")

  // table
  val tx = 240
  val tw = 636
  widgets/panel(p, Rect(tx, 108, tw, 300))
  widgets/table-header(r, p, tx + 16, 122, tw - 32, cols)

  val list-box = Rect(tx + 1, 150, tw - 2, 256)
  widgets/scroll-area(r, p, list-box, people.length * widgets/row-h, scroll) fn(dy)
    people.foreach-indexed fn(i, m)
      val (name, phone, joined, status) = m
      val ry = list-box.y + dy + i * widgets/row-h
      val row = Rect(list-box.x, ry, list-box.w - widgets/scrollbar-w, widgets/row-h)
      widgets/table-row(r, p, row, i, ui/wid-at("member", i))
      widgets/cell(r, cols.head.default(Column("",0,0)), tx + 16, ry, name, p.text)
      match cols.drop(1)
        Cons(c2, rest) ->
          widgets/cell(r, c2, tx + 16, ry, phone, p.text-muted)
          match rest
            Cons(c3, rest2) ->
              widgets/cell(r, c3, tx + 16, ry, joined, p.text-muted)
              match rest2
                Cons(c4, _) ->
                  val col = if status == "Paid" then theme/positive
                            elif status == "Due" then theme/negative
                            else 0xFFA3A3A3
                  widgets/pill((!r).font-small, tx + 16 + c4.x, ry + 10, status, col)
                Nil -> ()
            Nil -> ()
        Nil -> ()

  widgets/separator(p, tx + 16, 408, tw - 32)
  widgets/label((!r).font-small, tx + 16, 420,
                people.length.show ++ " members  -  6 active", p.text-muted)
  widgets/label-right((!r).font-body, tx + tw - 16, 418,
                      "Due this month  Rs 3,000", theme/negative)
  typed
