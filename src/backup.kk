// Backups, and the restore that spans a restart.
//
// This module is Durability.tla made executable. Every loss modelled there
// happened with the app behaving exactly as written -- no disk failure, no
// corruption, nobody deleting anything -- so the two fixes below are not
// hardening, they are the difference between a backup and a file that looks
// like one. Read docs/tla/README.md before changing anything here.
module backup

import sql
import dates
import win32
import util

// The ring keeps this many. Older ones are pruned oldest-first.
pub val keep-last = 7

pub fun backups-dir( db-path : string ) : string
  parent-of(db-path) ++ "/backups"

pub fun parent-of( path : string ) : string
  val cs = path.list
  val cut = last-sep(cs, 0, -1)
  if cut < 0 then "." else cs.take(cut).string

pub fun base-name( path : string ) : string
  val cs = path.list
  cs.drop(last-sep(cs, 0, -1) + 1).string

fun last-sep( cs : list<char>, i : int, best : int ) : int
  match cs
    Nil -> best
    Cons(c, rest) ->
      val b = if c == '/' || c == '\\' then i else best
      last-sep(rest, i + 1, b)

// `tenne_20260920-164233.db` -- sorts chronologically as text, which is what
// makes pruning oldest-first a plain sort.
pub fun stamp-name( now : string ) : string
  val cs = now.list
  val d = cs.take(10).filter(fn(c) { c != '-' }).string
  val t = cs.drop(11).filter(fn(c) { c != ':' }).string
  "tenne_" ++ d ++ "-" ++ t ++ ".db"

// Backups on file, oldest first.
pub fun list-backups( db-path : string ) : io list<string>
  win32/listdir(backups-dir(db-path), "tenne_*.db").sort-by(fn(a : string, b : string) { a < b })

// Take a backup now.
//
// VACUUM INTO, never a file copy. In WAL mode the main file is not the
// database: recent commits live in `tenne.db-wal` until a checkpoint moves
// them across, so copying the main file can capture a database that does not
// contain them -- on a young database, not even the schema. The Rust build
// copied anyway whenever its checkpoint failed, and a checkpoint fails
// whenever another reader holds the WAL, which on Windows is an antivirus
// scanner as easily as a second copy of the app.
//
// BackupsAreHonest.
pub fun backup-now( db-path : string ) : io maybe<string>
  val dir = backups-dir(db-path)
  win32/mkdir(dir).ignore
  val path = dir ++ "/" ++ stamp-name(dates/now())
  if !sql/backup-to(path) then Nothing
  else
    prune(db-path)
    Just(path)

// Keep the newest `keep-last`, delete the rest.
//
// Note what this assumes, from the model: dropping old backups is harmless
// only while data merely grows, because then every later backup is a superset.
// It stops being harmless the moment anything bulk-destructive exists. That is
// a constraint on future features, not just a note.
pub fun prune( db-path : string ) : io ()
  val dir = backups-dir(db-path)
  val all = list-backups(db-path)
  val excess = all.length - keep-last
  if excess <= 0 then ()
  else all.take(excess).foreach fn(name)
    sql/remove-file(dir ++ "/" ++ name).ignore

// The safety copies from `restore`, oldest first. They sit beside the
// database rather than in `backups/`, because they are evidence of a
// recovery attempt and not part of the ring the user browses.
pub fun list-pre-restore( db-path : string ) : io list<string>
  win32/listdir(parent-of(db-path), base-name(db-path) ++ ".pre-restore-*")
    .sort-by(fn(a : string, b : string) { a < b })

// Fewer than the backup ring: these exist to survive the recovery session you
// are in, not to be a history.
pub val keep-pre-restore = 3

pub fun prune-pre-restore( db-path : string ) : io ()
  val dir = parent-of(db-path)
  val all = list-pre-restore(db-path)
  val excess = all.length - keep-pre-restore
  if excess <= 0 then ()
  else all.take(excess).foreach fn(name)
    sql/remove-file(dir ++ "/" ++ name).ignore

// Restore `source` over the live database.
//
// Two things beyond the copy, both load-bearing:
//
// 1. Delete `-wal` and `-shm`. A `-wal` belongs to the file it was written
//    against; once that file has been replaced it is garbage. Without this,
//    opening the restored database replays the stale WAL on top of it and the
//    data you were trying to escape is still there -- reported as success,
//    with `PRAGMA integrity_check` saying `ok`. RestoreHonoured.
//
// 2. Keep a pre-restore copy. The Rust build did too, but overwrote it on
//    every restore, so a second attempt at recovery destroyed the evidence
//    from the first. This one is stamped -- and therefore pruned, or full
//    copies of the database accumulate beside it forever.
pub fun restore( db-path : string, source : string ) : io bool
  if !sql/file-exists(source) then False
  else
    val safety = db-path ++ ".pre-restore-" ++ stamp-name(dates/now())
    win32/copy-file(db-path, safety).ignore
    prune-pre-restore(db-path)
    if !win32/copy-file(source, db-path) then False
    else
      ["-wal", "-shm"].foreach fn(sfx)
        if sql/file-exists(db-path ++ sfx) then sql/remove-file(db-path ++ sfx).ignore
      True

// Queue a restore for the next launch, for when the database is open and
// cannot be replaced underneath itself.
pub fun queue-restore( db-path : string, source : string ) : io bool
  win32/write-text(db-path ++ ".pending-restore", source)

// Apply a restore queued by a previous run, if any. Called before the database
// is opened.
//
// The claim the UI made -- "restore ready, close and reopen to finish" -- is
// only honoured if this runs and the stale WAL goes with it.
pub fun apply-pending( db-path : string ) : io bool
  val pending = db-path ++ ".pending-restore"
  if !sql/file-exists(pending) then False
  else
    val src = win32/read-text(pending).trim
    val done = if src == "" then False else restore(db-path, src)
    sql/remove-file(pending).ignore
    done

// Is the newest backup older than `hours`? The exit backup is throttled on
// this so closing and reopening the app repeatedly doesn't rewrite the whole
// database each time.
pub fun stale( db-path : string, hours : int ) : io bool
  match list-backups(db-path).last
    Nothing -> True
    Just(name) ->
      val cutoff = stamp-name(hours-ago(dates/now(), hours))
      name < cutoff

// `now` minus `hours`, as a `YYYY-MM-DD HH:MM:SS` string. Only used to build a
// comparison stamp, so second-level precision is plenty.
pub fun hours-ago( now : string, hours : int ) : string
  match dates/parse-date(now.list.take(10).string)
    Nothing -> now
    Just((y, m, d)) ->
      val hh = parse2(now.list.drop(11).take(2).string)
      val back = hh - hours
      val days = if back >= 0 then 0 else (0 - back + 23) / 24
      val hh2 = back + days * 24
      val base = dates/add-days(dates/fmt-date(y, m, d), 0 - days)
      base ++ " " ++ dates/pad2(hh2) ++ now.list.drop(13).string

fun parse2( s : string ) : int
  s.list.foldl(0) fn(a, c)
    if c.is-digit then a * 10 + (c.int - '0'.int) else a
