// The Dashboard's arithmetic, asserted against a gym with a full year of
// dues, shop sales and expenses behind it.
module dashtest

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
import view-dashboard
import view-transactions
import view-expenses
import dialogs

fun check( f : ref<global,int>, name : string, got : string, want : string ) : io ()
  val ok = got == want
  if !ok then f := !f + 1
  println((if ok then "  ok   " else "  FAIL ") ++ name.pad-right(48) ++ got.pad-right(16) ++
          (if ok then "" else "want " ++ want))

fun seed( path : string ) : io ()
  if sql/file-exists(path) then sql/remove-file(path).ignore
  db/open-db(path).ignore
  repo/set-setting("gym_name", "Bright Star Gym").ignore

  // Eight members, staggered joins, partial payment histories.
  [("Priya Lalthanmawii", "9862011234", "2025-01-15", True,  6),
   ("Zonunsanga",         "9436152200", "2025-02-17", True,  0),
   ("Lalrinpuia",         "",           "2024-07-21", False, 2),
   ("Vanlalruati Chhangte","9612440099","2025-03-02", True,  4),
   ("Lalhmingliana Ralte","9856120044", "2025-01-08", True,  6),
   ("Zothansangi",        "9774005512", "2025-04-30", True,  1),
   ("Malsawmtluanga",     "9615003388", "2025-05-14", True,  2),
   ("Rosangliani",        "9862774411", "2025-06-19", True,  1)]
    .foreach fn(row)
      val (name, phone, joined, active, months) = row
      val ph = if phone == "" then Nothing else Just(phone)
      val id = repo/create-member(Member(0, name, ph, Nothing, joined, active, Nothing),
                                  500.0, Nothing, joined.list.take(7).string, joined)
      match dates/parse-month(joined.list.take(7).string)
        Just((y, m)) -> list(0, months - 1).foreach fn(k)
          val (yy, mm) = dates/add-months-ym(y, m, k)
          repo/insert-payment(Payment(0, id, dates/fmt-month(yy, mm), 1500.0,
                                      dates/fmt-date(yy, mm, 5), Nothing,
                                      models/cat-membership)).ignore
        Nothing -> ()

  // A shop with stock, and two sales in August.
  val bar = repo2/insert-product(Product(0, "Protein bar", 60.0, 24, True))
  val shaker = repo2/insert-product(Product(0, "Shaker bottle", 250.0, 3, True))
  val tape = repo2/insert-product(Product(0, "Wrist tape", 120.0, 0, True))
  repo2/record-sale("2025-08-04", [(bar, 5, 60.0)]).ignore
  repo2/record-sale("2025-08-19", [(shaker, 2, 250.0), (bar, 3, 60.0)]).ignore

  // Two expenses in August.
  repo2/insert-expense(Expense(0, "Rent", 12000.0, "2025-08-01", Nothing)).ignore
  repo2/insert-expense(Expense(0, "Electricity", 2400.0, "2025-08-09", Just("summer"))).ignore
  // and one in July, so the trend line has a baseline to compare against
  repo2/insert-expense(Expense(0, "Rent", 12000.0, "2025-07-01", Nothing)).ignore

pub fun main() : io ()
  sql/unbuffer()
  seed("out/dash.db")
  val fails = checks()
  render()
  val total = fails + recurring-ui()
  sql/close().ignore
  println(if total == 0 then "ALL PASS" else "FAILED: " ++ total.show)

