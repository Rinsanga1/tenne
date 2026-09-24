// The payments book: a year of one member's dues, twelve months at a time.
//
// This is the dialog the Rust build gets right and is worth copying exactly.
// It is not a form for recording a payment -- it is a year of months you type
// into. Insert, update and delete all fall out of one diff against what is on
// file (`commit` below), which is why there is no Delete button: clearing a
// month's box is the delete.
//
// Three states per month, not two:
//   an amount    money was received that month
//   empty        the month is due
//   Paid ahead   settled without money, stored as a zero-amount payment
//
// The third is what makes six months paid up front representable without
// inventing income in five months it never arrived in. See `app/month-entry`.
module dlg-payments

import std/num/float64
import win32
import sql
import ui
import theme
import widgets
import models
import repo
import dates
import util
import app

// Geometry, exported so the tests click what is actually drawn rather than
// their own copy of these numbers.
pub val book-w = 620
pub val book-h = 430
pub val col-w = 290
pub val line-h = 34

// Twelve months in two columns of six: a year fits with no scrolling, and the
// dialog stays short enough to survive a small window.
pub fun row-x( box : rect, i : int ) : int
  box.x + 16 + (if i < 6 then 0 else col-w)

pub fun row-y( box : rect, i : int ) : int
  box.y + 150 + (i % 6) * line-h

pub fun amount-at( box : rect, i : int ) : (int, int)
  (row-x(box, i) + 78 + 42, row-y(box, i) + 14)

pub fun status-at( box : rect, i : int ) : (int, int)
  (row-x(box, i) + 172 + 50, row-y(box, i) + 14)

pub fun dialog( r : ref<global,ui/ui>, s : app/state, f : app/payments-book ) : io app/state
  val p = s.palette
  // every field read once, up front -- see the Gotchas
  val member-id = f.member-id
  val who = f.who
  val year = f.year
  val lo = f.min-year
  val hi = f.max-year
  val err = f.error
  val was-saved = f.saved
  val box = widgets/modal-frame(r, p, book-w, book-h, "Payments - " ++ who)
  val small = (!r).font-small

  // --- year stepper
  val back = widgets/button(r, p, Rect(box.x + 20, box.y + 62, 30, 30), "<", ui/wid("pb:prev"))
  widgets/label-center((!r).font-body, box.x + 54, 80, box.y + 69, year.show, p.text)
  val fwd = widgets/button(r, p, Rect(box.x + 138, box.y + 62, 30, 30), ">", ui/wid("pb:next"))

  // The money is what the owner is reconciling against, so it is on screen
  // rather than in their head.
  val total = f.entries.foldl(0.0) fn(a, e : app/month-entry)
    a + util/parse-money(e.amount.trim).default(0.0)
  widgets/label-right((!r).font-body, box.x + box.w - 20, box.y + 68,
                      "Total " ++ models/money(s.currency, total), p.text)

  widgets/label(small, box.x + 20, box.y + 100,
                "Put the amount in the month you received it.", p.text-muted)
  widgets/label(small, box.x + 20, box.y + 118,
                "Paid a few months up front? Mark those months Paid ahead - " ++
                "no need to split the money.", p.text-muted)

  // --- the twelve months
  val grid = Rect(box.x + 8, box.y + 140, box.w - 16, box.h - 140 - 56)
  win32/clip(grid.x, grid.y, grid.w, grid.h)
  val edited = f.entries.map-indexed fn(i, e : app/month-entry)
    draw-entry(r, p, box, grid, i, e)
  win32/clip-all()

  val bad = edited.foldl(False) fn(acc, e : app/month-entry)
    val t = e.amount.trim
    acc || (t != "" && util/parse-money(t).is-nothing)

  val g = f(entries = edited)
  val msg-y = box.y + box.h - 46
  if bad then
    widgets/label(small, box.x + 150, msg-y, "Fix the amounts marked ?", theme/warning)
  elif err != "" then
    widgets/label(small, box.x + 150, msg-y, err, theme/negative)
  elif was-saved != "" && was-saved == app/book-snapshot(edited) then
    // Snapshot-based, so the confirmation cannot outlive the edit that
    // invalidated it: one keystroke and it is gone.
    widgets/label(small, box.x + 150, msg-y, "Saved", theme/positive)

  val (save, close) = widgets/modal-buttons(r, p, box, "Save", "pb", !bad)
  val moved = if back && year > lo then 0 - 1 elif fwd && year < hi then 1 else 0

  if close || ui/escape-pressed(r) then s(book = Nothing)
  elif moved != 0 then
    // Commit before switching, or a year's edits are lost by changing year --
    // and refuse to move at all while an amount is unreadable, rather than
    // silently treating it as "no payment" and deleting the month.
    if bad then s(book = Just(g(error = "Fix the amounts marked ? before changing year")))
    else
      val failed = commit(g)
      if failed != "" then s(book = Just(g(error = "Could not save " ++ year.show ++ " - " ++ failed)))
      else s(book = Just(reload(g, year + moved)))
  elif !save then s(book = Just(g))
  else
    val failed = commit(g)
    if failed != "" then s(book = Just(g(error = "Could not save - " ++ failed)))
    else
      val fresh = reload(g, year)
      s(book = Just(fresh(saved = app/book-snapshot(fresh.entries))),
        notice = "Payments saved for " ++ who)

