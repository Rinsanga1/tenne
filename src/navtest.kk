// Navigation between views, driven by clicks.
//
// A number on the Dashboard and a row in the ledger are both pointers at a
// record somewhere else. If tapping them does not open that record, the owner
// has to go and find it by hand -- and worse, the Dashboard's figure and the
// list it claims to summarise can quietly disagree.
module navtest

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
import view-members
import view-dashboard
import view-transactions
import view-shop

fun chk( name : string, got : string, want : string ) : io int
  val ok = got == want
  println((if ok then "  ok   " else "  FAIL ") ++ name.pad-right(52) ++ got.pad-right(16) ++
          (if ok then "" else "want " ++ want))
  if ok then 0 else 1

fun click( x : int, y : int ) : list<win32/event>
  [win32/Event(win32/ev-mouse-down, x, y, 0), win32/Event(win32/ev-mouse-up, x, y, 0)]

pub fun main() : io ()
  sql/unbuffer()
  val f = checks()
  sql/close().ignore
  println(if f == 0 then "ALL PASS" else "FAILED: " ++ f.show)

fun frame( r : ref<global,ui/ui>, s : app/state, evs : list<win32/event> ) : io app/state
  ui/frame-begin(r, evs)
  win32/clip-all()
  win32/fill(0, 0, 1180, 720, s.palette.main)
  app/sidebar(r, s).ignore
  val next = if app/same-view(s.view, Members) then view-members/show(r, s)
             elif app/same-view(s.view, Dashboard) then view-dashboard/show(r, s)
             elif app/same-view(s.view, Transactions) then view-transactions/show(r, s)
             elif app/same-view(s.view, Shop) then view-shop/show(r, s)
             else s
  ui/frame-end(r)
  next

