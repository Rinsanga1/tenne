// The rest of the data-access layer: the shop, expenses, and the unified
// ledger. Split from repo.kk only for file size; it is the same layer.
//
// The stock functions here are where TenneCRM.tla's StockConserved and
// StockNeverNegative live. Read docs/tla/README.md before changing them.
module repo2

import std/num/float64
import sql
import dates
import models
import repo

// --- products -----------------------------------------------------------

val product-cols = "id, name, price, stock, active"

fun product-of( s : sql/stmt ) : io models/product
  Product(sql/col-int(s, 0), sql/col-text(s, 1), sql/col-real(s, 2),
          sql/col-int(s, 3), sql/col-int(s, 4) != 0)

pub fun list-products() : io list<models/product>
  sql/rows("SELECT " ++ product-cols ++ " FROM products ORDER BY name COLLATE NOCASE",
           [], product-of)

// Inactive products are counted too: a product taken off sale still occupies
// a slot, or the licence cap is lifted by unticking a checkbox.
pub fun count-products() : io int
  sql/scalar-int("SELECT COUNT(*) FROM products", [], 0)

pub fun get-product( id : int ) : io maybe<models/product>
  sql/query-with("SELECT " ++ product-cols ++ " FROM products WHERE id = ?",
                 fn(s) { sql/bind-int(s, 1, id) }, Nothing,
                 fn(_a, s) { Just(product-of(s)) })

pub fun low-stock-products( threshold : int ) : io list<models/product>
  sql/rows-with("SELECT " ++ product-cols ++ " FROM products WHERE active = 1" ++
                " AND stock <= ? ORDER BY stock ASC",
                fn(s) { sql/bind-int(s, 1, threshold) }, product-of)

pub fun insert-product( p : models/product ) : io int
  val ok = sql/exec-with("INSERT INTO products(name, price, stock, active) VALUES (?,?,?,?)") fn(s)
    sql/bind-text(s, 1, p.name)
    sql/bind-real(s, 2, p.price)
    sql/bind-int(s, 3, p.stock)
    sql/bind-int(s, 4, if p.active then 1 else 0)
  if ok then sql/last-id() else 0

pub fun update-product( p : models/product ) : io bool
  sql/exec-with("UPDATE products SET name=?, price=?, stock=?, active=? WHERE id=?") fn(s)
    sql/bind-text(s, 1, p.name)
    sql/bind-real(s, 2, p.price)
    sql/bind-int(s, 3, p.stock)
    sql/bind-int(s, 4, if p.active then 1 else 0)
    sql/bind-int(s, 5, p.id)

// Detach the product from any sale it appears in, then delete it.
// sale_items.product_id references products(id), so deleting a product that has
// ever been sold would otherwise fail the foreign key -- which the Rust build
// swallowed with .is_ok(), so the delete silently did nothing. Nulling the
// reference keeps the sale, and its revenue, on the books.
pub fun delete-product( id : int ) : io bool
  sql/exec("BEGIN").ignore
  val a = sql/exec-with("UPDATE sale_items SET product_id = NULL WHERE product_id = ?",
                        fn(s) { sql/bind-int(s, 1, id) })
  val b = sql/exec-with("DELETE FROM products WHERE id = ?",
                        fn(s) { sql/bind-int(s, 1, id) })
  val ok = a && b
  sql/exec(if ok then "COMMIT" else "ROLLBACK").ignore
  ok

// --- sales --------------------------------------------------------------

fun sale-of( s : sql/stmt ) : io models/sale
  Sale(sql/col-int(s, 0), sql/col-text(s, 1), sql/col-real(s, 2))

pub fun list-sales() : io list<models/sale>
  sql/rows("SELECT id, date, total FROM sales ORDER BY date DESC, id DESC", [], sale-of)

pub fun count-sales() : io int
  sql/scalar-int("SELECT COUNT(*) FROM sales", [], 0)

pub fun list-sales-between( start : string, end : string ) : io list<models/sale>
  sql/rows-with("SELECT id, date, total FROM sales WHERE date BETWEEN ? AND ?" ++
                " ORDER BY date DESC, id DESC",
                fn(s) { sql/bind-text(s, 1, start); sql/bind-text(s, 2, end) }, sale-of)

