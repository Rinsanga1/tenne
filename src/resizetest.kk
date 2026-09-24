// Every view at every size, including sizes nobody would choose.
//
// The window is resizable and every view test so far has rendered at exactly
// 1180x720. A gym owner on a small laptop, or anyone who drags the corner, is
// entirely untested territory -- and `app/content-rect` goes negative below
// about 270px wide, which is the kind of thing that turns into a crash or a
// silently blank panel.
module resizetest

import std/num/float64
import win32
import sql
import db
import ui
import theme
import widgets
import models
import repo
import repo2
import dates
import util
import app
import view-members
import view-dashboard
import view-transactions
import view-expenses
import view-shop
import view-settings
import dlg-members
import dlg-payments
import dlg-shop
// Returns 1 on failure, 0 on success. No ref anywhere in this file: a `ref`
// that is merely live while a closure is created is enough to make Koka 3.2.3
// emit undeclared evidence variables.
fun chk( name : string, got : string, want : string ) : io int
  val ok = got == want
  println((if ok then "  ok   " else "  FAIL ") ++ name.pad-right(52) ++ got.pad-right(14) ++
          (if ok then "" else "want " ++ want))
  if ok then 0 else 1

// Sizes worth trying: the default, a small laptop, a half-screen window, an
// absurdly narrow one, and an absurdly short one.
val sizes = [(1180, 720), (1024, 640), (800, 600), (640, 480),
             (420, 400), (320, 720), (1180, 260), (300, 200)]

val views = [Dashboard, Members, Shop, Expenses, Transactions, Settings]

pub fun main() : io ()
  sql/unbuffer()
  val fails = checks()
  sql/close().ignore
  println(if fails == 0 then "ALL PASS" else "FAILED: " ++ fails.show)

fun checks() : io int
  val path = "out/dash.db"
  if !sql/file-exists(path) then
    println("  SKIP: seed out/dash.db by running dashtest first")
    1
  else
    db/open-db(path).ignore
    win32/offscreen(1180, 720)
    win32/font-file("assets/fonts/Geist-Regular.ttf").ignore
    win32/font-file("assets/fonts/Geist-SemiBold.ttf").ignore
    val r = ref(ui/new-ui(win32/font("Geist", 14, 400), win32/font("Geist SemiBold", 15, 600),
                          win32/font("Geist", 12, 400), win32/font("Geist SemiBold", 30, 600)))
    val s0 = app/new-state(theme/palette-of("dark"), repo/gym-name(), "Rs", "out",
                           "2025-08", "1500", "500")

    // The content rectangle must never be negative, whatever the window does.
    // A negative width silently draws nothing and reads as a blank app.
    val bad-sizes = sizes.foldl("") fn(acc : string, sz : (int, int))
      win32/offscreen(sz.fst, sz.snd)
      val box = app/content-rect()
      if box.w > 0 && box.h > 0 then acc
      else acc ++ sz.fst.show ++ "x" ++ sz.snd.show ++ " "
    val e1 = chk("content rect stays positive at every size", bad-sizes, "")

    // Every view, at every size, with a dialog open over it. Survival is the
    // assertion: a bad rectangle takes the renderer or the allocator with it.
    val drawn = sizes.foldl(0) fn(acc : int, sz : (int, int))
      win32/offscreen(sz.fst, sz.snd)
      acc + views.foldl(0) fn(a : int, v : app/view)
        draw(r, s0(view = v))
        draw(r, s0(view = v, selected = 1))
        draw(r, s0(view = v, form = Just(app/blank-form("2025-08-20", "500", "1500"))))
        draw(r, s0(view = v, sale = Just(app/blank-sale("2025-08-20"))))
        // the payments book is the largest dialog and the only grid, so it is
        // the one most likely to paint outside a clamped frame
        draw(r, s0(view = v, book = Just(demo-book())))
        a + 5
    val e2 = chk("every view/size/dialog combination drew", drawn.show,
                 (sizes.length * views.length * 5).show)

    // A dialog bigger than the window must still be reachable: its buttons sit
    // on its bottom edge, so the frame has to be clamped to what is on screen.
    win32/offscreen(300, 200)
    val box = widgets/modal-frame(r, theme/palette-of("dark"), 520, 540, "Too big")
    val e3 = chk("an oversized dialog is clamped to the window",
                 ((box.x >= 0) && (box.y >= 0) && (box.x + box.w <= 300) &&
                  (box.y + box.h <= 200)).show, "True")

    // the enforced minimum window size (WM_GETMINMAXINFO)
    win32/offscreen(900, 560)
    draw(r, s0(view = Members))
    win32/save-bmp("out/resize-min.bmp").ignore
    win32/offscreen(420, 400)
    draw(r, s0(view = Dashboard))
    win32/save-bmp("out/resize-420.bmp").ignore
    e1 + e2 + e3
fun draw( r : ref<global,ui/ui>, s : app/state ) : io ()
  ui/frame-begin(r, [win32/Event(win32/ev-mouse-move, 200, 200, 0)])
  win32/clip-all()
  win32/fill(0, 0, win32/width(), win32/height(), s.palette.main)
  val blocked = app/modal-open(s)
  if blocked then ui/begin-inert(r)
  app/sidebar(r, s).ignore
  // if/elif, not match: the arms consume `s` -- see the Gotchas.
  if app/same-view(s.view, Members) then view-members/show(r, s).ignore
  elif app/same-view(s.view, Dashboard) then view-dashboard/show(r, s).ignore
  elif app/same-view(s.view, Transactions) then view-transactions/show(r, s).ignore
  elif app/same-view(s.view, Expenses) then view-expenses/show(r, s).ignore
  elif app/same-view(s.view, Shop) then view-shop/show(r, s).ignore
  elif app/same-view(s.view, Settings) then view-settings/show(r, s).ignore
  if blocked then ui/end-inert(r)
  if s.selected != 0 then dlg-members/member-card(r, s, s.selected).ignore
  elif s.form.is-just then
    dlg-members/member-dialog(r, s, s.form.default(app/blank-form("", "", ""))).ignore
  elif s.sale.is-just then
    dlg-shop/sale-dialog(r, s, s.sale.default(app/blank-sale(""))).ignore
  elif s.book.is-just then
    dlg-payments/dialog(r, s, s.book.default(app/blank-book())).ignore
  ui/frame-end(r)

// Twelve months with nothing on file: no database needed, and drawing the
// book touches none.
fun demo-book() : app/payments-book
  app/book-of(Member(1, "Zonunsanga", Nothing, Nothing, "2025-01-05", True, Nothing),
              [], "2025-08")
