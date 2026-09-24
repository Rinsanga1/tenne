// The Shop dialogs, driven by clicks, with the shelf checked afterwards.
//
// StockNeverNegative is enforced in the repository; this suite proves the
// counter cannot route around it, and that the dialog refuses *before* the
// user commits rather than silently doing nothing.
module shoptest

import std/num/float64
import win32
import sql
import db
import ui
import theme
import widgets
import models
import repo
import repo2
import dates
import util
import app
import license
import dlg-shop
import view-shop

fun check( f : ref<global,int>, name : string, got : string, want : string ) : io ()
  val ok = got == want
  if !ok then f := !f + 1
  println((if ok then "  ok   " else "  FAIL ") ++ name.pad-right(50) ++ got.pad-right(14) ++
          (if ok then "" else "want " ++ want))

fun click( x : int, y : int ) : list<win32/event>
  [win32/Event(win32/ev-mouse-down, x, y, 0), win32/Event(win32/ev-mouse-up, x, y, 0)]

fun frame( r : ref<global,ui/ui>, s : app/state, evs : list<win32/event> ) : io app/state
  ui/frame-begin(r, evs)
  win32/clip-all()
  win32/fill(0, 0, 1180, 720, s.palette.main)
  val next = if s.sale.is-just then dlg-shop/sale-dialog(r, s, s.sale.default(app/blank-sale("")))
             elif s.product.is-just
               then dlg-shop/product-dialog(r, s, s.product.default(app/blank-product()))
             else s
  ui/frame-end(r)
  next

// Geometry of the sale dialog, which is 520x540 centred in 1180x720.
val dlg-w = 520
val dlg-h = 540
val dlg-x = (1180 - dlg-w) / 2
val dlg-y = (720 - dlg-h) / 2
val list-x = dlg-x + 20
val list-y = dlg-y + 148
fun plus-at( i : int ) : (int, int)
  (list-x + (dlg-w - 40) - 28 + 14, list-y + i * 34 + 13)
fun minus-at( i : int ) : (int, int)
  (list-x + (dlg-w - 40) - 96 + 14, list-y + i * 34 + 13)
val save-at = (dlg-x + dlg-w - 110 + 45, dlg-y + dlg-h - 52 + 26)
val delete-at = (dlg-x + 20 + 65, dlg-y + dlg-h - 26)

fun shelf( what : string ) : io int
  repo2/list-products().filter(fn(p : models/product) { p.name == what })
    .map(fn(p : models/product) { p.stock }).head.default(-99)

fun conserved() : io int
  sql/scalar-int("SELECT COALESCE(SUM(stock),0) FROM products", [], -1) +
  sql/scalar-int("SELECT COALESCE(SUM(qty),0) FROM sale_items WHERE product_id IS NOT NULL", [], -1)

pub fun main() : io ()
  sql/unbuffer()
  seed()
  val fails = checks()
  sql/close().ignore
  println(if fails == 0 then "ALL PASS" else "FAILED: " ++ fails.show)

fun seed() : io ()
  val path = "out/shop.db"
  if sql/file-exists(path) then sql/remove-file(path).ignore
  db/open-db(path).ignore
  // Products are listed by name, so this is the on-screen order:
  //   0 Protein bar (2), 1 Shaker bottle (5), 2 Wrist tape (0)
  repo2/insert-product(Product(0, "Protein bar", 60.0, 2, True)).ignore
  repo2/insert-product(Product(0, "Shaker bottle", 250.0, 5, True)).ignore
  repo2/insert-product(Product(0, "Wrist tape", 120.0, 0, True)).ignore