fun item-of( s : sql/stmt ) : io models/sale-item
  val pid = if sql/col-null(s, 2) then Nothing else Just(sql/col-int(s, 2))
  Sale-item(sql/col-int(s, 0), sql/col-int(s, 1), pid,
            sql/col-int(s, 3), sql/col-real(s, 4))

pub fun sale-items( sale-id : int ) : io list<models/sale-item>
  sql/rows-with("SELECT id, sale_id, product_id, qty, unit_price FROM sale_items" ++
                " WHERE sale_id = ? ORDER BY id",
                fn(s) { sql/bind-int(s, 1, sale-id) }, item-of)

// Every (sale_id, product_id, qty) line for sales in [start, end] in one query,
// so a month of sales costs one round trip instead of one per sale.
fun line-of( s : sql/stmt ) : io (int, maybe<int>, int)
  val pid = if sql/col-null(s, 1) then Nothing else Just(sql/col-int(s, 1))
  (sql/col-int(s, 0), pid, sql/col-int(s, 2))

pub fun sale-item-lines-between( start : string, end : string ) : io list<(int, maybe<int>, int)>
  sql/rows-with("SELECT si.sale_id, si.product_id, si.qty FROM sale_items si" ++
                " JOIN sales s ON s.id = si.sale_id WHERE s.date BETWEEN ? AND ?" ++
                " ORDER BY si.sale_id, si.id",
                fn(s) { sql/bind-text(s, 1, start); sql/bind-text(s, 2, end) },
                line-of)

// A line about to be sold: product, quantity, unit price.
pub alias line = (int, int, float64)

// A product and how many units of it a sale currently holds.
pub alias holding = (int, int)

fun move-stock( product-id : int, delta : int ) : io bool
  sql/exec-with("UPDATE products SET stock = stock + ? WHERE id = ?") fn(s)
    sql/bind-int(s, 1, delta)
    sql/bind-int(s, 2, product-id)

fun put-back( sale-id : int ) : io ()
  sale-items(sale-id).foreach fn(li : models/sale-item)
    match li.product-id
      Just(pid) -> move-stock(pid, li.qty).ignore
      Nothing -> ()

// How many units of `product-id` these lines take, summed.
//
// Totalling per product is the point: two lines of the same item each pass a
// per-line check and together overdraw the shelf. That is exactly the
// StockNeverNegative counterexample TLC produced, and why the sale dialog sums
// before it validates.
pub fun units-of( lines : list<line>, product-id : int ) : int
  lines.foldl(0) fn(acc, l : line)
    if l.fst == product-id then acc + l.snd else acc

// Is there enough on the shelf for these lines? `held` is what the sale being
// edited already holds, which it may take back -- so widening an existing sale
// still works.
pub fun stock-ok( lines : list<line>, held : list<holding> ) : io bool
  lines.map(fn(l : line) { l.fst }).all fn(pid)
    val have = match get-product(pid)
      Just(p) -> p.stock
      Nothing -> 0
    val back = held.foldl(0, fn(a, h : holding) { if h.fst == pid then a + h.snd else a })
    units-of(lines, pid) <= have + back

// What a sale currently holds, by product.
pub fun holdings( sale-id : int ) : io list<holding>
  sale-items(sale-id).foldl([]) fn(acc, li : models/sale-item)
    match li.product-id
      Just(pid) -> Cons((pid, li.qty), acc)
      Nothing -> acc

fun insert-line( sale-id : int, product-id : maybe<int>, qty : int, unit-price : float64 ) : io bool
  sql/exec-with("INSERT INTO sale_items(sale_id, product_id, qty, unit_price) VALUES (?,?,?,?)") fn(s)
    sql/bind-int(s, 1, sale-id)
    match product-id
      Just(pid) -> sql/bind-int(s, 2, pid)
      Nothing -> sql/bind-null(s, 2)
    sql/bind-int(s, 3, qty)
    sql/bind-real(s, 4, unit-price)

