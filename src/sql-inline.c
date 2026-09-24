/*---------------------------------------------------------------------------
#include <stdio.h>
  SQLite, as thin a wrapper as the FFI allows.

  We keep the amalgamation because the whole point is that an existing
  tenne.db opens unchanged. Writing our own file format would mean writing a
  migration for real gym data, which is a worse trade than one C file.

  Handles are small integers into fixed tables rather than pointers cast to
  ints -- the pointer would be a lie Koka's integer type is under no
  obligation to keep.

  Naming: Koka mangles module `sql` + `f` to `kk_sql_f`, so the C side is
  `kk_dbx_*` and cannot collide.
---------------------------------------------------------------------------*/
#include "sqlite3.h"

#define DBX_MAXSTMT 64

static sqlite3 *g_db = 0;
static sqlite3_stmt *g_stmt[DBX_MAXSTMT];
static char g_err[512];

static int dbx_slot(void) {
  int i;
  for (i = 0; i < DBX_MAXSTMT; i++)
    if (!g_stmt[i]) return i;
  return -1;
}

static void dbx_seterr(const char *what) {
  const char *m = g_db ? sqlite3_errmsg(g_db) : "no database open";
  snprintf(g_err, sizeof(g_err), "%s: %s", what, m ? m : "?");
}

static bool kk_dbx_open(kk_string_t path, kk_context_t *ctx) {
  kk_ssize_t len;
  const char *cs = kk_string_cbuf_borrow(path, &len, ctx);
  int rc = sqlite3_open(cs, &g_db);
  kk_string_drop(path, ctx);
  if (rc != SQLITE_OK) { dbx_seterr("open"); return false; }
  /* WAL, as the Rust build used, so an existing -wal is understood. */
  sqlite3_exec(g_db, "PRAGMA journal_mode=WAL", 0, 0, 0);
  sqlite3_exec(g_db, "PRAGMA foreign_keys=ON", 0, 0, 0);
  sqlite3_busy_timeout(g_db, 3000);
  return true;
}

static bool kk_dbx_close(kk_context_t *ctx) {
  int i;
  kk_unused(ctx);
  for (i = 0; i < DBX_MAXSTMT; i++) {
    if (g_stmt[i]) { sqlite3_finalize(g_stmt[i]); g_stmt[i] = 0; }
  }
  if (g_db) { sqlite3_close(g_db); g_db = 0; }
  return true;
}

static bool kk_dbx_exec(kk_string_t sql, kk_context_t *ctx) {
  kk_ssize_t len;
  const char *cs = kk_string_cbuf_borrow(sql, &len, ctx);
  char *err = 0;
  int rc = sqlite3_exec(g_db, cs, 0, 0, &err);
  kk_string_drop(sql, ctx);
  if (rc != SQLITE_OK) {
    snprintf(g_err, sizeof(g_err), "exec: %s", err ? err : "?");
    if (err) sqlite3_free(err);
    return false;
  }
  return true;
}

/* Returns a statement handle, or -1. */
static kk_integer_t kk_dbx_prepare(kk_string_t sql, kk_context_t *ctx) {
  kk_ssize_t len;
  const char *cs = kk_string_cbuf_borrow(sql, &len, ctx);
  int s = dbx_slot();
  sqlite3_stmt *st = 0;
  int rc;
  if (s < 0) {
    kk_string_drop(sql, ctx);
    snprintf(g_err, sizeof(g_err), "prepare: out of statement slots");
    return kk_integer_from_int(-1, ctx);
  }
  rc = sqlite3_prepare_v2(g_db, cs, (int)len, &st, 0);
  kk_string_drop(sql, ctx);
  if (rc != SQLITE_OK || !st) { dbx_seterr("prepare"); return kk_integer_from_int(-1, ctx); }
  g_stmt[s] = st;
  return kk_integer_from_int(s, ctx);
}

static sqlite3_stmt *dbx_get(kk_integer_t h, kk_context_t *ctx) {
  int i = kk_integer_clamp32(h, ctx);
  if (i < 0 || i >= DBX_MAXSTMT) return 0;
  return g_stmt[i];
}