fun checks() : io int
  val f = ref(0)
  win32/offscreen(1180, 720)
  win32/font-file("assets/fonts/Geist-Regular.ttf").ignore
  win32/font-file("assets/fonts/Geist-SemiBold.ttf").ignore
  val r = ref(ui/new-ui(win32/font("Geist", 14, 400), win32/font("Geist SemiBold", 15, 600),
                        win32/font("Geist", 12, 400), win32/font("Geist SemiBold", 30, 600)))
  val s0 = app/new-state(theme/palette-of("dark"), "Bright Star Gym", "Rs", "out", "2025-08", "1500", "500")

  check(f, "shelf starts with 7 units", conserved().show, "7")
  check(f, "protein bars on the shelf", shelf("Protein bar").show, "2")

  // --- ring up one protein bar
  var s := s0(sale = Just(app/blank-sale("2025-08-04")))
  s := frame(r, s, [])
  val (px, py) = plus-at(0)
  s := frame(r, s, click(px, py))
  check(f, "one bar on the sale", s.sale.map(fn(g : app/sale-form) { app/qty-of(g, 1) })
        .default(-1).show, "1")
  s := frame(r, s, click(save-at.fst, save-at.snd))
  check(f, "sale recorded", s.sale.is-nothing.show, "True")
  check(f, "shelf down to one bar", shelf("Protein bar").show, "1")
  check(f, "units conserved", conserved().show, "7")

  // --- StockNeverNegative through the counter: ask for two when one is left
  s := s0(sale = Just(app/blank-sale("2025-08-05")))
  s := frame(r, s, [])
  s := frame(r, s, click(px, py))
  s := frame(r, s, click(px, py))
  check(f, "two bars asked for", s.sale.map(fn(g : app/sale-form) { app/qty-of(g, 1) })
        .default(-1).show, "2")
  s := frame(r, s, click(save-at.fst, save-at.snd))
  check(f, "Save is refused while the shelf is short", s.sale.is-just.show, "True")
  check(f, "and nothing was sold", shelf("Protein bar").show, "1")
  check(f, "no sale row was written",
        sql/scalar-int("SELECT COUNT(*) FROM sales WHERE date = '2025-08-05'", [], -1).show, "0")
  check(f, "units still conserved", conserved().show, "7")
  check(f, "stock never went negative",
        sql/scalar-int("SELECT COUNT(*) FROM products WHERE stock < 0", [], -1).show, "0")

  // Step one back off and it becomes sellable again.
  val (mx, my) = minus-at(0)
  s := frame(r, s, click(mx, my))
  check(f, "back to one bar", s.sale.map(fn(g : app/sale-form) { app/qty-of(g, 1) })
        .default(-1).show, "1")
  s := frame(r, s, click(save-at.fst, save-at.snd))
  check(f, "now it saves", s.sale.is-nothing.show, "True")
  check(f, "shelf empty of bars", shelf("Protein bar").show, "0")
  check(f, "units conserved", conserved().show, "7")

  // --- an out-of-stock product cannot be added at all
  s := s0(sale = Just(app/blank-sale("2025-08-06")))
  s := frame(r, s, [])
  val (tx, ty) = plus-at(2)                 // Wrist tape, 0 in stock
  s := frame(r, s, click(tx, ty))
  s := frame(r, s, click(save-at.fst, save-at.snd))
  check(f, "an out-of-stock item blocks Save", s.sale.is-just.show, "True")
  check(f, "and sells nothing", shelf("Wrist tape").show, "0")

  // --- a multi-product sale that the shelf can cover
  s := s0(sale = Just(app/blank-sale("2025-08-07")))
  s := frame(r, s, [])
  val (sx, sy) = plus-at(1)                 // Shaker bottle, 5 in stock
  s := frame(r, s, click(sx, sy))
  s := frame(r, s, click(sx, sy))
  s := frame(r, s, click(save-at.fst, save-at.snd))
  check(f, "two shakers sold", s.sale.is-nothing.show, "True")
  check(f, "shelf down to three", shelf("Shaker bottle").show, "3")
  check(f, "units conserved", conserved().show, "7")
  check(f, "and the money is on the books",
        models/money("Rs", repo2/merch-income("2025-08-01", "2025-08-31")), "Rs 620")

  // --- adding a product through its dialog
  s := s0(product = Just(app/blank-product()))
  s := frame(r, s, [])
  s := frame(r, s, click((1180 - 430) / 2 + 100, (720 - 400) / 2 + 68 + 33))   // name field
  s := frame(r, s, "Towel".list.map(fn(c) { win32/Event(win32/ev-char, 0, 0, c.int) }))
  // the product dialog is 430 wide, not 520 -- its own centre line
  val pdlg-x = (1180 - 430) / 2
  val psave = (pdlg-x + 430 - 110 + 45, (720 - 400) / 2 + 400 - 52 + 26)
  s := frame(r, s, click(psave.fst, psave.snd))
  check(f, "a product with no price is refused", s.product.is-just.show, "True")
  check(f, "and was not created",
        repo2/list-products().length.show, "3")

  win32/save-bmp("out/shop-sale.bmp").ignore
  // The cap cases run last: they bulk up the shelf and the till, and every
  // case above counts both.
  !f + sale-corrections() + licence-caps()

