// SQLite, as thin a wrapper as the FFI allows. The point of keeping the
// amalgamation is that an existing tenne.db opens unchanged.
module sql

import std/num/float64

extern import
  c file "sql-inline.c"

pub alias stmt = int

pub extern open( path : string ) : io bool
  c "kk_dbx_open"

pub extern close() : io bool
  c "kk_dbx_close"

pub extern exec( sql : string ) : io bool
  c "kk_dbx_exec"

pub extern prepare( sql : string ) : io stmt
  c "kk_dbx_prepare"

// 1 = a row is available, 0 = done, -1 = error.
pub extern step( s : stmt ) : io int
  c "kk_dbx_step"

pub extern finalize( s : stmt ) : io ()
  c "kk_dbx_finalize"

pub extern reset( s : stmt ) : io ()
  c "kk_dbx_reset"

pub extern bind-text( s : stmt, i : int, v : string ) : io ()
  c "kk_dbx_bind_text"

pub extern bind-int( s : stmt, i : int, v : int ) : io ()
  c "kk_dbx_bind_int"

pub extern bind-real( s : stmt, i : int, v : float64 ) : io ()
  c "kk_dbx_bind_real"

pub extern bind-null( s : stmt, i : int ) : io ()
  c "kk_dbx_bind_null"

pub extern col-text( s : stmt, i : int ) : io string
  c "kk_dbx_col_text"

pub extern col-int( s : stmt, i : int ) : io int
  c "kk_dbx_col_int"

pub extern col-real( s : stmt, i : int ) : io float64
  c "kk_dbx_col_real"

pub extern col-null( s : stmt, i : int ) : io bool
  c "kk_dbx_col_null"

pub extern col-count( s : stmt ) : io int
  c "kk_dbx_col_count"

pub extern col-name( s : stmt, i : int ) : io string
  c "kk_dbx_col_name"

pub extern last-id() : io int
  c "kk_dbx_last_id"

pub extern changes() : io int
  c "kk_dbx_changes"

pub extern error() : io string
  c "kk_dbx_error"

// VACUUM INTO, not a file copy -- see Durability.tla, BackupsAreHonest.
pub extern backup-into( path : string ) : io bool
  c "kk_dbx_backup_into"

// --- comfort ------------------------------------------------------------

// A nullable TEXT column, as the schema actually uses it.
pub fun col-text-opt( s : stmt, i : int ) : io maybe<string>
  if col-null(s, i) then Nothing else Just(col-text(s, i))

// Run a prepared statement to exhaustion, folding each row.
pub fun query( s : stmt, acc : a, f : (a, stmt) -> io a ) : io a
  val rc = step(s)
  if rc == 1 then query(s, f(acc, s), f)
  else acc

// Prepare, bind, fold, finalize. The shape almost every read takes.
pub fun select( sql : string, binds : list<string>, acc : a,
                f : (a, stmt) -> io a ) : io a
  val s = prepare(sql)
  if s < 0 then acc
  else
    binds.foreach-indexed fn(i, v) { bind-text(s, i + 1, v) }
    val r = query(s, acc, f)
    finalize(s)
    r

// Collect rows into a list, in query order.
pub fun rows( sql : string, binds : list<string>, f : (stmt) -> io a ) : io list<a>
  select(sql, binds, [], fn(acc, s) { Cons(f(s), acc) }).reverse

pub fun scalar-int( sql : string, binds : list<string>, dflt : int ) : io int
  select(sql, binds, dflt, fn(_acc, s) { col-int(s, 0) })

pub fun scalar-real( sql : string, binds : list<string>, dflt : float64 ) : io float64
  select(sql, binds, dflt, fn(_acc, s) { col-real(s, 0) })

// Delete a file. VACUUM INTO refuses to overwrite, so a backup target that
// already exists must be cleared first.
pub extern remove-file( path : string ) : io bool
  c "kk_dbx_remove"

pub extern file-exists( path : string ) : io bool
  c "kk_dbx_exists"

// An honest backup: clear the target, then ask SQLite for a consistent
// snapshot. Never a file copy -- see Durability.tla, BackupsAreHonest.
pub fun backup-to( path : string ) : io bool
  if file-exists(path) then
    remove-file(path)
    ()
  backup-into(path)

// Prepare, bind by hand, fold, finalize. The typed counterpart to `select`,
// for the many queries that bind an int or a float rather than a string.
pub fun query-with( sqltext : string, bind : (stmt) -> io (),
                    acc : a, f : (a, stmt) -> io a ) : io a
  val s = prepare(sqltext)
  if s < 0 then acc
  else
    bind(s)
    val r = query(s, acc, f)
    finalize(s)
    r

pub fun rows-with( sqltext : string, bind : (stmt) -> io (),
                   f : (stmt) -> io a ) : io list<a>
  query-with(sqltext, bind, [], fn(acc, s) { Cons(f(s), acc) }).reverse

pub fun exec-with( sqltext : string, bind : (stmt) -> io () ) : io bool
  val s = prepare(sqltext)
  if s < 0 then False
  else
    bind(s)
    val rc = step(s)
    finalize(s)
    rc >= 0

pub fun int-with( sqltext : string, bind : (stmt) -> io (), dflt : int ) : io int
  query-with(sqltext, bind, dflt, fn(_a, s) { col-int(s, 0) })

pub fun real-with( sqltext : string, bind : (stmt) -> io (), dflt : float64 ) : io float64
  query-with(sqltext, bind, dflt, fn(_a, s) { col-real(s, 0) })

// Bind a nullable TEXT the way the schema means it: absent is NULL, never "".
pub fun bind-text-opt( s : stmt, i : int, v : maybe<string> ) : io ()
  match v
    Just(t) -> bind-text(s, i, t)
    Nothing -> bind-null(s, i)

// Unbuffer stdout, so a crash does not swallow the output that would have
// said where it happened.
pub extern unbuffer() : io ()
  c "kk_dbx_unbuffer"
