// The Members dialogs: add/edit, record a payment, the member card, and the
// delete confirmation.
//
// Every write to the database happens in this file, and each one goes through
// the repository function that carries the invariant -- `create-member` for a
// new member (one transaction: the row, the mandatory joining fee, optionally
// the first month), `ensure-registration-payment` for collecting a joining fee
// later. Nothing here writes a `registration` payment by hand, because
// AtMostOneJoiningFee depends on every door going through that guard.
module dlg-members

import std/num/float64
import win32
import ui
import theme
import widgets
import models
import repo
import repo2
import sql
import dates
import util
import license
import app

// --- add / edit ---------------------------------------------------------

pub fun member-dialog( r : ref<global,ui/ui>, s : app/state,
                       f : app/member-form ) : io app/state
  val p = s.palette
  val adding = f.editing == 0
  val dlg-h = if adding then 470 else 370
  val box = widgets/modal-frame(r, p, 460, dlg-h,
                                if adding then "Add member" else "Edit member")

  var g := f
  val r0 = widgets/field-row(r, p, box, 0, "Member name")
  g := g(name = widgets/text-field(r, p, r0, f.name, ui/wid("f:name"), "Full name"))
  val r1 = widgets/field-row(r, p, box, 1, "Phone")
  g := g(phone = widgets/text-field(r, p, r1, f.phone, ui/wid("f:phone"), "Optional"))
  val r2 = widgets/field-row(r, p, box, 2, "Address")
  g := g(address = widgets/text-field(r, p, r2, f.address, ui/wid("f:addr"), "Optional"))
  val r3 = widgets/field-row(r, p, box, 3, "Joined on")
  g := g(join-date = widgets/text-field(r, p, Rect(r3.x, r3.y, 160, r3.h), f.join-date,
                                        ui/wid("f:date"), "YYYY-MM-DD"))
  if widgets/button(r, p, Rect(r3.x + 170, r3.y, 70, 30), "Today", ui/wid("f:today")) then
    g := g(join-date = dates/today())

  if adding then
    val r4 = widgets/field-row(r, p, box, 4, "Joining fee")
    g := g(joining-fee = widgets/text-field(r, p, Rect(r4.x, r4.y, 160, r4.h), f.joining-fee,
                                            ui/wid("f:join-fee"), "0"))
    val month = f.join-date.list.take(7).string
    val r5 = widgets/field-row(r, p, box, 5,
                               dates/pretty-month(month) ++ " fee (leave blank to skip)")
    g := g(month-fee = widgets/text-field(r, p, Rect(r5.x, r5.y, 160, r5.h), f.month-fee,
                                          ui/wid("f:month-fee"), "0"))

  // --- validation, and the sentence that explains a disabled Save
  val name-ok = g.name.trim != ""
  val date-ok = dates/is-valid-date(g.join-date)
  val joining = util/parse-money(g.joining-fee)
  val month-blank = g.month-fee.trim == ""
  val monthly = util/parse-money(g.month-fee)
  val fees-ok = !adding || (joining.is-just && (month-blank || monthly.is-just))
  // The licence gate. It refuses here, with Save disabled and the reason on
  // screen, rather than after the form is filled in -- and it refuses only
  // new members: an existing roster stays editable however big it is.
  val capped = adding && !license/can-add-member(s.licensee != "")
  val valid = name-ok && date-ok && fees-ok && !capped

  val why = if capped then license/member-cap-notice()
            elif !name-ok then "A name is required"
            elif !date-ok then "Joined on must be a real date, YYYY-MM-DD"
            elif !fees-ok then "Fees must be numbers"
            else ""
  val msg-y = box.y + box.h - 84
  if why != "" then
    widgets/label((!r).font-small, box.x + 20, msg-y, why, theme/warning)
  elif adding then
    // What the member is handing over today, added up, so the number the
    // owner takes at the desk is on screen before they commit.
    val collecting = joining.default(0.0) + (if month-blank then 0.0 else monthly.default(0.0))
    widgets/label((!r).font-body, box.x + 20, msg-y,
                  "Collecting " ++ models/money(s.currency, collecting) ++ " today", p.text)
  if f.error != "" then
    widgets/label((!r).font-small, box.x + 20, msg-y + 18, f.error, theme/negative)

  val (save, cancel) = widgets/modal-buttons(r, p, box, "Save", "f", valid)
  if cancel || ui/escape-pressed(r) then s(form = Nothing)
  elif !save then s(form = Just(g))
  else
    if adding then
      // A blank or zero first month means "not collecting one today", not a
      // zero-rupee payment on the ledger.
      val first = if month-blank then Nothing else
        match monthly
          Just(v) -> if v > 0.0 then Just(v) else Nothing
          Nothing -> Nothing
      val id = repo/create-member(g.to-member(), joining.default(0.0), first,
                                  g.join-date.list.take(7).string, dates/today())
      if id == 0 then s(form = Just(g(error = "Could not save: " ++ sql/error())))
      else s(form = Nothing, notice = g.name.trim ++ " added")
    else
      if !repo/update-member(g.to-member())
        then s(form = Just(g(error = "Could not save: " ++ sql/error())))
        else s(form = Nothing, notice = g.name.trim ++ " updated")