// --- correcting a sale through the Sales tab ----------------------------
//
// Without this the owner can ring up a sale but never fix one, and the stock
// stays wrong forever. `update-sale` and `delete-sale` were tested at the
// repository level from the start but were unreachable from the UI.
//
// These cases go through the dialog, not the repository. The earlier version
// called `repo2/update-sale` directly and passed for an iteration while the
// dialog was in fact calling `record-sale` on save -- so correcting a sale
// wrote a second one and took the stock twice.
pub fun sale-corrections() : io int
  win32/offscreen(1180, 720)
  val r = ref(ui/new-ui(win32/font("Geist", 14, 400), win32/font("Geist SemiBold", 15, 600),
                        win32/font("Geist", 12, 400), win32/font("Geist SemiBold", 30, 600)))
  val s0 = app/new-state(theme/palette-of("dark"), "Bright Star Gym", "Rs", "out",
                         "2025-08", "1500", "500")(view = Shop)

  val shakers = repo2/list-products().filter(fn(x : models/product) { x.name == "Shaker bottle" })
                  .map(fn(x : models/product) { models/product/id(x) }).head.default(0)
  val before-shelf = shelf("Shaker bottle")
  val before-units = conserved()
  val before-sales = repo2/list-sales().length

  val sid = repo2/record-sale("2025-08-21", [(shakers, 1, 250.0)])
  val e1 = chk2("a sale was recorded", (sid > 0).show, "True")
  val e2 = chk2("shelf went down by one", shelf("Shaker bottle").show, (before-shelf - 1).show)

  // open it the way the Sales tab does, with its quantities loaded
  var s := s0(sale = Just(app/sale-form-of(sid, "2025-08-21", repo2/holdings(sid))))
  s := frame(r, s, [])
  val e3 = chk2("the sale opens with what was rung up",
                s.sale.map(fn(g : app/sale-form) { app/qty-of(g, shakers) }).default(-1).show, "1")

  // widen it to two and save. The unit this sale already holds counts as
  // available, or widening would be refused against a shelf it is itself
  // holding stock out of.
  val (sx, sy) = plus-at(1)
  s := frame(r, s, click(sx, sy))
  s := frame(r, s, click(save-at.fst, save-at.snd))
  val e4 = chk2("correcting it to two saves", s.sale.is-nothing.show, "True")
  val e5 = chk2("and does not write a second sale", repo2/list-sales().length.show,
                (before-sales + 1).show)
  val e6 = chk2("the shelf reflects the correction", shelf("Shaker bottle").show,
                (before-shelf - 2).show)
  val e7 = chk2("units still conserved", conserved().show, before-units.show)

  // --- delete it from the same dialog, which puts the units back
  s := s0(sale = Just(app/sale-form-of(sid, "2025-08-21", repo2/holdings(sid))))
  s := frame(r, s, [])
  s := frame(r, s, click(delete-at.fst, delete-at.snd))
  val e8 = chk2("one click on Delete removes nothing", repo2/list-sales().length.show,
                (before-sales + 1).show)
  s := frame(r, s, [])
  win32/save-bmp("out/dlg-sale-edit.bmp").ignore
  val e9 = chk2("but it is armed",
                s.sale.map(fn(g : app/sale-form) { g.confirm }).default(False).show, "True")
  s := frame(r, s, click(delete-at.fst, delete-at.snd))
  val e10 = chk2("the second click deletes it", repo2/list-sales().length.show,
                 before-sales.show)
  val e11 = chk2("the shelf is back to where it started", shelf("Shaker bottle").show,
                 before-shelf.show)
  val e12 = chk2("units conserved after delete", conserved().show, before-units.show)

  // render the Sales tab so the layout is exercised too
  ui/frame-begin(r, [])
  win32/clip-all()
  win32/fill(0, 0, 1180, 720, s0.palette.main)
  app/sidebar(r, s0(shop-sales = True)).ignore
  view-shop/show(r, s0(shop-sales = True)).ignore
  ui/frame-end(r)
  win32/save-bmp("out/shop-sales.bmp").ignore
  e1+e2+e3+e4+e5+e6+e7+e8+e9+e10+e11+e12 + product-deletion(r, s0)

