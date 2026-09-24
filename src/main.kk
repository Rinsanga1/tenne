// TenneCRM. The frame loop, and nothing else.
module main

import std/num/float64
import win32
import sql
import db
import backup
import ui
import theme
import widgets
import repo
import dates
import util
import license
import app
import view-members
import view-dashboard
import view-transactions
import view-expenses
import view-shop
import view-settings
import dialogs

val body-px = 14
val semi-px = 15
val small-px = 12

// Long enough that an idle window costs nothing; short enough that a hover
// highlight still feels immediate when the mouse is already moving.
val idle-ms = 120

pub fun main() : io ()
  val path = db/db-path()
  // A restore queued by a previous run is applied before the database is
  // opened -- see Durability.tla, RestoreHonoured.
  backup/apply-pending(path).ignore
  val fresh = !sql/file-exists(path)
  if !db/open-db(path) then
    win32/open("TenneCRM", 640, 200).ignore
    println("cannot open database: " ++ sql/error())
  else
    if !win32/open("TenneCRM", 1180, 720) then println("cannot open window")
    else
      // Relative to the exe, not the working directory: a shortcut or a Run
      // box starts the app elsewhere, and the fonts would silently fall back
      // to a GDI default with no sign of why.
      val assets = win32/exe-dir() ++ "/assets/fonts/"
      win32/font-file(assets ++ "Geist-Regular.ttf").ignore
      win32/font-file(assets ++ "Geist-SemiBold.ttf").ignore
      val r = ref(ui/new-ui(win32/font("Geist", body-px, 400),
                            win32/font("Geist SemiBold", semi-px, 600),
                            win32/font("Geist", small-px, 400),
                            win32/font("Geist SemiBold", 30, 600)))
      val label = if fresh then "New empty database" else backup/parent-of(path)
      val s0 = app/new-state(theme/palette-of(repo/get-setting("theme").default("dark")),
                             repo/gym-name(), repo/currency(), label,
                             dates/current-month(),
                             util/show-money(repo/default-monthly-fee()),
                             util/show-money(repo/registration-fee()))(
                             licensee = license/licensee())
      // the first frame is owed unconditionally -- nothing is on screen yet
      loop(r, s0, True)
      // A snapshot on the way out, throttled so opening and closing the app
      // repeatedly does not rewrite the whole database each time.
      if backup/stale(path, 6) then backup/backup-now(path).ignore
      sql/close().ignore

// The frame loop.
//
// Nothing in this application animates, so a frame built from no input draws
// exactly what is already on screen. Skipping it is the difference between a
// window that costs a whole CPU core while the owner reads it and one that
// costs nothing. Any input at all wakes it immediately -- win32/wait returns
// the instant a message is posted.
// `pending` means the last frame held back keystrokes that arrived in the same
// batch as a click (see ui/frame-begin). Those are owed a frame even if the
// user does nothing more, so the loop must not go to sleep on them.
fun loop( r : ref<global,ui/ui>, s : app/state, pending : bool ) : io ()
  if !win32/pump() then ()
  else
    val evs = win32/drain()
    if evs.is-nil && !pending then
      win32/wait(idle-ms)
      loop(r, s, False)
    else
      ui/frame-begin(r, evs)
      win32/clip-all()
      win32/fill(0, 0, win32/width(), win32/height(), s.palette.main)

      // Everything behind an open dialog is drawn but takes no input. It still
      // declares its widgets, so a capture or focus underneath is not mistaken
      // for a vanished widget -- ActiveIsPresent and FocusIsPresent.
      val blocked = app/modal-open(s)
      if blocked then ui/begin-inert(r)

      val chosen = app/sidebar(r, s)
      val s1 = if app/same-view(chosen, s.view) then s
               else app/close-dialogs(s)(view = chosen, scroll = 0, notice = "")

      // if/elif, not match. A match arm that consumes an outer owned value --
      // here `s1` -- double-drops it in Koka 3.2.3, the same shape as the
      // pattern-guard bug. See the Gotchas in .ralph/koka-tenne.md.
      val s2 = if app/same-view(s1.view, Members) then view-members/show(r, s1)
               elif app/same-view(s1.view, Dashboard) then view-dashboard/show(r, s1)
               elif app/same-view(s1.view, Transactions) then view-transactions/show(r, s1)
               elif app/same-view(s1.view, Expenses) then view-expenses/show(r, s1)
               elif app/same-view(s1.view, Shop) then view-shop/show(r, s1)
               elif app/same-view(s1.view, Settings) then view-settings/show(r, s1)
               else placeholder(r, s1)

      if blocked then ui/end-inert(r)
      val s3 = dialogs/show(r, s2)

      ui/frame-end(r)
      win32/present()
      if (!r).quitting then win32/quit()
      loop(r, s3, ui/has-deferred(r))

// The views not yet ported say so, rather than showing an empty panel that
// reads as broken.
fun placeholder( r : ref<global,ui/ui>, s : app/state ) : io app/state
  val box = app/content-rect()
  app/page-title(r, s, app/view-label(s.view))
  widgets/panel(s.palette, box)
  widgets/empty-state(r, s.palette, box, app/view-label(s.view) ++ " is not ported yet",
                      "The Members view is the one wired to real data so far")
  s
