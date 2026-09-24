// The application shell: the database, the view the user is on, and the
// per-view state that has to survive a frame.
//
// Everything here is state the UI cannot recompute. In an immediate-mode GUI
// that is deliberately a short list -- if it is not in this record, it is
// derived from the database every frame.
module app

import std/num/float64
import win32
import ui
import theme
import widgets
import models
import repo
import dates

pub type view
  Dashboard
  Members
  Shop
  Expenses
  Transactions
  Settings

// The filter opens on the month the app believes it is.
pub fun current-filter-of( month : string ) : dates/month-filter
  match dates/parse-month(month)
    Just((y, m)) -> Month-filter(y, Just(m))
    Nothing -> Month-filter(2026, Nothing)

pub fun view-label( v : view ) : string
  match v
    Dashboard -> "Dashboard"
    Members -> "Members"
    Shop -> "Shop"
    Expenses -> "Expenses"
    Transactions -> "Transactions"
    Settings -> "Settings"

pub val all-views = [Dashboard, Members, Shop, Expenses, Transactions, Settings]

pub fun same-view( a : view, b : view ) : bool
  view-label(a) == view-label(b)

// The Add / Edit member dialog. `editing` of 0 means a new member.
//
// The two fee fields exist only when adding. Editing a member never touches
// their ledger -- a joining fee is collected once, and AtMostOneJoiningFee
// depends on there being no second door into it.
pub struct member-form
  editing   : int
  name      : string
  phone     : string
  address   : string
  join-date : string
  notes     : string
  joining-fee : string
  month-fee : string
  error     : string

pub fun blank-form( today : string, fee : string, monthly : string ) : member-form
  Member-form(0, "", "", "", today, "", fee, monthly, "")

pub fun form-of( m : models/member ) : member-form
  Member-form(m.id, m.name, m.phone.default(""), m.address.default(""),
              m.join-date, m.notes.default(""), "", "", "")

pub fun to-member( f : member-form ) : models/member
  fun opt( s : string ) : maybe<string>
    if s.trim == "" then Nothing else Just(s.trim)
  Member(f.editing, f.name.trim, opt(f.phone), opt(f.address),
         f.join-date.trim, True, opt(f.notes))

// Adding or editing a product.
pub struct product-form
  editing : int
  name    : string
  price   : string
  stock   : string
  active  : bool
  error   : string
  confirm : bool

pub fun blank-product() : product-form
  Product-form(0, "", "", "0", True, "", False)

pub fun product-form-of( p : models/product ) : product-form
  Product-form(p.id, p.name, show-amount(p.price), p.stock.show, p.active, "", False)

// A sale being rung up: a quantity per product, and the day it happened.
//
// Quantities are held per product, not as a list of lines, so two lines of the
// same item cannot arise from the counter at all. The repository still sums
// per product because the CSV importer is another door -- StockNeverNegative.
pub struct sale-form
  editing : int
  date    : string
  picks   : list<(int, int)>
  error   : string
  confirm : bool

pub fun blank-sale( today : string ) : sale-form
  Sale-form(0, today, [], "", False)

pub fun qty-of( f : sale-form, product-id : int ) : int
  f.picks.foldl(0) fn(a, q : (int, int))
    if q.fst == product-id then a + q.snd else a

pub fun set-qty( f : sale-form, product-id : int, n : int ) : sale-form
  val rest = f.picks.filter(fn(q : (int, int)) { q.fst != product-id })
  f(picks = if n <= 0 then rest else Cons((product-id, n), rest))

// Adding or editing a saved expense template.
pub struct recurring-form
  editing : int
  name    : string
  amount  : string
  error   : string
  // Delete is two-stage: the button arms itself before it fires, so a
  // mis-click cannot remove a template the owner typed months ago.
  confirm : bool

pub fun blank-recurring() : recurring-form
  Recurring-form(0, "", "", "", False)

pub fun recurring-form-of( t : models/recurring-expense ) : recurring-form
  Recurring-form(t.id, t.name, show-amount(t.amount), "", False)

// Adding or editing an expense. `editing` of 0 means a new one.
pub struct expense-form
  editing : int
  name    : string
  amount  : string
  date    : string
  note    : string
  error   : string
  confirm : bool

pub fun blank-expense( today : string ) : expense-form
  Expense-form(0, "", "", today, "", "", False)

// The licence key, while it is being entered.
pub struct licence-form
  key   : string
  error : string

pub fun blank-licence() : licence-form
  Licence-form("", "")

pub fun expense-form-of( e : models/expense ) : expense-form
  Expense-form(e.id, e.name, show-amount(e.amount), e.date, e.note.default(""), "", False)

