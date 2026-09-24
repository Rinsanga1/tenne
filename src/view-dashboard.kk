// The Dashboard: the two numbers that matter, then the figures behind them.
//
// Every figure is recomputed from the database each frame. The Rust build
// cached this and had to invalidate the cache on every navigation; here there
// is nothing to invalidate, so a payment recorded in a dialog shows up in the
// net-earnings figure on the very next frame.
module view-dashboard

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

pub fun show( r : ref<global,ui/ui>, s : app/state ) : io app/state
  val p = s.palette
  val box = app/content-rect()
  app/page-title(r, s, "Dashboard")

  val f = s.filter
  // .fst/.snd rather than a tuple pattern: destructuring in a function that
  // also consumes `s` has miscompiled in Koka 3.2.3. See the Gotchas.
  val range = dates/range(f)
  val start = range.fst
  val end = range.snd
  val income = repo2/total-income(start, end)
  val expenses = repo2/total-expenses(start, end)
  val net = income - expenses
  val dues = repo/category-income(models/cat-membership, start, end)
  val joining = repo/category-income(models/cat-registration, start, end)
  val merch = repo2/merch-income(start, end)
  val units = repo2/merch-units(start, end)
  val due-now = repo/due-members-with-arrears(s.month)
  val owed = due-now.foldl(0.0, fn(a, t : repo/arrears) { a + t.thd })

  // the same figure one period back, for the up/down-vs-last line
  val prev = dates/previous(f)
  val prange = dates/range(prev)
  val pstart = prange.fst
  val pend = prange.snd
  val prev-net = repo2/net-earnings(pstart, pend)

  var st := s

  // --- period picker
  if widgets/button(r, p, Rect(box.x + box.w - 210, box.y - 40, 30, 26), "<",
                    ui/wid("d:prev")) then
    st := st(filter = dates/previous(f))
  widgets/label-center((!r).font-small, box.x + box.w - 176, 142, box.y - 34,
                       dates/label(f), p.text-muted)
  if widgets/button(r, p, Rect(box.x + box.w - 30, box.y - 40, 30, 26), ">",
                    ui/wid("d:next")) then
    st := st(filter = next-period(f))

  // --- the two heroes
  val hw = (box.w - 16) / 2
  hero(r, s, Rect(box.x, box.y, hw, 108), "Net earnings",
       models/money(s.currency, net),
       trend-line(net, prev-net, dates/label(prev)),
       if net < 0.0 then theme/negative else theme/positive)

  val due-hero = Rect(box.x + hw + 16, box.y, hw, 108)
  hero(r, s, due-hero, "Members due", due-now.length.show,
       (if due-now.is-nil then ("all paid up for " ++ dates/pretty-month(s.month), p.text-muted)
        else (models/money(s.currency, owed) ++ " outstanding", theme/negative)),
       if due-now.is-nil then theme/positive else theme/negative)
  // The figure drills through to exactly the members it counted.
  if ui/behavior(r, ui/wid("d:due"), due-hero).clicked then
    st := st(view = Members, active-only = True, search = "", member-slice = 1, scroll = 0)

  // --- the figures behind them
  val ky = box.y + 124
  widgets/panel(p, Rect(box.x, ky, box.w, 84))
  val kw = box.w / 4
  kpi(r, s, box.x + 20, ky + 18, kw, "Monthly dues", models/money(s.currency, dues))
  kpi(r, s, box.x + 20 + kw, ky + 18, kw, "Joining fees", models/money(s.currency, joining))
  kpi(r, s, box.x + 20 + kw * 2, ky + 18, kw, "Shop",
      models/money(s.currency, merch) ++ "  (" ++ units.show ++
      (if units == 1 then " unit)" else " units)"))
  kpi(r, s, box.x + 20 + kw * 3, ky + 18, kw, "Expenses",
      "-" ++ models/money(s.currency, expenses))

  // --- revenue chart
  val cy = ky + 100
  val ch = 170
  widgets/panel(p, Rect(box.x, cy, box.w, ch))
  widgets/label((!r).font-small, box.x + 20, cy + 14, "REVENUE, LAST 12 MONTHS", p.text-muted)
  chart(r, s, Rect(box.x + 20, cy + 40, box.w - 40, ch - 62),
        repo2/monthly-revenue(s.month, 12))

  // --- low stock and recent activity, side by side
  val by = cy + ch + 16
  val bh = box.y + box.h - by
  val bw = (box.w - 16) / 2
  // the low-stock panel drills through to the Shop, which is where the owner
  // acts on it
  if low-stock(r, s, Rect(box.x, by, bw, bh)) then st := st(view = Shop, shop-sales = False)
  val nav = recent(r, s, Rect(box.x + bw + 16, by, bw, bh))
  if nav then st := st(view = Transactions)
  st

fun next-period( f : dates/month-filter ) : dates/month-filter
  match f.month
    Just(12) -> Month-filter(f.year + 1, Just(1))
    Just(m) -> Month-filter(f.year, Just(m + 1))
    Nothing -> Month-filter(f.year + 1, Nothing)

// A number big enough to read across the room, with a line under it saying
// what it is measured against.
fun hero( r : ref<global,ui/ui>, s : app/state, b : rect, caption : string,
          value : string, sub : (string, int), accent : int ) : io ()
  val p = s.palette
  widgets/panel(p, b)
  win32/round-fill(b.x, b.y, 3, b.h, 2, accent)
  widgets/label((!r).font-small, b.x + 20, b.y + 16, caption, p.text-muted)
  widgets/label((!r).font-hero, b.x + 20, b.y + 36, value, p.text)
  widgets/label((!r).font-small, b.x + 20, b.y + 76, sub.fst, sub.snd)

