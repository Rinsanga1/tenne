// Export and import of the whole database as one spreadsheet.
//
// This file is where the Rust build's worst bug lived. Three of them, in fact,
// and each is guarded here with the reason attached:
//
//  1. The importer wrote the file's Category cell straight into `payments`
//     with no check, so re-importing an export billed every member the
//     joining fee a second time. AtMostOneJoiningFee, broken by the one door
//     into `payments` that skipped `ensure-registration-payment`.
//
//  2. The export wrote `date` but not `period_month`, and the import
//     reconstructed the period as `date[..7]`. July's dues paid on 15 August
//     came back as August's, silently reopening July. There is a Period
//     column now; files written before it fall back to the old behaviour.
//
//  3. Re-importing duplicated every member, because rows were inserted
//     unconditionally and the name->id map was then overwritten, so the
//     file's payments attached to the new duplicate. Members already on file
//     are left alone and reported as such.
//
// Note what export does NOT carry, because Settings calls it a backup and it
// is not one: products, stock levels, sale line items, recurring-expense
// templates, and every setting. Losing the database and importing this file
// gets the ledger back and the shop wiped. `backup.kk` is the backup.
module csv

import std/num/float64
import win32
import sql
import models
import repo
import repo2
import dates
import util
import license

pub val headers = ["Type", "Date", "Period", "Name", "Phone", "Address",
                   "Category", "Amount", "Note"]

// --- writing ------------------------------------------------------------

// A cell, quoted only when it has to be. Anything containing a comma, a quote
// or a newline is quoted, with embedded quotes doubled -- RFC 4180, which is
// what every spreadsheet actually reads.
pub fun cell( s : string ) : string
  val needs = s.contains(",") || s.contains("\"") || s.contains("\n") || s.contains("\r")
  if !needs then s
  else "\"" ++ s.list.map(fn(c) { if c == '"' then "\"\"" else c.string }).join("") ++ "\""

pub fun row( cells : list<string> ) : string
  cells.map(cell).join(",")

pub fun export-all( path : string ) : io int
  val members = repo/list-members(False)
  val member-rows = members.map fn(m : models/member)
    row(["Member", m.join-date, "", m.name, m.phone.default(""), m.address.default(""),
         (if m.active then "active" else "inactive"), "", m.notes.default("")])
  val payment-rows = members.flatmap fn(m : models/member)
    repo/payments-for-member(models/member/id(m)).map fn(p : models/payment)
      // The month the payment settles, which is not always the month it was
      // handed over. Without this column the import guesses, and guesses wrong.
      row(["Payment", p.date, p.period-month, m.name, "", "", p.category,
           util/show-money(p.amount), p.note.default("")])
  val sale-rows = repo2/list-sales().map fn(sl : models/sale)
    row(["Sale", sl.date, "", "", "", "", "shop", util/show-money(sl.total), ""])
  val expense-rows = repo2/list-expenses().map fn(e : models/expense)
    row(["Expense", e.date, "", e.name, "", "", "", util/show-money(e.amount),
         e.note.default("")])
  val all = Cons(row(headers), member-rows ++ payment-rows ++ sale-rows ++ expense-rows)
  if win32/write-text(path, all.join("\n") ++ "\n") then all.length - 1 else -1

// --- reading ------------------------------------------------------------

// Split one CSV line, honouring quotes. Written by hand because the shape is
// small and a dependency for this would be absurd.
pub fun split-row( line : string ) : list<string>
  scan(line.list, [], [], False).reverse

fun scan( cs : list<char>, field : list<char>, out : list<string>,
          quoted : bool ) : list<string>
  match cs
    Nil -> Cons(field.reverse.string, out)
    Cons(c, rest) ->
      if quoted then
        if c != '"' then scan(rest, Cons(c, field), out, True)
        else match rest
          // a doubled quote inside a quoted field is one literal quote
          Cons(d, more) -> if d == '"' then scan(more, Cons('"', field), out, True)
                           else scan(rest, field, out, False)
          Nil -> scan(rest, field, out, False)
      elif c == '"' then scan(rest, field, out, True)
      elif c == ',' then scan(rest, [], Cons(field.reverse.string, out), False)
      elif c == '\r' then scan(rest, field, out, False)
      else scan(rest, Cons(c, field), out, False)

