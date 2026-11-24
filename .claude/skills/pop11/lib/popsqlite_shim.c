/* popsqlite_shim.c — non-variadic C surface over sqlite3 for Pop-11.
 *
 * Why a shim (the sqlite3 API is already non-variadic): it flattens the
 * awkward-for-FFI parts — out-parameters (sqlite3_open's sqlite3**,
 * prepare's stmt**), the SQLITE_TRANSIENT destructor pointer on binds,
 * int64 rowids, and NULL-pointer results — into a surface of plain ints
 * and strings. Databases and statements are small integer handles
 * (>= 1; 0 means failure — read psq_errmsg), so the Pop-11 side never
 * holds a raw pointer. Single-threaded by design, like the session.
 *
 * Build: bin/build-popsqlite  (cc -O2 -shared -o popsqlite.{dylib,so}
 *        ... -lsqlite3)
 *
 * Column indices are 0-based (sqlite3_column_*), bind indices 1-based
 * (sqlite3_bind_*) — same as the sqlite C API; the generated Pop-11
 * loader hides both behind whole-row procedures.
 */
#include <sqlite3.h>
#include <stdio.h>
#include <string.h>

#define MAX_DB   32
#define MAX_STMT 256

static sqlite3      *dbs[MAX_DB + 1];
static sqlite3_stmt *stmts[MAX_STMT + 1];
static char last_err[512];
static char rowid_buf[32];

static void set_err(const char *msg) {
    snprintf(last_err, sizeof last_err, "%s", msg ? msg : "unknown error");
}

const char *psq_version(void) { return sqlite3_libversion(); }

#ifdef __CYGWIN__
/* Cygwin: SQLite's allocation calls are redirected to the routines below.
 *
 * Poplog supplies its own malloc, and on Cygwin a program's malloc serves
 * every DLL in the process.  malloc_usable_size is not part of that
 * arrangement: once malloc has been replaced, cygwin1.dll's answers 0 for
 * every block.  Cygwin's SQLite sizes its hash tables from that answer, so
 * the first sqlite3_open divided by zero (signal 8, which ends a Poplog
 * process).  Nor does this SQLite build call an allocator installed with
 * sqlite3_config(SQLITE_CONFIG_MALLOC): it accepts one and goes on using
 * the C library (measured, 3.49.1-1).
 *
 * What is left is the SQLite DLL's import table.  Its entries for malloc,
 * calloc, realloc, free and malloc_usable_size are pointed at wrappers that
 * keep each block's size in a 16-byte header of their own, so that the
 * size can be answered without asking the C library.  The header carries a
 * tag: a block that does not have it came from somewhere else and is
 * passed through untouched.  Done once, before SQLite first allocates.
 */
#include <stdlib.h>
#include <windows.h>

#define PM_TAG 0x706f7073716c6974ULL    /* "popsqlit" */
typedef struct { unsigned long long tag; size_t size; } pm_hdr;

static int pm_ours(void *q) { return q && ((pm_hdr *) q)[-1].tag == PM_TAG; }

static void *pm_malloc(size_t n) {
    pm_hdr *h = malloc(n + sizeof(pm_hdr));
    if (!h) return NULL;
    h->tag = PM_TAG; h->size = n;
    return h + 1;
}
static void *pm_calloc(size_t count, size_t each) {
    size_t n = count * each;
    void *q;
    if (each && n / each != count) return NULL;
    if ((q = pm_malloc(n))) memset(q, 0, n);
    return q;
}
static void pm_free(void *q) {
    if (!pm_ours(q)) { free(q); return; }
    ((pm_hdr *) q)[-1].tag = 0;
    free((pm_hdr *) q - 1);
}
static void *pm_realloc(void *q, size_t n) {
    pm_hdr *h;
    if (!q) return pm_malloc(n);
    if (!pm_ours(q)) return realloc(q, n);
    if (!(h = realloc((pm_hdr *) q - 1, n + sizeof(pm_hdr)))) return NULL;
    h->size = n;
    return h + 1;
}
static size_t pm_usable_size(void *q) {
    return pm_ours(q) ? ((pm_hdr *) q)[-1].size : 0;
}

static void pm_redirect(unsigned char *base, const char *name, void *fn) {
    IMAGE_NT_HEADERS *nt =
        (IMAGE_NT_HEADERS *) (base + ((IMAGE_DOS_HEADER *) base)->e_lfanew);
    IMAGE_DATA_DIRECTORY dir =
        nt->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_IMPORT];
    IMAGE_IMPORT_DESCRIPTOR *imp;
    if (!dir.VirtualAddress) return;
    for (imp = (IMAGE_IMPORT_DESCRIPTOR *) (base + dir.VirtualAddress);
         imp->Name; imp++) {
        IMAGE_THUNK_DATA *names, *slots;
        if (!imp->OriginalFirstThunk) continue;
        names = (IMAGE_THUNK_DATA *) (base + imp->OriginalFirstThunk);
        slots = (IMAGE_THUNK_DATA *) (base + imp->FirstThunk);
        for (; names->u1.AddressOfData; names++, slots++) {
            IMAGE_IMPORT_BY_NAME *by;
            DWORD old;
            if (IMAGE_SNAP_BY_ORDINAL(names->u1.Ordinal)) continue;
            by = (IMAGE_IMPORT_BY_NAME *) (base + names->u1.AddressOfData);
            if (strcmp((const char *) by->Name, name) != 0) continue;
            if (!VirtualProtect(slots, sizeof *slots, PAGE_READWRITE, &old))
                continue;
            slots->u1.Function = (ULONG_PTR) fn;
            VirtualProtect(slots, sizeof *slots, old, &old);
        }
    }
}