// --- record a payment ---------------------------------------------------

pub fun payment-dialog( r : ref<global,ui/ui>, s : app/state,
                        f : app/payment-form ) : io app/state
  val p = s.palette
  // every field read once, up front -- see the Gotchas
  val editing = f.editing
  val armed = f.confirm
  val who = f.who
  val member-id = f.member-id
  val adding = editing == 0
  val box = widgets/modal-frame(r, p, 430, 330,
                                if adding then "Record payment" else "Edit payment")
  widgets/label((!r).font-body, box.x + 20, box.y + 62, who, p.text)

  var g := f
  val r1 = widgets/field-row(r, p, box, 1, "For which month")
  g := g(month = widgets/text-field(r, p, Rect(r1.x, r1.y, 160, r1.h), f.month,
                                    ui/wid("p:month"), "YYYY-MM"))
  widgets/label((!r).font-small, r1.x + 172, r1.y + 8, dates/pretty-month(g.month), p.text-muted)

  val r2 = widgets/field-row(r, p, box, 2, "Amount")
  g := g(amount = widgets/text-field(r, p, Rect(r2.x, r2.y, 160, r2.h), f.amount,
                                     ui/wid("p:amount"), "0"))

  val month-ok = dates/is-valid-month(g.month)
  val amount = util/parse-money(g.amount)
  val valid = month-ok && amount.is-just
  // only meaningful when adding: a payment being corrected is itself the
  // reason its own month reads as settled
  val already = if !month-ok || !adding then False else repo/is-paid(member-id, g.month)

  val msg-y = box.y + box.h - 84
  if !month-ok then
    widgets/label((!r).font-small, box.x + 20, msg-y, "Month must be YYYY-MM", theme/warning)
  elif amount.is-nothing then
    widgets/label((!r).font-small, box.x + 20, msg-y, "Amount must be a number", theme/warning)
  elif already then
    // Not blocked: a member may pay twice in a month. But the dashboard
    // counts DISTINCT months, so say plainly that this will not settle a
    // second one.
    widgets/label((!r).font-small, box.x + 20, msg-y,
                  dates/pretty-month(g.month) ++ " is already settled - this adds to it",
                  theme/warning)
  if f.error != "" then
    widgets/label((!r).font-small, box.x + 20, msg-y + 18, f.error, theme/negative)

  // A payment entered against the wrong month, or for the wrong amount, moves
  // the member's arrears and every ledger total until it is corrected here.
  val hit-delete = if adding then False
                   else widgets/button-danger(r, p, Rect(box.x + 20, box.y + box.h - 42, 130, 32),
                                              (if armed then "Really delete?" else "Delete"),
                                              ui/wid("p:del"))
  val (save, cancel) = widgets/modal-buttons(r, p, box,
                                             (if adding then "Record" else "Save"), "p", valid)
  if cancel || ui/escape-pressed(r) then s(paying = Nothing)
  elif hit-delete then
    if !armed then s(paying = Just(g(confirm = True)))
    elif repo/delete-payment(editing)
      then s(paying = Nothing, notice = "Payment deleted for " ++ who)
      else s(paying = Just(g(error = "Could not delete: " ++ sql/error())))
  elif !save then s(paying = Just(g))
  elif adding then
    val id = repo/insert-payment(Payment(0, member-id, g.month, amount.default(0.0),
                                         dates/today(), Nothing, models/cat-membership))
    if id == 0 then s(paying = Just(g(error = "Could not record: " ++ sql/error())))
    else s(paying = Nothing,
           notice = models/money(s.currency, amount.default(0.0)) ++ " recorded for " ++ who)
  else
    // g.category is carried from the payment being edited, never from the UI:
    // a membership payment cannot be turned into a second joining fee here.
    val ok = match repo/get-payment(editing)
      Nothing -> False
      Just(old) -> repo/update-payment(Payment(editing, member-id, g.month,
                                               amount.default(0.0), old.date, old.note,
                                               g.category))
    if !ok then s(paying = Just(g(error = "Could not save: " ++ sql/error())))
    else s(paying = Nothing,
           notice = "Payment updated for " ++ who)