// Re-read from the database rather than trusting what was just written: a
// month that was deleted has to lose its id, or the next save would update a
// payment that no longer exists.
fun reload( f : app/payments-book, year : int ) : io app/payments-book
  f(year = year, entries = app/entries-for(year, repo/payments-for-member(f.member-id)),
    error = "", saved = "")

fun draw-entry( r : ref<global,ui/ui>, p : theme/palette, box : rect, grid : rect,
                i : int, e : app/month-entry ) : io app/month-entry
  val rx = row-x(box, i)
  val ry = row-y(box, i)
  // Rows that do not fit are not drawn and declare no widgets, exactly as the
  // sale dialog's product list does when the window is too short.
  if ry + line-h > grid.y + grid.h || rx + 240 > grid.x + grid.w then e else
    val small = (!r).font-small
    val cov = e.covered
    widgets/label(small, rx, ry + 9, e.label, p.text-muted)
    val typed = widgets/text-field(r, p, Rect(rx + 78, ry, 84, 28), e.amount,
                                   ui/wid-at("pb:amt", i), "")
    val t = typed.trim
    val amount = util/parse-money(t)
    // Empty months carry a button, because their state is the one the user
    // sets: due, or settled without money. A month with an amount in it has
    // already said what it is.
    val toggled = if t != "" then False
                  else widgets/button(r, p, Rect(rx + 172, ry, 100, 28),
                                      (if cov then "Paid ahead" else "Due"),
                                      ui/wid-at("pb:st", i))
    if t != "" then
      val paid = amount.default(0.0) > 0.0
      val word = if amount.is-nothing then "?" elif paid then "Paid" else "Due"
      val col = if amount.is-nothing then theme/negative
                elif paid then theme/positive
                else theme/warning
      widgets/label(small, rx + 180, ry + 9, word, col)
    e(amount = typed, covered = if toggled then !cov else cov)

// Reconcile the year on screen against what is on file. One pass, and every
// one of insert / update / delete falls out of the comparison.
fun commit( f : app/payments-book ) : io string
  val member-id = f.member-id
  f.entries.foldl("") fn(acc, e : app/month-entry)
    if acc != "" then acc else apply(member-id, e)

// What this month should be worth: money if an amount was typed, zero if it
// was marked paid ahead, nothing at all otherwise.
fun target-of( e : app/month-entry ) : maybe<float64>
  val t = e.amount.trim
  val typed = if t == "" then Nothing else util/parse-money(t)
  val v = typed.default(0.0)
  if typed.is-just && v > 0.0 then Just(v)
  elif e.covered then Just(0.0)
  else Nothing

fun apply( member-id : int, e : app/month-entry ) : io string
  val orig = e.original
  val target = target-of(e)
  val want = target.default(0.0)
  val gone = target.is-nothing
  if orig == 0 && gone then ""
  elif orig == 0 then
    // The date is when the money was entered, not the month it settles: the
    // ledger is cash-basis, and `period_month` is what carries the month.
    if repo/insert-payment(Payment(0, member-id, e.month, want, dates/today(), Nothing,
                                   models/cat-membership)) > 0 then "" else sql/error()
  elif gone then
    if repo/delete-payment(orig) then "" else sql/error()
  elif (want - e.was).abs < 0.005 then ""
  else
    match repo/get-payment(orig)
      Nothing -> ""
      Just(old) -> if repo/update-payment(old(amount = want)) then "" else sql/error()
