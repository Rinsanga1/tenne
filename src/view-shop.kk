// The Shop: what is on the shelf, and what has been sold.
//
// Stock is the one place in this application where a number can go wrong in a
// way the owner cannot see -- a member's arrears are recomputed from payments
// every frame, but stock is a stored counter that every sale moves. That is
// why StockConserved and StockNeverNegative exist, and why the sale dialog
// refuses rather than overdraws.
module view-shop

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

val cols = [Column("PRODUCT", 16, 240), Column("PRICE", 280, 110),
            Column("STOCK", 410, 110), Column("VALUE", 540, 120)]

fun col( i : int ) : widgets/column
  cols.drop(i).head.default(Column("", 0, 0))

pub fun show( r : ref<global,ui/ui>, s : app/state ) : io app/state
  val p = s.palette
  val box = app/content-rect()
  app/page-title(r, s, "Shop")

  val products = repo2/list-products()
  val f = s.filter
  // .fst/.snd rather than a tuple pattern: destructuring in a function that
  // also consumes `s` has miscompiled in Koka 3.2.3. See the Gotchas.
  val range = dates/range(f)
  val start = range.fst
  val end = range.snd
  val took = repo2/merch-income(start, end)
  val units = repo2/merch-units(start, end)
  val shelf-value = products.foldl(0.0) fn(a, prod : models/product)
    a + prod.price * prod.stock.float64

  var st := s
  if s.notice != "" then
    widgets/label((!r).font-small, box.x, box.y - 24, s.notice, theme/positive)

  if widgets/button-primary(r, p, Rect(box.x, box.y, 120, 32), "New sale",
                            ui/wid("s:sell")) then
    st := st(notice = "", sale = Just(app/blank-sale(dates/today())))
  if widgets/button(r, p, Rect(box.x + 132, box.y, 120, 32), "Add product",
                    ui/wid("s:addp")) then
    st := st(notice = "", product = Just(app/blank-product()))

  // period stepper, for the sales figure on the right
  if widgets/button(r, p, Rect(box.x + box.w - 220, box.y + 1, 30, 30), "<",
                    ui/wid("s:prev")) then
    st := st(filter = dates/previous(f))
  widgets/label-center((!r).font-body, box.x + box.w - 186, 150, box.y + 8,
                       dates/label(f), p.text)
  if widgets/button(r, p, Rect(box.x + box.w - 30, box.y + 1, 30, 30), ">",
                    ui/wid("s:next")) then
    st := st(filter = next-period(f))

  // Products or sales. The sales list is the only way to correct a sale that
  // was rung up wrong -- without it the stock stays wrong forever.
  val tabs-y = box.y + 44
  val on-sales = s.shop-sales
  if widgets/tab(r, p, Rect(box.x, tabs-y, 90, 28), "Products", !on-sales, "s:tp") then
    st := st(shop-sales = False, scroll = 0)
  if widgets/tab(r, p, Rect(box.x + 94, tabs-y, 70, 28), "Sales", on-sales, "s:ts") then
    st := st(shop-sales = True, scroll = 0)

  val ty = box.y + 80
  val th = box.h - 80 - 40
  widgets/panel(p, Rect(box.x, ty, box.w, th))
  val list-box = Rect(box.x + 1, ty + 42, box.w - 2, th - 43)

  if on-sales then st := sales-tab(r, st, box, ty, list-box)
  else
    widgets/table-header(r, p, box.x + 16, ty + 14, box.w - 32, cols)
    if products.is-nil then
      widgets/empty-state(r, p, list-box, "Nothing in the shop yet",
                          "Add a product to start selling and tracking stock")
    else
      val opened = ref(0)
      val snap = st
      val next-scroll = widgets/scroll-area(r, p, list-box, products.length * widgets/row-h,
                                            s.scroll) fn(dy)
        products.foreach-indexed fn(i, prod : models/product)
          if draw-row(r, snap, list-box, dy, i, prod) then opened := models/product/id(prod)
      if next-scroll != s.scroll then st := st(scroll = next-scroll)
      val hit = !opened
      if hit != 0 then
        match repo2/get-product(hit)
          Just(prod) -> st := st(product = Just(app/product-form-of(prod)), notice = "")
          Nothing -> ()

  val fy = box.y + box.h - 26
  widgets/label((!r).font-small, box.x + 16, fy,
                products.length.show ++ (if products.length == 1 then " product" else " products") ++
                "  -  shelf worth " ++ models/money(s.currency, shelf-value), p.text-muted)
  widgets/label-right((!r).font-body, box.x + box.w - 16, fy - 2,
                      "Sold in " ++ dates/label(f) ++ "  " ++
                      models/money(s.currency, took) ++ " (" ++ units.show ++
                      (if units == 1 then " unit)" else " units)"), theme/positive)
  st

val sale-cols = [Column("DATE", 16, 100), Column("WHAT WAS SOLD", 130, 320),
                 Column("TOTAL", 470, 110)]

fun scol( i : int ) : widgets/column
  sale-cols.drop(i).head.default(Column("", 0, 0))