fun new-sale( date : string, total : float64 ) : io int
  val ok = sql/exec-with("INSERT INTO sales(date, total, created_at) VALUES (?,?,?)") fn(s)
    sql/bind-text(s, 1, date)
    sql/bind-real(s, 2, total)
    sql/bind-text(s, 3, dates/now())
  if ok then sql/last-id() else 0

pub fun line-total( lines : list<line> ) : float64
  lines.foldl(0.0) fn(acc, l : line) { acc + l.snd.float64 * l.thd }

// Record a sale and its lines in one transaction, taking the units off the
// shelf. Refuses rather than overdrawing -- StockNeverNegative. Returns 0 when
// the shelf is short, so the caller can say what is short and by how much.
pub fun record-sale( date : string, lines : list<line> ) : io int
  if !stock-ok(lines, []) then 0
  else
    sql/exec("BEGIN").ignore
    val sid = new-sale(date, line-total(lines))
    if sid == 0 then
      sql/exec("ROLLBACK").ignore
      0
    else
      lines.foreach fn(l : line)
        insert-line(sid, Just(l.fst), l.snd, l.thd).ignore
        move-stock(l.fst, 0 - l.snd).ignore
      sql/exec("COMMIT").ignore
      sid

// Insert a sale exactly as given (CSV import): preserves the recorded total
// rather than recomputing it from the lines. Lines naming a product still move
// stock, so deleting an imported sale returns exactly what it took -- without
// that, delete-sale would mint units the sale never held.
pub fun import-sale( date : string, total : float64,
                     lines : list<(maybe<int>, int, float64)> ) : io int
  sql/exec("BEGIN").ignore
  val sid = new-sale(date, total)
  if sid == 0 then
    sql/exec("ROLLBACK").ignore
    0
  else
    lines.foreach fn(l : (maybe<int>, int, float64))
      insert-line(sid, l.fst, l.snd, l.thd).ignore
      match l.fst
        Just(pid) -> move-stock(pid, 0 - l.snd).ignore
        Nothing -> ()
    sql/exec("COMMIT").ignore
    sid

// Delete a sale, putting back exactly the units it took. StockConserved.
pub fun delete-sale( id : int ) : io bool
  sql/exec("BEGIN").ignore
  put-back(id)
  val ok = sql/exec-with("DELETE FROM sales WHERE id = ?", fn(s) { sql/bind-int(s, 1, id) })
  sql/exec(if ok then "COMMIT" else "ROLLBACK").ignore
  ok

// Replace a sale's lines, adjusting stock by the net difference: put back what
// it held, then take what it now needs.
pub fun update-sale( sale-id : int, date : string, lines : list<line> ) : io bool
  if !stock-ok(lines, holdings(sale-id)) then False
  else
    sql/exec("BEGIN").ignore
    put-back(sale-id)
    sql/exec-with("DELETE FROM sale_items WHERE sale_id = ?",
                  fn(s) { sql/bind-int(s, 1, sale-id) }).ignore
    val ok = sql/exec-with("UPDATE sales SET date = ?, total = ? WHERE id = ?") fn(s)
      sql/bind-text(s, 1, date)
      sql/bind-real(s, 2, line-total(lines))
      sql/bind-int(s, 3, sale-id)
    lines.foreach fn(l : line)
      insert-line(sale-id, Just(l.fst), l.snd, l.thd).ignore
      move-stock(l.fst, 0 - l.snd).ignore
    sql/exec(if ok then "COMMIT" else "ROLLBACK").ignore
    ok

pub fun merch-income( start : string, end : string ) : io float64
  sql/real-with("SELECT COALESCE(SUM(total),0) FROM sales WHERE date >= ? AND date <= ?",
                fn(s) { sql/bind-text(s, 1, start); sql/bind-text(s, 2, end) }, 0.0)

pub fun merch-units( start : string, end : string ) : io int
  sql/int-with("SELECT COALESCE(SUM(si.qty),0) FROM sale_items si" ++
               " JOIN sales s ON s.id = si.sale_id WHERE s.date >= ? AND s.date <= ?",
               fn(s) { sql/bind-text(s, 1, start); sql/bind-text(s, 2, end) }, 0)

