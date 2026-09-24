// A soak of the real frame loop: every view, every dialog, hundreds of frames,
// with synthetic input, checking that nothing corrupts.
//
// This exists because Koka 3.2.3's `match`-arm double-free lived in main.kk's
// view dispatch for a whole iteration without any suite noticing -- the per-view
// tests each exercised one view in one process. The bug needed the dispatch
// itself, run repeatedly. So this runs the dispatch.
module soak

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
import view-expenses
import view-shop
import view-settings
import dialogs

// The same dispatch main.kk uses. If this drifts from main.kk the soak is
// worthless, so keep them identical.
fun views( r : ref<global,ui/ui>, s : app/state ) : io app/state
  if app/same-view(s.view, Members) then view-members/show(r, s)
  elif app/same-view(s.view, Dashboard) then view-dashboard/show(r, s)
  elif app/same-view(s.view, Transactions) then view-transactions/show(r, s)
  elif app/same-view(s.view, Expenses) then view-expenses/show(r, s)
  elif app/same-view(s.view, Shop) then view-shop/show(r, s)
  elif app/same-view(s.view, Settings) then view-settings/show(r, s)
  else s

fun frame( r : ref<global,ui/ui>, s : app/state, evs : list<win32/event> ) : io app/state
  ui/frame-begin(r, evs)
  win32/clip-all()
  win32/fill(0, 0, win32/width(), win32/height(), s.palette.main)
  val blocked = app/modal-open(s)
  if blocked then ui/begin-inert(r)
  val chosen = app/sidebar(r, s)
  val s1 = if app/same-view(chosen, s.view) then s
           else app/close-dialogs(s)(view = chosen, scroll = 0, notice = "")
  val s2 = views(r, s1)
  if blocked then ui/end-inert(r)
  val s3 = dialogs/show(r, s2)
  ui/frame-end(r)
  s3

pub fun main() : io ()
  sql/unbuffer()
  val path = "out/dash.db"
  if !sql/file-exists(path) then println("SKIP: seed out/dash.db by running dashtest first")
  else
    db/open-db(path).ignore
    win32/offscreen(1180, 720)
    win32/font-file("assets/fonts/Geist-Regular.ttf").ignore
    win32/font-file("assets/fonts/Geist-SemiBold.ttf").ignore
    val r = ref(ui/new-ui(win32/font("Geist", 14, 400), win32/font("Geist SemiBold", 15, 600),
                          win32/font("Geist", 12, 400), win32/font("Geist SemiBold", 30, 600)))
    val s0 = app/new-state(theme/palette-of("dark"), repo/gym-name(), "Rs", "out", "2025-08", "1500", "500")
    val n = rounds(r, s0, 12, 0)
    println("soaked " ++ n.show ++ " frames across every view and dialog")
    sql/close().ignore
    println("ALL PASS")

// No refs anywhere below: a `ref` passed across a function boundary makes
// Koka 3.2.3 emit undeclared evidence variables. State is threaded instead,
// which is what an immediate-mode UI does anyway.
fun rounds( r : ref<global,ui/ui>, s : app/state, left : int, n : int ) : io int
  if left <= 0 then n
  else
    val (s1, n1) = sweep-views(r, s, 0, n)
    val (s2, n2) = sweep-dialogs(r, s1, n1)
    rounds(r, s2, left - 1, n2)

// Every view in turn, reached by a real click on the sidebar, then hovered and
// scrolled both ways.
fun sweep-views( r : ref<global,ui/ui>, s : app/state, i : int,
                 n : int ) : io (app/state, int)
  if i > 5 then (s, n)
  else
    val a = frame(r, s, click(90, 90 + i * 34))
    val b = frame(r, a, [])
    val c = frame(r, b, [win32/Event(win32/ev-mouse-move, 600, 300, 0)])
    val d = frame(r, c, [win32/Event(win32/ev-scroll, 600, 300, -120)])
    val e = frame(r, d, [win32/Event(win32/ev-scroll, 600, 300, 120)])
    sweep-views(r, e, i + 1, n + 5)

// Open each dialog, draw it, hover it, type into it, then Escape out.
fun sweep-dialogs( r : ref<global,ui/ui>, s : app/state, n : int ) : io (app/state, int)
  val id = repo/list-members(True).map(fn(m : models/member) { models/member/id(m) })
             .head.default(1)
  // Editing is a different dialog from adding -- it carries an id and grows a
  // Delete button -- so both shapes of each get swept.
  val pay = repo/payments-for-member(id).head
  val prod = repo2/list-products().head
  val sale = repo2/list-sales().head
  val expense = repo2/list-expenses-between("0000-00-00", "9999-99-99").head
  val tpl = repo2/list-recurring-expenses().head
  val edits = [ repo/get-member(id).map(fn(m : models/member)
                  { s(view = Members, book = Just(app/book-of(m, repo/payments-for-member(id),
                                                              "2025-08"))) }),
                pay.map(fn(x : models/payment) { s(view = Members, paying = Just(app/payment-form-of(x, "X"))) }),
                prod.map(fn(x : models/product) { s(view = Shop, product = Just(app/product-form-of(x))) }),
                sale.map(fn(x : models/sale) { s(view = Shop, shop-sales = True,
                                                 sale = Just(app/sale-form-of(models/sale/id(x), x.date,
                                                                              repo2/holdings(models/sale/id(x))))) }),
                expense.map(fn(x : models/expense) { s(view = Expenses, expense = Just(app/expense-form-of(x))) }),
                tpl.map(fn(x : models/recurring-expense) { s(view = Expenses, expense-recurring = True,
                                                             recurring = Just(app/recurring-form-of(x))) }) ]
  val opens = edits.foldl([], fn(acc : list<app/state>, m : maybe<app/state>)
                                { match m { Just(x) -> Cons(x, acc); Nothing -> acc } }) ++
              [ s(view = Members, selected = id),
                s(view = Members, form = Just(app/blank-form("2025-08-20", "500", "1500"))),
                s(view = Members, paying = Just(Payment-form(0, id, "X", "2025-08", "1500",
                                                             models/cat-membership, "", False))),
                s(view = Members, confirm-delete = id),
                s(view = Expenses, expense = Just(app/blank-expense("2025-08-20"))),
                s(view = Expenses, expense-recurring = True,
                  recurring = Just(app/blank-recurring())),
                s(view = Shop, product = Just(app/blank-product())),
                s(view = Shop, sale = Just(app/blank-sale("2025-08-20"))),
                s(view = Settings, licence = Just(app/blank-licence())) ]
  val ended = opens.foldl(s) fn(acc : app/state, st : app/state)
    val a = frame(r, st, [])
    val b = frame(r, a, [win32/Event(win32/ev-mouse-move, 590, 360, 0)])
    val c = frame(r, b, "abc".list.map(fn(ch) { win32/Event(win32/ev-char, 0, 0, ch.int) }))
    val d = frame(r, c, [win32/Event(win32/ev-key-down, 0, 0, win32/key-escape)])
    app/close-dialogs(d)
  (ended, n + opens.length * 4)

fun click( x : int, y : int ) : list<win32/event>
  [win32/Event(win32/ev-mouse-down, x, y, 0), win32/Event(win32/ev-mouse-up, x, y, 0)]
