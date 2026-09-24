// Migrations must bring a database written by an OLDER build up to date
// without touching the rows already in it.
module dbtest
import sql
import db

fun check( fails : ref<global,int>, name : string, got : string, want : string ) : io ()
  val ok = got == want
  if !ok then fails := !fails + 1
  println((if ok then "  ok   " else "  FAIL ") ++ name.pad-right(40) ++ got.pad-right(12) ++
          (if ok then "" else "want " ++ want))

pub fun main() : io ()
  val f = ref(0)
  val p = "out/migrate.db"
  if sql/file-exists(p) then sql/remove-file(p).ignore

  // Build a database the way the FIRST release did: no address, no category,
  // no created_at, no expenses.name. Then put real rows in it.
  sql/open(p).ignore
  sql/exec("CREATE TABLE members (id INTEGER PRIMARY KEY, name TEXT NOT NULL, phone TEXT," ++
           " join_date TEXT NOT NULL, active INTEGER NOT NULL DEFAULT 1, notes TEXT)").ignore
  sql/exec("CREATE TABLE payments (id INTEGER PRIMARY KEY, member_id INTEGER NOT NULL," ++
           " period_month TEXT NOT NULL, amount REAL NOT NULL, date TEXT NOT NULL, note TEXT)").ignore
  sql/exec("CREATE TABLE expenses (id INTEGER PRIMARY KEY, amount REAL NOT NULL," ++
           " date TEXT NOT NULL, note TEXT)").ignore
  sql/exec("INSERT INTO members(name, phone, join_date) VALUES ('Priya','986201','2024-11-03')").ignore
  sql/exec("INSERT INTO payments(member_id, period_month, amount, date)" ++
           " VALUES (1,'2025-07',1500,'2025-07-05')").ignore
  sql/exec("INSERT INTO expenses(amount, date) VALUES (4000,'2025-07-01')").ignore
  sql/close().ignore

  // Now open it the way the current build does.
  check(f, "old database migrates", db/open-db(p).show, "True")

  check(f, "members.address added", db/has-column("members","address").show, "True")
  check(f, "members.registration_fee_paid added", db/has-column("members","registration_fee_paid").show, "True")
  check(f, "payments.category added", db/has-column("payments","category").show, "True")
  check(f, "expenses.name added", db/has-column("expenses","name").show, "True")
  check(f, "payments.created_at added", db/has-column("payments","created_at").show, "True")
  check(f, "sales.created_at added", db/has-column("sales","created_at").show, "True")
  check(f, "expenses.created_at added", db/has-column("expenses","created_at").show, "True")

  // the rows that were already there must survive untouched
  check(f, "existing member kept", sql/scalar-int("SELECT COUNT(*) FROM members",[],-1).show, "1")
  check(f, "existing member name kept",
        sql/select("SELECT name FROM members",[],"",fn(_a,s){sql/col-text(s,0)}), "Priya")
  check(f, "existing payment kept", sql/scalar-int("SELECT COUNT(*) FROM payments",[],-1).show, "1")

  // new columns take the documented defaults, not NULL
  check(f, "category defaults to membership",
        sql/select("SELECT category FROM payments",[],"",fn(_a,s){sql/col-text(s,0)}), "membership")
  check(f, "created_at backfilled from date",
        sql/select("SELECT created_at FROM payments",[],"",fn(_a,s){sql/col-text(s,0)}), "2025-07-05")

  // tables the old build never had
  check(f, "products table created", sql/scalar-int("SELECT COUNT(*) FROM products",[],-1).show, "0")
  check(f, "recurring_expenses created", sql/scalar-int("SELECT COUNT(*) FROM recurring_expenses",[],-1).show, "0")

  // seeded settings
  check(f, "default_monthly_fee seeded",
        sql/select("SELECT value FROM settings WHERE key='default_monthly_fee'",[],"",fn(_a,s){sql/col-text(s,0)}), "1500")
  check(f, "currency seeded",
        sql/select("SELECT value FROM settings WHERE key='currency'",[],"",fn(_a,s){sql/col-text(s,0)}), "Rs")

  // migrating twice must be a no-op, not an error
  check(f, "migrate is idempotent", db/migrate().show, "True")
  check(f, "still one member", sql/scalar-int("SELECT COUNT(*) FROM members",[],-1).show, "1")
  sql/close().ignore

  println(if !f == 0 then "ALL PASS" else "FAILED: " ++ (!f).show)
