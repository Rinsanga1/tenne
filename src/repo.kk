// The data-access layer. UI-free, and the place TenneCRM.tla's actions land:
// see docs/tla/README.md for the action-to-function map.
module repo

import std/num/float64
import sql
import dates
import models
import util

// --- settings -----------------------------------------------------------

pub fun get-setting( key : string ) : io maybe<string>
  sql/select("SELECT value FROM settings WHERE key = ?", [key], Nothing,
             fn(_a, s) { Just(sql/col-text(s, 0)) })

pub fun set-setting( key : string, value : string ) : io bool
  sql/exec-with("INSERT INTO settings(key, value) VALUES (?,?)" ++
                " ON CONFLICT(key) DO UPDATE SET value = excluded.value") fn(s)
    sql/bind-text(s, 1, key)
    sql/bind-text(s, 2, value)

fun setting-float( key : string, dflt : float64 ) : io float64
  match get-setting(key)
    Just(v) -> match v.parse-float
      Just(f) -> f
      Nothing -> dflt
    Nothing -> dflt

// one parser, in util, so settings and the forms agree on what a number is
fun parse-float( s : string ) : maybe<float64>
  util/parse-money(s)

pub fun default-monthly-fee() : io float64
  setting-float("default_monthly_fee", 1500.0)

pub fun registration-fee() : io float64
  setting-float("registration_fee", 500.0)

pub fun currency() : io string
  get-setting("currency").default("Rs")

pub fun gym-name() : io string
  get-setting("gym_name").default("TenneCRM")

// --- reading rows -------------------------------------------------------

// Column order is fixed by member-cols, so every read agrees.
val member-cols = "id, name, phone, address, join_date, active, notes"

fun member-of( s : sql/stmt ) : io models/member
  Member(sql/col-int(s, 0), sql/col-text(s, 1), sql/col-text-opt(s, 2),
         sql/col-text-opt(s, 3), sql/col-text(s, 4), sql/col-int(s, 5) != 0,
         sql/col-text-opt(s, 6))

val payment-cols = "id, member_id, period_month, amount, date, note, category"

fun payment-of( s : sql/stmt ) : io models/payment
  Payment(sql/col-int(s, 0), sql/col-int(s, 1), sql/col-text(s, 2),
          sql/col-real(s, 3), sql/col-text(s, 4), sql/col-text-opt(s, 5),
          sql/col-text(s, 6))

// --- members ------------------------------------------------------------

pub fun list-members( active-only : bool ) : io list<models/member>
  val where = if active-only then " WHERE active = 1" else ""
  sql/rows("SELECT " ++ member-cols ++ " FROM members" ++ where ++
           " ORDER BY name COLLATE NOCASE", [], member-of)

pub fun get-member( id : int ) : io maybe<models/member>
  sql/query-with("SELECT " ++ member-cols ++ " FROM members WHERE id = ?",
                 fn(s) { sql/bind-int(s, 1, id) }, Nothing,
                 fn(_a, s) { Just(member-of(s)) })

pub fun search-members( q : string, active-only : bool ) : io list<models/member>
  val where = if active-only then " AND active = 1" else ""
  val like = "%" ++ q ++ "%"
  sql/rows-with("SELECT " ++ member-cols ++ " FROM members WHERE (name LIKE ?" ++
                " OR phone LIKE ?)" ++ where ++ " ORDER BY name COLLATE NOCASE",
                fn(s) { sql/bind-text(s, 1, like); sql/bind-text(s, 2, like) },
                member-of)

pub fun count-members( active-only : bool ) : io int
  val where = if active-only then " WHERE active = 1" else ""
  sql/scalar-int("SELECT COUNT(*) FROM members" ++ where, [], 0)

fun bind-member( s : sql/stmt, m : models/member, from : int ) : io ()
  sql/bind-text(s, from, m.name)
  sql/bind-text-opt(s, from + 1, m.phone)
  sql/bind-text-opt(s, from + 2, m.address)
  sql/bind-text(s, from + 3, m.join-date)
  sql/bind-int(s, from + 4, if m.active then 1 else 0)
  sql/bind-text-opt(s, from + 5, m.notes)