// The ref stays inside this function. Koka 3.2.3 emits undeclared evidence
// variables when a `ref` created in `main` is passed to another function that
// also performs io -- see the Gotchas in .ralph/koka-tenne.md.
fun checks() : io int
  val f = ref(0)
  val aug = dates/range(Month-filter(2025, Just(8)))
  val dues = repo/category-income(models/cat-membership, aug.fst, aug.snd)
  val joining = repo/category-income(models/cat-registration, aug.fst, aug.snd)
  val merch = repo2/merch-income(aug.fst, aug.snd)
  val units = repo2/merch-units(aug.fst, aug.snd)
  val spend = repo2/total-expenses(aug.fst, aug.snd)
  val net = repo2/net-earnings(aug.fst, aug.snd)

  check(f, "August range", aug.show, "(\"2025-08-01\",\"2025-08-31\")")
  // Nobody's payment history reaches August: every member's runs out earlier.
  check(f, "no dues collected in August", models/money("Rs", dues), "Rs 0")
  check(f, "no joining fees in August", models/money("Rs", joining), "Rs 0")
  // 5 bars + (2 shakers + 3 bars) = 300 + 500 + 180
  check(f, "shop took Rs 980", models/money("Rs", merch), "Rs 980")
  check(f, "across 10 units", units.show, "10")
  check(f, "expenses were Rs 14,400", models/money("Rs", spend), "Rs 14,400")
  check(f, "so net is -Rs 13,420", models/money("Rs", net), "-Rs 13,420")

  // The previous period is July, which had only the Rs 12,000 rent.
  val jul = dates/range(dates/previous(Month-filter(2025, Just(8))))
  check(f, "July range", jul.show, "(\"2025-07-01\",\"2025-07-31\")")
  check(f, "July net was -Rs 12,000", models/money("Rs", repo2/net-earnings(jul.fst, jul.snd)),
        "-Rs 12,000")

  // Low stock at threshold 5: the shaker (3) and the tape (0), not the bars.
  val low = repo2/low-stock-products(5)
  check(f, "low stock names the right two",
        low.map(fn(p : models/product) { p.name }).join(", "), "Wrist tape, Shaker bottle")
  check(f, "and the protein bars are not low",
        low.any(fn(p : models/product) { p.name == "Protein bar" }).show, "False")

  // The ledger carries all three kinds, newest first.
  val recent = repo2/recent-transactions(6)
  check(f, "recent activity is not empty", (recent.length > 0).show, "True")
  check(f, "newest first",
        (recent.map(fn(t : models/txn) { t.date }) ==
         recent.map(fn(t : models/txn) { t.date }).sort-by(fn(a : string, b : string) { a > b })).show,
        "True")

  // The chart: 12 months ending August, zero-filled.
  val chart = repo2/monthly-revenue("2025-08", 12)
  check(f, "chart has 12 points", chart.length.show, "12")
  check(f, "oldest first", chart.head.map(fn(d : (string, float64)) { d.fst }).default(""), "2024-09")
  check(f, "newest last", chart.last.map(fn(d : (string, float64)) { d.fst }).default(""), "2025-08")
  check(f, "August revenue is the shop only",
        models/money("Rs", chart.last.map(fn(d : (string, float64)) { d.snd }).default(0.0)),
        "Rs 980")
  // A month before anyone joined must be zero, not missing.
  check(f, "a month before the gym existed is zero, not absent",
        models/money("Rs", chart.head.map(fn(d : (string, float64)) { d.snd }).default(-1.0)),
        "Rs 0")
  !f


fun render() : io ()
  win32/offscreen(1180, 720)
  win32/font-file("assets/fonts/Geist-Regular.ttf").ignore
  win32/font-file("assets/fonts/Geist-SemiBold.ttf").ignore
  val r = ref(ui/new-ui(win32/font("Geist", 14, 400), win32/font("Geist SemiBold", 15, 600),
                        win32/font("Geist", 12, 400), win32/font("Geist SemiBold", 30, 600)))
  val s0 = app/new-state(theme/palette-of("dark"), repo/gym-name(), "Rs", "out", "2025-08", "1500", "500")
  ui/frame-begin(r, [])
  win32/clip-all()
  win32/fill(0, 0, 1180, 720, s0.palette.main)
  app/sidebar(r, s0(view = Dashboard)).ignore
  view-dashboard/show(r, s0(view = Dashboard)).ignore
  ui/frame-end(r)
  println(if win32/save-bmp("out/dashboard.bmp") then "wrote out/dashboard.bmp" else "FAILED")

  // the other two ledger views, from the same seeded gym
  shot(r, s0(view = Transactions), "out/transactions.bmp")
  repo2/insert-recurring-expense(Recurring-expense(0, "Rent", 12000.0)).ignore
  repo2/insert-recurring-expense(Recurring-expense(0, "Trainer salary", 9000.0)).ignore
  shot(r, s0(view = Expenses), "out/expenses.bmp")