/* 1 = a row is available, 0 = done, -1 = error. */
static kk_integer_t kk_dbx_step(kk_integer_t h, kk_context_t *ctx) {
  sqlite3_stmt *st = dbx_get(h, ctx);
  int rc;
  if (!st) return kk_integer_from_int(-1, ctx);
  rc = sqlite3_step(st);
  if (rc == SQLITE_ROW) return kk_integer_from_int(1, ctx);
  if (rc == SQLITE_DONE) return kk_integer_from_int(0, ctx);
  dbx_seterr("step");
  return kk_integer_from_int(-1, ctx);
}

static kk_unit_t kk_dbx_finalize(kk_integer_t h, kk_context_t *ctx) {
  int i = kk_integer_clamp32(h, ctx);
  if (i >= 0 && i < DBX_MAXSTMT && g_stmt[i]) {
    sqlite3_finalize(g_stmt[i]);
    g_stmt[i] = 0;
  }
  return kk_Unit;
}

static kk_unit_t kk_dbx_reset(kk_integer_t h, kk_context_t *ctx) {
  sqlite3_stmt *st = dbx_get(h, ctx);
  if (st) { sqlite3_reset(st); sqlite3_clear_bindings(st); }
  return kk_Unit;
}

/*--- binding (1-based, as SQLite counts) ---------------------------------*/

static kk_unit_t kk_dbx_bind_text(kk_integer_t h, kk_integer_t i, kk_string_t v,
                                  kk_context_t *ctx) {
  sqlite3_stmt *st = dbx_get(h, ctx);
  kk_ssize_t len;
  const char *cs = kk_string_cbuf_borrow(v, &len, ctx);
  if (st) sqlite3_bind_text(st, kk_integer_clamp32(i, ctx), cs, (int)len, SQLITE_TRANSIENT);
  kk_string_drop(v, ctx);
  return kk_Unit;
}

static kk_unit_t kk_dbx_bind_int(kk_integer_t h, kk_integer_t i, kk_integer_t v,
                                 kk_context_t *ctx) {
  sqlite3_stmt *st = dbx_get(h, ctx);
  if (st) sqlite3_bind_int64(st, kk_integer_clamp32(i, ctx), kk_integer_clamp64(v, ctx));
  return kk_Unit;
}

static kk_unit_t kk_dbx_bind_real(kk_integer_t h, kk_integer_t i, double v,
                                  kk_context_t *ctx) {
  sqlite3_stmt *st = dbx_get(h, ctx);
  if (st) sqlite3_bind_double(st, kk_integer_clamp32(i, ctx), v);
  return kk_Unit;
}

static kk_unit_t kk_dbx_bind_null(kk_integer_t h, kk_integer_t i, kk_context_t *ctx) {
  sqlite3_stmt *st = dbx_get(h, ctx);
  if (st) sqlite3_bind_null(st, kk_integer_clamp32(i, ctx));
  return kk_Unit;
}

/*--- reading (0-based, as SQLite counts) ---------------------------------*/

static kk_string_t kk_dbx_col_text(kk_integer_t h, kk_integer_t i, kk_context_t *ctx) {
  sqlite3_stmt *st = dbx_get(h, ctx);
  const unsigned char *s;
  if (!st) return kk_string_empty();
  s = sqlite3_column_text(st, kk_integer_clamp32(i, ctx));
  if (!s) return kk_string_empty();
  return kk_string_alloc_from_utf8((const char *)s, ctx);
}

static kk_integer_t kk_dbx_col_int(kk_integer_t h, kk_integer_t i, kk_context_t *ctx) {
  sqlite3_stmt *st = dbx_get(h, ctx);
  if (!st) return kk_integer_from_int(0, ctx);
  return kk_integer_from_int64(sqlite3_column_int64(st, kk_integer_clamp32(i, ctx)), ctx);
}

static double kk_dbx_col_real(kk_integer_t h, kk_integer_t i, kk_context_t *ctx) {
  sqlite3_stmt *st = dbx_get(h, ctx);
  if (!st) return 0.0;
  return sqlite3_column_double(st, kk_integer_clamp32(i, ctx));
}

