// Stubs for missing ICU and SQLite symbols in One UI 9
// ucol_setStrength_android: missing in One UI 9 ICU, required by Android 17 libsqlite.so
// sqlite3_changes64: missing in both recovery and Android 17 libsqlite.so, required by keystore2

#include <stdint.h>
#include <dlfcn.h>

typedef void* UCollator;
typedef enum {
    UCOL_PRIMARY = 0,
    UCOL_SECONDARY = 1,
    UCOL_TERTIARY = 2,
    UCOL_DEFAULT_STRENGTH = 2,
    UCOL_QUATERNARY = 3,
    UCOL_IDENTICAL = 15
} UCollationStrength;

typedef struct sqlite3 sqlite3;

// Stub function - does nothing but prevents linker error
// Mark parameters as unused to suppress -Werror,-Wunused-parameter
void ucol_setStrength_android(UCollator* coll __attribute__((unused)),
                               UCollationStrength strength __attribute__((unused))) {
    // No-op stub - SQLite will work without this since it's just a collation strength setter
    // In worst case, string comparisons might be slightly less precise, but data won't be corrupted
    return;
}

// sqlite3_changes64: 64-bit version of sqlite3_changes (returns number of rows modified)
// This symbol exists in newer SQLite versions but is missing from both Android 17 and recovery
// libsqlite.so. We forward to the 32-bit sqlite3_changes() which is present.
// Use dlsym to find sqlite3_changes at runtime instead of linking directly.
__attribute__((weak))
int64_t sqlite3_changes64(sqlite3* db) {
    typedef int (*sqlite3_changes_fn)(sqlite3*);
    static sqlite3_changes_fn real_sqlite3_changes = NULL;

    if (!real_sqlite3_changes) {
        // Find sqlite3_changes in the already-loaded libsqlite.so
        real_sqlite3_changes = (sqlite3_changes_fn)dlsym(RTLD_DEFAULT, "sqlite3_changes");
        if (!real_sqlite3_changes) {
            // Fallback: return 0 if we can't find it
            return 0;
        }
    }

    return (int64_t)real_sqlite3_changes(db);
}
