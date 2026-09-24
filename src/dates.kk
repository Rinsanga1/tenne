// Dates, as the database stores them: `YYYY-MM-DD` and `YYYY-MM`, always.
//
// The Rust build leaned on chrono. Koka has no such library, so the calendar
// arithmetic here is Howard Hinnant's days-from-civil / civil-from-days --
// exact, branch-free, and correct through every leap rule. The only impure
// thing in the module is reading the clock.
module dates

import win32

val month-names = ["January", "February", "March", "April", "May", "June",
                   "July", "August", "September", "October", "November", "December"]

val month-abbr = ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
                  "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

// Full month name for m in 1..12, else empty.
//
// No pattern guards anywhere in this file: Koka 3.2.3 mis-compiles a guarded
// match arm into a fall-through that drops the scrutinee's owned fields a
// second time. See the Gotchas section of .ralph/koka-tenne.md.
pub fun month-name( m : int ) : string
  if m < 1 || m > 12 then "" else
    match month-names.drop(m - 1)
      Cons(n, _) -> n
      Nil -> ""

fun month-abbrev( m : int ) : string
  if m < 1 || m > 12 then "" else
    match month-abbr.drop(m - 1)
      Cons(n, _) -> n
      Nil -> ""

pub fun pad2( n : int ) : string
  if n < 10 && n >= 0 then "0" ++ n.show else n.show

fun pad4( n : int ) : string
  if n < 10 then "000" ++ n.show
  elif n < 100 then "00" ++ n.show
  elif n < 1000 then "0" ++ n.show
  else n.show

// --- civil <-> serial day ------------------------------------------------
// Days since 1970-01-01. Only ever called with years well after 1, so the
// negative-era branches of Hinnant's algorithm are unreachable here.

pub fun days-from-civil( y0 : int, m : int, d : int ) : int
  val y = if m <= 2 then y0 - 1 else y0
  val era = y / 400
  val yoe = y - era * 400
  val mp = if m > 2 then m - 3 else m + 9
  val doy = (153 * mp + 2) / 5 + d - 1
  val doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
  era * 146097 + doe - 719468

pub fun civil-from-days( z0 : int ) : (int, int, int)
  val z = z0 + 719468
  val era = z / 146097
  val doe = z - era * 146097
  val yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365
  val y = yoe + era * 400
  val doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
  val mp = (5 * doy + 2) / 153
  val d = doy - (153 * mp + 2) / 5 + 1
  val m = if mp < 10 then mp + 3 else mp - 9
  (if m <= 2 then y + 1 else y, m, d)

// --- parsing -------------------------------------------------------------

fun parse-nat( s : string ) : maybe<int>
  val cs = s.list
  if cs.is-nil then Nothing
  elif cs.all(fn(c) { c.is-digit }) then
    Just(cs.foldl(0) fn(a, c) { a * 10 + (c.int - '0'.int) })
  else Nothing

// `YYYY-MM-DD` -> (y, m, d), only when it is a real calendar date. 2025-02-30
// parses as digits but is not a day, and must not be accepted.
pub fun parse-date( s : string ) : maybe<(int, int, int)>
  match s.trim.split("-")
    [ys, ms, ds] ->
      if ys.count != 4 || ms.count != 2 || ds.count != 2 then Nothing else
        match (parse-nat(ys), parse-nat(ms), parse-nat(ds))
          (Just(y), Just(m), Just(d)) ->
            if m >= 1 && m <= 12 && d >= 1 && d <= 31 &&
               civil-from-days(days-from-civil(y, m, d)) == (y, m, d)
              then Just((y, m, d)) else Nothing
          _ -> Nothing
    _ -> Nothing

// `YYYY-MM` -> (y, m).
pub fun parse-month( s : string ) : maybe<(int, int)>
  match s.trim.split("-")
    [ys, ms] ->
      if ys.count != 4 || ms.count != 2 then Nothing else
        match (parse-nat(ys), parse-nat(ms))
          (Just(y), Just(m)) -> if m >= 1 && m <= 12 then Just((y, m)) else Nothing
          _ -> Nothing
    _ -> Nothing

pub fun is-valid-date( s : string ) : bool
  parse-date(s).is-just

pub fun is-valid-month( s : string ) : bool
  parse-month(s).is-just

// --- formatting ----------------------------------------------------------

pub fun fmt-date( y : int, m : int, d : int ) : string
  pad4(y) ++ "-" ++ pad2(m) ++ "-" ++ pad2(d)

pub fun fmt-month( y : int, m : int ) : string
  pad4(y) ++ "-" ++ pad2(m)

// `YYYY-MM` -> `June 2026`. Falls back to the input, as the Rust build did.
pub fun pretty-month( ym : string ) : string
  match parse-month(ym)
    Just((y, m)) -> month-name(m) ++ " " ++ y.show
    Nothing -> ym