// --- the member card ----------------------------------------------------

pub fun member-card( r : ref<global,ui/ui>, s : app/state, who : int ) : io app/state
  match repo/get-member(who)
    Nothing -> s(selected = 0)
    Just(m) -> card(r, s, m)

fun card( r : ref<global,ui/ui>, s : app/state, m : models/member ) : io app/state
  val p = s.palette
  val box = widgets/modal-frame(r, p, 520, 520, m.name)
  val f = (!r).font-body
  val small = (!r).font-small

  val (behind, owed) = repo/membership-arrears(m.id, m.join-month, s.month)
  detail-line(r, p, box, 0, "Phone", m.phone.default("-"))
  detail-line(r, p, box, 1, "Address", m.address.default("-"))
  detail-line(r, p, box, 2, "Joined", m.join-date)
  detail-line(r, p, box, 3, "Status", if m.active then "Active" else "Inactive")
  detail-line(r, p, box, 4, "Arrears",
              if behind == 0 then "Up to date"
              else models/money(s.currency, owed) ++ "  (" ++ behind.show ++
                   (if behind == 1 then " month)" else " months)"))
  match m.notes
    Just(n) -> detail-line(r, p, box, 5, "Notes", n)
    Nothing -> ()

  // payment history. Each row opens for correction: a payment against the
  // wrong month moves the member's arrears and the ledger totals, and this is
  // the only way to reach update-payment or delete-payment.
  widgets/label(small, box.x + 20, box.y + 258, "PAYMENT HISTORY", p.text-muted)
  widgets/separator(p, box.x + 20, box.y + 276, box.w - 40)
  val history = repo/payments-for-member(m.id)
  val picked = ref(0)
  if history.is-nil then
    widgets/label(small, box.x + 20, box.y + 288, "Nothing recorded yet", p.text-muted)
  else
    val hist-box = Rect(box.x + 20, box.y + 284, box.w - 40, 130)
    win32/clip(hist-box.x, hist-box.y, hist-box.w, hist-box.h)
    history.foreach-indexed fn(i, pay : models/payment)
      val ry = hist-box.y + i * 24
      if ry > hist-box.y + hist-box.h then () else
        val row = Rect(hist-box.x, ry - 3, hist-box.w, 24)
        val act = ui/behavior(r, ui/wid-at("c:pmt", i), row)
        if act.hovered then
          win32/round-fill(row.x, row.y, row.w, row.h, widgets/radius, p.btn-hover)
        if act.clicked then picked := models/payment/id(pay)
        widgets/label(small, hist-box.x, ry, dates/pretty-month(pay.period-month), p.text)
        widgets/label(small, hist-box.x + 130, ry, models/category-label(pay.category), p.text-muted)
        widgets/label-right(small, hist-box.x + hist-box.w, ry,
                            models/money(s.currency, pay.amount), p.text)
    win32/clip-all()

  // actions
  val ay = box.y + box.h - 52
  var next := s
  val hit = !picked
  if hit != 0 then
    match repo/get-payment(hit)
      Just(pay) -> next := next(selected = 0, paying = Just(app/payment-form-of(pay, m.name)))
      Nothing -> ()
  // A year at a time, not a payment at a time: dues are a twelve-month book,
  // and recording them one modal per month is how the owner ends up with
  // months entered against the wrong period. See `dlg-payments.kk`.
  if widgets/button(r, p, Rect(box.x + 20, ay + 10, 140, 32), "Payments",
                    ui/wid("c:pay")) then
    next := next(selected = 0,
                 book = Just(app/book-of(m, repo/payments-for-member(m.id), s.month)))
  if widgets/button(r, p, Rect(box.x + 168, ay + 10, 70, 32), "Edit", ui/wid("c:edit")) then
    next := next(selected = 0, form = Just(app/form-of(m)))
  if widgets/button-danger(r, p, Rect(box.x + 246, ay + 10, 80, 32), "Delete",
                           ui/wid("c:del")) then
    next := next(selected = 0, confirm-delete = m.id)
  if widgets/button(r, p, Rect(box.x + box.w - 100, ay + 10, 80, 32), "Close",
                    ui/wid("c:close")) || ui/escape-pressed(r) then
    next := next(selected = 0)
  next

