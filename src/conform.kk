// Conformance: the implementation checked against TenneCRM.tla.
//
// TLC proves the *design* holds across 279,737 states. That says nothing about
// whether this code implements that design. This walks the spec's actions over
// a real database -- in a deterministic pseudo-random order, so the
// interleavings are ones nobody chose by hand -- and re-checks every invariant
// after every single action.
//
// The action names below are the ones in docs/tla/README.md's "Actions ->
// functions" table. If an action is added to the spec it should appear here.
module conform

import std/num/float64
import win32
import sql
import db
import models
import repo
import repo2
import dates
import util

val names = ["Priya", "Zonunsanga", "Lalrinpuia", "Vanlalruati", "Zothansangi"]
val months = ["2025-01", "2025-02", "2025-03", "2025-04"]

// A deterministic generator, so a failure is reproducible from the seed alone.
fun next-rand( seed : int ) : int
  (seed * 1103515245 + 12345) % 2147483648

// --- the invariants, in the spec's own terms ----------------------------

// AtMostOneJoiningFee: the joining fee is a one-time charge.
fun at-most-one-joining-fee() : io int
  sql/scalar-int("SELECT COUNT(*) FROM (SELECT member_id FROM payments" ++
                 " WHERE category = 'registration' GROUP BY member_id HAVING COUNT(*) > 1)", [], -1)

// NoOrphanPayments: deleting a member takes their whole ledger with them.
fun orphan-payments() : io int
  sql/scalar-int("SELECT COUNT(*) FROM payments p LEFT JOIN members m" ++
                 " ON m.id = p.member_id WHERE m.id IS NULL", [], -1)

// StockNeverNegative: you cannot sell what you do not have.
fun negative-stock() : io int
  sql/scalar-int("SELECT COUNT(*) FROM products WHERE stock < 0", [], -1)

// StockConserved: every unit is either on the shelf or inside a sale still on
// the books. Recording, editing or deleting a sale moves units, never mints or
// destroys them.
fun units-accounted() : io int
  sql/scalar-int("SELECT COALESCE(SUM(stock),0) FROM products", [], -1) +
  sql/scalar-int("SELECT COALESCE(SUM(qty),0) FROM sale_items WHERE product_id IS NOT NULL", [], -1)

// PaidUpMeansPaidThisMonth: nobody reads "all paid up" without having paid for
// the month they are looking at. Checked over every active member who joined
// on or before `month`.
fun falsely-paid-up( month : string ) : io int
  repo/list-members(True).filter(fn(m : models/member)
    val joined = m.join-month
    if joined > month then False
    else
      val behind = repo/membership-arrears(models/member/id(m), joined, month).fst
      behind == 0 && !repo/is-paid(models/member/id(m), month)
  ).length

// NewMemberWhoPaidIsNotDue: someone who joins this month and pays this month
// is not chased for dues this month.
fun new-payer-wrongly-due( month : string ) : io int
  repo/list-members(True).filter(fn(m : models/member)
    val mid = models/member/id(m)
    m.join-month == month && repo/is-paid(mid, month) &&
      repo/membership-arrears(mid, m.join-month, month).fst > 0
  ).length

fun check-all( failures : ref<global,int>, step : int, action : string,
               units : int ) : io ()
  fun bad( what : string, got : int, want : int ) : io ()
    if got != want then
      failures := !failures + 1
      println("  FAIL after step " ++ step.show ++ " <" ++ action ++ ">: " ++
              what ++ " = " ++ got.show ++ ", want " ++ want.show)
  bad("AtMostOneJoiningFee (members with two fees)", at-most-one-joining-fee(), 0)
  bad("NoOrphanPayments (payments with no member)", orphan-payments(), 0)
  bad("StockNeverNegative (products below zero)", negative-stock(), 0)
  bad("StockConserved (units on shelf + in sales)", units-accounted(), units)
  bad("PaidUpMeansPaidThisMonth (falsely paid up)", falsely-paid-up("2025-04"), 0)
  bad("NewMemberWhoPaidIsNotDue (new payer chased)", new-payer-wrongly-due("2025-04"), 0)