// `YYYY-MM-DD` -> `Jul 08`. The year is redundant under a month header.
pub fun short-date( s : string ) : string
  match parse-date(s)
    Just((_, m, d)) -> month-abbrev(m) ++ " " ++ pad2(d)
    Nothing -> s

// --- the clock -----------------------------------------------------------

// `YYYY-MM-DD HH:MM:SS`, for ordering same-day transactions by when they
// were actually recorded.
pub fun now() : io string
  win32/now-string()

pub fun today() : io string
  now().list.take(10).string

pub fun current-month() : io string
  now().list.take(7).string

// --- arithmetic ----------------------------------------------------------

pub fun add-days( s : string, n : int ) : string
  match parse-date(s)
    Just((y, m, d)) ->
      val (y2, m2, d2) = civil-from-days(days-from-civil(y, m, d) + n)
      fmt-date(y2, m2, d2)
    Nothing -> s

// Add months to a `YYYY-MM`, rolling the year over.
pub fun add-months-ym( y : int, m : int, n : int ) : (int, int)
  val total = y * 12 + (m - 1) + n
  (total / 12, total % 12 + 1)

// Whole months from `from` to `to`, both `YYYY-MM`. Same month = 0, later
// `to` = positive. Unparseable inputs = 0, as before.
pub fun month-diff( from : string, to : string ) : int
  match (parse-month(from), parse-month(to))
    (Just((y1, m1)), Just((y2, m2))) -> (y2 - y1) * 12 + (m2 - m1)
    _ -> 0

pub fun months-ago( n : int ) : io string
  match parse-date(today())
    Just((y, m, d)) ->
      val (y2, m2) = add-months-ym(y, m, 0 - n)
      // clamp the day, so the 31st going back to a short month stays real
      val dd = if d > days-in-month(y2, m2) then days-in-month(y2, m2) else d
      fmt-date(y2, m2, dd)
    Nothing -> today()

pub fun days-in-month( y : int, m : int ) : int
  val (y2, m2) = add-months-ym(y, m, 1)
  days-from-civil(y2, m2, 1) - days-from-civil(y, m, 1)

// Inclusive `YYYY-MM-DD` days from start to end. Empty if either is
// unparseable or end is before start.
pub fun days-inclusive( start : string, end : string ) : list<string>
  match (parse-date(start), parse-date(end))
    (Just((y1, m1, d1)), Just((y2, m2, d2))) ->
      val a = days-from-civil(y1, m1, d1)
      val b = days-from-civil(y2, m2, d2)
      if b < a then [] else list(a, b).map fn(z)
        val (yy, mm, dd) = civil-from-days(z)
        fmt-date(yy, mm, dd)
    _ -> []

// Inclusive `YYYY-MM` months from `from` to `to`, oldest first.
pub fun months-between( from : string, to : string ) : list<string>
  match (parse-month(from), parse-month(to))
    (Just((y1, m1)), Just((y2, m2))) ->
      val a = y1 * 12 + (m1 - 1)
      val b = y2 * 12 + (m2 - 1)
      if b < a then [] else list(a, b).map(fn(t) { fmt-month(t / 12, t % 12 + 1) })
    _ -> []

// Months for a picker: `forward` ahead down to `back` behind the current
// month, newest first, so the common case is a short reach.
pub fun month-options( back : int, forward : int ) : io list<string>
  match parse-month(current-month())
    Just((y, m)) -> list(0, back + forward).map fn(i)
      val (yy, mm) = add-months-ym(y, m, forward - i)
      fmt-month(yy, mm)
    Nothing -> []

// --- the calendar filter -------------------------------------------------

// A whole year, or one month within it. More intuitive than a rolling window
// for "show me July" or "show me 2025".
pub struct month-filter
  year  : int
  month : maybe<int>

pub fun current-filter() : io month-filter
  match parse-month(current-month())
    Just((y, m)) -> Month-filter(y, Just(m))
    Nothing -> Month-filter(2026, Nothing)

// Inclusive [start, end] `YYYY-MM-DD` for SQL filtering.
pub fun range( f : month-filter ) : (string, string)
  match f.month
    Just(m) ->
      val (y2, m2) = add-months-ym(f.year, m, 1)
      (fmt-date(f.year, m, 1), add-days(fmt-date(y2, m2, 1), -1))
    Nothing -> (fmt-date(f.year, 1, 1), fmt-date(f.year, 12, 31))

// One step back: the previous month, or the previous year when viewing a
// whole year. The honest baseline for a "vs last period" trend.
pub fun previous( f : month-filter ) : month-filter
  match f.month
    Just(1) -> Month-filter(f.year - 1, Just(12))
    Just(m) -> Month-filter(f.year, Just(m - 1))
    Nothing -> Month-filter(f.year - 1, Nothing)

pub fun label( f : month-filter ) : string
  match f.month
    Just(m) -> month-name(m) ++ " " ++ f.year.show
    Nothing -> f.year.show
