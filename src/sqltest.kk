module sqltest
import std/num/float64
import sql

fun check( fails : ref<global,int>, name : string, got : string, want : string ) : io ()
  val ok = got == want
  if !ok then fails := !fails + 1
  println((if ok then "  ok   " else "  FAIL ") ++ name ++ " = " ++ got ++
          (if ok then "" else "   (want " ++ want ++ ")"))

pub fun main() : io ()
  val fails = ref(0)
  if !sql/open("out/test.db") then
    println("FAILED to open: " ++ sql/error())
  else
    sql/exec("DROP TABLE IF EXISTS members")
    val made = sql/exec("CREATE TABLE members (id INTEGER PRIMARY KEY, name TEXT NOT NULL," ++
                        " phone TEXT, join_date TEXT NOT NULL, active INTEGER NOT NULL DEFAULT 1)")
    check(fails, "create table    ", made.show, "True")

    val ins = sql/prepare("INSERT INTO members(name, phone, join_date, active) VALUES (?,?,?,?)")
    [("Priya Lalthanmawii", "9862011234", "2024-11-03", 1),
     ("Zonunsanga", "", "2025-02-17", 1),
     ("Lalrinpuia", "9436152200", "2023-07-21", 0)].foreach fn(m)
      val (n, p, d, a) = m
      sql/reset(ins)
      sql/bind-text(ins, 1, n)
      if p == "" then sql/bind-null(ins, 2) else sql/bind-text(ins, 2, p)
      sql/bind-text(ins, 3, d)
      sql/bind-int(ins, 4, a)
      sql/step(ins)
      ()
    sql/finalize(ins)

    check(fails, "row count       ", sql/scalar-int("SELECT COUNT(*) FROM members", [], -1).show, "3")
    check(fails, "last insert id  ", sql/last-id().show, "3")

    val names = sql/rows("SELECT name FROM members ORDER BY name", [], fn(s) { sql/col-text(s, 0) })
    check(fails, "ordered names   ", names.join(", "), "Lalrinpuia, Priya Lalthanmawii, Zonunsanga")

    // NULL must come back as Nothing, not as the empty string -- the schema
    // has nullable phone/address/notes and the UI must tell them apart.
    val phones = sql/rows("SELECT phone FROM members ORDER BY name", [],
                          fn(s) { sql/col-text-opt(s, 0) })
    check(fails, "null vs empty   ", phones.map(fn(p) { p.default("<null>") }).join(", "),
          "9436152200, 9862011234, <null>")

    // bound parameters
    val active = sql/rows("SELECT name FROM members WHERE active = ? ORDER BY name", ["1"],
                          fn(s) { sql/col-text(s, 0) })
    check(fails, "bound parameter ", active.join(", "), "Priya Lalthanmawii, Zonunsanga")

    check(fails, "real column     ", sql/scalar-real("SELECT 1500.5", [], 0.0).show, "1500.5")

    // VACUUM INTO, the honest backup
    check(fails, "backup-into     ", sql/backup-to("out/backup.db").show, "True")
    sql/close()
    if !sql/open("out/backup.db") then println("  FAIL backup will not open")
    check(fails, "backup has rows ", sql/scalar-int("SELECT COUNT(*) FROM members", [], -1).show, "3")
    sql/close()

    println(if !fails == 0 then "ALL PASS" else "FAILED: " ++ (!fails).show)