// `guarded = False` removes the joining-fee guard from the import path, which
// is exactly the hole the Rust build had. The broken run must FAIL, or this
// whole suite is checking nothing -- same discipline as the TLA broken runs.
pub fun run( guarded : bool ) : io int
  sql/unbuffer()
  val path = "out/conform.db"
  if sql/file-exists(path) then sql/remove-file(path).ignore
  db/open-db(path).ignore

  // The shelf starts with a known number of units and nothing here ever
  // restocks, so StockConserved has a fixed constant to check against.
  repo2/insert-product(Product(0, "Protein bar", 60.0, 6, True)).ignore
  repo2/insert-product(Product(0, "Shaker bottle", 250.0, 4, True)).ignore
  val units = units-accounted()
  println("shelf holds " ++ units.show ++ " units; they must all still be accounted for at the end")

  val failures = ref(0)
  check-all(failures, 0, "Init", units)
  val steps = walk(failures, 1, 400, 20260920, units, guarded)
  println("applied " ++ steps.show ++ " spec actions")
  println("units still accounted for: " ++ units-accounted().show ++ " of " ++ units.show)
  println("members: " ++ repo/count-members(False).show ++
          ", payments: " ++ sql/scalar-int("SELECT COUNT(*) FROM payments", [], -1).show ++
          ", sales: " ++ sql/scalar-int("SELECT COUNT(*) FROM sales", [], -1).show)
  sql/close().ignore
  !failures

pub fun main() : io ()
  val bad = run(True)
  println(if bad == 0 then "ALL PASS" else "FAILED: " ++ bad.show)

// One action per step, chosen from the seed, with every invariant re-checked
// after each. No refs cross a function boundary here -- see the Gotchas.
fun walk( failures : ref<global,int>, i : int, left : int, seed : int,
          units : int, guarded : bool ) : io int
  if left <= 0 then i - 1
  else
    val s1 = next-rand(seed)
    val action = act(s1, i, guarded)
    check-all(failures, i, action, units)
    walk(failures, i + 1, left - 1, s1, units, guarded)

// The spec's actions, one per branch. `if`/`elif`, not `match`, because the
// arms touch outer values -- see the compiler-bug note in the Gotchas.
fun act( seed : int, i : int, guarded : bool ) : io string
  val pick = (seed / 1024) % 10
  val members = repo/list-members(False)
  val who = pick-member(members, seed)
  if pick == 0 then add-member(seed, i)
  elif pick == 1 then record-joining-fee(who)
  elif pick == 2 then remove-joining-fee(who)
  elif pick == 3 then record-dues(who, month-of(seed))
  elif pick == 4 then delete-dues(who)
  elif pick == 5 then set-active(who, (seed / 64) % 2 == 0)
  elif pick == 6 then delete-member(who, members)
  elif pick == 7 then import-payment(who, month-of(seed), (seed / 32) % 2 == 0, guarded)
  elif pick == 8 then record-sale(seed)
  else edit-or-delete-sale(seed)

fun pick-member( members : list<models/member>, seed : int ) : maybe<models/member>
  if members.is-nil then Nothing
  else members.drop((seed / 256) % members.length).head

fun month-of( seed : int ) : string
  months.drop((seed / 128) % months.length).head.default("2025-01")

// AddMember(m, withFirstMonth): one transaction -- the row, the mandatory
// joining fee, optionally the first month.
fun add-member( seed : int, i : int ) : io string
  val nm = names.drop(seed % names.length).head.default("X") ++ " " ++ i.show
  val month = month-of(seed)
  val first = if (seed / 16) % 2 == 0 then Just(1500.0) else Nothing
  repo/create-member(Member(0, nm, Nothing, Nothing, month ++ "-05", True, Nothing),
                     500.0, first, month, month ++ "-05").ignore
  "AddMember"

