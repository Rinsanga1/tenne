// Settings: the handful of numbers the gym runs on, and the two things that
// decide whether the data survives -- backups and the spreadsheet.
module view-settings

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
import backup
import csv
import db
import license
import app

// Where the lower row of panels starts, measured from the top of the content
// area. Exported because settingstest clicks Back up now and Restore by
// coordinate: with the number written out twice, moving the panels moved the
// buttons out from under the test's clicks and it failed with seven unrelated
// complaints about backups.
pub val lower-panels = 316

pub fun show( r : ref<global,ui/ui>, s : app/state ) : io app/state
  val p = s.palette
  val box = app/content-rect()
  app/page-title(r, s, "Settings")
  var st := s

  if s.notice != "" then
    widgets/label((!r).font-small, box.x, box.y - 24, s.notice, theme/positive)

  val colw = (box.w - 20) / 2

  // --- the gym
  widgets/panel(p, Rect(box.x, box.y, colw, 300))
  widgets/label((!r).font-small, box.x + 20, box.y + 16, "THE GYM", p.text-muted)
  val f1 = setting-row(r, p, box.x, box.y, 0, "Gym name")
  val gym = widgets/text-field(r, p, f1, s.gym-name, ui/wid("st:gym"), "My Gym")
  if gym != s.gym-name then
    repo/set-setting("gym_name", gym).ignore
    st := st(gym-name = gym)

  // The fee fields edit a draft in app/state, not a value re-read from the
  // database each frame. Reading it back means backspacing the last digit
  // rewrites the setting from the half-deleted text, and the field can never
  // be cleared to retype -- it springs back under the cursor.
  val f2 = setting-row(r, p, box.x, box.y, 1, "Monthly fee")
  val fee = widgets/text-field(r, p, Rect(f2.x, f2.y, 140, f2.h), s.fee-draft,
                               ui/wid("st:fee"), "1500")
  if fee != s.fee-draft then
    st := st(fee-draft = fee)
    save-number(fee, "default_monthly_fee")
  if !valid-fee(fee) then
    widgets/label((!r).font-small, f2.x + 150, f2.y + 8, "must be a number", theme/warning)

  val f3 = setting-row(r, p, box.x, box.y, 2, "Joining fee")
  val jfee = widgets/text-field(r, p, Rect(f3.x, f3.y, 140, f3.h), s.jfee-draft,
                                ui/wid("st:jfee"), "500")
  if jfee != s.jfee-draft then
    st := st(jfee-draft = jfee)
    save-number(jfee, "registration_fee")
  if !valid-fee(jfee) then
    widgets/label((!r).font-small, f3.x + 150, f3.y + 8, "must be a number", theme/warning)

  val f4 = setting-row(r, p, box.x, box.y, 3, "Currency prefix")
  val cur = widgets/text-field(r, p, Rect(f4.x, f4.y, 140, f4.h), s.currency,
                               ui/wid("st:cur"), "Rs")
  if cur != s.currency && cur.trim != "" then
    repo/set-setting("currency", cur).ignore
    st := st(currency = cur)

  // --- appearance
  val ax = box.x + colw + 20
  widgets/panel(p, Rect(ax, box.y, colw, 300))
  widgets/label((!r).font-small, ax + 20, box.y + 16, "APPEARANCE", p.text-muted)
  widgets/label((!r).font-small, ax + 20, box.y + 46, "Theme", p.text-muted)
  val current = theme/palette-name(s.palette)
  ["dark", "light", "tenne"].foreach-indexed fn(i, name)
    val b = Rect(ax + 20 + i * 96, box.y + 68, 88, 32)
    val chosen = name == current
    win32/round-fill(b.x, b.y, b.w, b.h, widgets/radius, if chosen then p.accent else p.btn)
    win32/round-border(b.x, b.y, b.w, b.h, widgets/radius, p.border)
    widgets/label-center((!r).font-body, b.x, b.w,
                         b.y + (b.h - win32/font-line((!r).font-body)) / 2,
                         name, if chosen then 0xFFFFFFFF else p.text)
    if ui/behavior(r, ui/wid-at("st:theme", i), b).clicked then
      repo/set-setting("theme", name).ignore
      st := st(palette = theme/palette-of(name))

  widgets/label((!r).font-small, ax + 20, box.y + 118, "Database", p.text-muted)
  widgets/label-clipped((!r).font-small, ax + 20, box.y + 138, colw - 40,
                        db/db-path(), p.text)
  widgets/label((!r).font-small, ax + 20, box.y + 162,
                "The database sits beside the .exe. Move the .exe on its own", p.text-muted)
  widgets/label((!r).font-small, ax + 20, box.y + 180,
                "and the data stays behind.", p.text-muted)

  // --- the licence
  widgets/label((!r).font-small, ax + 20, box.y + 212, "LICENCE", p.text-muted)
  if s.licensee != "" then
    widgets/label-clipped((!r).font-small, ax + 20, box.y + 236, colw - 150,
                          "Licensed to " ++ s.licensee, theme/positive)
  else
    val n = repo/count-members(False)
    widgets/label((!r).font-small, ax + 20, box.y + 236,
                  "Unlicensed - " ++ n.show ++ " of " ++ license/free-members.show ++
                  " members used", theme/warning)
  if widgets/button(r, p, Rect(ax + colw - 130, box.y + 230, 110, 30),
                    (if s.licensee != "" then "Change key" else "Enter key"),
                    ui/wid("st:lic")) then
    st := st(licence = Just(app/blank-licence()))

  // --- backups
  val by = box.y + lower-panels
  val bh = box.y + box.h - by
  widgets/panel(p, Rect(box.x, by, colw, bh))
  widgets/label((!r).font-small, box.x + 20, by + 16, "BACKUPS", p.text-muted)
  val path = db/db-path()
  val backups = backup/list-backups(path).reverse
  if widgets/button(r, p, Rect(box.x + 20, by + 40, 120, 32), "Back up now",
                    ui/wid("st:backup")) then
    match backup/backup-now(path)
      Just(_) -> st := st(notice = "Backup taken")
      Nothing -> st := st(notice = "Backup failed: " ++ sql/error())
  widgets/label((!r).font-small, box.x + 152, by + 50,
                "Keeps the newest " ++ backup/keep-last.show, p.text-muted)

  if backups.is-nil then
    widgets/label((!r).font-small, box.x + 20, by + 90, "No backups yet", p.text-muted)
  else
    win32/clip(box.x + 1, by + 84, colw - 2, bh - 90)
    backups.foreach-indexed fn(i, name)
      val ry = by + 88 + i * 30
      widgets/label((!r).font-small, box.x + 20, ry + 8, pretty-stamp(name), p.text)
      val sz = win32/file-size(backup/backups-dir(path) ++ "/" ++ name)
      widgets/label((!r).font-small, box.x + 190, ry + 8,
                    (if sz < 0 then "?" else (sz / 1024).show ++ " KB"), p.text-muted)
      if widgets/button(r, p, Rect(box.x + colw - 110, ry, 90, 26), "Restore",
                        ui/wid-at("st:rest", i)) then
        // Queued, not applied: the database is open, and replacing a file
        // underneath an open connection is how the stale -wal gets replayed
        // over it. Durability.tla, RestoreHonoured.
        backup/queue-restore(path, backup/backups-dir(path) ++ "/" ++ name).ignore
        st := st(notice = "Restore ready - close and reopen the app to finish")
    win32/clip-all()

  // --- the spreadsheet
  widgets/panel(p, Rect(ax, by, colw, bh))
  widgets/label((!r).font-small, ax + 20, by + 16, "SPREADSHEET", p.text-muted)
  if widgets/button(r, p, Rect(ax + 20, by + 40, 120, 32), "Export", ui/wid("st:export")) then
    val out = backup/parent-of(path) ++ "/tenne-export.csv"
    val n = csv/export-all(out)
    st := st(notice = if n < 0 then "Could not write " ++ out
                      else n.show ++ " rows written to tenne-export.csv")
  if widgets/button(r, p, Rect(ax + 152, by + 40, 120, 32), "Import", ui/wid("st:import")) then
    val src = backup/parent-of(path) ++ "/tenne-export.csv"
    if !sql/file-exists(src) then st := st(notice = "No tenne-export.csv beside the app")
    else st := st(notice = csv/summary(csv/import-all(src, s.licensee != "")))

  // Say plainly what the spreadsheet is not, because the Rust build called it
  // a backup and it is not one.
  widgets/label((!r).font-small, ax + 20, by + 88,
                "Members, payments, sale totals and expenses.", p.text-muted)
  widgets/label((!r).font-small, ax + 20, by + 108,
                "It does NOT carry products, stock, sale lines or these", theme/warning)
  widgets/label((!r).font-small, ax + 20, by + 126,
                "settings - so it is not a backup. Use Back up now for that.", theme/warning)
  st

