// The Members view: who is on the books, who has paid, who owes.
//
// Everything on screen is read from the database each frame. The only state
// that survives is in app/state -- the search box, the scroll offset, which
// dialog is open. That is the immediate-mode bargain: no cache to invalidate,
// so a payment recorded in a dialog is visible the moment the dialog closes.
module view-members

import std/num/float64
import win32
import ui
import theme
import widgets
import models
import repo
import dates
import util
import app

// Offsets chosen so every column fits at the enforced minimum window width
// (900px, giving a 630px table). STATUS being cut off is not cosmetic -- it is
// the column the owner scans down.
// named, not an inline multi-statement lambda: those cannot be a
// parenthesised argument in Koka
fun owes( m : models/member, owing-ids : list<int> ) : bool
  val mid = models/member/id(m)
  owing-ids.any(fn(i) { i == mid })

fun col( i : int ) : widgets/column
  cols.drop(i).head.default(Column("", 0, 0))

val cols = [Column("NAME", 16, 190), Column("PHONE", 220, 120),
            Column("JOINED", 350, 100), Column("ARREARS", 460, 100),
            Column("STATUS", 570, 80)]

pub fun show( r : ref<global,ui/ui>, s : app/state ) : io app/state
  val p = s.palette
  val box = app/content-rect()
  app/page-title(r, s, "Members")

  // --- data, read fresh every frame
  val listed = if s.search.trim == ""
                 then repo/list-members(s.active-only)
                 else repo/search-members(s.search.trim, s.active-only)
  val paid-ids = repo/paid-member-ids(s.month)
  val arrears = repo/due-members-with-arrears(s.month)
  // The Dashboard's "Members due" hero drills through to exactly this set, so
  // the number it shows and the list here can never disagree.
  val owing-ids = arrears.map(fn(t : repo/arrears) { models/member/id(t.fst) })
  val slice = s.member-slice
  val everyone = if slice == 1 then listed.filter(fn(m : models/member) { owes(m, owing-ids) })
                 elif slice == 2 then listed.filter(fn(m : models/member) { !owes(m, owing-ids) })
                 else listed
  val total-due = arrears.foldl(0.0, fn(a, t : repo/arrears) { a + t.thd })

  // the outcome of the last action, so a dialog that closed still says what
  // it did
  if s.notice != "" then
    widgets/label((!r).font-small, box.x, box.y - 24, s.notice, theme/positive)

  // --- header controls, laid out from the right so they never overlap the
  // search box. Overlapping widgets also overlap their hit areas, so a click
  // would land on whichever was built first rather than the one under it.
  var st := s
  val add-w = 120
  val only-w = 110
  val q-w = int/max(150, box.w - add-w - only-w - 32)
  val q = widgets/text-field(r, p, Rect(box.x, box.y, q-w, 32), s.search,
                             ui/wid("m:search"), "Search name or phone")
  if q != s.search then st := st(search = q, scroll = 0, notice = "")

  val only = widgets/checkbox(r, p, box.x + q-w + 16, box.y + 6, "Active only",
                              s.active-only, "m:active")
  if only != s.active-only then st := st(active-only = only, scroll = 0, notice = "")

  // The slice is always on screen, not only once something else set it: a
  // roster that looks short has to explain itself, and the way out of a
  // filter has to be where the filter is.
  val tabs-y = box.y + 42
  if widgets/tab(r, p, Rect(box.x, tabs-y, 90, 26), "All", slice == 0, "m:sall") then
    st := st(member-slice = 0, scroll = 0, notice = "")
  if widgets/tab(r, p, Rect(box.x + 94, tabs-y, 80, 26), "Owing", slice == 1, "m:sdue") then
    st := st(member-slice = 1, scroll = 0, notice = "")
  if widgets/tab(r, p, Rect(box.x + 178, tabs-y, 110, 26), "Paid up", slice == 2, "m:spaid") then
    st := st(member-slice = 2, scroll = 0, notice = "")

  if widgets/button-primary(r, p, Rect(box.x + box.w - add-w, box.y, add-w, 32),
                            "Add member", ui/wid("m:add")) then
    st := st(notice = "",
             form = Just(app/blank-form(dates/today(),
                                        util/show-money(repo/registration-fee()),
                                        util/show-money(repo/default-monthly-fee()))))

  // --- the table
  val ty = box.y + 76
  val th = box.y + box.h - ty - 40
  widgets/panel(p, Rect(box.x, ty, box.w, th))
  widgets/table-header(r, p, box.x + 16, ty + 14, box.w - 32, cols)

  val list-box = Rect(box.x + 1, ty + 42, box.w - 2, th - 43)
  if everyone.is-nil then
    val what = if slice == 1 then "Nobody owes anything"
               elif slice == 2 then "Nobody is paid up yet"
               elif s.search.trim != "" then "No member matches that search"
               elif s.active-only then "No active members yet"
               else "No members yet"
    widgets/empty-state(r, p, list-box, what,
                        if slice == 1 then "Every active member is paid up for " ++
                                            dates/pretty-month(s.month)
                        elif slice == 2 then "Nobody has settled " ++
                                             dates/pretty-month(s.month) ++ " yet"
                        elif s.search.trim != "" then "Try a different name or phone number"
                        else "Add your first member to start recording payments")
  else
    // A ref, not a var: a `var` read inside the closure drags a local heap
    // effect into a signature that has to be plain `io`.
    val opened = ref(0)
    val snap = st
    val next-scroll = widgets/scroll-area(r, p, list-box,
                                          everyone.length * widgets/row-h, s.scroll) fn(dy)
      everyone.foreach-indexed fn(i, m : models/member)
        if draw-row(r, snap, list-box, dy, i, m, paid-ids, arrears)
          then opened := models/member/id(m)
    if next-scroll != s.scroll then st := st(scroll = next-scroll)
    if !opened != 0 then st := st(selected = !opened, notice = "")

  // --- footer
  val fy = box.y + box.h - 26
  val active = repo/count-members(True)
  widgets/label((!r).font-small, box.x + 16, fy,
                everyone.length.show ++ " shown  -  " ++ active.show ++ " active", p.text-muted)
  if total-due > 0.0 then
    widgets/label-right((!r).font-body, box.x + box.w - 16, fy - 2,
                        "Due this month  " ++ models/money(s.currency, total-due),
                        theme/negative)
  st