// Deleting a product keeps the sales it appeared in, and their revenue, on
// the books: delete-product nulls the reference rather than cascading, and
// nothing but this dialog can reach it.
fun product-deletion( r : ref<global,ui/ui>, s0 : app/state ) : io int
  val tape = repo2/list-products().filter(fn(x : models/product) { x.name == "Wrist tape" })
               .map(fn(x : models/product) { models/product/id(x) }).head.default(0)
  val before = repo2/list-products().length
  val pdlg-x = (1180 - 430) / 2
  val pdlg-y = (720 - 400) / 2
  val pdel = (pdlg-x + 20 + 65, pdlg-y + 400 - 26)

  var s := s0(product = Just(Product-form(tape, "Wrist tape", "120", "0", True, "", False)))
  s := frame(r, s, [])
  s := frame(r, s, click(pdel.fst, pdel.snd))
  val d1 = chk2("one click on Delete removes no product",
                repo2/list-products().length.show, before.show)
  s := frame(r, s, click(pdel.fst, pdel.snd))
  val d2 = chk2("the second click deletes it", repo2/list-products().length.show,
                (before - 1).show)
  val d3 = chk2("and it is gone from the shelf", shelf("Wrist tape").show, "-99")
  d1+d2+d3

// The licence caps, through the two Save buttons rather than through the
// guard behind them. lictest already covers the guard; a cap the dialog never
// asks about is the failure this catches.
fun licence-caps() : io int
  val f = ref(0)
  win32/offscreen(1180, 720)
  val r = ref(ui/new-ui(win32/font("Geist", 14, 400), win32/font("Geist SemiBold", 15, 600),
                        win32/font("Geist", 12, 400), win32/font("Geist SemiBold", 30, 600)))
  val s0 = app/new-state(theme/palette-of("dark"), "Bright Star Gym", "Rs", "out",
                         "2025-08", "1500", "500")(view = Shop)
  val pdlg-x = (1180 - 430) / 2
  val psave = (pdlg-x + 430 - 110 + 45, (720 - 400) / 2 + 400 - 52 + 26)

  list(1, license/free-products).foreach fn(i)
    repo2/insert-product(Product(0, "Bulk " ++ i.show, 10.0, 5, True)).ignore
  val shelf-now = repo2/list-products().length
  var s := s0(licensee = "", product = Just(Product-form(0, "Towel", "120", "4", True, "", False)))
  s := frame(r, s, [])
  s := frame(r, s, click(psave.fst, psave.snd))
  check(f, "over the cap, a product is refused", s.product.is-just.show, "True")
  check(f, "and the shelf did not grow", repo2/list-products().length.show, shelf-now.show)
  s := s(licensee = "Bright Star Gym")
  s := frame(r, s, [])
  s := frame(r, s, click(psave.fst, psave.snd))
  check(f, "licensed, the same Save works", s.product.is-nothing.show, "True")
  check(f, "and the product was created",
        repo2/list-products().length.show, (shelf-now + 1).show)

  list(1, license/free-sales).foreach fn(i)
    repo2/import-sale("2025-07-01", 50.0, []).ignore
  val till-now = repo2/count-sales()
  s := s0(licensee = "", sale = Just(app/blank-sale("2025-08-09")))
  s := frame(r, s, [])
  s := frame(r, s, click(plus-at(1).fst, plus-at(1).snd))
  s := frame(r, s, click(save-at.fst, save-at.snd))
  check(f, "over the cap, a sale is refused", s.sale.is-just.show, "True")
  check(f, "and nothing was rung up", repo2/count-sales().show, till-now.show)
  s := s(licensee = "Bright Star Gym")
  s := frame(r, s, [])
  s := frame(r, s, click(save-at.fst, save-at.snd))
  check(f, "licensed, the sale goes through", s.sale.is-nothing.show, "True")
  check(f, "and the till moved", repo2/count-sales().show, (till-now + 1).show)
  !f

fun chk2( name : string, got : string, want : string ) : io int
  val ok = got == want
  println((if ok then "  ok   " else "  FAIL ") ++ name.pad-right(50) ++ got.pad-right(14) ++
          (if ok then "" else "want " ++ want))
  if ok then 0 else 1