pub fun insert-member( m : models/member ) : io int
  val ok = sql/exec-with("INSERT INTO members(name, phone, address, join_date, active, notes)" ++
                         " VALUES (?,?,?,?,?,?)", fn(s) { bind-member(s, m, 1) })
  if ok then sql/last-id() else 0

// One transaction: the member row, the mandatory joining fee, and optionally
// the first month's dues. `AddMember(m, withFirstMonth)` in TenneCRM.tla.
//
// AtMostOneJoiningFee holds here because the member is new -- it is the CSV
// importer that has to check, and does.
pub fun create-member( m : models/member, joining-fee : float64,
                       first-month : maybe<float64>, month : string,
                       date : string ) : io int
  val now = dates/now()
  sql/exec("BEGIN").ignore
  val id = insert-member(m)
  if id == 0 then
    sql/exec("ROLLBACK").ignore
    0
  else
    add-payment(id, month, joining-fee, date, models/cat-registration, now).ignore
    // NB: written as a nested `if`, not a pattern guard. Koka 3.2.3 mis-compiles
    // `Just(fee) | fee > 0.0 ->` here: the guarded arm falls through into the
    // no-match cleanup, so month/date/now are dropped twice. See the Gotchas
    // section of .ralph/koka-tenne.md.
    match first-month
      Just(fee) -> if fee > 0.0 then add-payment(id, month, fee, date, models/cat-membership, now).ignore
      Nothing -> ()
    sql/exec("COMMIT").ignore
    id

pub fun update-member( m : models/member ) : io bool
  sql/exec-with("UPDATE members SET name=?, phone=?, address=?, join_date=?," ++
                " active=?, notes=? WHERE id=?") fn(s)
    bind-member(s, m, 1)
    sql/bind-int(s, 7, m.id)

// payments.member_id is ON DELETE CASCADE, so the ledger goes with them.
// NoOrphanPayments in TenneCRM.tla depends on that clause being present.
pub fun delete-member( id : int ) : io bool
  sql/exec-with("DELETE FROM members WHERE id = ?", fn(s) { sql/bind-int(s, 1, id) })

pub fun set-member-active( id : int, active : bool ) : io bool
  sql/exec-with("UPDATE members SET active = ? WHERE id = ?") fn(s)
    sql/bind-int(s, 1, if active then 1 else 0)
    sql/bind-int(s, 2, id)

// --- payments -----------------------------------------------------------

fun add-payment( member-id : int, month : string, amount : float64, date : string,
                 category : string, now : string ) : io int
  val ok = sql/exec-with("INSERT INTO payments(member_id, period_month, amount, date," ++
                         " note, category, created_at) VALUES (?,?,?,?,NULL,?,?)") fn(s)
    sql/bind-int(s, 1, member-id)
    sql/bind-text(s, 2, month)
    sql/bind-real(s, 3, amount)
    sql/bind-text(s, 4, date)
    sql/bind-text(s, 5, category)
    sql/bind-text(s, 6, now)
  if ok then sql/last-id() else 0

pub fun insert-payment( p : models/payment ) : io int
  val ok = sql/exec-with("INSERT INTO payments(member_id, period_month, amount, date," ++
                         " note, category, created_at) VALUES (?,?,?,?,?,?,?)") fn(s)
    sql/bind-int(s, 1, p.member-id)
    sql/bind-text(s, 2, p.period-month)
    sql/bind-real(s, 3, p.amount)
    sql/bind-text(s, 4, p.date)
    sql/bind-text-opt(s, 5, p.note)
    sql/bind-text(s, 6, p.category)
    sql/bind-text(s, 7, dates/now())
  if ok then sql/last-id() else 0

pub fun has-registration-payment( member-id : int ) : io bool
  sql/int-with("SELECT COUNT(*) FROM payments WHERE member_id = ? AND category = 'registration'",
               fn(s) { sql/bind-int(s, 1, member-id) }, 0) > 0

