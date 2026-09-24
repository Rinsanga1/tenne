// Expenses: what the gym spent, and the templates that stop the owner
// retyping "Rent  12000" twelve times a year.
//
// Two tabs. The ledger is what was actually spent; Monthly bills is the list
// of templates behind it. The templates need a tab of their own because
// otherwise they can be used as prefill but never corrected or removed --
// the same gap the Shop had before it grew a Sales tab.
module view-expenses

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

val cols = [Column("DATE", 16, 90), Column("WHAT", 120, 260),
            Column("NOTE", 400, 200), Column("AMOUNT", 620, 110)]

fun col( i : int ) : widgets/column
  cols.drop(i).head.default(Column("", 0, 0))

val tpl-cols = [Column("WHAT", 16, 320), Column("EVERY MONTH", 380, 150)]

fun tcol( i : int ) : widgets/column
  tpl-cols.drop(i).head.default(Column("", 0, 0))

pub fun show( r : ref<global,ui/ui>, s : app/state ) : io app/state
  val p = s.palette
  val box = app/content-rect()
  app/page-title(r, s, "Expenses")

  val f = s.filter
  // .fst/.snd rather than a tuple pattern: destructuring in a function that
  // also consumes `s` has miscompiled in Koka 3.2.3. See the Gotchas.
  val range = dates/range(f)
  val start = range.fst
  val end = range.snd
  val rows = repo2/list-expenses-between(start, end)
  val total = rows.foldl(0.0, fn(a, e : models/expense) { a + e.amount })
  // queried once here and passed down: a repository call inside a row-drawing
  // function drags a `div` effect into it that Koka 3.2.3 miscompiles
  val templates = repo2/list-recurring-expenses()
  val on-recurring = s.expense-recurring

  var st := s

  // period stepper
  if widgets/button(r, p, Rect(box.x, box.y + 1, 30, 30), "<", ui/wid("e:prev")) then
    st := st(filter = dates/previous(f), scroll = 0)
  widgets/label-center((!r).font-body, box.x + 34, 150, box.y + 8, dates/label(f), p.text)
  if widgets/button(r, p, Rect(box.x + 188, box.y + 1, 30, 30), ">", ui/wid("e:next")) then
    st := st(filter = next-period(f), scroll = 0)
  // bound once: reading f.month.is-just twice corrupts the heap in Koka 3.2.3
  val by-month = f.month.is-just
  if widgets/button(r, p, Rect(box.x + 228, box.y + 1, 110, 30),
                    (if by-month then "Whole year" else "By month"),
                    ui/wid("e:span")) then
    st := st(filter = (if by-month then Month-filter(f.year, Nothing)
                       else app/current-filter-of(s.month)), scroll = 0)

  // the primary button follows the tab: on the bills tab it saves a template,
  // not a one-off expense
  if widgets/button-primary(r, p, Rect(box.x + box.w - 120, box.y, 120, 32),
                            (if on-recurring then "Add bill" else "Add expense"),
                            ui/wid("e:add")) then
    if on-recurring then st := st(recurring = Just(app/blank-recurring()), notice = "")
    else st := st(expense = Just(app/blank-expense(dates/today())), notice = "")

  if s.notice != "" then
    widgets/label((!r).font-small, box.x, box.y - 24, s.notice, theme/positive)

  val tabs-y = box.y + 44
  if widgets/tab(r, p, Rect(box.x, tabs-y, 90, 28), "Expenses", !on-recurring, "e:te") then
    st := st(expense-recurring = False, scroll = 0)
  if widgets/tab(r, p, Rect(box.x + 94, tabs-y, 116, 28), "Monthly bills",
                 on-recurring, "e:tr") then
    st := st(expense-recurring = True, scroll = 0)

  // On the ledger tab the saved bills are one-click prefill, so logging this
  // month's rent is a click rather than a retype.
  val chips = !on-recurring && !templates.is-nil
  if chips then st := template-chips(r, st, box, templates)

  val ty = if chips then box.y + 116 else box.y + 84
  val th = box.y + box.h - ty - 40
  widgets/panel(p, Rect(box.x, ty, box.w, th))
  val list-box = Rect(box.x + 1, ty + 42, box.w - 2, th - 43)

  if on-recurring then st := recurring-tab(r, st, box, ty, list-box, templates)
  else st := ledger-tab(r, st, box, ty, list-box, rows)

  val fy = box.y + box.h - 26
  if on-recurring then
    val n = templates.length
    val monthly = templates.foldl(0.0, fn(a, t : models/recurring-expense) { a + t.amount })
    widgets/label((!r).font-small, box.x + 16, fy,
                  n.show ++ (if n == 1 then " saved bill" else " saved bills"), p.text-muted)
    widgets/label-right((!r).font-body, box.x + box.w - 16, fy - 2,
                        models/money(s.currency, monthly) ++ " a month", theme/negative)
  else
    widgets/label((!r).font-small, box.x + 16, fy,
                  rows.length.show ++ (if rows.length == 1 then " expense" else " expenses") ++
                  " in " ++ dates/label(f), p.text-muted)
    widgets/label-right((!r).font-body, box.x + box.w - 16, fy - 2,
                        "Total " ++ models/money(s.currency, total), theme/negative)
  st

