// Opening the database, and the migrations that make an older one usable.
//
// The schema is the Rust build's schema, to the column. That is the whole
// point: an existing tenne.db opens with no conversion step.
module db

import sql
import win32

// The database sits next to the .exe, so the folder is portable. Note the
// cost, recorded in docs/tla/README.md: moving the .exe alone leaves the data
// behind, and backups/ is a sibling, so one deleted folder takes both.
pub fun db-path() : io string
  win32/exe-dir() ++ "/tenne.db"

// Take over a database left by the RocheCRM builds, which named it roche.db
// and its backups roche_*.db. Without this, an upgrade in place finds no
// tenne.db, silently creates a blank one beside the real data, and lists no
// backups either -- the whole history still on disk and entirely invisible.
//
// Does nothing once tenne.db exists, so it runs at most once.
pub fun adopt-legacy( path : string ) : io ()
  if sql/file-exists(path) then () else
    val dir = win32/exe-dir()
    val legacy = dir ++ "/roche.db"
    if !sql/file-exists(legacy) then () else
      if !win32/rename(legacy, path) then () else
        // a -wal belongs to the file it was written against; carry them over
        // together or the rename silently drops recent commits
        ["-wal", "-shm"].foreach fn(sfx)
          if sql/file-exists(legacy ++ sfx)
            then win32/rename(legacy ++ sfx, path ++ sfx).ignore
        val bdir = dir ++ "/backups"
        win32/listdir(bdir, "roche_*.db").foreach fn(name)
          val rest = name.list.drop(6).string
          win32/rename(bdir ++ "/" ++ name, bdir ++ "/tenne_" ++ rest).ignore


// The schema, statement by statement. Identical to the Rust build's, to the
// column: an existing tenne.db must open with no conversion step.
val schema : list<string> = [
  "CREATE TABLE IF NOT EXISTS members (id INTEGER PRIMARY KEY, name TEXT NOT NULL," ++
  " phone TEXT, address TEXT, join_date TEXT NOT NULL, active INTEGER NOT NULL DEFAULT 1," ++
  " notes TEXT, registration_fee_paid INTEGER NOT NULL DEFAULT 0)",
  "CREATE INDEX IF NOT EXISTS idx_members_name  ON members(name)",
  "CREATE INDEX IF NOT EXISTS idx_members_phone ON members(phone)",

  "CREATE TABLE IF NOT EXISTS payments (id INTEGER PRIMARY KEY, member_id INTEGER NOT NULL" ++
  " REFERENCES members(id) ON DELETE CASCADE, period_month TEXT NOT NULL, amount REAL NOT NULL," ++
  " date TEXT NOT NULL, note TEXT, category TEXT NOT NULL DEFAULT 'membership')",
  "CREATE INDEX IF NOT EXISTS idx_payments_period ON payments(period_month)",
  "CREATE INDEX IF NOT EXISTS idx_payments_member ON payments(member_id)",
  "CREATE INDEX IF NOT EXISTS idx_payments_date   ON payments(date)",

  "CREATE TABLE IF NOT EXISTS products (id INTEGER PRIMARY KEY, name TEXT NOT NULL," ++
  " price REAL NOT NULL, stock INTEGER NOT NULL DEFAULT 0, active INTEGER NOT NULL DEFAULT 1)",

  "CREATE TABLE IF NOT EXISTS sales (id INTEGER PRIMARY KEY, date TEXT NOT NULL, total REAL NOT NULL)",
  "CREATE INDEX IF NOT EXISTS idx_sales_date ON sales(date)",

  "CREATE TABLE IF NOT EXISTS sale_items (id INTEGER PRIMARY KEY, sale_id INTEGER NOT NULL" ++
  " REFERENCES sales(id) ON DELETE CASCADE, product_id INTEGER REFERENCES products(id)," ++
  " qty INTEGER NOT NULL, unit_price REAL NOT NULL)",
  "CREATE INDEX IF NOT EXISTS idx_sale_items_sale ON sale_items(sale_id)",

  "CREATE TABLE IF NOT EXISTS expenses (id INTEGER PRIMARY KEY, name TEXT NOT NULL DEFAULT ''," ++
  " amount REAL NOT NULL, date TEXT NOT NULL, note TEXT)",
  "CREATE INDEX IF NOT EXISTS idx_expenses_date ON expenses(date)",

  "CREATE TABLE IF NOT EXISTS recurring_expenses (id INTEGER PRIMARY KEY, name TEXT NOT NULL," ++
  " amount REAL NOT NULL)",

  "CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, value TEXT NOT NULL)"
]

// True if `table` already has a column named `column`.
pub fun has-column( table : string, column : string ) : io bool
  sql/rows("PRAGMA table_info(" ++ table ++ ")", [], fn(s) { sql/col-text(s, 1) })
    .any(fn(n) { n == column })

// Columns introduced after the initial schema. CREATE TABLE IF NOT EXISTS
// never alters an existing table, so new columns must be patched in here.
fun add-missing-columns() : io ()
  if !has-column("members", "registration_fee_paid") then
    sql/exec("ALTER TABLE members ADD COLUMN registration_fee_paid INTEGER NOT NULL DEFAULT 0").ignore
  if !has-column("members", "address") then
    sql/exec("ALTER TABLE members ADD COLUMN address TEXT").ignore
  if !has-column("payments", "category") then
    sql/exec("ALTER TABLE payments ADD COLUMN category TEXT NOT NULL DEFAULT 'membership'").ignore
  if !has-column("expenses", "name") then
    sql/exec("ALTER TABLE expenses ADD COLUMN name TEXT NOT NULL DEFAULT ''").ignore
  // Records the moment a row was entered, so same-day transactions order by
  // real time. ALTER ADD COLUMN cannot take a dynamic default, so add it
  // nullable and backfill from the (day-only) date.
  ["payments", "sales", "expenses"].foreach fn(t)
    if !has-column(t, "created_at") then
      sql/exec("ALTER TABLE " ++ t ++ " ADD COLUMN created_at TEXT").ignore
      sql/exec("UPDATE " ++ t ++ " SET created_at = date WHERE created_at IS NULL").ignore

val defaults = [("default_monthly_fee", "1500"), ("currency", "Rs"),
                ("gym_name", "My Gym"), ("registration_fee", "500")]

pub fun migrate() : io bool
  if !schema.all(fn(s) { sql/exec(s) }) then False
  else
    add-missing-columns()
    defaults.foreach fn(kv)
      sql/exec("INSERT OR IGNORE INTO settings(key, value) VALUES ('" ++
               kv.fst ++ "', '" ++ kv.snd ++ "')").ignore
    True

// Open (creating if needed) the database and bring the schema up to date.
pub fun open-db( path : string ) : io bool
  adopt-legacy(path)
  if !sql/open(path) then False else migrate()
