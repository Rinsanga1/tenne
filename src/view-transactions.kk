// Transactions: every money movement in one list, newest first.
//
// Payments, sales and expenses live in three tables; this view is the one
// place they are read as a single stream, which is what makes "where did the
// money go" answerable at all.
module view-transactions

import std/num/float64
import win32
import ui
import theme
import widgets
import models
import repo
import repo2
import dates
import util
import app

val cols = [Column("DATE", 16, 90), Column("WHAT", 120, 300),
            Column("KIND", 440, 110), Column("AMOUNT", 580, 120)]

fun col( i : int ) : widgets/column
  cols.drop(i).head.default(Column("", 0, 0))

pub fun show( r : ref<global,ui/ui>, s : app/state ) : io app/state
  val p = s.palette
  val box = app/content-rect()
  app/page-title(r, s, "Transactions")

  val f = s.filter
  // .fst/.snd rather than a tuple pattern: destructuring in a function that
  // also consumes `s` has miscompiled in Koka 3.2.3. See the Gotchas.
  val range = dates/range(f)
  val start = range.fst
  val end = range.snd
  val all = repo2/transactions-between(start, end)
  val rows = if s.search.trim == "" then all
             else all.filter(fn(t : models/txn) { contains-ci(t.label, s.search.trim) })

  val money-in = rows.filter(fn(t : models/txn) { t.amount > 0.0 })
                     .foldl(0.0, fn(a, t : models/txn) { a + t.amount })
  val money-out = rows.filter(fn(t : models/txn) { t.amount < 0.0 })
                      .foldl(0.0, fn(a, t : models/txn) { a - t.amount })

  var st := s
  val q = widgets/text-field(r, p, Rect(box.x, box.y, 280, 32), s.search,
                             ui/wid("t:search"), "Filter by description")
  if q != s.search then st := st(search = q, scroll = 0)

  // period stepper
  if widgets/button(r, p, Rect(box.x + 300, box.y + 1, 30, 30), "<", ui/wid("t:prev")) then
    st := st(filter = dates/previous(f), scroll = 0)
  widgets/label-center((!r).font-body, box.x + 334, 150, box.y + 8, dates/label(f), p.text)
  if widgets/button(r, p, Rect(box.x + 488, box.y + 1, 30, 30), ">", ui/wid("t:next")) then
    st := st(filter = next-period(f), scroll = 0)
  // A whole year, or one month within it.
  val by-month = f.month.is-just
  if widgets/button(r, p, Rect(box.x + 528, box.y + 1, 110, 30),
                    (if by-month then "Whole year" else "By month"),
                    ui/wid("t:span")) then
    st := st(filter = (if by-month then Month-filter(f.year, Nothing)
                       else app/current-filter-of(s.month)), scroll = 0)

  val ty = box.y + 48
  val th = box.h - 48 - 40
  widgets/panel(p, Rect(box.x, ty, box.w, th))
  widgets/table-header(r, p, box.x + 16, ty + 14, box.w - 32, cols)

  val list-box = Rect(box.x + 1, ty + 42, box.w - 2, th - 43)
  if rows.is-nil then
    widgets/empty-state(r, p, list-box,
                        (if s.search.trim != "" then "Nothing matches that filter"
                         else "Nothing recorded in " ++ dates/label(f)),
                        "Payments, shop sales and expenses all appear here")
  else
    val opened = ref(0)
    val snap = st
    val next-scroll = widgets/scroll-area(r, p, list-box, rows.length * widgets/row-h,
                                          s.scroll) fn(dy)
      rows.foreach-indexed fn(i, t : models/txn)
        if draw-row(r, snap, list-box, dy, i, t) then opened := i + 1
    if next-scroll != s.scroll then st := st(scroll = next-scroll)
    // A row in the ledger is a pointer at a real record somewhere else. Tapping
    // it should open that record, not leave the owner to go and find it.
    val hit = !opened
    if hit != 0 then
      match rows.drop(hit - 1).head
        Just(t) -> st := open-source(st, t)
        Nothing -> ()

  val fy = box.y + box.h - 26
  widgets/label((!r).font-small, box.x + 16, fy,
                rows.length.show ++ (if rows.length == 1 then " entry" else " entries"),
                p.text-muted)
  // In, out, and the difference -- the three numbers a ledger is for.
  widgets/label((!r).font-small, box.x + 150, fy,
                "in " ++ models/money(s.currency, money-in), theme/positive)
  widgets/label((!r).font-small, box.x + 290, fy,
                "out " ++ models/money(s.currency, money-out), theme/negative)
  val net = money-in - money-out
  widgets/label-right((!r).font-body, box.x + box.w - 16, fy - 2,
                      "Net " ++ models/money(s.currency, net),
                      if net < 0.0 then theme/negative else theme/positive)
  st

fun next-period( f : dates/month-filter ) : dates/month-filter
  match f.month
    Just(12) -> Month-filter(f.year + 1, Just(1))
    Just(m) -> Month-filter(f.year, Just(m + 1))
    Nothing -> Month-filter(f.year + 1, Nothing)

fun contains-ci( hay : string, needle : string ) : bool
  hay.to-lower.contains(needle.to-lower)

// Where a ledger row came from. A payment opens the member it belongs to (with
// the roster unfiltered behind it, so they are findable); a sale opens the Shop's
// sales list; an expense opens its own dialog for correction.
fun open-source( s : app/state, t : models/txn ) : io app/state
  val k = t.kind
  if k.is-payment then
    match repo/get-payment(models/txn/id(t))
      Just(pay) -> s(view = Members, selected = pay.member-id, member-slice = 0,
                     active-only = False, search = "", notice = "")
      Nothing -> s(notice = "That payment is no longer on file")
  elif k.is-sale then
    s(view = Shop, shop-sales = True, filter = app/current-filter-of(t.date), scroll = 0)
  else
    match repo2/get-expense(models/txn/id(t))
      Just(e) -> s(expense = Just(app/expense-form-of(e)), notice = "")
      Nothing -> s(notice = "That expense is no longer on file")

fun draw-row( r : ref<global,ui/ui>, s : app/state, list-box : rect, dy : int,
              i : int, t : models/txn ) : io bool
  val p = s.palette
  val ry = list-box.y + dy + i * widgets/row-h
  if ry + widgets/row-h < list-box.y || ry > list-box.y + list-box.h then False else
    val row = Rect(list-box.x, ry, list-box.w - widgets/scrollbar-w, widgets/row-h)
    val act = widgets/table-row(r, p, row, i, ui/wid-at("t:row", i))
    val ox = list-box.x + 15
    // straight-line, not a nested `match cols` -- see the Gotchas
    widgets/cell(r, col(0), ox, ry, dates/short-date(t.date), p.text-muted)
    widgets/cell(r, col(1), ox, ry, t.label, p.text)
    widgets/pill((!r).font-small, ox + col(2).x, ry + 10,
                 kind-label(t.kind), kind-colour(t.kind, p))
    val c-amt = col(3)
    val sign = if t.amount < 0.0 then "" else "+"
    widgets/label-right((!r).font-body, ox + c-amt.x + c-amt.w,
                        ry + (widgets/row-h - win32/font-line((!r).font-body)) / 2,
                        sign ++ models/money(s.currency, t.amount),
                        if t.amount < 0.0 then theme/negative else theme/positive)
    act.clicked

fun kind-label( k : models/txn-kind ) : string
  if k.is-payment then "Payment" elif k.is-sale then "Shop" else "Expense"

fun kind-colour( k : models/txn-kind, p : theme/palette ) : int
  if k.is-payment then theme/positive
  elif k.is-sale then p.accent
  else theme/negative