// The sales for this period, newest first, each openable for correction.
fun sales-tab( r : ref<global,ui/ui>, s : app/state, box : rect, ty : int,
               list-box : rect ) : io app/state
  val p = s.palette
  val range = dates/range(s.filter)
  val sales = repo2/list-sales-between(range.fst, range.snd)
  widgets/table-header(r, p, box.x + 16, ty + 14, box.w - 32, sale-cols)
  var st := s
  if sales.is-nil then
    widgets/empty-state(r, p, list-box, "No sales in " ++ dates/label(s.filter),
                        "Ring one up with New sale, and it will appear here")
    st
  else
    // Describe every sale up front, in one pass, rather than querying inside
    // the row -- a row function that calls into the repository drags a `div`
    // effect into it that Koka 3.2.3 then miscompiles.
    val rows = sales.map(fn(sl : models/sale) { (sl, describe(models/sale/id(sl))) })
    val opened = ref(0)
    val snap = st
    val next-scroll = widgets/scroll-area(r, p, list-box, sales.length * widgets/row-h,
                                          s.scroll) fn(dy)
      rows.foreach-indexed fn(i, row : (models/sale, string))
        if draw-sale(r, snap, list-box, dy, i, row.fst, row.snd)
          then opened := models/sale/id(row.fst)
    if next-scroll != s.scroll then st := st(scroll = next-scroll)
    val hit = !opened
    if hit != 0 then
      // Load the sale's current lines as quantities so the dialog opens on
      // what was actually rung up. update-sale puts the old units back before
      // taking the new ones, so editing never loses stock -- StockConserved.
      match repo2/list-sales().filter(fn(x : models/sale) { models/sale/id(x) == hit }).head
        Just(sl) -> st := st(sale = Just(app/sale-form-of(hit, sl.date, repo2/holdings(hit))),
                             notice = "")
        Nothing -> ()
    st

fun draw-sale( r : ref<global,ui/ui>, s : app/state, list-box : rect, dy : int,
               i : int, sl : models/sale, what : string ) : io bool
  val p = s.palette
  val ry = list-box.y + dy + i * widgets/row-h
  if ry + widgets/row-h < list-box.y || ry > list-box.y + list-box.h then False else
    val row = Rect(list-box.x, ry, list-box.w - widgets/scrollbar-w, widgets/row-h)
    val act = widgets/table-row(r, p, row, i, ui/wid-at("s:sale", i))
    // everything bound once, before any drawing -- see the Gotchas
    val ox = list-box.x + 15
    val f = (!r).font-body
    val line = win32/font-line(f)
    val total = models/money(s.currency, sl.total)
    val c-total = scol(2)
    widgets/cell(r, scol(0), ox, ry, dates/short-date(sl.date), p.text-muted)
    widgets/cell(r, scol(1), ox, ry, what, p.text)
    widgets/label-right(f, ox + c-total.x + c-total.w,
                        ry + (widgets/row-h - line) / 2, total, p.text)
    act.clicked

// "2 x Protein bar, 1 x Shaker bottle". A sale is only recognisable by what
// was in it, so the row says so rather than showing a bare id.
fun describe( sale-id : int ) : io string
  val lines = repo2/sale-items(sale-id).map fn(li : models/sale-item)
    val what = match li.product-id
      Just(pid) -> match repo2/get-product(pid)
        Just(prod) -> prod.name
        Nothing -> "(deleted product)"
      Nothing -> "(deleted product)"
    li.qty.show ++ " x " ++ what
  if lines.is-nil then "(no lines)" else lines.join(", ")

fun next-period( f : dates/month-filter ) : dates/month-filter
  match f.month
    Just(12) -> Month-filter(f.year + 1, Just(1))
    Just(m) -> Month-filter(f.year, Just(m + 1))
    Nothing -> Month-filter(f.year + 1, Nothing)

fun draw-row( r : ref<global,ui/ui>, s : app/state, list-box : rect, dy : int,
              i : int, prod : models/product ) : io bool
  val p = s.palette
  val ry = list-box.y + dy + i * widgets/row-h
  if ry + widgets/row-h < list-box.y || ry > list-box.y + list-box.h then False else
    val row = Rect(list-box.x, ry, list-box.w - widgets/scrollbar-w, widgets/row-h)
    val act = widgets/table-row(r, p, row, i, ui/wid-at("s:row", i))
    val ox = list-box.x + 15
    // straight-line, not a nested `match cols` -- see the Gotchas
    widgets/cell(r, col(0), ox, ry, prod.name,
                 if prod.active then p.text else p.text-muted)
    widgets/cell(r, col(1), ox, ry, models/money(s.currency, prod.price), p.text-muted)
    draw-stock(r, s, col(2), ox, ry, prod)
    widgets/cell(r, col(3), ox, ry,
                 models/money(s.currency, prod.price * prod.stock.float64), p.text-muted)
    act.clicked

// Stock is the number the owner acts on, so it says what it means rather than
// printing a bare integer: "out of stock" and "low" are decisions, not counts.
fun draw-stock( r : ref<global,ui/ui>, s : app/state, c : widgets/column,
                ox : int, ry : int, prod : models/product ) : io ()
  // Everything bound once before the call: two functions instead of a
  // destructured tuple, and one read of the font rather than two. Both shapes
  // have miscompiled here. See the Gotchas.
  val n = prod.stock
  val f = (!r).font-body
  val line = win32/font-line(f)
  val word = stock-word(n)
  val col = stock-colour(n, s.palette)
  widgets/label(f, ox + c.x, ry + (widgets/row-h - line) / 2, word, col)

fun stock-word( n : int ) : string
  if n < 0 then "oversold by " ++ (0 - n).show
  elif n == 0 then "out of stock"
  elif n <= 5 then n.show ++ " left"
  else n.show

fun stock-colour( n : int, p : theme/palette ) : int
  if n <= 0 then theme/negative
  elif n <= 5 then theme/warning
  else p.text