fun detail-line( r : ref<global,ui/ui>, p : theme/palette, box : rect,
                 n : int, caption : string, value : string ) : io ()
  val y = box.y + 66 + n * 32
  widgets/label((!r).font-small, box.x + 20, y + 3, caption, p.text-muted)
  widgets/label-clipped((!r).font-body, box.x + 120, y, box.w - 140, value, p.text)

// --- delete confirmation ------------------------------------------------

pub fun confirm-delete( r : ref<global,ui/ui>, s : app/state, who : int ) : io app/state
  match repo/get-member(who)
    Nothing -> s(confirm-delete = 0)
    Just(m) ->
      val p = s.palette
      val box = widgets/modal-frame(r, p, 440, 250, "Delete member")
      val n = repo/payments-for-member(m.id).length
      widgets/label((!r).font-body, box.x + 20, box.y + 70,
                    "Delete " ++ m.name ++ "?", p.text)
      // Say what else goes, because payments cascade and the ledger totals
      // will change. NoOrphanPayments is why this is not optional.
      widgets/label((!r).font-small, box.x + 20, box.y + 98,
                    (if n == 0 then "They have no payments on record."
                     else "Their " ++ n.show ++
                          (if n == 1 then " payment" else " payments") ++
                          " will be deleted too, and the ledger totals will change."),
                    p.text-muted)
      widgets/label((!r).font-small, box.x + 20, box.y + 122,
                    "This cannot be undone.", p.text-muted)
      widgets/label((!r).font-small, box.x + 20, box.y + 150,
                    "To keep their history, set them inactive instead.", p.text-muted)

      val ay = box.y + box.h - 52
      widgets/separator(p, box.x + 1, ay - 1, box.w - 2)
      var next := s
      if widgets/button(r, p, Rect(box.x + 20, ay + 10, 130, 32), "Set inactive",
                        ui/wid("d:deact")) then
        repo/set-member-active(m.id, False).ignore
        next := next(confirm-delete = 0, notice = m.name ++ " set inactive")
      if widgets/button(r, p, Rect(box.x + box.w - 210, ay + 10, 90, 32), "Cancel",
                        ui/wid("d:cancel")) || ui/escape-pressed(r) then
        next := next(confirm-delete = 0)
      if widgets/button-danger(r, p, Rect(box.x + box.w - 110, ay + 10, 90, 32), "Delete",
                               ui/wid("d:ok")) then
        repo/delete-member(m.id).ignore
        next := next(confirm-delete = 0, notice = m.name ++ " deleted")
      next

// --- expense ------------------------------------------------------------

// A saved monthly bill: rent, salaries, power. Only two fields, but without
// this dialog the templates can be used as prefill and never corrected or
// removed -- insert/update/delete-recurring-expense were unreachable from the
// UI until it existed.
pub fun recurring-dialog( r : ref<global,ui/ui>, s : app/state,
                          f : app/recurring-form ) : io app/state
  val p = s.palette
  // every field read once, up front: repeated reads of the same field have
  // corrupted the heap in Koka 3.2.3. See the Gotchas.
  val editing = f.editing
  val armed = f.confirm
  val err = f.error
  val adding = editing == 0
  val box = widgets/modal-frame(r, p, 430, 280,
                                if adding then "Add monthly bill" else "Edit monthly bill")
  var g := f
  val r0 = widgets/field-row(r, p, box, 0, "What is it for")
  g := g(name = widgets/text-field(r, p, r0, f.name, ui/wid("rc:name"), "Rent, salary, ..."))
  val r1 = widgets/field-row(r, p, box, 1, "Amount every month")
  g := g(amount = widgets/text-field(r, p, Rect(r1.x, r1.y, 160, r1.h), f.amount,
                                     ui/wid("rc:amt"), "0"))

  val name-ok = g.name.trim != ""
  val amount = util/parse-money(g.amount)
  val valid = name-ok && amount.is-just
  val why = if !name-ok then "Say what the bill is for"
            elif amount.is-nothing then "Amount must be a number"
            else ""
  val msg-y = box.y + box.h - 84
  if why != "" then widgets/label((!r).font-small, box.x + 20, msg-y, why, theme/warning)
  if err != "" then
    widgets/label((!r).font-small, box.x + 20, msg-y + 18, err, theme/negative)

  // Deleting a template keeps the expenses already logged from it, so this is
  // a smaller decision than deleting a member -- one armed click, no separate
  // confirmation dialog.
  val hit-delete = if adding then False
                   else widgets/button-danger(r, p, Rect(box.x + 20, box.y + box.h - 42, 130, 32),
                                              (if armed then "Really delete?" else "Delete"),
                                              ui/wid("rc:del"))
  val (save, cancel) = widgets/modal-buttons(r, p, box, "Save", "rc", valid)
  if cancel || ui/escape-pressed(r) then s(recurring = Nothing)
  elif hit-delete then
    if !armed then s(recurring = Just(g(confirm = True)))
    elif repo2/delete-recurring-expense(editing)
      then s(recurring = Nothing, notice = g.name.trim ++ " removed")
      else s(recurring = Just(g(error = "Could not delete: " ++ sql/error())))
  elif !save then s(recurring = Just(g))
  else
    val t = Recurring-expense(editing, g.name.trim, amount.default(0.0))
    val ok = if adding then repo2/insert-recurring-expense(t) > 0
             else repo2/update-recurring-expense(t)
    if !ok then s(recurring = Just(g(error = "Could not save: " ++ sql/error())))
    else s(recurring = Nothing,
           notice = g.name.trim ++ (if adding then " saved" else " updated"))

