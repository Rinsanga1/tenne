// The Shop dialogs: ringing up a sale, and adding or editing a product.
//
// The sale dialog is the one place a user can drive stock negative, so it is
// the one place StockNeverNegative has to be enforced where they can see it.
// The repository refuses an overdrawing sale outright; this dialog's job is to
// refuse *earlier*, and to say what is short and by how much, so the owner
// fixes the count instead of wondering why Save does nothing.
module dlg-shop

import std/num/float64
import win32
import sql
import ui
import theme
import widgets
import models
import repo
import repo2
import dates
import util
import license
import app

// --- ringing up a sale --------------------------------------------------

pub fun sale-dialog( r : ref<global,ui/ui>, s : app/state, f : app/sale-form ) : io app/state
  val p = s.palette
  // every field read once, up front -- see the Gotchas
  val editing = f.editing
  val armed = f.confirm
  val adding = editing == 0
  val box = widgets/modal-frame(r, p, 520, 540, if adding then "New sale" else "Edit sale")
  val products = repo2/list-products().filter(fn(x : models/product) { x.active })
  // What this sale is already holding. Editing it puts these units back before
  // taking the new ones, so they count as available here too -- otherwise
  // widening a sale from 1 to 2 is refused against a shelf that already has
  // this sale's unit deducted from it.
  val held = if adding then [] else repo2/holdings(editing)

  var g := f
  val r0 = widgets/field-row(r, p, box, 0, "Date")
  g := g(date = widgets/text-field(r, p, Rect(r0.x, r0.y, 160, r0.h), f.date,
                                   ui/wid("sl:date"), "YYYY-MM-DD"))
  if widgets/button(r, p, Rect(r0.x + 170, r0.y, 70, 30), "Today", ui/wid("sl:today")) then
    g := g(date = dates/today())

  widgets/label((!r).font-small, box.x + 20, box.y + 122, "WHAT ARE THEY BUYING", p.text-muted)
  widgets/separator(p, box.x + 20, box.y + 140, box.w - 40)

  if products.is-nil then
    widgets/label((!r).font-small, box.x + 20, box.y + 156,
                  "Nothing in the shop to sell yet", p.text-muted)
  else
    val picked = ref(0)
    val delta = ref(0)
    val list-box = Rect(box.x + 20, box.y + 148, box.w - 40, 230)
    val snap = g
    win32/clip(list-box.x, list-box.y, list-box.w, list-box.h)
    products.foreach-indexed fn(i, prod : models/product)
      val ly = list-box.y + i * 34
      if ly > list-box.y + list-box.h - 30 then () else
        val pid = models/product/id(prod)
        val want = app/qty-of(snap, pid)
        widgets/label-clipped((!r).font-body, list-box.x, ly + 6, 190, prod.name, p.text)
        widgets/label((!r).font-small, list-box.x + 196, ly + 8,
                      models/money(s.currency, prod.price), p.text-muted)
        // what is on the shelf, so the limit is visible before it is hit
        val have = prod.stock + units-held(held, pid)
        widgets/label((!r).font-small, list-box.x + 280, ly + 8,
                      have.show ++ " in stock",
                      if want > have then theme/negative else p.text-muted)
        if widgets/button(r, p, Rect(list-box.x + list-box.w - 96, ly, 28, 26), "-",
                          ui/wid-at("sl:less", i)) then
          picked := pid
          delta := -1
        widgets/label-center((!r).font-body, list-box.x + list-box.w - 66, 34, ly + 5,
                             want.show, if want > 0 then p.text else p.text-muted)
        if widgets/button(r, p, Rect(list-box.x + list-box.w - 28, ly, 28, 26), "+",
                          ui/wid-at("sl:more", i)) then
          picked := pid
          delta := 1
    win32/clip-all()
    val who = !picked
    if who != 0 then
      g := app/set-qty(g, who, int/max(0, app/qty-of(g, who) + !delta))

  // --- the total, and the reason Save is disabled
  val lines = g.picks.map fn(q : (int, int))
    val price = match repo2/get-product(q.fst)
      Just(prod) -> prod.price
      Nothing -> 0.0
    (q.fst, q.snd, price)
  val total = repo2/line-total(lines)
  val short = shortfall(lines, held)
  val date-ok = dates/is-valid-date(g.date)
  // Only a new sale is capped. An existing one stays correctable however many
  // are on the books -- a mis-rung sale the owner cannot fix is worse than an
  // unlicensed one they can.
  val capped = adding && !license/can-add-sale(s.licensee != "")
  val valid = !lines.is-nil && date-ok && short == "" && !capped

  val msg-y = box.y + box.h - 84
  if capped then
    widgets/label((!r).font-small, box.x + 20, msg-y, license/sale-cap-notice(), theme/warning)
  elif !date-ok then
    widgets/label((!r).font-small, box.x + 20, msg-y, "Date must be YYYY-MM-DD", theme/warning)
  elif short != "" then
    // Naming what is short, and by how much, is the difference between a
    // disabled button and an answerable question.
    widgets/label((!r).font-small, box.x + 20, msg-y, short, theme/negative)
  elif lines.is-nil then
    widgets/label((!r).font-small, box.x + 20, msg-y, "Add something to the sale", p.text-muted)
  else
    widgets/label((!r).font-body, box.x + 20, msg-y,
                  "Total " ++ models/money(s.currency, total), p.text)
  if f.error != "" then
    widgets/label((!r).font-small, box.x + 20, msg-y + 18, f.error, theme/negative)

  // Deleting a sale puts its units back on the shelf, so this is the only way
  // to undo one rung up by mistake. Two-stage, because it moves stock.
  val hit-delete = if adding then False
                   else widgets/button-danger(r, p, Rect(box.x + 20, box.y + box.h - 42, 130, 32),
                                              (if armed then "Really delete?" else "Delete sale"),
                                              ui/wid("sl:del"))
  val (save, cancel) = widgets/modal-buttons(r, p, box,
                                             (if adding then "Record sale" else "Save"),
                                             "sl", valid)
  if cancel || ui/escape-pressed(r) then s(sale = Nothing)
  elif hit-delete then
    if !armed then s(sale = Just(g(confirm = True)))
    elif repo2/delete-sale(editing)
      then s(sale = Nothing, notice = "Sale deleted, stock put back")
      else s(sale = Just(g(error = "Could not delete the sale")))
  elif !save then s(sale = Just(g))
  elif adding then
    val id = repo2/record-sale(g.date, lines)
    if id == 0 then s(sale = Just(g(error = "Could not record the sale")))
    else s(sale = Nothing,
           notice = "Sale recorded - " ++ models/money(s.currency, total))
  else
    // update-sale, not record-sale: opening a sale from the Sales tab and
    // saving used to write a *second* sale and deduct the stock twice.
    if !repo2/update-sale(editing, g.date, lines)
      then s(sale = Just(g(error = "Could not update the sale")))
      else s(sale = Nothing,
             notice = "Sale updated - " ++ models/money(s.currency, total))