// The joining fee is a one-time charge. This is the guard that makes
// AtMostOneJoiningFee true; every door into a registration payment must go
// through it, which is exactly what the CSV importer failed to do.
pub fun ensure-registration-payment( member-id : int, amount : float64,
                                     date : string, month : string ) : io ()
  if has-registration-payment(member-id) then ()
  else add-payment(member-id, month, amount, date, models/cat-registration, dates/now()).ignore

pub fun remove-registration-payment( member-id : int ) : io bool
  sql/exec-with("DELETE FROM payments WHERE member_id = ? AND category = 'registration'",
                fn(s) { sql/bind-int(s, 1, member-id) })

pub fun payments-for-member( member-id : int ) : io list<models/payment>
  sql/rows-with("SELECT " ++ payment-cols ++ " FROM payments WHERE member_id = ?" ++
                " ORDER BY period_month DESC, id DESC",
                fn(s) { sql/bind-int(s, 1, member-id) }, payment-of)

pub fun get-payment( id : int ) : io maybe<models/payment>
  sql/query-with("SELECT " ++ payment-cols ++ " FROM payments WHERE id = ?",
                 fn(s) { sql/bind-int(s, 1, id) }, Nothing,
                 fn(_a, s) { Just(payment-of(s)) })

pub fun delete-payment( id : int ) : io bool
  sql/exec-with("DELETE FROM payments WHERE id = ?", fn(s) { sql/bind-int(s, 1, id) })

pub fun update-payment( p : models/payment ) : io bool
  sql/exec-with("UPDATE payments SET member_id=?, period_month=?, amount=?, date=?," ++
                " note=?, category=? WHERE id=?") fn(s)
    sql/bind-int(s, 1, p.member-id)
    sql/bind-text(s, 2, p.period-month)
    sql/bind-real(s, 3, p.amount)
    sql/bind-text(s, 4, p.date)
    sql/bind-text-opt(s, 5, p.note)
    sql/bind-text(s, 6, p.category)
    sql/bind-int(s, 7, p.id)

// Dues only. A registration payment never settles a month -- that is the
// difference between `fees` and `paid` in TenneCRM.tla.
pub fun is-paid( member-id : int, month : string ) : io bool
  sql/int-with("SELECT COUNT(*) FROM payments WHERE member_id = ? AND period_month = ?" ++
               " AND category != 'registration'",
               fn(s) { sql/bind-int(s, 1, member-id); sql/bind-text(s, 2, month) }, 0) > 0

// Every member id with dues recorded for `month`, in one query, so a list of
// 400 members costs one round trip instead of 400.
pub fun paid-member-ids( month : string ) : io list<int>
  sql/rows-with("SELECT DISTINCT member_id FROM payments WHERE period_month = ?" ++
                " AND category != 'registration'",
                fn(s) { sql/bind-text(s, 1, month) }, fn(s) { sql/col-int(s, 0) })

// --- arrears ------------------------------------------------------------

// How many membership-months this member is behind as of `current-month`,
// counted from their own join month, and what that is worth at the current fee.
//
// `expected` counts the join month itself, which is why it is `diff + 1`.
// NewMemberWhoPaidIsNotDue in TenneCRM.tla is precisely the check that this
// off-by-one is the right way round: someone who joins today and pays today
// owes nothing today.
pub fun membership-arrears( member-id : int, join-month : string,
                            current-month : string ) : io (int, float64)
  val paid = sql/int-with(
    "SELECT COUNT(DISTINCT period_month) FROM payments WHERE member_id = ?" ++
    " AND category != 'registration' AND period_month >= ? AND period_month <= ?",
    fn(s)
      sql/bind-int(s, 1, member-id)
      sql/bind-text(s, 2, join-month)
      sql/bind-text(s, 3, current-month)
    , 0)
  val diff = dates/month-diff(join-month, current-month)
  val expected = (if diff < 0 then 0 else diff) + 1
  val behind = if expected - paid < 0 then 0 else expected - paid
  (behind, behind.float64 * default-monthly-fee())