static bool kk_dbx_col_null(kk_integer_t h, kk_integer_t i, kk_context_t *ctx) {
  sqlite3_stmt *st = dbx_get(h, ctx);
  if (!st) return true;
  return sqlite3_column_type(st, kk_integer_clamp32(i, ctx)) == SQLITE_NULL;
}

static kk_integer_t kk_dbx_col_count(kk_integer_t h, kk_context_t *ctx) {
  sqlite3_stmt *st = dbx_get(h, ctx);
  return kk_integer_from_int(st ? sqlite3_column_count(st) : 0, ctx);
}

static kk_string_t kk_dbx_col_name(kk_integer_t h, kk_integer_t i, kk_context_t *ctx) {
  sqlite3_stmt *st = dbx_get(h, ctx);
  const char *s;
  if (!st) return kk_string_empty();
  s = sqlite3_column_name(st, kk_integer_clamp32(i, ctx));
  return s ? kk_string_alloc_from_utf8(s, ctx) : kk_string_empty();
}

/*--- odds and ends --------------------------------------------------------*/

static kk_integer_t kk_dbx_last_id(kk_context_t *ctx) {
  return kk_integer_from_int64(g_db ? sqlite3_last_insert_rowid(g_db) : 0, ctx);
}

static kk_integer_t kk_dbx_changes(kk_context_t *ctx) {
  return kk_integer_from_int(g_db ? sqlite3_changes(g_db) : 0, ctx);
}

static kk_string_t kk_dbx_error(kk_context_t *ctx) {
  return kk_string_alloc_from_utf8(g_err, ctx);
}

/* VACUUM INTO, not a file copy. Durability.tla, BackupsAreHonest: in WAL mode
   the main file is not the database, so copying it can capture a file that
   does not contain the recent commits -- on a young database, not even the
   schema. VACUUM INTO asks SQLite for a consistent snapshot and is correct
   whatever the -wal holds. */
static bool kk_dbx_backup_into(kk_string_t path, kk_context_t *ctx) {
  kk_ssize_t len;
  const char *cs = kk_string_cbuf_borrow(path, &len, ctx);
  sqlite3_stmt *st = 0;
  char *sql = sqlite3_mprintf("VACUUM INTO %Q", cs);
  int rc;
  kk_string_drop(path, ctx);
  if (!sql) return false;
  rc = sqlite3_prepare_v2(g_db, sql, -1, &st, 0);
  if (rc == SQLITE_OK && st) {
    rc = sqlite3_step(st);
    sqlite3_finalize(st);
    rc = (rc == SQLITE_DONE) ? SQLITE_OK : rc;
  }
  sqlite3_free(sql);
  if (rc != SQLITE_OK) { dbx_seterr("backup"); return false; }
  return true;
}

/* VACUUM INTO refuses to overwrite, so the target must not exist. Every
   caller that reuses a path needs this first. */
static bool kk_dbx_remove(kk_string_t path, kk_context_t *ctx) {
  kk_ssize_t len;
  const char *cs = kk_string_cbuf_borrow(path, &len, ctx);
  int rc = remove(cs);
  kk_string_drop(path, ctx);
  return rc == 0;
}

static bool kk_dbx_exists(kk_string_t path, kk_context_t *ctx) {
  kk_ssize_t len;
  const char *cs = kk_string_cbuf_borrow(path, &len, ctx);
  FILE *f = fopen(cs, "rb");
  kk_string_drop(path, ctx);
  if (f) { fclose(f); return true; }
  return false;
}

/* Unbuffer stdout. Without this a crash swallows every println that had not
   yet flushed, and the failure looks like it happened at startup. */
static kk_unit_t kk_dbx_unbuffer(kk_context_t *ctx) {
  kk_unused(ctx);
  setvbuf(stdout, NULL, _IONBF, 0);
  setvbuf(stderr, NULL, _IONBF, 0);
  return kk_Unit;
}
