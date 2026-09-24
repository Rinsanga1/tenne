// Durability.tla made executable. Each case below is one of the three ways
// the Rust build lost data with no disk failure and nobody deleting anything.
module backuptest

import std/num/float64
import sql
import db
import repo
import backup
import win32
import models
import util

fun check( f : ref<global,int>, name : string, got : string, want : string ) : io ()
  val ok = got == want
  if !ok then f := !f + 1
  println((if ok then "  ok   " else "  FAIL ") ++ name.pad-right(46) ++ got.pad-right(18) ++
          (if ok then "" else "want " ++ want))

fun members-in( path : string ) : io int
  sql/close().ignore
  if !sql/open(path) then -1
  else
    val n = sql/scalar-int("SELECT COUNT(*) FROM members", [], -1)
    sql/close().ignore
    n

fun seed( path : string, n : int ) : io ()
  list(1, n).foreach fn(i)
    repo/insert-member(Member(0, "M" ++ i.show, Nothing, Nothing, "2025-01-01", True, Nothing)).ignore

pub fun main() : io ()
  sql/unbuffer()
  val f = ref(0)
  val dir = "out/bk"
  val p = dir ++ "/tenne.db"
  win32/mkdir("out").ignore
  win32/mkdir(dir).ignore
  win32/mkdir(dir ++ "/backups").ignore
  // clean slate
  (win32/listdir(dir, "*") ++ win32/listdir(dir ++ "/backups", "*")).foreach fn(n)
    sql/remove-file(dir ++ "/" ++ n).ignore
    sql/remove-file(dir ++ "/backups/" ++ n).ignore

  check(f, "parent-of a path", backup/parent-of("out/bk/tenne.db"), "out/bk")
  check(f, "backups dir", backup/backups-dir(p), "out/bk/backups")
  check(f, "stamp name", backup/stamp-name("2026-09-20 16:42:33"), "tenne_20260920-164233.db")

  db/open-db(p).ignore
  seed(p, 50)
  check(f, "50 members on file", sql/scalar-int("SELECT COUNT(*) FROM members", [], -1).show, "50")

  // --- BackupsAreHonest.
  // The database is in WAL mode and has just been written, so the main file is
  // NOT the database. A copy would capture a file missing those commits; on a
  // young database it comes back "no such table". VACUUM INTO must not.
  check(f, "wal sidecar exists (so a copy would lie)", sql/file-exists(p ++ "-wal").show, "True")
  val b1 = backup/backup-now(p)
  check(f, "backup taken", b1.is-just.show, "True")
  val b1path = b1.default("")
  check(f, "backup is not an empty file", (win32/file-size(b1path) > 4096).show, "True")
  check(f, "and it holds all 50 members", members-in(b1path).show, "50")

  // --- RestoreHonoured.
  // Reopen, do something destructive, then restore. A stale -wal left on disk
  // would be replayed over the restored file and bring the damage back.
  sql/open(p).ignore
  sql/exec("DELETE FROM members").ignore
  seed(p, 110)
  check(f, "live database now has 110", sql/scalar-int("SELECT COUNT(*) FROM members", [], -1).show, "110")
  sql/close().ignore

  // A *clean* close checkpoints and removes the -wal, so closing normally
  // cannot reproduce the bug. The loss needs a dirty shutdown -- Task Manager,
  // a reboot for updates, a flat battery -- which leaves tenne.db-wal on disk
  // to be replayed over whatever file is there next time.
  //
  // We cannot kill our own process mid-test, so stand in for it: put the
  // sidecars back by hand. What is being checked is the fix -- that restore
  // removes a -wal belonging to the file it just replaced.
  win32/write-text(p ++ "-wal", "stale wal from a dirty shutdown").ignore
  win32/write-text(p ++ "-shm", "stale shm").ignore
  check(f, "a stale wal is present before restore", sql/file-exists(p ++ "-wal").show, "True")

  check(f, "restore succeeds", backup/restore(p, b1path).show, "True")
  check(f, "restore removed the stale wal", sql/file-exists(p ++ "-wal").show, "False")
  check(f, "restore removed the stale shm", sql/file-exists(p ++ "-shm").show, "False")
  check(f, "reopening shows the backup, not the damage", members-in(p).show, "50")
  check(f, "a pre-restore safety copy was kept",
        (win32/listdir(dir, "tenne.db.pre-restore-*").length > 0).show, "True")

  // Stamped means they accumulate. Each one is a full copy of the database,
  // and 17 had piled up in the working directory from test runs alone before
  // they were pruned, so the bound is the other half of the fix.
  list(1, 6).foreach fn(i)
    win32/write-text(p ++ ".pre-restore-tenne_2026010" ++ i.show ++
                     "-00000" ++ i.show ++ ".db", "x").ignore
  check(f, "several safety copies on disk",
        (backup/list-pre-restore(p).length >= 6).show, "True")
  // pruned by the restore itself, not by a call the caller has to remember
  check(f, "a second restore still succeeds", backup/restore(p, b1path).show, "True")
  check(f, "and prunes the safety copies to a bound",
        backup/list-pre-restore(p).length.show, backup/keep-pre-restore.show)
  val kept = backup/list-pre-restore(p)
  check(f, "and the safety copies kept are the newest",
        (kept.last.default("") > kept.head.default("~")).show, "True")

  // --- the queued restore that spans a restart
  sql/open(p).ignore
  sql/exec("DELETE FROM members").ignore
  seed(p, 7)
  sql/close().ignore
  check(f, "damaged again to 7", members-in(p).show, "7")
  check(f, "restore queued", backup/queue-restore(p, b1path).show, "True")
  check(f, "pending marker written", sql/file-exists(p ++ ".pending-restore").show, "True")
  check(f, "next launch applies it", backup/apply-pending(p).show, "True")
  check(f, "and the marker is cleared", sql/file-exists(p ++ ".pending-restore").show, "False")
  check(f, "the claim was honoured", members-in(p).show, "50")
  check(f, "applying again is a no-op", backup/apply-pending(p).show, "False")

  // --- the 7-deep ring
  sql/open(p).ignore
  list(1, 10).foreach fn(i)
    // distinct names, since the stamp has one-second resolution
    val name = backup/backups-dir(p) ++ "/tenne_2026010" ++ (i % 10).show ++ "-00000" ++ (i % 10).show ++ ".db"
    sql/backup-to(name).ignore
  check(f, "10 backups on disk before pruning",
        (win32/listdir(backup/backups-dir(p), "tenne_*.db").length >= 10).show, "True")
  backup/prune(p)
  check(f, "pruned to keep-last", backup/list-backups(p).length.show, backup/keep-last.show)
  check(f, "and the ones kept are the newest",
        (backup/list-backups(p).last.default("") > backup/list-backups(p).head.default("~")).show, "True")

  // every surviving backup must still be a real database
  val bad = backup/list-backups(p).filter fn(n)
    members-in(backup/backups-dir(p) ++ "/" ++ n) < 0
  check(f, "every kept backup still opens", bad.length.show, "0")

  sql/close().ignore
  println(if !f == 0 then "ALL PASS" else "FAILED: " ++ (!f).show)