static void psq_setup(void) {
    static int done;
    HMODULE mod;
    if (done) return;
    done = 1;
    /* the version string lives in SQLite's DLL, which is how to find it */
    if (!GetModuleHandleExA(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS
                            | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                            (LPCSTR) sqlite3_libversion(), &mod))
        return;
    pm_redirect((unsigned char *) mod, "malloc", pm_malloc);
    pm_redirect((unsigned char *) mod, "calloc", pm_calloc);
    pm_redirect((unsigned char *) mod, "realloc", pm_realloc);
    pm_redirect((unsigned char *) mod, "free", pm_free);
    pm_redirect((unsigned char *) mod, "malloc_usable_size", pm_usable_size);
}
#else
#define psq_setup()
#endif

/* Most recent error: per-db if the handle is live, else the saved one
 * (covers failed open/prepare where no live handle exists). */
const char *psq_errmsg(int db) {
    if (db >= 1 && db <= MAX_DB && dbs[db]) return sqlite3_errmsg(dbs[db]);
    return last_err;
}

int psq_open(const char *path) {
    int h;
    psq_setup();
    for (h = 1; h <= MAX_DB && dbs[h]; h++) ;
    if (h > MAX_DB) { set_err("too many open databases"); return 0; }
    sqlite3 *db = NULL;
    if (sqlite3_open(path, &db) != SQLITE_OK) {
        set_err(db ? sqlite3_errmsg(db) : "out of memory");
        if (db) sqlite3_close(db);
        return 0;
    }
    dbs[h] = db;
    return h;
}

int psq_close(int db) {
    if (db < 1 || db > MAX_DB || !dbs[db]) return SQLITE_MISUSE;
    /* finalize any statements still open on this db */
    for (int s = 1; s <= MAX_STMT; s++)
        if (stmts[s] && sqlite3_db_handle(stmts[s]) == dbs[db]) {
            sqlite3_finalize(stmts[s]);
            stmts[s] = NULL;
        }
    int rc = sqlite3_close(dbs[db]);
    if (rc == SQLITE_OK) dbs[db] = NULL;
    return rc;
}

int psq_exec(int db, const char *sql) {
    if (db < 1 || db > MAX_DB || !dbs[db]) return SQLITE_MISUSE;
    char *err = NULL;
    int rc = sqlite3_exec(dbs[db], sql, NULL, NULL, &err);
    if (err) { set_err(err); sqlite3_free(err); }
    return rc;
}

int psq_prepare(int db, const char *sql) {
    if (db < 1 || db > MAX_DB || !dbs[db]) { set_err("bad db handle"); return 0; }
    int s;
    for (s = 1; s <= MAX_STMT && stmts[s]; s++) ;
    if (s > MAX_STMT) { set_err("too many open statements"); return 0; }
    sqlite3_stmt *st = NULL;
    if (sqlite3_prepare_v2(dbs[db], sql, -1, &st, NULL) != SQLITE_OK) {
        set_err(sqlite3_errmsg(dbs[db]));
        return 0;
    }
    if (!st) { set_err("empty statement"); return 0; }
    stmts[s] = st;
    return s;
}

static sqlite3_stmt *st_of(int s) {
    return (s >= 1 && s <= MAX_STMT) ? stmts[s] : NULL;
}

int psq_step(int s) {          /* 100 = row, 101 = done, else error rc */
    sqlite3_stmt *st = st_of(s);
    return st ? sqlite3_step(st) : SQLITE_MISUSE;
}

int psq_reset(int s) {
    sqlite3_stmt *st = st_of(s);
    return st ? sqlite3_reset(st) : SQLITE_MISUSE;
}

int psq_finalize(int s) {
    sqlite3_stmt *st = st_of(s);
    if (!st) return SQLITE_MISUSE;
    int rc = sqlite3_finalize(st);
    stmts[s] = NULL;
    return rc;
}

int psq_col_count(int s) {
    sqlite3_stmt *st = st_of(s);
    return st ? sqlite3_column_count(st) : 0;
}

const char *psq_col_name(int s, int i) {
    sqlite3_stmt *st = st_of(s);
    const char *n = st ? sqlite3_column_name(st, i) : NULL;
    return n ? n : "";
}

/* Everything comes back as text ("" for SQL NULL — disambiguate with
 * psq_col_is_null). Text round-trips are lossless under sqlite's dynamic
 * typing, and keeping doubles/int64 out of the FFI surface sidesteps
 * per-port float-ABI questions; typed accessors can come in v0.2. */
const char *psq_col_text(int s, int i) {
    sqlite3_stmt *st = st_of(s);
    const unsigned char *t = st ? sqlite3_column_text(st, i) : NULL;
    return t ? (const char *)t : "";
}

int psq_col_is_null(int s, int i) {
    sqlite3_stmt *st = st_of(s);
    return (st && sqlite3_column_type(st, i) == SQLITE_NULL) ? 1 : 0;
}

int psq_bind_text(int s, int i, const char *v) {
    sqlite3_stmt *st = st_of(s);
    return st ? sqlite3_bind_text(st, i, v, -1, SQLITE_TRANSIENT)
              : SQLITE_MISUSE;
}

int psq_changes(int db) {
    if (db < 1 || db > MAX_DB || !dbs[db]) return 0;
    return sqlite3_changes(dbs[db]);
}

const char *psq_last_rowid(int db) {
    if (db < 1 || db > MAX_DB || !dbs[db]) return "0";
    snprintf(rowid_buf, sizeof rowid_buf, "%lld",
             (long long)sqlite3_last_insert_rowid(dbs[db]));
    return rowid_buf;
}