// The saved bills as buttons: clicking one opens the expense dialog already
// filled in, which is the whole point of keeping templates.
fun template-chips( r : ref<global,ui/ui>, s : app/state, box : rect,
                    templates : list<models/recurring-expense> ) : io app/state
  val p = s.palette
  widgets/label((!r).font-small, box.x, box.y + 84, "SAVED", p.text-muted)
  // refs, not vars: a `var` read inside the closure drags a local heap
  // effect into a signature that has to be plain `io`
  val pen = ref(box.x + 52)
  val picked = ref("")
  templates.foreach-indexed fn(i, t : models/recurring-expense)
    val caption = t.name ++ "  " ++ models/money(s.currency, t.amount)
    val bw = win32/text-width((!r).font-small, caption) + 24
    val px = !pen
    if widgets/button(r, p, Rect(px, box.y + 80, bw, 26), caption, ui/wid-at("e:tpl", i))
      then picked := t.name ++ "|" ++ util/show-money(t.amount)
    pen := px + bw + 8
  val chosen = !picked
  var st := s
  if chosen != "" then
    match chosen.split("|")
      [nm, amt] -> st := st(expense = Just(Expense-form(0, nm, amt, dates/today(), "", "", False)))
      _ -> ()
  st

fun ledger-tab( r : ref<global,ui/ui>, s : app/state, box : rect, ty : int,
                list-box : rect, rows : list<models/expense> ) : io app/state
  val p = s.palette
  widgets/table-header(r, p, box.x + 16, ty + 14, box.w - 32, cols)
  var st := s
  if rows.is-nil then
    widgets/empty-state(r, p, list-box, "Nothing spent in " ++ dates/label(s.filter),
                        "Rent, salaries, electricity -- anything that leaves the till")
  else
    val opened = ref(0)
    val snap = st
    val next-scroll = widgets/scroll-area(r, p, list-box, rows.length * widgets/row-h,
                                          s.scroll) fn(dy)
      rows.foreach-indexed fn(i, e : models/expense)
        if draw-row(r, snap, list-box, dy, i, e) then opened := models/expense/id(e)
    if next-scroll != s.scroll then st := st(scroll = next-scroll)
    val hit = !opened
    if hit != 0 then
      match repo2/get-expense(hit)
        Just(e) -> st := st(expense = Just(app/expense-form-of(e)), notice = "")
        Nothing -> ()
  st

// The saved bills themselves. A row opens its template for correction or
// removal -- without this, update/delete-recurring-expense are unreachable.
fun recurring-tab( r : ref<global,ui/ui>, s : app/state, box : rect, ty : int,
                   list-box : rect,
                   templates : list<models/recurring-expense> ) : io app/state
  val p = s.palette
  widgets/table-header(r, p, box.x + 16, ty + 14, box.w - 32, tpl-cols)
  var st := s
  if templates.is-nil then
    widgets/empty-state(r, p, list-box, "No monthly bills saved yet",
                        "Save rent, salaries, power -- then log them in one click")
  else
    val opened = ref(0)
    val snap = st
    val next-scroll = widgets/scroll-area(r, p, list-box, templates.length * widgets/row-h,
                                          s.scroll) fn(dy)
      templates.foreach-indexed fn(i, t : models/recurring-expense)
        if draw-template(r, snap, list-box, dy, i, t)
          then opened := models/recurring-expense/id(t)
    if next-scroll != s.scroll then st := st(scroll = next-scroll)
    val hit = !opened
    if hit != 0 then
      match templates.filter(fn(x : models/recurring-expense)
                               { models/recurring-expense/id(x) == hit }).head
        Just(t) -> st := st(recurring = Just(app/recurring-form-of(t)), notice = "")
        Nothing -> ()
  st

fun draw-template( r : ref<global,ui/ui>, s : app/state, list-box : rect, dy : int,
                   i : int, t : models/recurring-expense ) : io bool
  val p = s.palette
  val ry = list-box.y + dy + i * widgets/row-h
  if ry + widgets/row-h < list-box.y || ry > list-box.y + list-box.h then False else
    val row = Rect(list-box.x, ry, list-box.w - widgets/scrollbar-w, widgets/row-h)
    val act = widgets/table-row(r, p, row, i, ui/wid-at("e:tpr", i))
    // everything bound once, before any drawing -- see the Gotchas
    val ox = list-box.x + 15
    val fnt = (!r).font-body
    val line = win32/font-line(fnt)
    val amount = models/money(s.currency, t.amount)
    val c-amt = tcol(1)
    widgets/cell(r, tcol(0), ox, ry, t.name, p.text)
    widgets/label-right(fnt, ox + c-amt.x + c-amt.w, ry + (widgets/row-h - line) / 2,
                        amount, p.text)
    act.clicked

fun next-period( f : dates/month-filter ) : dates/month-filter
  match f.month
    Just(12) -> Month-filter(f.year + 1, Just(1))
    Just(m) -> Month-filter(f.year, Just(m + 1))
    Nothing -> Month-filter(f.year + 1, Nothing)

fun draw-row( r : ref<global,ui/ui>, s : app/state, list-box : rect, dy : int,
              i : int, e : models/expense ) : io bool
  val p = s.palette
  val ry = list-box.y + dy + i * widgets/row-h
  if ry + widgets/row-h < list-box.y || ry > list-box.y + list-box.h then False else
    val row = Rect(list-box.x, ry, list-box.w - widgets/scrollbar-w, widgets/row-h)
    val act = widgets/table-row(r, p, row, i, ui/wid-at("e:row", i))
    val ox = list-box.x + 15
    // straight-line, not a nested `match cols` -- see the Gotchas
    widgets/cell(r, col(0), ox, ry, dates/short-date(e.date), p.text-muted)
    widgets/cell(r, col(1), ox, ry,
                 (if e.name.trim == "" then "Expense" else e.name), p.text)
    widgets/cell(r, col(2), ox, ry, e.note.default(""), p.text-muted)
    val c-amt = col(3)
    widgets/label-right((!r).font-body, ox + c-amt.x + c-amt.w,
                        ry + (widgets/row-h - win32/font-line((!r).font-body)) / 2,
                        models/money(s.currency, e.amount), p.text)
    act.clicked