// --- expenses -----------------------------------------------------------

val expense-cols = "id, name, amount, date, note"

fun expense-of( s : sql/stmt ) : io models/expense
  Expense(sql/col-int(s, 0), sql/col-text(s, 1), sql/col-real(s, 2),
          sql/col-text(s, 3), sql/col-text-opt(s, 4))

pub fun list-expenses() : io list<models/expense>
  sql/rows("SELECT " ++ expense-cols ++ " FROM expenses ORDER BY date DESC, id DESC",
           [], expense-of)

pub fun list-expenses-between( start : string, end : string ) : io list<models/expense>
  sql/rows-with("SELECT " ++ expense-cols ++ " FROM expenses WHERE date BETWEEN ? AND ?" ++
                " ORDER BY date DESC, id DESC",
                fn(s) { sql/bind-text(s, 1, start); sql/bind-text(s, 2, end) }, expense-of)

pub fun get-expense( id : int ) : io maybe<models/expense>
  sql/query-with("SELECT " ++ expense-cols ++ " FROM expenses WHERE id = ?",
                 fn(s) { sql/bind-int(s, 1, id) }, Nothing,
                 fn(_a, s) { Just(expense-of(s)) })

pub fun insert-expense( e : models/expense ) : io int
  val ok = sql/exec-with("INSERT INTO expenses(name, amount, date, note, created_at)" ++
                         " VALUES (?,?,?,?,?)") fn(s)
    sql/bind-text(s, 1, e.name)
    sql/bind-real(s, 2, e.amount)
    sql/bind-text(s, 3, e.date)
    sql/bind-text-opt(s, 4, e.note)
    sql/bind-text(s, 5, dates/now())
  if ok then sql/last-id() else 0

pub fun update-expense( e : models/expense ) : io bool
  sql/exec-with("UPDATE expenses SET name=?, amount=?, date=?, note=? WHERE id=?") fn(s)
    sql/bind-text(s, 1, e.name)
    sql/bind-real(s, 2, e.amount)
    sql/bind-text(s, 3, e.date)
    sql/bind-text-opt(s, 4, e.note)
    sql/bind-int(s, 5, e.id)

pub fun delete-expense( id : int ) : io bool
  sql/exec-with("DELETE FROM expenses WHERE id = ?", fn(s) { sql/bind-int(s, 1, id) })

pub fun total-expenses( start : string, end : string ) : io float64
  sql/real-with("SELECT COALESCE(SUM(amount),0) FROM expenses WHERE date >= ? AND date <= ?",
                fn(s) { sql/bind-text(s, 1, start); sql/bind-text(s, 2, end) }, 0.0)

pub fun expense-years() : io list<int>
  sql/rows("SELECT DISTINCT substr(date,1,4) FROM expenses ORDER BY 1 DESC", [],
           fn(s) { sql/col-int(s, 0) })

// A saved template the Add-expense form prefills from. Not automatic.
pub fun list-recurring-expenses() : io list<models/recurring-expense>
  sql/rows("SELECT id, name, amount FROM recurring_expenses ORDER BY name COLLATE NOCASE", [],
           fn(s) { Recurring-expense(sql/col-int(s, 0), sql/col-text(s, 1), sql/col-real(s, 2)) })

pub fun insert-recurring-expense( r : models/recurring-expense ) : io int
  val ok = sql/exec-with("INSERT INTO recurring_expenses(name, amount) VALUES (?,?)") fn(s)
    sql/bind-text(s, 1, r.name)
    sql/bind-real(s, 2, r.amount)
  if ok then sql/last-id() else 0

pub fun update-recurring-expense( r : models/recurring-expense ) : io bool
  sql/exec-with("UPDATE recurring_expenses SET name=?, amount=? WHERE id=?") fn(s)
    sql/bind-text(s, 1, r.name)
    sql/bind-real(s, 2, r.amount)
    sql/bind-int(s, 3, r.id)