fun record-joining-fee( who : maybe<models/member> ) : io string
  match who
    Nothing -> "skip"
    Just(m) ->
      repo/ensure-registration-payment(models/member/id(m), 500.0, "2025-04-01", "2025-04")
      "RecordJoiningFee"

fun remove-joining-fee( who : maybe<models/member> ) : io string
  match who
    Nothing -> "skip"
    Just(m) ->
      repo/remove-registration-payment(models/member/id(m)).ignore
      "RemoveJoiningFee"

fun record-dues( who : maybe<models/member>, month : string ) : io string
  match who
    Nothing -> "skip"
    Just(m) ->
      repo/insert-payment(Payment(0, models/member/id(m), month, 1500.0, month ++ "-10",
                                  Nothing, models/cat-membership)).ignore
      "RecordDues"

fun delete-dues( who : maybe<models/member> ) : io string
  match who
    Nothing -> "skip"
    Just(m) ->
      val dues = repo/payments-for-member(models/member/id(m))
                   .filter(fn(p : models/payment) { p.category != "registration" })
      match dues.head
        Nothing -> "skip"
        Just(p) ->
          repo/delete-payment(models/payment/id(p)).ignore
          "DeleteDues"

fun set-active( who : maybe<models/member>, on : bool ) : io string
  match who
    Nothing -> "skip"
    Just(m) ->
      repo/set-member-active(models/member/id(m), on).ignore
      "SetActive"

// DeleteMember(m): payments.member_id is ON DELETE CASCADE, so the ledger
// goes with them. Keeps at least two members so the walk has something to do.
fun delete-member( who : maybe<models/member>, members : list<models/member> ) : io string
  if members.length <= 2 then "skip"
  else match who
    Nothing -> "skip"
    Just(m) ->
      repo/delete-member(models/member/id(m)).ignore
      "DeleteMember"

// ImportPayment(m, mo, isJoiningFee): the CSV path. This is the action that
// broke AtMostOneJoiningFee in the Rust build, so it goes through the guard.
fun import-payment( who : maybe<models/member>, month : string,
                    joining : bool, guarded : bool ) : io string
  match who
    Nothing -> "skip"
    Just(m) ->
      val mid = models/member/id(m)
      if joining then
        if guarded && repo/has-registration-payment(mid) then "ImportPayment(skipped)"
        else
          repo/insert-payment(Payment(0, mid, month, 500.0, month ++ "-02", Nothing,
                                      models/cat-registration)).ignore
          "ImportPayment(fee)"
      else
        repo/insert-payment(Payment(0, mid, month, 1500.0, month ++ "-02", Nothing,
                                    models/cat-membership)).ignore
        "ImportPayment(dues)"

fun record-sale( seed : int ) : io string
  val products = repo2/list-products()
  match products.drop((seed / 512) % int/max(1, products.length)).head
    Nothing -> "skip"
    Just(p) ->
      val qty = 1 + (seed / 8) % 3
      repo2/record-sale("2025-04-1" ++ ((seed / 4) % 10).show,
                        [(models/product/id(p), qty, p.price)]).ignore
      "RecordSale"

fun edit-or-delete-sale( seed : int ) : io string
  val sales = repo2/list-sales()
  match sales.drop((seed / 2048) % int/max(1, sales.length)).head
    Nothing -> "skip"
    Just(sl) ->
      val sid = models/sale/id(sl)
      if (seed / 2) % 2 == 0 then
        repo2/delete-sale(sid).ignore
        "DeleteSale"
      else
        val products = repo2/list-products()
        match products.head
          Nothing -> "skip"
          Just(p) ->
            repo2/update-sale(sid, sl.date,
                              [(models/product/id(p), 1 + (seed / 1024) % 2, p.price)]).ignore
            "EditSale"