// Returns True if this row was clicked.
fun draw-row( r : ref<global,ui/ui>, s : app/state, list-box : rect, dy : int,
              i : int, m : models/member, paid-ids : list<int>,
              arrears : list<repo/arrears> ) : io bool
  val p = s.palette
  val ry = list-box.y + dy + i * widgets/row-h
  // Rows scrolled out of view cost nothing but a rectangle test.
  if ry + widgets/row-h < list-box.y || ry > list-box.y + list-box.h then False else
    val row = Rect(list-box.x, ry, list-box.w - widgets/scrollbar-w, widgets/row-h)
    val act = widgets/table-row(r, p, row, i, ui/wid-at("m:row", i))
    val ox = list-box.x + 15

    // Straight-line, not a nested `match cols`: those arms consume `r`, `s`,
    // `m` and the rest from outside the match, which Koka 3.2.3 miscompiles
    // into a double-drop. It segfaulted here. See the Gotchas.
    widgets/cell(r, col(0), ox, ry, m.name, p.text)
    widgets/cell(r, col(1), ox, ry, m.phone.default("-"), p.text-muted)
    widgets/cell(r, col(2), ox, ry, m.join-date, p.text-muted)
    draw-arrears(r, s, col(3), ox, ry, m, arrears)
    draw-status(r, s, col(4), ox, ry, m, paid-ids)
    act.clicked

fun draw-arrears( r : ref<global,ui/ui>, s : app/state, c : widgets/column, ox : int, ry : int,
                  m : models/member, arrears : list<repo/arrears> ) : io ()
  val mid = models/member/id(m)
  val owed = arrears.filter(fn(t : repo/arrears) { models/member/id(t.fst) == mid })
  match owed
    Nil -> widgets/cell(r, c, ox, ry, "-", s.palette.text-muted)
    Cons(t, _) ->
      // Months behind and what that is worth, because "3 months" and
      // "Rs 4,500" answer different questions.
      val f = (!r).font-body
      val small = (!r).font-small
      widgets/label(f, ox + c.x, ry + 6, models/money(s.currency, t.thd), theme/negative)
      widgets/label(small, ox + c.x, ry + 23,
                    t.snd.show ++ (if t.snd == 1 then " month" else " months"),
                    s.palette.text-muted)

fun draw-status( r : ref<global,ui/ui>, s : app/state, c : widgets/column, ox : int, ry : int,
                 m : models/member, paid-ids : list<int> ) : io ()
  val status = repo/status-of(m, paid-ids)
  val col = match status
    Paid -> theme/positive
    Due -> theme/negative
    Inactive -> s.palette.text-muted
  widgets/pill((!r).font-small, ox + c.x, ry + 10, models/status-label(status), col)