fun at( cells : list<string>, i : int ) : string
  if i < 0 then "" else cells.drop(i).head.default("").trim

// Where each column landed, by heading, so a file with columns in a different
// order -- or missing the Period column entirely -- still reads correctly.
pub fun index-of( hdr : list<string>, name : string ) : int
  val lowered = hdr.map(fn(h : string) { h.trim.to-lower })
  find-at(lowered, name.to-lower, 0)

fun find-at( xs : list<string>, want : string, i : int ) : int
  match xs
    Nil -> -1
    Cons(x, rest) -> if x == want then i else find-at(rest, want, i + 1)

pub struct import-result
  members  : int
  payments : int
  sales    : int
  expenses : int
  skipped  : int
  existing : int
  // members the file held that the licence had no room for. Counted apart
  // from `skipped` because a row dropped for want of a licence is the one
  // kind of loss the owner can do something about.
  capped   : int
  error    : string

pub fun summary( r : import-result ) : string
  if r.error != "" then r.error
  else
    val parts = [(r.members, "member"), (r.payments, "payment"),
                 (r.sales, "sale"), (r.expenses, "expense")]
              .filter(fn(t : (int, string)) { t.fst > 0 })
              .map(fn(t : (int, string)) { t.fst.show ++ " " ++ plural(t.fst, t.snd) })
    val added = if parts.is-nil then "Nothing new to import" else "Added " ++ parts.join(", ")
    val kept = if r.existing == 0 then ""
               else "; " ++ r.existing.show ++ " " ++ plural(r.existing, "member") ++
                    " already on file, left unchanged"
    val lost = if r.skipped == 0 then "" else "; " ++ r.skipped.show ++ " row(s) skipped"
    val over = if r.capped == 0 then ""
               else "; " ++ r.capped.show ++ " row(s) NOT imported - this copy is" ++
                    " unlicensed. Enter your licence key in Settings."
    added ++ kept ++ lost ++ over

fun plural( n : int, word : string ) : string
  if n == 1 then word else word ++ "s"

// `licensed` is threaded in rather than read here so that the whole app asks
// the same question once, at startup. The importer has to ask it at all
// because a cap the spreadsheet walks straight through is not a cap.
pub fun import-all( path : string, licensed : bool ) : io import-result
  val text = win32/read-text(path)
  if text.trim == "" then
    Import-result(0, 0, 0, 0, 0, 0, 0, "That file is empty")
  else
    val lines = text.split("\n").filter(fn(l : string) { l.trim != "" })
    match lines
      Nil -> Import-result(0, 0, 0, 0, 0, 0, 0, "That file is empty")
      Cons(head-line, body) ->
        val hdr = split-row(head-line)
        if index-of(hdr, "type") < 0 then
          Import-result(0, 0, 0, 0, 0, 0, 0,
                        "That does not look like a TenneCRM export - no Type column")
        else run-import(hdr, body, licensed)