fun show-amount( v : float64 ) : string
  val r = v.round
  if r == v then r.int.show else v.show

// --- the payments book ---------------------------------------------------
//
// A year of one member's dues, twelve months at a time.
//
// The unit here is the **month**, not the payment. A month is settled by money
// (an amount), or by being marked paid ahead (a zero-amount payment on file),
// or not at all. The payment row hanging off a month is an implementation
// detail -- which is why this has no Delete button: clearing a month's amount
// *is* the delete, and typing in an empty one is the insert.
//
// Paid ahead exists because a member who hands over six months of cash at once
// should not have that money split across six months it did not arrive in.
// Every figure in this app counts settled *months* (`COUNT(DISTINCT
// period_month)`) and sums *amounts* separately, so a zero-amount month
// settles arrears without inventing income.
pub struct month-entry
  month    : string      // YYYY-MM
  label    : string      // "January"
  amount   : string      // as typed
  covered  : bool        // settled without money
  original : int         // the payment already on file, or 0
  was      : float64     // its amount, to tell a real edit from a redraw

pub struct payments-book
  member-id : int
  who       : string
  year      : int
  min-year  : int
  max-year  : int
  entries   : list<month-entry>
  error     : string
  // The amounts as they stood at the last save. "Saved" shows only while the
  // current ones still match, so the confirmation cannot outlive an edit.
  saved     : string

// The joining fee is not a month and is deliberately absent: a registration
// payment cannot be created, changed or deleted from this dialog at all.
// AtMostOneJoiningFee holds here by construction rather than by a guard.
pub fun entries-for( year : int, payments : list<models/payment> ) : list<month-entry>
  list(1, 12).map fn(m)
    val month = dates/fmt-month(year, m)
    val mine = payments.filter fn(p : models/payment)
      p.category != models/cat-registration && p.period-month == month
    val pid = mine.map(fn(p : models/payment) { models/payment/id(p) }).head.default(0)
    val amt = mine.map(fn(p : models/payment) { p.amount }).head.default(0.0)
    Month-entry(month, dates/month-name(m),
                (if pid != 0 && amt != 0.0 then show-amount(amt) else ""),
                pid != 0 && amt == 0.0, pid, amt)

pub fun book-of( m : models/member, payments : list<models/payment>,
                 now-month : string ) : payments-book
  val cur = year-in(now-month, 2026)
  val joined = year-in(m.join-month, cur)
  // Every year the member has existed for, plus next year so dues can be taken
  // in advance. Widened by any stray payment, so one recorded outside that
  // range is reachable rather than invisible.
  val lo = payments.foldl(int/min(joined, cur)) fn(a, p : models/payment)
    int/min(a, year-in(p.period-month, a))
  val hi = payments.foldl(cur + 1) fn(a, p : models/payment)
    int/max(a, year-in(p.period-month, a))
  Payments-book(m.id, m.name, cur, lo, hi, entries-for(cur, payments), "", "")

fun year-in( ym : string, fallback : int ) : int
  match dates/parse-month(ym.list.take(7).string)
    Just((y, _)) -> y
    Nothing -> fallback

pub fun blank-book() : payments-book
  Payments-book(0, "", 2026, 2026, 2026, [], "", "")

pub fun book-snapshot( es : list<month-entry> ) : string
  es.map(fn(e : month-entry) { e.amount.trim ++ (if e.covered then "*" else "") }).join("|")

// Recording a payment against a member.
pub struct payment-form
  // the payment being corrected, or 0 when recording a new one
  editing   : int
  member-id : int
  who       : string
  month     : string
  amount    : string
  // Carried, never edited. The joining fee is a one-time charge guarded by
  // `ensure-registration-payment`; letting this dialog change a category
  // would be a second door into a registration payment -- AtMostOneJoiningFee.
  category  : string
  error     : string
  confirm   : bool

pub fun blank-payment() : payment-form
  Payment-form(0, 0, "", "", "", models/cat-membership, "", False)

pub fun payment-form-of( p : models/payment, who : string ) : payment-form
  Payment-form(p.id, p.member-id, who, p.period-month, show-amount(p.amount),
               p.category, "", False)

