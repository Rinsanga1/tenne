// Opens a database written by the Rust build and reads it with no migration
// and no conversion. This is the data-compatibility promise, made checkable.
module dbinfo
import sql
import std/num/float64

pub fun main() : io ()
  val path = "out/real.db"
  if !sql/open(path) then println("cannot open " ++ path ++ ": " ++ sql/error())
  else
    println("opened " ++ path)
    val tables = sql/rows("SELECT name FROM sqlite_master WHERE type='table'" ++
                          " AND name NOT LIKE 'sqlite_%' ORDER BY name", [],
                          fn(s) { sql/col-text(s, 0) })
    println("tables: " ++ tables.join(", "))

    tables.foreach fn(t)
      val n = sql/scalar-int("SELECT COUNT(*) FROM \"" ++ t ++ "\"", [], -1)
      println("  " ++ t.pad-right(20) ++ n.show.pad-left(5) ++ " rows")

    println("")
    println("members:")
    sql/rows("SELECT id, name, phone, join_date, active FROM members ORDER BY id", [], fn(s)
      "  #" ++ sql/col-int(s, 0).show ++ "  " ++ sql/col-text(s, 1).pad-right(22) ++
      sql/col-text-opt(s, 2).default("(no phone)").pad-right(14) ++
      " joined " ++ sql/col-text(s, 3) ++
      (if sql/col-int(s, 4) == 1 then "  active" else "  inactive")
    ).foreach(println)

    println("")
    println("payments:")
    sql/rows("SELECT p.period_month, p.amount, p.category, m.name FROM payments p" ++
             " JOIN members m ON m.id = p.member_id ORDER BY p.period_month", [], fn(s)
      "  " ++ sql/col-text(s, 0) ++ "  Rs " ++ sql/col-real(s, 1).show.pad-right(9) ++
      sql/col-text(s, 2).pad-right(14) ++ sql/col-text(s, 3)
    ).foreach(println)

    println("")
    println("settings:")
    sql/rows("SELECT key, value FROM settings ORDER BY key", [], fn(s)
      "  " ++ sql/col-text(s, 0).pad-right(22) ++ sql/col-text(s, 1)
    ).foreach(println)
    sql/close()
    ()