fun shot( r : ref<global,ui/ui>, s : app/state, path : string ) : io ()
  ui/frame-begin(r, [])
  win32/clip-all()
  win32/fill(0, 0, 1180, 720, s.palette.main)
  app/sidebar(r, s).ignore
  // if/elif, not match: a match arm that consumes an outer owned value
  // double-drops it in Koka 3.2.3 -- same shape as the pattern-guard bug.
  if app/same-view(s.view, Transactions) then view-transactions/show(r, s).ignore
  elif app/same-view(s.view, Expenses) then view-expenses/show(r, s).ignore
  ui/frame-end(r)
  println(if win32/save-bmp(path) then "wrote " ++ path else "FAILED " ++ path)

// --- the Monthly bills tab, driven by clicks ----------------------------
//
// insert/update/delete-recurring-expense were tested at the repository level
// from the start but were unreachable from the UI: a template could be used
// as prefill and never corrected or removed. These cases go through the
// dialog, so that cannot silently become true again.
pub fun recurring-ui() : io int
  win32/offscreen(1180, 720)
  val r = ref(ui/new-ui(win32/font("Geist", 14, 400), win32/font("Geist SemiBold", 15, 600),
                        win32/font("Geist", 12, 400), win32/font("Geist SemiBold", 30, 600)))
  val s0 = app/new-state(theme/palette-of("dark"), "Bright Star Gym", "Rs", "out",
                         "2025-08", "1500", "500")(view = Expenses, expense-recurring = True)
  val before = repo2/list-recurring-expenses().length

  // --- add one by typing into the dialog
  var s := s0(recurring = Just(app/blank-recurring()))
  s := frame(r, s, [])
  s := frame(r, s, click(name-at.fst, name-at.snd))
  s := frame(r, s, typing("Water"))
  s := frame(r, s, click(save-at.fst, save-at.snd))
  val e1 = chk("a bill with no amount is refused", s.recurring.is-just.show, "True")
  val e2 = chk("and nothing was saved", repo2/list-recurring-expenses().length.show,
               before.show)

  s := frame(r, s, click(amount-at.fst, amount-at.snd))
  s := frame(r, s, typing("800"))
  s := frame(r, s, click(save-at.fst, save-at.snd))
  val e3 = chk("with an amount it saves", s.recurring.is-nothing.show, "True")
  val e4 = chk("and the bill is on the list", money-of("Water"), "Rs 800")

  // --- correct it: the whole reason the tab exists
  val wid = id-of("Water")
  s := s0(recurring = Just(Recurring-form(wid, "Water and power", "950", "", False)))
  s := frame(r, s, [])
  s := frame(r, s, click(save-at.fst, save-at.snd))
  val e5 = chk("editing renames it", money-of("Water and power"), "Rs 950")
  val e6 = chk("and does not leave a duplicate behind",
               repo2/list-recurring-expenses().length.show, (before + 1).show)

  // --- delete is two-stage: the first click only arms it
  repo2/insert-expense(Expense(0, "Water and power", 950.0, "2025-08-03", Nothing)).ignore
  s := s0(recurring = Just(Recurring-form(wid, "Water and power", "950", "", False)))
  s := frame(r, s, [])
  s := frame(r, s, click(delete-at.fst, delete-at.snd))
  val e7 = chk("one click on Delete removes nothing",
               repo2/list-recurring-expenses().length.show, (before + 1).show)
  // one settled frame, so the armed caption is what gets drawn
  s := frame(r, s, [])
  win32/save-bmp("out/dlg-bill.bmp").ignore
  val e8 = chk("but it is armed",
               s.recurring.map(fn(g : app/recurring-form) { g.confirm }).default(False).show,
               "True")
  s := frame(r, s, click(delete-at.fst, delete-at.snd))
  val e9 = chk("the second click deletes it", money-of("Water and power"), "")
  val e10 = chk("the list is back to where it started",
                repo2/list-recurring-expenses().length.show, before.show)

  // deleting the template must not take the money with it: what was spent
  // was spent, and the ledger is the record of it
  val e11 = chk("the expense logged from it is kept",
                sql/scalar-int("SELECT COUNT(*) FROM expenses WHERE name = 'Water and power'",
                               [], -1).show, "1")

  // render the tab itself so its layout is exercised too
  ui/frame-begin(r, [])
  win32/clip-all()
  win32/fill(0, 0, 1180, 720, s0.palette.main)
  app/sidebar(r, s0).ignore
  view-expenses/show(r, s0).ignore
  ui/frame-end(r)
  println(if win32/save-bmp("out/expenses-bills.bmp") then "wrote out/expenses-bills.bmp"
          else "FAILED out/expenses-bills.bmp")
  e1+e2+e3+e4+e5+e6+e7+e8+e9+e10+e11 + expense-deletion(r, s0)