// "+18% vs July 2025", or nothing when the baseline is zero -- a percentage
// change from nothing is not a number, it is a division by zero dressed up.
fun trend-line( net : float64, prev : float64, baseline : string ) : (string, int)
  if prev == 0.0 then ("no comparable " ++ baseline, 0xFF737373)
  else
    val pct = ((net - prev) / (if prev < 0.0 then 0.0 - prev else prev) * 100.0).round.int
    val up = net >= prev
    ((if up then "+" else "") ++ pct.show ++ "% vs " ++ baseline,
     if up then theme/positive else theme/negative)

fun kpi( r : ref<global,ui/ui>, s : app/state, x : int, y : int, w : int,
         caption : string, value : string ) : io ()
  widgets/label((!r).font-small, x, y, caption, s.palette.text-muted)
  widgets/label-clipped((!r).font-semi, x, y + 20, w - 20, value, s.palette.text)

// A bar per month. Hand-drawn, because a chart library for eight rectangles
// would be the tail wagging the dog.
fun chart( r : ref<global,ui/ui>, s : app/state, b : rect,
           data : list<(string, float64)> ) : io ()
  val p = s.palette
  if data.is-nil then
    widgets/label((!r).font-small, b.x, b.y + b.h / 2, "No revenue recorded yet", p.text-muted)
  else
    val peak = data.foldl(0.0, fn(a, d : (string, float64)) { if d.snd > a then d.snd else a })
    val n = data.length
    val slot = b.w / n
    val bw = int/max(6, slot - 10)
    data.foreach-indexed fn(i, d : (string, float64))
      // .fst/.snd rather than destructuring: a tuple pattern in a closure that
      // also touches outer values has miscompiled in Koka 3.2.3 before.
      val ym = d.fst
      val v = d.snd
      // A zero month still gets a 2px stub, so an empty month reads as
      // "nothing came in" rather than as a gap in the chart.
      val bh = if peak <= 0.0 then 2 else int/max(2, (v / peak * (b.h - 22).float64).int)
      val bx = b.x + i * slot + (slot - bw) / 2
      val by = b.y + (b.h - 22) - bh
      val this-month = ym == s.month
      win32/round-fill(bx, by, bw, bh, 3, if this-month then p.accent else widgets/tint(p.accent, 110))
      widgets/label-center((!r).font-small, bx - 6, bw + 12, b.y + b.h - 16,
                           month-initial(ym), if this-month then p.text else p.text-muted)
    if peak > 0.0 then
      widgets/label-right((!r).font-small, b.x + b.w, b.y - 18,
                          "peak " ++ models/money(s.currency, peak), p.text-muted)

fun month-initial( ym : string ) : string
  match dates/parse-month(ym)
    Nothing -> "?"
    Just((_, m)) -> dates/month-name(m).list.take(1).string

fun low-stock( r : ref<global,ui/ui>, s : app/state, b : rect ) : io bool
  val p = s.palette
  widgets/panel(p, b)
  widgets/label((!r).font-small, b.x + 20, b.y + 14, "LOW STOCK", p.text-muted)
  val go = widgets/button(r, p, Rect(b.x + b.w - 90, b.y + 8, 70, 24), "Shop",
                          ui/wid("d:shop"))
  val low = repo2/low-stock-products(5)
  if low.is-nil then
    widgets/label((!r).font-small, b.x + 20, b.y + 40, "Everything is well stocked", p.text-muted)
  else
    win32/clip(b.x, b.y + 34, b.w, b.h - 40)
    low.foreach-indexed fn(i, prod : models/product)
      val y = b.y + 40 + i * 24
      widgets/label-clipped((!r).font-body, b.x + 20, y, b.w - 120, prod.name, p.text)
      // Negative stock should be impossible -- StockNeverNegative -- but if a
      // database ever arrives with it, say so rather than drawing "-1 left".
      val n = prod.stock
      widgets/label-right((!r).font-body, b.x + b.w - 20, y,
                          (if n < 0 then "oversold by " ++ (0 - n).show
                           elif n == 0 then "out of stock"
                           else n.show ++ " left"),
                          if n <= 0 then theme/negative else theme/warning)
    win32/clip-all()
  go

// Returns True if the user asked to see the whole ledger.
fun recent( r : ref<global,ui/ui>, s : app/state, b : rect ) : io bool
  val p = s.palette
  widgets/panel(p, b)
  widgets/label((!r).font-small, b.x + 20, b.y + 14, "RECENT ACTIVITY", p.text-muted)
  val more = widgets/button(r, p, Rect(b.x + b.w - 90, b.y + 8, 70, 24), "See all",
                            ui/wid("d:all"))
  val rows = repo2/recent-transactions(6)
  if rows.is-nil then
    widgets/label((!r).font-small, b.x + 20, b.y + 40, "Nothing recorded yet", p.text-muted)
  else
    win32/clip(b.x, b.y + 34, b.w, b.h - 40)
    rows.foreach-indexed fn(i, t : models/txn)
      val y = b.y + 40 + i * 24
      widgets/label((!r).font-small, b.x + 20, y, dates/short-date(t.date), p.text-muted)
      widgets/label-clipped((!r).font-body, b.x + 80, y, b.w - 200, t.label, p.text)
      val sign = if t.amount < 0.0 then "" else "+"
      widgets/label-right((!r).font-body, b.x + b.w - 20, y,
                          sign ++ models/money(s.currency, t.amount),
                          if t.amount < 0.0 then theme/negative else theme/positive)
    win32/clip-all()
  more