pub fun expense-dialog( r : ref<global,ui/ui>, s : app/state,
                        f : app/expense-form ) : io app/state
  val p = s.palette
  // every field read once, up front -- see the Gotchas
  val editing = f.editing
  val armed = f.confirm
  val adding = editing == 0
  val box = widgets/modal-frame(r, p, 430, 360,
                                if adding then "Add expense" else "Edit expense")
  var g := f
  val r0 = widgets/field-row(r, p, box, 0, "What was it for")
  g := g(name = widgets/text-field(r, p, r0, f.name, ui/wid("e:name"), "Rent, salary, ..."))
  val r1 = widgets/field-row(r, p, box, 1, "Amount")
  g := g(amount = widgets/text-field(r, p, Rect(r1.x, r1.y, 160, r1.h), f.amount,
                                     ui/wid("e:amt"), "0"))
  val r2 = widgets/field-row(r, p, box, 2, "Date")
  g := g(date = widgets/text-field(r, p, Rect(r2.x, r2.y, 160, r2.h), f.date,
                                   ui/wid("e:date"), "YYYY-MM-DD"))
  if widgets/button(r, p, Rect(r2.x + 170, r2.y, 70, 30), "Today", ui/wid("e:today")) then
    g := g(date = dates/today())
  val r3 = widgets/field-row(r, p, box, 3, "Note")
  g := g(note = widgets/text-field(r, p, r3, f.note, ui/wid("e:note"), "Optional"))

  val name-ok = g.name.trim != ""
  val amount = util/parse-money(g.amount)
  val date-ok = dates/is-valid-date(g.date)
  val valid = name-ok && amount.is-just && date-ok
  val why = if !name-ok then "Say what the money was for"
            elif amount.is-nothing then "Amount must be a number"
            elif !date-ok then "Date must be YYYY-MM-DD"
            else ""
  val msg-y = box.y + box.h - 84
  if why != "" then widgets/label((!r).font-small, box.x + 20, msg-y, why, theme/warning)
  if f.error != "" then
    widgets/label((!r).font-small, box.x + 20, msg-y + 18, f.error, theme/negative)

  // An expense typed twice, or typed against the wrong month, can only be
  // taken off the books here: every total in the app is a sum over this table.
  val hit-delete = if adding then False
                   else widgets/button-danger(r, p, Rect(box.x + 20, box.y + box.h - 42, 130, 32),
                                              (if armed then "Really delete?" else "Delete"),
                                              ui/wid("e:del"))
  val (save, cancel) = widgets/modal-buttons(r, p, box, "Save", "e", valid)
  if cancel || ui/escape-pressed(r) then s(expense = Nothing)
  elif hit-delete then
    if !armed then s(expense = Just(g(confirm = True)))
    elif repo2/delete-expense(editing)
      then s(expense = Nothing, notice = g.name.trim ++ " deleted")
      else s(expense = Just(g(error = "Could not delete: " ++ sql/error())))
  elif !save then s(expense = Just(g))
  else
    val e = Expense(editing, g.name.trim, amount.default(0.0), g.date.trim,
                    if g.note.trim == "" then Nothing else Just(g.note.trim))
    val ok = if adding then repo2/insert-expense(e) > 0 else repo2/update-expense(e)
    if !ok then s(expense = Just(g(error = "Could not save: " ++ sql/error())))
    else s(expense = Nothing,
           notice = models/money(s.currency, amount.default(0.0)) ++ " - " ++ g.name.trim ++
                    (if adding then " added" else " updated"))