fun checks() : io int
  val path = "out/nav.db"
  if sql/file-exists(path) then sql/remove-file(path).ignore
  db/open-db(path).ignore

  // Two members: one paid up for August, one deep in arrears.
  val paid = repo/create-member(Member(0, "Priya", Nothing, Nothing, "2025-08-01",
                                       True, Nothing), 500.0, Just(1500.0), "2025-08", "2025-08-01")
  val owing = repo/create-member(Member(0, "Zonunsanga", Nothing, Nothing, "2025-02-01",
                                        True, Nothing), 500.0, Nothing, "2025-02", "2025-02-01")
  val bar = repo2/insert-product(Product(0, "Protein bar", 60.0, 10, True))
  repo2/record-sale("2025-08-04", [(bar, 2, 60.0)]).ignore
  repo2/insert-expense(Expense(0, "Rent", 12000.0, "2025-08-02", Nothing)).ignore

  win32/offscreen(1180, 720)
  win32/font-file("assets/fonts/Geist-Regular.ttf").ignore
  win32/font-file("assets/fonts/Geist-SemiBold.ttf").ignore
  val r = ref(ui/new-ui(win32/font("Geist", 14, 400), win32/font("Geist SemiBold", 15, 600),
                        win32/font("Geist", 12, 400), win32/font("Geist SemiBold", 30, 600)))
  val s0 = app/new-state(theme/palette-of("dark"), "Bright Star Gym", "Rs", "out",
                         "2025-08", "1500", "500")

  val e1 = chk("one member owes in August",
               repo/due-members-with-arrears("2025-08").length.show, "1")

  // --- the Dashboard's "Members due" figure drills through to that member
  var s := s0(view = Dashboard)
  s := frame(r, s, [])
  val box = app/content-rect()
  val hero-x = box.x + (box.w - 16) / 2 + 16 + 100
  s := frame(r, s, click(hero-x, box.y + 50))
  val e2 = chk("the due figure opens Members", app/view-label(s.view), "Members")
  val e3 = chk("filtered to the ones who owe", (s.member-slice == 1).show, "True")

  // and the list behind it holds exactly that member
  s := frame(r, s, [])
  val e4 = chk("the filtered roster shows only them",
               repo/list-members(True).filter(behind)
                 .map(fn(m : models/member) { m.name }).join(","), "Zonunsanga")
  val e5 = chk("and the paid-up member is not in it",
               (repo/membership-arrears(paid, "2025-08", "2025-08").fst == 0).show, "True")

  // the chip clears the filter
  s := frame(r, s, click(box.x + 40, box.y + 52))
  val e6 = chk("the All tab clears the filter", (s.member-slice == 1).show, "False")

  // --- a ledger row opens its source record
  val ledger = repo2/transactions-between("2025-08-01", "2025-08-31")
  val e7 = chk("the ledger has all three kinds", ledger.length.show, "4")

  // payment row -> the member it belongs to
  val pay = ledger.filter(fn(t : models/txn) { t.kind.is-payment }).head
  val e8 = chk("a payment row names a real payment",
               pay.map(fn(t : models/txn) { repo/get-payment(models/txn/id(t)).is-just }).default(False).show,
               "True")
  val e9 = chk("and it points at the member who made it",
               pay.map(payer).default(0).show,
               paid.show)

  // Drive it through the view: click the first ledger row.
  s := s0(view = Transactions)
  s := frame(r, s, [])
  val tbox = app/content-rect()
  val row-y = tbox.y + 48 + 42 + 20
  s := frame(r, s, click(tbox.x + 200, row-y))
  val e10 = chk("clicking the newest row navigated somewhere",
                (app/view-label(s.view) != "Transactions" || s.expense.is-just).show, "True")

  // sale row -> the Shop's sales list
  val sale = ledger.filter(fn(t : models/txn) { t.kind.is-sale }).head
  val s-after = match sale
    Just(t) -> open-via(s0, t)
    Nothing -> s0
  val e11 = chk("a sale row opens the Shop", app/view-label(s-after.view), "Shop")
  val e12 = chk("on the sales tab", s-after.shop-sales.show, "True")

  // expense row -> its edit dialog, loaded with the real expense
  val exp = ledger.filter(fn(t : models/txn) { t.kind.is-expense }).head
  val e-after = match exp
    Just(t) -> open-via(s0, t)
    Nothing -> s0
  val e13 = chk("an expense row opens its dialog", e-after.expense.is-just.show, "True")
  val e14 = chk("loaded with that expense",
                e-after.expense.map(fn(g : app/expense-form) { g.name }).default(""), "Rent")

  // payment row -> the member card, with the roster unfiltered behind it
  val p-after = match pay
    Just(t) -> open-via(s0, t)
    Nothing -> s0
  val e15 = chk("a payment row opens the member", app/view-label(p-after.view), "Members")
  val e16 = chk("the right member", p-after.selected.show, paid.show)
  val e17 = chk("with the roster unfiltered so they are findable",
                ((p-after.member-slice != 0) || p-after.active-only).show, "False")

  win32/save-bmp("out/nav.bmp").ignore
  e1+e2+e3+e4+e5+e6+e7+e8+e9+e10+e11+e12+e13+e14+e15+e16+e17

// The same routing the view uses, reached directly so each kind can be checked.
fun open-via( s : app/state, t : models/txn ) : io app/state
  val k = t.kind
  if k.is-payment then
    match repo/get-payment(models/txn/id(t))
      Just(pay) -> s(view = Members, selected = pay.member-id, member-slice = 0,
                     active-only = False, search = "")
      Nothing -> s
  elif k.is-sale then s(view = Shop, shop-sales = True)
  else
    match repo2/get-expense(models/txn/id(t))
      Just(e) -> s(expense = Just(app/expense-form-of(e)))
      Nothing -> s

// Named rather than inline: a multi-statement lambda cannot be a parenthesised
// argument in Koka, and a repository call inside one drags a `div` effect in.
fun behind( m : models/member ) : io bool
  repo/membership-arrears(models/member/id(m), m.join-month, "2025-08").fst > 0

fun payer( t : models/txn ) : io int
  repo/get-payment(models/txn/id(t)).map(fn(q : models/payment) { q.member-id }).default(0)
