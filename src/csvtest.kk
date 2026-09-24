// The CSV round trip, which is where the Rust build's three worst bugs lived.
//
// The headline case is the one TLC produced as a counterexample: export your
// data and import it back, and every member is billed the joining fee twice.
module csvtest

import std/num/float64
import win32
import sql
import db
import models
import repo
import repo2
import dates
import util
import csv
import license

fun check( f : ref<global,int>, name : string, got : string, want : string ) : io ()
  val ok = got == want
  if !ok then f := !f + 1
  println((if ok then "  ok   " else "  FAIL ") ++ name.pad-right(52) ++ got.pad-right(14) ++
          (if ok then "" else "want " ++ want))

fun regs( id : int ) : io int
  repo/payments-for-member(id)
    .filter(fn(p : models/payment) { p.category == "registration" }).length

pub fun main() : io ()
  sql/unbuffer()
  val fails = checks()
  sql/close().ignore
  println(if fails == 0 then "ALL PASS" else "FAILED: " ++ fails.show)

fun checks() : io int
  val f = ref(0)

  // --- the writer
  check(f, "a plain cell is not quoted", csv/cell("Rent"), "Rent")
  check(f, "a cell with a comma is quoted", csv/cell("Rent, August"), "\"Rent, August\"")
  check(f, "an embedded quote is doubled", csv/cell("6\" pipe"), "\"6\"\" pipe\"")
  check(f, "a row joins with commas", csv/row(["a", "b,c", "d"]), "a,\"b,c\",d")

  // --- the reader
  check(f, "a plain row splits", csv/split-row("a,b,c").join("|"), "a|b|c")
  check(f, "a quoted comma survives", csv/split-row("a,\"b,c\",d").join("|"), "a|b,c|d")
  check(f, "a doubled quote survives", csv/split-row("a,\"6\"\" pipe\",d").join("|"),
        "a|6\" pipe|d")
  check(f, "empty cells survive", csv/split-row("a,,c").join("|"), "a||c")
  check(f, "a trailing empty cell survives", csv/split-row("a,b,").join("|"), "a|b|")
  check(f, "round trip through cell and split",
        csv/split-row(csv/row(["x,y", "z\"w", ""])).join("|"), "x,y|z\"w|")

  // column lookup is by heading, so order does not matter
  check(f, "column index by name", csv/index-of(["Type","Date","Period"], "period").show, "2")
  check(f, "a missing column is -1", csv/index-of(["Type","Date"], "period").show, "-1")

  // --- seed a small gym and export it
  val path = "out/csv.db"
  if sql/file-exists(path) then sql/remove-file(path).ignore
  db/open-db(path).ignore
  val priya = repo/create-member(Member(0, "Priya", Just("986201"), Nothing,
                                        "2025-01-15", True, Nothing),
                                 500.0, Just(1500.0), "2025-01", "2025-01-15")
  // July's dues, handed over in August. This is the case the Period column exists for.
  repo/insert-payment(Payment(0, priya, "2025-07", 1500.0, "2025-08-15", Nothing,
                              models/cat-membership)).ignore
  repo2/insert-expense(Expense(0, "Rent", 12000.0, "2025-08-01", Just("paid, in cash"))).ignore

  check(f, "seeded: one member", repo/count-members(False).show, "1")
  check(f, "seeded: one joining fee", regs(priya).show, "1")
  check(f, "seeded: three payments", repo/payments-for-member(priya).length.show, "3")
  check(f, "seeded: July is settled", repo/is-paid(priya, "2025-07").show, "True")

  val csv-path = "out/export.csv"
  if sql/file-exists(csv-path) then sql/remove-file(csv-path).ignore
  val written = csv/export-all(csv-path)
  check(f, "export wrote every row", written.show, "5")       // 1 member + 3 payments + 1 expense
  check(f, "the file has a Period column",
        (win32/read-text(csv-path).contains("Period")).show, "True")
  check(f, "and a quoted note survived the writer",
        (win32/read-text(csv-path).contains("\"paid, in cash\"")).show, "True")

  // --- THE BUG: import the export back into the same database
  val res = csv/import-all(csv-path, True)
  check(f, "re-import adds no members", res.members.show, "0")
  check(f, "and reports the one already on file", res.existing.show, "1")
  check(f, "still one member", repo/count-members(False).show, "1")
  check(f, "STILL ONE JOINING FEE", regs(priya).show, "1")
  check(f, "the joining-fee row was skipped, not inserted", (res.skipped >= 1).show, "True")

  // The two membership payments do come back in -- a member may genuinely pay
  // the same month twice, so those are not deduplicated. Only the joining fee
  // is a one-time charge.
  check(f, "membership payments were re-added", res.payments.show, "2")
  check(f, "the expense came back too", res.expenses.show, "1")

  // --- the Period column: July's dues stay July's
  val julys = repo/payments-for-member(priya)
                .filter(fn(p : models/payment) { p.period-month == "2025-07" })
  check(f, "July's dues are still July's, not August's", julys.length.show, "2")
  check(f, "and none of them drifted to August",
        repo/payments-for-member(priya)
          .filter(fn(p : models/payment) { p.period-month == "2025-08" }).length.show, "0")

  // --- importing into an EMPTY database brings everything across
  val fresh = "out/csv2.db"
  if sql/file-exists(fresh) then sql/remove-file(fresh).ignore
  sql/close().ignore
  db/open-db(fresh).ignore
  check(f, "fresh database is empty", repo/count-members(False).show, "0")
  val res2 = csv/import-all(csv-path, True)
  check(f, "the member came across", res2.members.show, "1")
  check(f, "with their payments", res2.payments.show, "3")
  check(f, "and the expense", res2.expenses.show, "1")
  val p2 = repo/list-members(False).map(fn(m : models/member) { models/member/id(m) })
             .head.default(0)
  check(f, "exactly one joining fee on the fresh copy", regs(p2).show, "1")
  check(f, "the note survived the round trip",
        repo2/list-expenses().map(fn(e : models/expense) { e.note.default("") }).join(""),
        "paid, in cash")
  check(f, "July is settled on the fresh copy", repo/is-paid(p2, "2025-07").show, "True")

  // importing the SAME file again is now idempotent for members and the fee
  val res3 = csv/import-all(csv-path, True)
  check(f, "second import adds no members", res3.members.show, "0")
  check(f, "and no second joining fee", regs(p2).show, "1")

  // --- a file that is not ours
  if sql/file-exists("out/junk.csv") then sql/remove-file("out/junk.csv").ignore
  win32/write-text("out/junk.csv", "name,age\nbob,7\n").ignore
  val bad = csv/import-all("out/junk.csv", True)
  check(f, "a foreign file is refused", (bad.error != "").show, "True")
  check(f, "and changes nothing", repo/count-members(False).show, "1")

  // --- an old file with no Period column falls back to the payment's date
  val old = "out/old.csv"
  if sql/file-exists(old) then sql/remove-file(old).ignore
  win32/write-text(old, "Type,Date,Name,Category,Amount\n" ++
                        "Payment,2025-09-20,Priya,membership,1500\n").ignore
  val res4 = csv/import-all(old, True)
  check(f, "the old-format row imported", res4.payments.show, "1")
  check(f, "and fell back to the date's month", repo/is-paid(p2, "2025-09").show, "True")

  // --- the licence cap, which the importer has to honour too. A spreadsheet
  // is exactly how an unlicensed copy would otherwise load a whole roster.
  val many = "out/many.csv"
  if sql/file-exists(many) then sql/remove-file(many).ignore
  val rows = list(1, 12).map(fn(i) { "Member,2025-01-01,Bulk " ++ i.show ++ ",active,0" })
  win32/write-text(many, "Type,Date,Name,Category,Amount\n" ++ rows.join("\n") ++ "\n").ignore
  val before = repo/count-members(False)
  val res5 = csv/import-all(many, False)
  check(f, "unlicensed import fills to the cap", (before + res5.members).show,
        license/free-members.show)
  check(f, "and reports what it left out", res5.capped.show,
        (12 - (license/free-members - before)).show)
  check(f, "the roster stops at the cap", repo/count-members(False).show,
        license/free-members.show)
  // ...and with a licence the same file goes in whole.
  val licensed = csv/import-all(many, True)
  check(f, "licensed, the rest import", licensed.members.show,
        (12 - (license/free-members - before)).show)
  check(f, "and nothing is left capped", licensed.capped.show, "0")

  !f