// An expense typed twice, or against the wrong month, can only come off the
// books here -- and every total in the app is a sum over that table.
fun expense-deletion( r : ref<global,ui/ui>, s0 : app/state ) : io int
  fun count() : io int
    sql/scalar-int("SELECT COUNT(*) FROM expenses", [], -1)
  val before = count()
  val eid = sql/scalar-int("SELECT id FROM expenses WHERE name = 'Water and power'", [], -1)
  val edlg-y = (720 - 360) / 2
  val edel = (rdlg-x + 20 + 65, edlg-y + 360 - 26)

  var s := s0(expense-recurring = False,
              expense = Just(Expense-form(eid, "Water and power", "950", "2025-08-03",
                                          "", "", False)))
  s := frame(r, s, [])
  s := frame(r, s, click(edel.fst, edel.snd))
  val d1 = chk("one click on Delete removes no expense", count().show, before.show)
  s := frame(r, s, click(edel.fst, edel.snd))
  val d2 = chk("the second click deletes the expense", count().show, (before - 1).show)
  val d3 = chk("and the dialog closed", s.expense.is-nothing.show, "True")
  d1+d2+d3

// The bill dialog is 430x280 centred in 1180x720; these are the widget centres.
val rdlg-x = (1180 - 430) / 2
val rdlg-y = (720 - 280) / 2
val name-at = (rdlg-x + 100, rdlg-y + 68 + 18 + 15)
val amount-at = (rdlg-x + 100, rdlg-y + 68 + 52 + 18 + 15)
val save-at = (rdlg-x + 430 - 110 + 45, rdlg-y + 280 - 26)
val delete-at = (rdlg-x + 20 + 65, rdlg-y + 280 - 26)

fun frame( r : ref<global,ui/ui>, s : app/state, evs : list<win32/event> ) : io app/state
  ui/frame-begin(r, evs)
  win32/clip-all()
  win32/fill(0, 0, 1180, 720, s.palette.main)
  val next = dialogs/show(r, s)
  ui/frame-end(r)
  next

fun click( x : int, y : int ) : list<win32/event>
  [win32/Event(win32/ev-mouse-down, x, y, 0), win32/Event(win32/ev-mouse-up, x, y, 0)]

fun typing( t : string ) : list<win32/event>
  t.list.map(fn(c) { win32/Event(win32/ev-char, 0, 0, c.int) })

fun bills-called( what : string ) : io list<models/recurring-expense>
  repo2/list-recurring-expenses().filter(fn(t : models/recurring-expense) { t.name == what })

fun money-of( what : string ) : io string
  bills-called(what).map(fn(t : models/recurring-expense) { models/money("Rs", t.amount) })
    .head.default("")

fun id-of( what : string ) : io int
  bills-called(what).map(fn(t : models/recurring-expense) { models/recurring-expense/id(t) })
    .head.default(0)

fun chk( name : string, got : string, want : string ) : io int
  val ok = got == want
  println((if ok then "  ok   " else "  FAIL ") ++ name.pad-right(48) ++ got.pad-right(16) ++
          (if ok then "" else "want " ++ want))
  if ok then 0 else 1