pub fun delete-recurring-expense( id : int ) : io bool
  sql/exec-with("DELETE FROM recurring_expenses WHERE id = ?", fn(s) { sql/bind-int(s, 1, id) })

// --- the unified ledger -------------------------------------------------

// Payments, sales and expenses as one stream of money movements, newest first.
// Ordered by date, then by when the row was actually entered, so two things
// recorded on the same day read back in the order they happened.
val ledger-sql =
  "SELECT kind, id, date, amount, label, detail FROM (" ++
  " SELECT 'payment' AS kind, p.id AS id, p.date AS date, p.amount AS amount," ++
  "        p.category AS label, m.name AS detail," ++
  "        COALESCE(p.created_at, p.date) AS ord" ++
  " FROM payments p LEFT JOIN members m ON m.id = p.member_id WHERE p.amount <> 0" ++
  " UNION ALL" ++
  " SELECT 'sale', s.id, s.date, s.total, 'Merchandise sale', NULL," ++
  "        COALESCE(s.created_at, s.date) FROM sales s" ++
  " UNION ALL" ++
  " SELECT 'expense', e.id, e.date, -e.amount, e.name, e.note," ++
  "        COALESCE(e.created_at, e.date) FROM expenses e" ++
  ") ORDER BY date DESC, ord DESC, id DESC"

fun txn-of( s : sql/stmt ) : io models/txn
  val kind = sql/col-text(s, 0)
  val id = sql/col-int(s, 1)
  val date = sql/col-text(s, 2)
  val amount = sql/col-real(s, 3)
  val label = sql/col-text(s, 4)
  val detail = sql/col-text-opt(s, 5)
  if kind == "payment" then
    val cat = models/category-label(label)
    val who = match detail
      Just(n) -> cat ++ " - " ++ n
      Nothing -> cat
    Txn(TxnPayment, id, date, amount, who, Nothing)
  elif kind == "sale" then
    Txn(TxnSale, id, date, amount, "Merchandise sale", Nothing)
  else
    val what = if label.trim == "" then "Expense" else label
    Txn(TxnExpense, id, date, amount, what, detail)

pub fun recent-transactions( limit : int ) : io list<models/txn>
  sql/rows-with(ledger-sql ++ " LIMIT ?", fn(s) { sql/bind-int(s, 1, limit) }, txn-of)

pub fun transactions-between( start : string, end : string ) : io list<models/txn>
  sql/rows-with("SELECT * FROM (" ++ ledger-sql ++ ") WHERE date BETWEEN ? AND ?" ++
                " ORDER BY date DESC",
                fn(s) { sql/bind-text(s, 1, start); sql/bind-text(s, 2, end) }, txn-of)

// Money in minus money out over a period. The dashboard's headline figure.
pub fun net-earnings( start : string, end : string ) : io float64
  total-income(start, end) - total-expenses(start, end)

// Everything the gym took in: dues, joining fees and the shop.
pub fun total-income( start : string, end : string ) : io float64
  repo/category-income(models/cat-membership, start, end) +
  repo/category-income(models/cat-registration, start, end) +
  merch-income(start, end)

// Revenue per calendar month, oldest first, zero-filled across the trailing
// `months` months up to `upto` (a `YYYY-MM`).
//
// Monthly, not daily, because billing is monthly -- a daily line is mostly
// empty days between payment spikes.
pub fun monthly-revenue( upto : string, months : int ) : io list<(string, float64)>
  match dates/parse-month(upto)
    Nothing -> []
    Just((y, m)) ->
      val (y0, m0) = dates/add-months-ym(y, m, 1 - months)
      dates/months-between(dates/fmt-month(y0, m0), upto).map fn(ym)
        val (start, end) = month-range(ym)
        (ym, total-income(start, end))

// The first and last day of a `YYYY-MM`, as the SQL between-clauses want them.
pub fun month-range( ym : string ) : (string, string)
  match dates/parse-month(ym)
    Nothing -> (ym, ym)
    Just((y, m)) ->
      val (y2, m2) = dates/add-months-ym(y, m, 1)
      (dates/fmt-date(y, m, 1), dates/add-days(dates/fmt-date(y2, m2, 1), -1))
