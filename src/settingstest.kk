// Settings, driven by clicks: the settings that change how money reads, and
// the restore path, which is the only dialog that touches the database file.
//
// Restore is queued, not applied, and the queue is honoured on the next
// launch. That is Durability.tla's RestoreHonoured, and this drives it the way
// a person does -- by clicking Restore in the backup list.
module settingstest

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
import backup
import app
import view-settings

fun check( f : ref<global,int>, name : string, got : string, want : string ) : io ()
  val ok = got == want
  if !ok then f := !f + 1
  println((if ok then "  ok   " else "  FAIL ") ++ name.pad-right(50) ++ got.pad-right(18) ++
          (if ok then "" else "want " ++ want))

fun click( x : int, y : int ) : list<win32/event>
  [win32/Event(win32/ev-mouse-down, x, y, 0), win32/Event(win32/ev-mouse-up, x, y, 0)]

fun backspaces( n : int ) : list<win32/event>
  list(1, n).map(fn(_i) { win32/Event(win32/ev-key-down, 0, 0, win32/key-backspace) })

fun typing( s : string ) : list<win32/event>
  s.list.map(fn(c) { win32/Event(win32/ev-char, 0, 0, c.int) })

fun frame( r : ref<global,ui/ui>, s : app/state, evs : list<win32/event> ) : io app/state
  ui/frame-begin(r, evs)
  win32/clip-all()
  win32/fill(0, 0, 1180, 720, s.palette.main)
  val next = view-settings/show(r, s)
  ui/frame-end(r)
  next

// Settings lays out from app/content-rect(): x = 240, y = 60, w = 1180-270.
val cx = 240
val cy = 60
val cw = 1180 - 270
val colw = (cw - 20) / 2
val ax = cx + colw + 20

// the n-th field in the left column
fun field( n : int ) : (int, int)
  (cx + 100, cy + 62 + n * 48 + 15)

pub fun main() : io ()
  sql/unbuffer()
  val fails = checks()
  sql/close().ignore
  println(if fails == 0 then "ALL PASS" else "FAILED: " ++ fails.show)

