// The Members dialogs, driven the way a person drives them -- clicks and
// keystrokes -- with the database checked afterwards.
//
// This is the level at which AtMostOneJoiningFee actually has to hold. The
// repository guards it; these cases prove the UI cannot route around the
// guard, which is exactly how the Rust build's CSV importer charged the fee
// twice.
module dlgtest

import std/num/float64
import win32
import sql
import db
import ui
import theme
import widgets
import models
import repo
import dates
import util
import app
import license
import dlg-members
import dlg-payments

fun check( f : ref<global,int>, name : string, got : string, want : string ) : io ()
  val ok = got == want
  if !ok then f := !f + 1
  println((if ok then "  ok   " else "  FAIL ") ++ name.pad-right(50) ++ got.pad-right(14) ++
          (if ok then "" else "want " ++ want))

fun click( x : int, y : int ) : list<win32/event>
  [win32/Event(win32/ev-mouse-down, x, y, 0), win32/Event(win32/ev-mouse-up, x, y, 0)]

fun typing( s : string ) : list<win32/event>
  s.list.map(fn(c) { win32/Event(win32/ev-char, 0, 0, c.int) })

// One frame of the real dialog stack, exactly as main.kk runs it.
fun frame( r : ref<global,ui/ui>, s : app/state, evs : list<win32/event> ) : io app/state
  ui/frame-begin(r, evs)
  win32/clip-all()
  win32/fill(0, 0, win32/width(), win32/height(), s.palette.main)
  val next = dialogs(r, s)
  ui/frame-end(r)
  next

fun dialogs( r : ref<global,ui/ui>, s : app/state ) : io app/state
  if s.confirm-delete != 0 then dlg-members/confirm-delete(r, s, s.confirm-delete)
  elif s.book.is-just then dlg-payments/dialog(r, s, s.book.default(app/blank-book()))
  else match s.form
    Just(f) -> dlg-members/member-dialog(r, s, f)
    Nothing -> match s.paying
      Just(f) -> dlg-members/payment-dialog(r, s, f)
      Nothing -> if s.selected != 0 then dlg-members/member-card(r, s, s.selected) else s

// The dialog is centred in a 1180x720 surface; these are the widget centres.
val screen-w = 1180
val dlg-w = 460
val dlg-x = (screen-w - dlg-w) / 2
fun field-y( n : int, dlg-h : int ) : int
  (720 - dlg-h) / 2 + 68 + n * 52 + 18 + 15

// Clicking a field now places the caret where the click landed, so a test that
// wants to append has to click PAST the end of the text, as a person would.
// Full-width rows run to the dialog edge; the date and fee rows are 160 wide
// with a button beside them, so clicking at the far right would miss entirely.
fun field-end( n : int, dlg-h : int ) : (int, int)
  (dlg-x + dlg-w - 40, field-y(n, dlg-h))

fun narrow-end( n : int, dlg-h : int ) : (int, int)
  (dlg-x + 20 + 150, field-y(n, dlg-h))
fun ok-btn( dlg-h : int ) : (int, int)
  (dlg-x + dlg-w - 110 + 45, (720 - dlg-h) / 2 + dlg-h - 52 + 10 + 16)