pub struct state
  view      : view
  palette   : theme/palette
  gym-name  : string
  currency  : string
  db-label  : string
  // Members view
  search    : string
  active-only : bool
  scroll    : int
  // the member whose detail card is open, or 0
  selected  : int
  form      : maybe<member-form>
  paying    : maybe<payment-form>
  expense   : maybe<expense-form>
  recurring : maybe<recurring-form>
  book      : maybe<payments-book>
  product   : maybe<product-form>
  sale      : maybe<sale-form>
  licence   : maybe<licence-form>
  confirm-delete : int
  // a one-line result of the last action, shown under the heading
  notice    : string
  // Expenses: the ledger, or the saved templates behind it. The templates are
  // only editable from their own tab, so without it they can be used but never
  // corrected or removed.
  expense-recurring : bool
  // Members: which slice of the roster is listed -- 0 everyone, 1 those who
  // owe, 2 those paid up for the month. The Dashboard's "Members due" figure
  // drills through to slice 1, so the number on the hero and the list behind
  // it are always the same set. One field rather than a flag per slice,
  // because two flags can both be on and that state means nothing.
  member-slice : int
  // Shop: products or sales. A mis-rung sale can only be corrected from the
  // sales list, so this is not a nicety.
  shop-sales  : bool
  // the period the Dashboard and the ledger views are looking at
  filter    : dates/month-filter
  // Settings fields are edited here, not read back from the database every
  // frame. Reading them back means deleting the last digit reverts the field
  // under the cursor, and the user can never clear it to retype.
  fee-draft   : string
  jfee-draft  : string
  // recomputed each frame from the database; kept here only so the frame
  // that opened a dialog and the frame that drew it agree
  month     : string
  // Who the copy is licensed to, or "" for an unlicensed one. Verified once
  // at startup and again after an activation: the signature check is cheap,
  // but not cheap enough to run on every frame, and nothing about it can
  // change while the app is open.
  licensee  : string

pub fun new-state( p : theme/palette, gym : string, cur : string,
                   db : string, month : string, fee : string, jfee : string ) : state
  State(Members, p, gym, cur, db, "", True, 0, 0, Nothing, Nothing, Nothing,
        Nothing, Nothing, Nothing, Nothing, Nothing, 0, "", False, 0, False,
        current-filter-of(month), fee, jfee, month, "")

// Is any dialog open? Everything behind one must be inert.
pub fun modal-open( s : state ) : bool
  s.form.is-just || s.paying.is-just || s.expense.is-just ||
  s.product.is-just || s.sale.is-just || s.recurring.is-just ||
  s.book.is-just || s.licence.is-just || s.confirm-delete != 0 || s.selected != 0

pub fun close-dialogs( s : state ) : state
  s(form = Nothing, paying = Nothing, expense = Nothing, product = Nothing,
    sale = Nothing, recurring = Nothing, book = Nothing, licence = Nothing,
    confirm-delete = 0, selected = 0)

// --- chrome -------------------------------------------------------------

pub val sidebar-w = 210

// The left rail. Returns the view the user asked for.
pub fun sidebar( r : ref<global,ui/ui>, s : state ) : io view
  val p = s.palette
  val h = win32/height()
  win32/fill(0, 0, sidebar-w, h, p.sidebar)
  win32/fill(sidebar-w, 0, 1, h, p.border)

  widgets/label((!r).font-semi, 16, 18, "TenneCRM", p.text)
  widgets/label-clipped((!r).font-small, 16, 38, sidebar-w - 32, s.gym-name, p.text-muted)

  var chosen := s.view
  all-views.foreach-indexed fn(i, v)
    val b = Rect(0, 74 + i * 34, sidebar-w, 32)
    if widgets/nav-item(r, p, b, view-label(v), same-view(v, s.view), ui/wid-at("nav", i)) then
      chosen := v
  // The licensee, on screen wherever the app is. A key cannot be stopped from
  // being passed around -- offline activation has nothing to count seats
  // against -- so it is signed into the key and shown instead: a shared copy
  // spends all day with somebody else's name on it.
  if s.licensee != "" then
    widgets/label-clipped((!r).font-small, 16, h - 48, sidebar-w - 32,
                          "Licensed to " ++ s.licensee, p.text-muted)
  widgets/label-clipped((!r).font-small, 16, h - 28, sidebar-w - 32, s.db-label, p.text-muted)
  chosen

// The heading strip every view shares.
pub fun page-title( r : ref<global,ui/ui>, s : state, title : string ) : io ()
  widgets/label((!r).font-semi, sidebar-w + 30, 22, title, s.palette.text)

pub fun content-rect() : io rect
  // Clamped: a negative width draws nothing and reads as a blank application
  // rather than as a window that is too small.
  Rect(sidebar-w + 30, 60,
       int/max(80, win32/width() - sidebar-w - 60),
       int/max(80, win32/height() - 90))

// A sale being edited, with its current lines loaded as quantities.
pub fun sale-form-of( id : int, date : string, picks : list<(int, int)> ) : sale-form
  Sale-form(id, date, picks, "", False)
