// One dialog at a time, drawn last so it paints over the view. The order is
// the order they stack: a confirmation sits above the card that raised it.
//
// This lives in its own module because main.kk and soak.kk both need it, and
// two copies meant the soak could silently stop covering a dialog -- which is
// how the Shop's sales list went unexercised for an iteration.
module dialogs

import ui
import app
import dlg-members
import dlg-payments
import dlg-shop
import dlg-license

pub fun show( r : ref<global,ui/ui>, s : app/state ) : io app/state
  // Each arm consumes `s`, so this is if/elif rather than nested matches --
  // see the double-drop note in the Gotchas.
  if s.confirm-delete != 0 then dlg-members/confirm-delete(r, s, s.confirm-delete)
  elif s.form.is-just then dlg-members/member-dialog(r, s, s.form.default(app/blank-form("", "", "")))
  elif s.paying.is-just then dlg-members/payment-dialog(r, s, s.paying.default(app/blank-payment()))
  elif s.book.is-just then dlg-payments/dialog(r, s, s.book.default(app/blank-book()))
  elif s.expense.is-just then dlg-members/expense-dialog(r, s, s.expense.default(app/blank-expense("")))
  elif s.recurring.is-just then dlg-members/recurring-dialog(r, s, s.recurring.default(app/blank-recurring()))
  elif s.product.is-just then dlg-shop/product-dialog(r, s, s.product.default(app/blank-product()))
  elif s.sale.is-just then dlg-shop/sale-dialog(r, s, s.sale.default(app/blank-sale("")))
  elif s.licence.is-just then dlg-license/dialog(r, s, s.licence.default(app/blank-licence()))
  elif s.selected != 0 then dlg-members/member-card(r, s, s.selected)
  else s