// Active members who owe at least one month, most-behind first, ties broken by
// name. One grouped query for the counts, then the arithmetic per member --
// not one query per row.
// A member, how many months they are behind, and what that is worth.
pub alias arrears = (models/member, int, float64)

pub fun due-members-with-arrears( current-month : string ) : io list<arrears>
  val counts = sql/rows-with(
    "SELECT p.member_id, COUNT(DISTINCT p.period_month) FROM payments p" ++
    " JOIN members m ON m.id = p.member_id" ++
    " WHERE m.active = 1 AND p.category != 'registration'" ++
    "   AND p.period_month <= ? AND p.period_month >= substr(m.join_date, 1, 7)" ++
    " GROUP BY p.member_id",
    fn(s) { sql/bind-text(s, 1, current-month) },
    fn(s) { (sql/col-int(s, 0), sql/col-int(s, 1)) })
  val fee = default-monthly-fee()
  val owing = list-members(True).map fn(m : models/member)
    val mid = models/member/id(m)
    val paid = counts.lookup(fn(k) { k == mid }).default(0)
    val diff = dates/month-diff(m.join-month, current-month)
    val expected = (if diff < 0 then 0 else diff) + 1
    val behind = if expected - paid < 0 then 0 else expected - paid
    (m, behind, behind.float64 * fee)
  owing.filter(fn(t : arrears) { t.snd > 0 }).sort-by fn(a : arrears, b : arrears)
    if a.snd != b.snd then a.snd > b.snd           // most behind first
    else a.fst.name.to-lower < b.fst.name.to-lower // then by name

// Active members with no dues recorded for `month` at all.
pub fun due-members( month : string ) : io list<models/member>
  sql/rows-with("SELECT " ++ member-cols ++ " FROM members WHERE active = 1" ++
                " AND id NOT IN (SELECT member_id FROM payments WHERE period_month = ?" ++
                " AND category != 'registration') ORDER BY name COLLATE NOCASE",
                fn(s) { sql/bind-text(s, 1, month) }, member-of)

// The status the members list reads by.
pub fun status-of( m : models/member, paid-ids : list<int> ) : models/member-status
  // bound outside the lambda: `m.id` in there resolves against std's `id`
  val mid = models/member/id(m)
  if !m.active then Inactive
  elif paid-ids.any(fn(i) { i == mid }) then Paid
  else Due

// --- registration -------------------------------------------------------

pub fun unpaid-registration-count( active-only : bool ) : io int
  val where = if active-only then "m.active = 1 AND " else ""
  sql/scalar-int("SELECT COUNT(*) FROM members m WHERE " ++ where ++
                 "NOT EXISTS (SELECT 1 FROM payments p WHERE p.member_id = m.id" ++
                 " AND p.category = 'registration')", [], 0)

pub fun members-missing-registration( active-only : bool ) : io list<models/member>
  val where = if active-only then "m.active = 1 AND " else ""
  sql/rows("SELECT " ++ member-cols ++ " FROM members m WHERE " ++ where ++
           "NOT EXISTS (SELECT 1 FROM payments p WHERE p.member_id = m.id" ++
           " AND p.category = 'registration') ORDER BY m.name COLLATE NOCASE",
           [], member-of)

// Sum of payments of one category whose `date` falls in [start, end].
pub fun category-income( category : string, start : string, end : string ) : io float64
  sql/real-with("SELECT COALESCE(SUM(amount),0) FROM payments WHERE category = ?" ++
                " AND date >= ? AND date <= ?",
                fn(s)
                  sql/bind-text(s, 1, category)
                  sql/bind-text(s, 2, start)
                  sql/bind-text(s, 3, end)
                , 0.0)

pub fun transaction-years() : io list<int>
  sql/rows("SELECT DISTINCT substr(date, 1, 4) FROM (" ++
           " SELECT date FROM payments UNION ALL SELECT date FROM sales" ++
           " UNION ALL SELECT date FROM expenses) ORDER BY 1 DESC", [],
           fn(s) { sql/col-int(s, 0) })