fun checks() : io int
  val f = ref(0)
  // Settings writes to the database beside the exe, so this test uses that
  // path rather than a temp one -- it is what db/db-path() returns.
  val path = db/db-path()
  val dir = backup/parent-of(path)
  [path, path ++ "-wal", path ++ "-shm", path ++ ".pending-restore"].foreach fn(p)
    if sql/file-exists(p) then sql/remove-file(p).ignore
  win32/listdir(dir ++ "/backups", "tenne_*.db").foreach fn(n)
    sql/remove-file(dir ++ "/backups/" ++ n).ignore

  db/open-db(path).ignore
  repo/create-member(Member(0, "Priya", Nothing, Nothing, "2025-01-05", True, Nothing),
                     500.0, Just(1500.0), "2025-01", "2025-01-05").ignore
  check(f, "one member to start", repo/count-members(False).show, "1")

  win32/offscreen(1180, 720)
  win32/font-file("assets/fonts/Geist-Regular.ttf").ignore
  win32/font-file("assets/fonts/Geist-SemiBold.ttf").ignore
  val r = ref(ui/new-ui(win32/font("Geist", 14, 400), win32/font("Geist SemiBold", 15, 600),
                        win32/font("Geist", 12, 400), win32/font("Geist SemiBold", 30, 600)))
  var s := app/new-state(theme/palette-of("dark"), repo/gym-name(), repo/currency(),
                         "out", "2025-08", util/show-money(repo/default-monthly-fee()),
                         util/show-money(repo/registration-fee()))(view = Settings)
  s := frame(r, s, [])

  // --- the gym name, typed in, reaches the database
  val (gx, gy) = field(0)
  s := frame(r, s, click(gx, gy))
  // the box already holds "My Gym"; clear it before typing, as a person would
  s := frame(r, s, backspaces(6))
  s := frame(r, s, typing("Bright Star"))
  check(f, "gym name saved", repo/get-setting("gym_name").default(""), "Bright Star")
  check(f, "and the state followed", s.gym-name, "Bright Star")

  // --- the monthly fee: a number changes what the arrears are worth
  val before = repo/membership-arrears(1, "2025-01", "2025-04").snd
  // joined 2025-01 and paid that month; by 2025-04 that is 3 months behind
  check(f, "arrears at the default fee", models/money("Rs", before), "Rs 4,500")
  val (fx, fy) = field(1)
  s := frame(r, s, click(fx, fy))
  s := frame(r, s, backspaces(4))
  // the field is now empty, which must NOT be written to the database
  check(f, "an empty fee leaves the setting alone", repo/default-monthly-fee().show, "1500")
  s := frame(r, s, typing("2000"))
  check(f, "monthly fee saved", repo/default-monthly-fee().show, "2000")
  check(f, "and the arrears revalue immediately",
        models/money("Rs", repo/membership-arrears(1, "2025-01", "2025-04").snd), "Rs 6,000")

  // A fee that is not a number must not be written -- a typo silently
  // becoming zero would waive everybody's dues.
  s := frame(r, s, click(fx, fy))
  s := frame(r, s, typing("x"))
  check(f, "a typo in the fee is ignored", repo/default-monthly-fee().show, "2000")

  // --- the theme switcher
  check(f, "starts dark", theme/palette-name(s.palette), "dark")
  s := frame(r, s, click(ax + 20 + 96 + 44, cy + 68 + 16))       // the "light" chip
  check(f, "switched to light", theme/palette-name(s.palette), "light")
  check(f, "and it persisted", repo/get-setting("theme").default(""), "light")

  // --- backups: take one by clicking the button
  val by = cy + view-settings/lower-panels
  check(f, "no backups yet", backup/list-backups(path).length.show, "0")
  s := frame(r, s, click(cx + 80, by + 56))                      // "Back up now"
  check(f, "a backup was taken", backup/list-backups(path).length.show, "1")
  check(f, "and it is a real database, not an empty file",
        (win32/file-size(backup/backups-dir(path) ++ "/" ++
                         backup/list-backups(path).head.default("")) > 4096).show, "True")

  // --- now damage the database, and restore from that backup BY CLICKING
  sql/exec("DELETE FROM members").ignore
  repo/insert-member(Member(0, "Wrong", Nothing, Nothing, "2025-01-01", True, Nothing)).ignore
  check(f, "the database is now wrong", repo/count-members(False).show, "1")
  check(f, "and the wrong member is the one on file",
        repo/list-members(False).map(fn(m : models/member) { m.name }).join(","), "Wrong")

  s := frame(r, s, [])
  // the Restore button on the first (only) backup row
  s := frame(r, s, click(cx + colw - 110 + 45, by + 88 + 13))
  check(f, "restore was queued, not applied",
        sql/file-exists(path ++ ".pending-restore").show, "True")
  check(f, "the live database is untouched until reopen",
        repo/list-members(False).map(fn(m : models/member) { m.name }).join(","), "Wrong")
  check(f, "and the UI says so", (s.notice.contains("reopen")).show, "True")

  // Reopening is what main.kk does at startup: apply the pending restore
  // before the database is opened.
  sql/close().ignore
  check(f, "the queued restore applies on the next launch",
        backup/apply-pending(path).show, "True")
  db/open-db(path).ignore
  check(f, "Priya is back", repo/list-members(False).map(fn(m : models/member) { m.name })
        .join(","), "Priya")
  check(f, "with her joining fee", repo/has-registration-payment(
        repo/list-members(False).map(fn(m : models/member) { models/member/id(m) })
          .head.default(0)).show, "True")
  check(f, "the marker is cleared", sql/file-exists(path ++ ".pending-restore").show, "False")
  // (the -wal below is the freshly reopened database's own, not the stale one;
  //  the stale-wal deletion is asserted in backuptest against a dirty shutdown)

  win32/save-bmp("out/settings.bmp").ignore
  !f