fun setting-row( r : ref<global,ui/ui>, p : theme/palette, x : int, y : int,
                 n : int, caption : string ) : io rect
  widgets/label((!r).font-small, x + 20, y + 46 + n * 48, caption, p.text-muted)
  Rect(x + 20, y + 62 + n * 48, 260, 30)

// A blank or malformed field is left alone in the database rather than
// written as zero -- a typo must not silently waive everybody's dues. The
// field says so on screen while it is invalid.
fun valid-fee( typed : string ) : bool
  match util/parse-money(typed)
    Just(v) -> v >= 0.0
    Nothing -> False

fun save-number( typed : string, key : string ) : io ()
  match util/parse-money(typed)
    Just(v) -> if v >= 0.0 then repo/set-setting(key, util/show-money(v)).ignore
    Nothing -> ()

// `tenne_20260920-164233.db` -> `20 Sep 2026, 16:42`
fun pretty-stamp( name : string ) : string
  val cs = name.list.drop(6)
  val d = cs.take(8).string
  val t = cs.drop(9).take(6).string
  match dates/parse-date(d.list.take(4).string ++ "-" ++ d.list.drop(4).take(2).string ++
                         "-" ++ d.list.drop(6).take(2).string)
    Nothing -> name
    Just((y, m, dd)) ->
      dates/pad2(dd) ++ " " ++ dates/month-name(m).list.take(3).string ++ " " ++ y.show ++
      ", " ++ t.list.take(2).string ++ ":" ++ t.list.drop(2).take(2).string