// "Only 2 Protein bar left, 3 wanted". Empty when the shelf can cover it.
//
// Totals per product first: two of the same item must be summed before the
// comparison, which is exactly the StockNeverNegative counterexample.
fun shortfall( lines : list<repo2/line>, held : list<(int, int)> ) : io string
  val bad = lines.map(fn(l : repo2/line) { l.fst }).foldl("") fn(acc, pid)
    if acc != "" then acc else
      val want = repo2/units-of(lines, pid)
      match repo2/get-product(pid)
        Nothing -> acc
        Just(prod) ->
          val have = prod.stock + units-held(held, pid)
          if want <= have then acc
          else "Only " ++ have.show ++ " " ++ prod.name ++ " left, " ++
               want.show ++ " wanted"
  bad

fun units-held( held : list<(int, int)>, product-id : int ) : int
  held.foldl(0) fn(a, h : (int, int))
    if h.fst == product-id then a + h.snd else a

// --- adding or editing a product ----------------------------------------

pub fun product-dialog( r : ref<global,ui/ui>, s : app/state,
                        f : app/product-form ) : io app/state
  val p = s.palette
  // every field read once, up front -- see the Gotchas
  val editing = f.editing
  val armed = f.confirm
  val adding = editing == 0
  val box = widgets/modal-frame(r, p, 430, 400,
                                if adding then "Add product" else "Edit product")
  var g := f
  val r0 = widgets/field-row(r, p, box, 0, "Name")
  g := g(name = widgets/text-field(r, p, r0, f.name, ui/wid("pr:name"), "Protein bar"))
  val r1 = widgets/field-row(r, p, box, 1, "Price")
  g := g(price = widgets/text-field(r, p, Rect(r1.x, r1.y, 160, r1.h), f.price,
                                    ui/wid("pr:price"), "0"))
  val r2 = widgets/field-row(r, p, box, 2, "Units in stock")
  g := g(stock = widgets/text-field(r, p, Rect(r2.x, r2.y, 160, r2.h), f.stock,
                                    ui/wid("pr:stock"), "0"))
  g := g(active = widgets/checkbox(r, p, box.x + 20, box.y + 268, "Selling this",
                                   f.active, "pr:active"))

  val name-ok = g.name.trim != ""
  val price = util/parse-money(g.price)
  val stock = util/parse-nat(g.stock.trim)
  val capped = adding && !license/can-add-product(s.licensee != "")
  val valid = name-ok && price.is-just && stock.is-just && !capped
  val why = if capped then license/product-cap-notice()
            elif !name-ok then "A name is required"
            elif price.is-nothing then "Price must be a number"
            elif stock.is-nothing then "Stock must be a whole number, zero or more"
            else ""
  val msg-y = box.y + box.h - 84
  if why != "" then widgets/label((!r).font-small, box.x + 20, msg-y, why, theme/warning)
  if f.error != "" then
    widgets/label((!r).font-small, box.x + 20, msg-y + 18, f.error, theme/negative)

  // Deleting a product keeps the sales it appears in, and their revenue, on
  // the books -- delete-product nulls the reference rather than cascading.
  // Setting it inactive is the gentler option and the checkbox above is it.
  val hit-delete = if adding then False
                   else widgets/button-danger(r, p, Rect(box.x + 20, box.y + box.h - 42, 130, 32),
                                              (if armed then "Really delete?" else "Delete"),
                                              ui/wid("pr:del"))
  val (save, cancel) = widgets/modal-buttons(r, p, box, "Save", "pr", valid)
  if cancel || ui/escape-pressed(r) then s(product = Nothing)
  elif hit-delete then
    if !armed then s(product = Just(g(confirm = True)))
    elif repo2/delete-product(editing)
      then s(product = Nothing, notice = g.name.trim ++ " deleted")
      else s(product = Just(g(error = "Could not delete: " ++ sql/error())))
  elif !save then s(product = Just(g))
  else
    val prod = Product(editing, g.name.trim, price.default(0.0),
                       stock.default(0), g.active)
    val ok = if adding then repo2/insert-product(prod) > 0 else repo2/update-product(prod)
    if !ok then s(product = Just(g(error = "Could not save: " ++ sql/error())))
    else s(product = Nothing, notice = g.name.trim ++ (if adding then " added" else " updated"))