pub fun main() : io ()
  sql/unbuffer()
  val f = ref(0)
  val path = "out/dlg.db"
  if sql/file-exists(path) then sql/remove-file(path).ignore
  db/open-db(path).ignore

  win32/offscreen(1180, 720)
  win32/font-file("assets/fonts/Geist-Regular.ttf").ignore
  win32/font-file("assets/fonts/Geist-SemiBold.ttf").ignore
  val r = ref(ui/new-ui(win32/font("Geist", 14, 400), win32/font("Geist SemiBold", 15, 600), win32/font("Geist", 12, 400), win32/font("Geist SemiBold", 30, 600)))
  val s0 = app/new-state(theme/palette-of("dark"), "Bright Star Gym", "Rs", "out", "2025-08", "1500", "500")

  // ---- adding a member, by hand
  val add-h = 470
  var s := s0(form = Just(app/blank-form("2025-03-02", "500", "1500")))
  s := frame(r, s, [])                                    // draw it once
  // click past the end of the (empty) name box
  s := frame(r, s, click(field-end(0, add-h).fst, field-end(0, add-h).snd))
  s := frame(r, s, typing("Zonunsanga"))
  check(f, "typed name reached the form",
        s.form.map(fn(g : app/member-form) { g.name }).default(""), "Zonunsanga")

  // Save is refused while the date is nonsense, and says why.
  s := frame(r, s, click(narrow-end(3, add-h).fst, narrow-end(3, add-h).snd))
  s := frame(r, s, typing("oops"))
  val (ox, oy) = ok-btn(add-h)
  s := frame(r, s, click(ox, oy))
  check(f, "a bad date blocks Save", s.form.is-just.show, "True")
  check(f, "and nothing was written", repo/count-members(False).show, "0")

  // Fix it and save. Clicking the disabled Save cleared the focus (it hits no
  // widget), so click back into the date box before erasing.
  s := frame(r, s, click(narrow-end(3, add-h).fst, narrow-end(3, add-h).snd))
  s := frame(r, s, [win32/Event(win32/ev-key-down, 0, 0, win32/key-backspace),
                    win32/Event(win32/ev-key-down, 0, 0, win32/key-backspace),
                    win32/Event(win32/ev-key-down, 0, 0, win32/key-backspace),
                    win32/Event(win32/ev-key-down, 0, 0, win32/key-backspace)])
  // four backspaces remove "oops" and leave the date the form opened with
  s := frame(r, s, click(ox, oy))
  check(f, "the dialog closed on save", s.form.is-nothing.show, "True")
  check(f, "the member was created", repo/count-members(False).show, "1")

  val id = repo/list-members(False).map(fn(m : models/member) { models/member/id(m) })
             .head.default(0)
  check(f, "name stored", repo/get-member(id).map(fn(m : models/member) { m.name }).default(""),
        "Zonunsanga")
  check(f, "join date stored",
        repo/get-member(id).map(fn(m : models/member) { m.join-date }).default(""), "2025-03-02")

  // AtMostOneJoiningFee: the add dialog collected it, exactly once.
  check(f, "joining fee charged once",
        repo/payments-for-member(id).filter(fn(p : models/payment) { p.category == "registration" })
          .length.show, "1")
  check(f, "first month collected too",
        repo/is-paid(id, "2025-03").show, "True")
  check(f, "two payments in total", repo/payments-for-member(id).length.show, "2")
  check(f, "and they total Rs 2,000",
        models/money("Rs", repo/payments-for-member(id)
          .foldl(0.0, fn(a, p : models/payment) { a + p.amount })), "Rs 2,000")

  // ---- editing must never touch the ledger
  s := frame(r, s0(form = Just(app/form-of(repo/get-member(id).default(models/blank-member())))), [])
  val edit-h = 370
  s := frame(r, s, click(field-end(1, edit-h).fst, field-end(1, edit-h).snd))
  s := frame(r, s, typing("9436152200"))
  val (ex, ey) = ok-btn(edit-h)
  s := frame(r, s, click(ex, ey))
  check(f, "edit saved the phone",
        repo/get-member(id).map(fn(m : models/member) { m.phone.default("-") }).default("-"),
        "9436152200")
  check(f, "editing charged no second joining fee",
        repo/payments-for-member(id).filter(fn(p : models/payment) { p.category == "registration" })
          .length.show, "1")
  check(f, "and added no payments at all", repo/payments-for-member(id).length.show, "2")

  // ---- recording a payment
  s := s0(paying = Just(Payment-form(0, id, "Zonunsanga", "2025-04", "1500",
                                     models/cat-membership, "", False)))
  s := frame(r, s, [])
  val (px, py) = ok-btn(330)
  s := frame(r, s, click(px, py))
  check(f, "payment recorded", repo/is-paid(id, "2025-04").show, "True")
  check(f, "three payments now", repo/payments-for-member(id).length.show, "3")
  check(f, "still one joining fee",
        repo/payments-for-member(id).filter(fn(p : models/payment) { p.category == "registration" })
          .length.show, "1")

  // a nonsense month is refused
  s := s0(paying = Just(Payment-form(0, id, "Zonunsanga", "nope", "1500",
                                     models/cat-membership, "", False)))
  s := frame(r, s, [])
  s := frame(r, s, click(px, py))
  check(f, "a bad month blocks Record", s.paying.is-just.show, "True")
  check(f, "and recorded nothing", repo/payments-for-member(id).length.show, "3")

  // ---- deleting takes the ledger with it
  val before = sql/scalar-int("SELECT COUNT(*) FROM payments", [], -1)
  check(f, "payments on file before delete", before.show, "3")
  s := s0(confirm-delete = id)
  s := frame(r, s, [])
  val dh = 250
  s := frame(r, s, click(dlg-x + dlg-w - 110 + 45, (720 - dh) / 2 + dh - 52 + 26))
  check(f, "member deleted", repo/get-member(id).is-nothing.show, "True")
  check(f, "their payments cascaded",
        sql/scalar-int("SELECT COUNT(*) FROM payments", [], -1).show, "0")
  check(f, "no payment is orphaned",
        sql/scalar-int("SELECT COUNT(*) FROM payments p LEFT JOIN members m" ++
                       " ON m.id = p.member_id WHERE m.id IS NULL", [], -1).show, "0")

  // ---- Set inactive keeps the history, which is the point of offering it
  val id2 = repo/create-member(Member(0, "Lalrinpuia", Nothing, Nothing, "2025-01-05",
                                      True, Nothing), 500.0, Just(1500.0), "2025-01", "2025-01-05")
  s := s0(confirm-delete = id2)
  s := frame(r, s, [])
  s := frame(r, s, click(dlg-x + 20 + 65, (720 - dh) / 2 + dh - 52 + 26))
  check(f, "set inactive kept the member", repo/get-member(id2).is-just.show, "True")
  check(f, "and marked them inactive",
        repo/get-member(id2).map(fn(m : models/member) { m.active.show }).default("?"), "False")
  check(f, "and kept their payments", repo/payments-for-member(id2).length.show, "2")

  // ---- correcting a payment, which nothing could reach before
  //
  // A payment entered against the wrong month moves the member's arrears and
  // every ledger total. update-payment and delete-payment were implemented and
  // tested at the repository level from the start, and no click reached either.
  val card-x = (1180 - 520) / 2
  val card-y = (720 - 520) / 2
  val psave = (375 + 430 - 110 + 45, 195 + 330 - 26)
  val pdel = (375 + 20 + 65, 195 + 330 - 26)

  s := s0(selected = id2)
  s := frame(r, s, [])
  val top-payment = repo/payments-for-member(id2)
                      .map(fn(p : models/payment) { models/payment/id(p) }).head.default(0)
  s := frame(r, s, click(card-x + 200, card-y + 284 + 9))
  check(f, "a history row opens that payment",
        s.paying.map(fn(g : app/payment-form) { g.editing }).default(0).show, top-payment.show)

  val memb = repo/payments-for-member(id2)
               .filter(fn(p : models/payment) { p.category == models/cat-membership })
               .map(fn(p : models/payment) { models/payment/id(p) }).head.default(0)
  s := s0(paying = Just(Payment-form(memb, id2, "Lalrinpuia", "2025-02", "1200",
                                     models/cat-membership, "", False)))
  s := frame(r, s, [])
  s := frame(r, s, click(psave.fst, psave.snd))
  check(f, "the payment moved to February",
        repo/get-payment(memb).map(fn(p : models/payment) { p.period-month }).default("?"),
        "2025-02")
  check(f, "and the amount was corrected",
        repo/get-payment(memb).map(fn(p : models/payment) { models/money("Rs", p.amount) })
          .default("?"), "Rs 1,200")
  check(f, "correcting one adds none", repo/payments-for-member(id2).length.show, "2")

  // The joining fee stays a joining fee: the dialog carries the category it
  // was opened with and never offers to change it. AtMostOneJoiningFee.
  val reg = repo/payments-for-member(id2)
              .filter(fn(p : models/payment) { p.category == models/cat-registration })
              .map(fn(p : models/payment) { models/payment/id(p) }).head.default(0)
  s := s0(paying = Just(Payment-form(reg, id2, "Lalrinpuia", "2025-01", "1600",
                                     models/cat-registration, "", False)))
  s := frame(r, s, [])
  s := frame(r, s, click(psave.fst, psave.snd))
  check(f, "editing the joining fee keeps it one",
        repo/get-payment(reg).map(fn(p : models/payment) { p.category }).default("?"),
        "registration")
  check(f, "and there is still exactly one",
        repo/payments-for-member(id2)
          .filter(fn(p : models/payment) { p.category == models/cat-registration }).length.show,
        "1")

  // ---- and deleting one, two-stage
  s := s0(paying = Just(Payment-form(memb, id2, "Lalrinpuia", "2025-02", "1200",
                                     models/cat-membership, "", False)))
  s := frame(r, s, [])
  s := frame(r, s, click(pdel.fst, pdel.snd))
  check(f, "one click on Delete removes no payment",
        repo/payments-for-member(id2).length.show, "2")
  s := frame(r, s, click(pdel.fst, pdel.snd))
  check(f, "the second click deletes it", repo/payments-for-member(id2).length.show, "1")
  check(f, "and it was the membership payment that went",
        repo/get-payment(memb).is-nothing.show, "True")
  check(f, "the joining fee is still on record", repo/get-payment(reg).is-just.show, "True")

  // ---- the payments book: a year of dues, twelve months at a time
  //
  // The unit is the month, not the payment, so insert, update and delete all
  // come out of typing in (or clearing) a box. That is the whole point of it,
  // and each of the three is asserted below against the database.
  val bbox = Rect((1180 - dlg-payments/book-w) / 2, (720 - dlg-payments/book-h) / 2,
                  dlg-payments/book-w, dlg-payments/book-h)
  val bsave = (bbox.x + dlg-payments/book-w - 110 + 45, bbox.y + dlg-payments/book-h - 26)
  fun months() : io int
    repo/payments-for-member(id2).length
  fun fees() : io int
    repo/payments-for-member(id2)
      .filter(fn(p : models/payment) { p.category == models/cat-registration }).length

  // opened from the card, so the button that reaches it is covered too
  s := s0(selected = id2)
  s := frame(r, s, [])
  s := frame(r, s, click(330 + 90, 100 + 520 - 52 + 26))
  check(f, "the card opens the payments book", s.book.is-just.show, "True")
  check(f, "and the card closed behind it", s.selected.show, "0")
  check(f, "the joining fee is not one of the twelve months",
        s.book.map(fn(b : app/payments-book)
                     { b.entries.filter(fn(e : app/month-entry) { e.original != 0 }).length })
          .default(-1).show, "0")

  // --- typing an amount into a month inserts that month's payment
  val jan = dlg-payments/amount-at(bbox, 0)
  s := frame(r, s, click(jan.fst, jan.snd))
  s := frame(r, s, typing("1500"))
  check(f, "nothing is written until Save", months().show, "1")
  s := frame(r, s, click(bsave.fst, bsave.snd))
  check(f, "January now has a payment", repo/is-paid(id2, "2025-01").show, "True")
  check(f, "and it is a membership payment, not a fee", months().show, "2")
  check(f, "the joining fee is untouched", fees().show, "1")
  check(f, "the book stays open on the year just saved",
        s.book.map(fn(b : app/payments-book) { b.year }).default(0).show, "2025")

  // --- Paid ahead: a month settled without money, stored as a zero amount
  val feb = dlg-payments/status-at(bbox, 1)
  s := frame(r, s, click(feb.fst, feb.snd))
  check(f, "February is marked paid ahead",
        s.book.map(fn(b : app/payments-book)
                     { b.entries.filter(fn(e : app/month-entry) { e.covered }).length })
          .default(0).show, "1")
  s := frame(r, s, click(bsave.fst, bsave.snd))
  check(f, "February counts as settled", repo/is-paid(id2, "2025-02").show, "True")
  check(f, "with no money against it",
        sql/scalar-int("SELECT COUNT(*) FROM payments WHERE member_id = " ++ id2.show ++
                       " AND period_month = '2025-02' AND amount = 0", [], -1).show, "1")
  check(f, "so a member paid up front is not in arrears for it",
        repo/membership-arrears(id2, "2025-01", "2025-02").fst.show, "0")
  s := frame(r, s, [])
  win32/save-bmp("out/dlg-book-paid.bmp").ignore

  // --- clearing a month deletes its payment. There is no Delete button.
  s := frame(r, s, click(jan.fst, jan.snd))
  s := frame(r, s, [win32/Event(win32/ev-key-down, 0, 0, win32/key-backspace),
                    win32/Event(win32/ev-key-down, 0, 0, win32/key-backspace),
                    win32/Event(win32/ev-key-down, 0, 0, win32/key-backspace),
                    win32/Event(win32/ev-key-down, 0, 0, win32/key-backspace)])
  s := frame(r, s, click(bsave.fst, bsave.snd))
  check(f, "clearing January deleted its payment", repo/is-paid(id2, "2025-01").show, "False")
  check(f, "February is still settled", repo/is-paid(id2, "2025-02").show, "True")
  check(f, "and the joining fee survived all of it", fees().show, "1")

  // --- an unreadable amount blocks Save rather than deleting the month
  s := frame(r, s, click(feb.fst, feb.snd))          // February back to Due
  val mar = dlg-payments/amount-at(bbox, 2)
  s := frame(r, s, click(mar.fst, mar.snd))
  s := frame(r, s, typing("abc"))
  s := frame(r, s, [])
  // Paid, Due, Paid ahead and an unreadable one, all on screen at once
  win32/save-bmp("out/dlg-book.bmp").ignore
  s := frame(r, s, click(bsave.fst, bsave.snd))
  check(f, "a bad amount blocks Save", repo/is-paid(id2, "2025-03").show, "False")
  check(f, "and nothing else was committed with it", repo/is-paid(id2, "2025-02").show, "True")

  // and it blocks the year switch too, rather than reading as "no payment"
  // and quietly deleting every month on the way past
  s := frame(r, s, click(bbox.x + 153, bbox.y + 77))
  check(f, "a bad amount blocks the year switch",
        s.book.map(fn(b : app/payments-book) { b.year }).default(0).show, "2025")
  check(f, "February survived the refused switch", repo/is-paid(id2, "2025-02").show, "True")

  // --- switching year commits the year being left
  s := frame(r, s, click(mar.fst, mar.snd))
  s := frame(r, s, [win32/Event(win32/ev-key-down, 0, 0, win32/key-backspace),
                    win32/Event(win32/ev-key-down, 0, 0, win32/key-backspace),
                    win32/Event(win32/ev-key-down, 0, 0, win32/key-backspace)])
  s := frame(r, s, typing("900"))
  s := frame(r, s, click(bbox.x + 153, bbox.y + 77))
  check(f, "the year moved on", s.book.map(fn(b : app/payments-book) { b.year }).default(0).show,
        "2026")
  check(f, "and March 2025 was saved on the way out",
        repo/is-paid(id2, "2025-03").show, "True")
  check(f, "the new year opens empty",
        s.book.map(fn(b : app/payments-book)
                     { b.entries.filter(fn(e : app/month-entry) { e.original != 0 }).length })
          .default(-1).show, "0")

  s := frame(r, s, [win32/Event(win32/ev-key-down, 0, 0, win32/key-escape)])
  check(f, "Escape closes the book", s.book.is-nothing.show, "True")

  // --- the licence cap, through the dialog rather than through the guard.
  // The guard is already covered in lictest; what is covered here is that the
  // dialog actually asks it. A cap the Save button ignores is not a cap.
  s := app/close-dialogs(s)
  list(1, license/free-members).foreach fn(i)
    repo/insert-member(Member(0, "Bulk " ++ i.show, Nothing, Nothing, "2025-01-01",
                              True, Nothing)).ignore
  val over = repo/count-members(False)
  s := s(licensee = "", form = Just(app/blank-form("2025-03-02", "500", "1500")))
  s := frame(r, s, [])
  s := frame(r, s, click(field-end(0, add-h).fst, field-end(0, add-h).snd))
  s := frame(r, s, typing("Over The Cap"))
  s := frame(r, s, click(ox, oy))
  check(f, "Save is refused over the cap", s.form.is-just.show, "True")
  check(f, "and nobody was written", repo/count-members(False).show, over.show)

  // The same click, the same form, with a licence in hand.
  s := s(licensee = "Bright Star Gym")
  s := frame(r, s, [])
  s := frame(r, s, click(ox, oy))
  check(f, "licensed, the same Save works", s.form.is-nothing.show, "True")
  check(f, "and the member was written", repo/count-members(False).show, (over + 1).show)

  win32/save-bmp("out/dlg-last.bmp").ignore
  sql/close().ignore
  println(if !f == 0 then "ALL PASS" else "FAILED: " ++ (!f).show)