fun run-import( hdr : list<string>, body : list<string>, licensed : bool ) : io import-result
  val i-type = index-of(hdr, "type")
  val i-date = index-of(hdr, "date")
  val i-period = index-of(hdr, "period")
  val i-name = index-of(hdr, "name")
  val i-phone = index-of(hdr, "phone")
  val i-addr = index-of(hdr, "address")
  val i-cat = index-of(hdr, "category")
  val i-amt = index-of(hdr, "amount")
  val i-note = index-of(hdr, "note")

  val added-m = ref(0)
  val existing-m = ref(0)
  val added-p = ref(0)
  val added-s = ref(0)
  val added-e = ref(0)
  val skipped = ref(0)
  val capped = ref(0)

  sql/exec("BEGIN").ignore

  // Members first, so payments in the same file can attach to them.
  //
  // A member already on file is LEFT ALONE, not inserted again. There is no
  // uniqueness on members.name, so the Rust build's unconditional insert
  // duplicated everyone on a re-import and then attached the file's payments
  // to the duplicate.
  body.foreach fn(line)
    val c = split-row(line)
    if at(c, i-type).to-lower != "member" then () else
      val nm = at(c, i-name)
      if nm == "" then skipped := !skipped + 1
      else
        val found = repo/search-members(nm, False)
                      .filter(fn(m : models/member) { m.name.to-lower == nm.to-lower })
        if !found.is-nil then existing-m := !existing-m + 1
        elif !license/can-add-member(licensed) then capped := !capped + 1
        else
          val joined = valid-date-or-today(at(c, i-date))
          val active = at(c, i-cat).to-lower != "inactive"
          val id = repo/insert-member(Member(0, nm, opt(at(c, i-phone)), opt(at(c, i-addr)),
                                             joined, active, opt(at(c, i-note))))
          if id == 0 then skipped := !skipped + 1 else added-m := !added-m + 1

  body.foreach fn(line)
    val c = split-row(line)
    val ty = at(c, i-type).to-lower
    if ty == "member" then ()
    elif ty == "payment" then import-payment(c, i-date, i-period, i-name, i-cat, i-amt,
                                             i-note, added-p, skipped)
    elif ty == "sale" then
      match util/parse-money(at(c, i-amt))
        Nothing -> skipped := !skipped + 1
        Just(v) ->
          if !license/can-add-sale(licensed) then capped := !capped + 1
          elif repo2/import-sale(valid-date-or-today(at(c, i-date)), v, []) == 0
            then skipped := !skipped + 1 else added-s := !added-s + 1
    elif ty == "expense" then
      match util/parse-money(at(c, i-amt))
        Nothing -> skipped := !skipped + 1
        Just(v) ->
          val note = at(c, i-note)
          val nm = at(c, i-name)
          val what = if nm != "" then nm elif note != "" then note else "Expense"
          val e = Expense(0, what, v, valid-date-or-today(at(c, i-date)), opt(note))
          if repo2/insert-expense(e) == 0 then skipped := !skipped + 1
          else added-e := !added-e + 1
    else skipped := !skipped + 1

  sql/exec("COMMIT").ignore
  Import-result(!added-m, !added-p, !added-s, !added-e, !skipped, !existing-m, !capped, "")

fun import-payment( c : list<string>, i-date : int, i-period : int, i-name : int,
                    i-cat : int, i-amt : int, i-note : int,
                    added : ref<global,int>, skipped : ref<global,int> ) : io ()
  val nm = at(c, i-name)
  val found = repo/search-members(nm, False)
                .filter(fn(m : models/member) { m.name.to-lower == nm.to-lower })
  match (found.head, util/parse-money(at(c, i-amt)))
    (Just(m), Just(amount)) ->
      val mid = models/member/id(m)
      val date = valid-date-or-today(at(c, i-date))
      // Which month the payment settles is its own column: a July fee paid in
      // August belongs to July. Files written before that column existed fall
      // back to the payment's own date, which is the old, lossy behaviour.
      val raw-period = at(c, i-period)
      val period = if dates/is-valid-month(raw-period) then raw-period
                   else date.list.take(7).string
      val cat-cell = at(c, i-cat)
      val category = if cat-cell == "" then models/cat-membership else cat-cell.to-lower
      // The joining fee is a one-time charge. A registration row for a member
      // who already has one is DROPPED, not inserted -- otherwise re-importing
      // a file bills them a second time. This is AtMostOneJoiningFee, and this
      // guard is the one the Rust importer was missing.
      if category == models/cat-registration && repo/has-registration-payment(mid) then
        skipped := !skipped + 1
      else
        val id = repo/insert-payment(Payment(0, mid, period, amount, date,
                                             opt(at(c, i-note)), category))
        if id == 0 then skipped := !skipped + 1 else added := !added + 1
    _ -> skipped := !skipped + 1

fun opt( s : string ) : maybe<string>
  if s.trim == "" then Nothing else Just(s.trim)

fun valid-date-or-today( s : string ) : io string
  if dates/is-valid-date(s) then s.trim else dates/today()
