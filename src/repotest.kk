// The TenneCRM.tla actions, exercised against a real database.
module repotest
import std/num/float64
import sql
import db
import repo
import models
import dates

fun check( f : ref<global,int>, name : string, got : string, want : string ) : io ()
  val ok = got == want
  if !ok then f := !f + 1
  println((if ok then "  ok   " else "  FAIL ") ++ name.pad-right(44) ++ got.pad-right(20) ++
          (if ok then "" else "want " ++ want))

pub fun main() : io ()
  sql/unbuffer()
  val f = ref(0)
  val p = "out/repo.db"
  if sql/file-exists(p) then sql/remove-file(p).ignore
  db/open-db(p).ignore

  check(f, "money formats with grouping", models/money("Rs", 1500.0), "Rs 1,500")
  check(f, "money groups millions", models/money("Rs", 1234567.0), "Rs 1,234,567")
  check(f, "money handles negatives", models/money("Rs", -3000.0), "-Rs 3,000")
  check(f, "money rounds", models/money("Rs", 99.6), "Rs 100")
  check(f, "category label registration", models/category-label("registration"), "Joining fee")
  check(f, "category label membership", models/category-label("membership"), "Monthly fee")

  check(f, "default fee from settings", repo/default-monthly-fee().show, "1500")
  check(f, "registration fee from settings", repo/registration-fee().show, "500")
  check(f, "currency from settings", repo/currency(), "Rs")
  repo/set-setting("gym_name", "Bright Star Gym").ignore
  check(f, "setting round trips", repo/gym-name(), "Bright Star Gym")

  // AddMember: member row + mandatory joining fee + optional first month
  val priya = Member(0, "Priya", Just("986201"), Nothing, "2025-01-15", True, Nothing)
  val pid = repo/create-member(priya, 500.0, Just(1500.0), "2025-01", "2025-01-15")
  check(f, "create-member returns an id", (pid > 0).show, "True")
  check(f, "joining fee recorded once", repo/has-registration-payment(pid).show, "True")
  check(f, "first month recorded", repo/is-paid(pid, "2025-01").show, "True")
  check(f, "two payments on file", repo/payments-for-member(pid).length.show, "2")

  // AtMostOneJoiningFee: the guard must be idempotent across re-saves
  repo/ensure-registration-payment(pid, 500.0, "2025-02-01", "2025-02")
  repo/ensure-registration-payment(pid, 500.0, "2025-03-01", "2025-03")
  check(f, "joining fee still charged once", repo/payments-for-member(pid)
        .filter(fn(x) { x.category == "registration" }).length.show, "1")

  // a member who joined and paid this month owes nothing this month
  check(f, "new member who paid is not due",
        repo/membership-arrears(pid, "2025-01", "2025-01").fst.show, "0")
  // three months later, having paid only January, they are three behind
  check(f, "three months later owes three",
        repo/membership-arrears(pid, "2025-01", "2025-04").fst.show, "3")
  check(f, "and that is worth 4,500",
        models/money("Rs", repo/membership-arrears(pid, "2025-01", "2025-04").snd), "Rs 4,500")

  // a registration payment must never settle a month
  val zonun = Member(0, "Zonunsanga", Nothing, Nothing, "2025-03-02", True, Nothing)
  val zid = repo/create-member(zonun, 500.0, Nothing, "2025-03", "2025-03-02")
  check(f, "joining fee alone does not settle a month", repo/is-paid(zid, "2025-03").show, "False")
  check(f, "so they are one month behind",
        repo/membership-arrears(zid, "2025-03", "2025-03").fst.show, "1")

  // arrears across the roll-up, most behind first
  val due = repo/due-members-with-arrears("2025-04")
  check(f, "two members owe in April", due.length.show, "2")
  check(f, "most behind is listed first", due.map(fn(t) { t.fst.name }).join(","), "Priya,Zonunsanga")
  check(f, "Priya is 3 behind", due.map(fn(t) { t.snd.show }).join(","), "3,2")

  // paid-member-ids drives the per-row status without N queries
  check(f, "paid ids for January", repo/paid-member-ids("2025-01").map(fn(i){i.show}).join(","), pid.show)
  check(f, "status is Paid in January",
        repo/status-of(priya(id = pid), repo/paid-member-ids("2025-01")).status-label, "Paid")
  check(f, "status is Due in April",
        repo/status-of(priya(id = pid), repo/paid-member-ids("2025-04")).status-label, "Due")
  check(f, "status is Inactive when inactive",
        repo/status-of(priya(id = pid, active = False), repo/paid-member-ids("2025-01")).status-label, "Inactive")

  // registration chase list
  val lal = Member(0, "Lalrinpuia", Nothing, Nothing, "2025-02-01", True, Nothing)
  val lid = repo/insert-member(lal)                      // inserted WITHOUT a joining fee
  check(f, "one member owes the joining fee", repo/unpaid-registration-count(True).show, "1")
  check(f, "and is named", repo/members-missing-registration(True).map(fn(m){m.name}).join(","), "Lalrinpuia")
  repo/ensure-registration-payment(lid, 500.0, "2025-02-01", "2025-02")
  check(f, "after collecting, nobody owes it", repo/unpaid-registration-count(True).show, "0")
  repo/remove-registration-payment(lid).ignore
  check(f, "removing it puts them back on the list",
        repo/unpaid-registration-count(True).show, "1")

  // search and listing
  check(f, "search by name", repo/search-members("priya", True).map(fn(m){m.name}).join(","), "Priya")
  check(f, "search by phone", repo/search-members("9862", True).map(fn(m){m.name}).join(","), "Priya")
  check(f, "list is name-ordered", repo/list-members(True).map(fn(m){m.name}).join(","), "Lalrinpuia,Priya,Zonunsanga")
  repo/set-member-active(lid, False).ignore
  check(f, "deactivating hides from active list", repo/list-members(True).map(fn(m){m.name}).join(","), "Priya,Zonunsanga")
  check(f, "but not from the full list", repo/count-members(False).show, "3")

  // NoOrphanPayments: deleting a member takes their ledger with them
  val before = sql/scalar-int("SELECT COUNT(*) FROM payments", [], -1)
  repo/delete-member(pid).ignore
  check(f, "member deleted", repo/get-member(pid).is-nothing.show, "True")
  check(f, "their payments went too",
        sql/scalar-int("SELECT COUNT(*) FROM payments WHERE member_id = " ++ pid.show, [], -1).show, "0")
  check(f, "and no payment is orphaned",
        sql/scalar-int("SELECT COUNT(*) FROM payments p LEFT JOIN members m ON m.id = p.member_id" ++
                       " WHERE m.id IS NULL", [], -1).show, "0")
  check(f, "the rest of the ledger survived", (before > sql/scalar-int("SELECT COUNT(*) FROM payments", [], -1)).show, "True")

  // nullable columns must round trip as absent, not as ""
  check(f, "NULL phone reads as Nothing",
        repo/list-members(False).filter(fn(m){m.name=="Zonunsanga"}).map(fn(m){m.phone.default("<null>")}).join(""), "<null>")

  sql/close().ignore
  println(if !f == 0 then "ALL PASS" else "FAILED: " ++ (!f).show)
