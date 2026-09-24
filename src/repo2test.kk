// The shop half of TenneCRM.tla, exercised against a real database.
// StockConserved and StockNeverNegative are the two that TLC produced
// counterexamples for; the cases below are those traces.
module repo2test

import std/num/float64
import sql
import db
import repo
import repo2
import models
import util

fun check( f : ref<global,int>, name : string, got : string, want : string ) : io ()
  val ok = got == want
  if !ok then f := !f + 1
  println((if ok then "  ok   " else "  FAIL ") ++ name.pad-right(46) ++ got.pad-right(18) ++
          (if ok then "" else "want " ++ want))

// Every unit is either on the shelf or inside a sale still on the books.
fun conserved( f : ref<global,int>, name : string, expected : int ) : io ()
  val shelf = sql/scalar-int("SELECT COALESCE(SUM(stock),0) FROM products", [], -1)
  val sold = sql/scalar-int("SELECT COALESCE(SUM(si.qty),0) FROM sale_items si" ++
                            " WHERE si.product_id IS NOT NULL", [], -1)
  check(f, name, (shelf + sold).show, expected.show)

pub fun main() : io ()
  sql/unbuffer()
  val f = ref(0)
  val p = "out/repo2.db"
  if sql/file-exists(p) then sql/remove-file(p).ignore
  db/open-db(p).ignore

  // --- products
  val bar = repo2/insert-product(Product(0, "Protein bar", 60.0, 2, True))
  val shake = repo2/insert-product(Product(0, "Shaker", 250.0, 5, True))
  check(f, "products inserted", (bar > 0 && shake > 0).show, "True")
  check(f, "listed by name", repo2/list-products().map(fn(x : models/product) { x.name }).join(","),
        "Protein bar,Shaker")
  check(f, "low stock threshold",
        repo2/low-stock-products(2).map(fn(x : models/product) { x.name }).join(","), "Protein bar")
  conserved(f, "7 units before any sale", 7)

  // --- StockNeverNegative: the exact TLC trace.
  // Two units on the shelf. Ring up one, then try to ring up two more.
  val s1 = repo2/record-sale("2025-05-01", [(bar, 1, 60.0)])
  check(f, "first sale recorded", (s1 > 0).show, "True")
  check(f, "one unit left", repo2/get-product(bar).map(fn(x : models/product) { x.stock }).default(-1).show, "1")
  val s2 = repo2/record-sale("2025-05-01", [(bar, 2, 60.0)])
  check(f, "overdrawing sale is refused", s2.show, "0")
  check(f, "and the shelf is untouched",
        repo2/get-product(bar).map(fn(x : models/product) { x.stock }).default(-1).show, "1")
  check(f, "stock never went negative",
        sql/scalar-int("SELECT COUNT(*) FROM products WHERE stock < 0", [], -1).show, "0")

  // Two lines of the SAME product must be summed before checking. Each line
  // passes a per-line check on its own; together they overdraw.
  val s3 = repo2/record-sale("2025-05-02", [(bar, 1, 60.0), (bar, 1, 60.0)])
  check(f, "two lines of one item are summed", s3.show, "0")
  check(f, "units-of totals per product", repo2/units-of([(bar,1,60.0),(bar,1,60.0)], bar).show, "2")
  conserved(f, "still 7 units", 7)

  // --- StockConserved: deleting a sale puts back exactly what it took
  val s4 = repo2/record-sale("2025-05-03", [(shake, 2, 250.0)])
  check(f, "shaker sale recorded", (s4 > 0).show, "True")
  check(f, "shakers down to 3", repo2/get-product(shake).map(fn(x : models/product) { x.stock }).default(-1).show, "3")
  conserved(f, "units conserved after sale", 7)
  repo2/delete-sale(s4).ignore
  check(f, "shakers back to 5", repo2/get-product(shake).map(fn(x : models/product) { x.stock }).default(-1).show, "5")
  conserved(f, "units conserved after delete", 7)

  // --- editing a sale: it may reclaim its own units
  val s5 = repo2/record-sale("2025-05-04", [(shake, 2, 250.0)])
  check(f, "widening a sale it already holds is allowed",
        repo2/update-sale(s5, "2025-05-04", [(shake, 4, 250.0)]).show, "True")
  check(f, "shelf reflects the wider sale",
        repo2/get-product(shake).map(fn(x : models/product) { x.stock }).default(-1).show, "1")
  conserved(f, "units conserved after edit", 7)
  check(f, "but not beyond the shelf",
        repo2/update-sale(s5, "2025-05-04", [(shake, 9, 250.0)]).show, "False")
  check(f, "and the failed edit changed nothing",
        repo2/get-product(shake).map(fn(x : models/product) { x.stock }).default(-1).show, "1")
  conserved(f, "units conserved after refused edit", 7)
  repo2/update-sale(s5, "2025-05-04", [(shake, 1, 250.0)]).ignore
  check(f, "narrowing puts units back",
        repo2/get-product(shake).map(fn(x : models/product) { x.stock }).default(-1).show, "4")
  conserved(f, "units conserved after narrowing", 7)

  // --- an imported sale must also move stock, or deleting it mints units
  val s6 = repo2/import-sale("2025-05-05", 120.0, [(Just(bar), 1, 60.0)])
  check(f, "import-sale moves stock",
        repo2/get-product(bar).map(fn(x : models/product) { x.stock }).default(-1).show, "0")
  check(f, "import preserves the recorded total",
        repo2/list-sales().filter(fn(x : models/sale) { models/sale/id(x) == s6 })
          .map(fn(x : models/sale) { x.total.show }).join(""), "120")
  conserved(f, "units conserved after import", 7)
  repo2/delete-sale(s6).ignore
  conserved(f, "deleting an imported sale mints nothing", 7)

  // --- deleting a product that has been sold keeps the sale on the books
  val revenue-before = repo2/merch-income("2025-01-01", "2025-12-31")
  check(f, "deleting a sold product succeeds", repo2/delete-product(bar).show, "True")
  check(f, "the product is gone", repo2/get-product(bar).is-nothing.show, "True")
  check(f, "its sale lines are detached, not deleted",
        sql/scalar-int("SELECT COUNT(*) FROM sale_items WHERE product_id IS NULL", [], -1).show, "1")
  check(f, "and the revenue stayed on the books",
        (repo2/merch-income("2025-01-01", "2025-12-31") == revenue-before).show, "True")

  // --- expenses
  repo2/insert-expense(Expense(0, "Rent", 12000.0, "2025-05-01", Nothing)).ignore
  repo2/insert-expense(Expense(0, "Electricity", 2400.0, "2025-05-09", Just("summer"))).ignore
  check(f, "expenses listed newest first",
        repo2/list-expenses().map(fn(x : models/expense) { x.name }).join(","), "Electricity,Rent")
  check(f, "expense total for May",
        models/money("Rs", repo2/total-expenses("2025-05-01", "2025-05-31")), "Rs 14,400")
  check(f, "expenses outside the range are excluded",
        models/money("Rs", repo2/total-expenses("2025-06-01", "2025-06-30")), "Rs 0")
  repo2/insert-recurring-expense(Recurring-expense(0, "Rent", 12000.0)).ignore
  check(f, "recurring template saved",
        repo2/list-recurring-expenses().map(fn(x : models/recurring-expense) { x.name }).join(","), "Rent")

  // --- the unified ledger
  val m = repo/create-member(Member(0, "Priya", Nothing, Nothing, "2025-05-01", True, Nothing),
                             500.0, Just(1500.0), "2025-05", "2025-05-01")
  check(f, "member created for the ledger", (m > 0).show, "True")
  val ledger = repo2/recent-transactions(50)
  check(f, "ledger carries all three kinds",
        [ledger.any(fn(t : models/txn) { t.kind.is-payment }),
         ledger.any(fn(t : models/txn) { t.kind.is-sale }),
         ledger.any(fn(t : models/txn) { t.kind.is-expense })].map(fn(b) { b.show }).join(","),
        "True,True,True")
  check(f, "expenses are money out",
        ledger.filter(fn(t : models/txn) { t.kind.is-expense })
              .all(fn(t : models/txn) { t.amount < 0.0 }).show, "True")
  check(f, "payments are money in",
        ledger.filter(fn(t : models/txn) { t.kind.is-payment })
              .all(fn(t : models/txn) { t.amount > 0.0 }).show, "True")
  check(f, "a joining fee reads as one",
        ledger.any(fn(t : models/txn) { t.label == "Joining fee - Priya" }).show, "True")
  check(f, "a monthly fee reads as one",
        ledger.any(fn(t : models/txn) { t.label == "Monthly fee - Priya" }).show, "True")
  check(f, "newest first",
        (ledger.map(fn(t : models/txn) { t.date }) ==
         ledger.map(fn(t : models/txn) { t.date }).sort-by(fn(a : string, b : string) { a > b })).show, "True")

  // net earnings: dues + joining fees + merch - expenses
  val net = repo2/net-earnings("2025-01-01", "2025-12-31")
  val expect = 500.0 + 1500.0 + repo2/merch-income("2025-01-01","2025-12-31") - 14400.0
  check(f, "net earnings adds up", models/money("Rs", net), models/money("Rs", expect))

  sql/close().ignore
  println(if !f == 0 then "ALL PASS" else "FAILED: " ++ (!f).show)
