// Stub for ucol_setStrength_android - missing symbol in One UI 9 ICU library
// This allows Android 17 libsqlite.so to load without crashing

typedef void* UCollator;
typedef enum {
    UCOL_PRIMARY = 0,
    UCOL_SECONDARY = 1,
    UCOL_TERTIARY = 2,
    UCOL_DEFAULT_STRENGTH = 2,
    UCOL_QUATERNARY = 3,
    UCOL_IDENTICAL = 15
} UCollationStrength;

// Stub function - does nothing but prevents linker error
// Mark parameters as unused to suppress -Werror,-Wunused-parameter
void ucol_setStrength_android(UCollator* coll __attribute__((unused)),
                               UCollationStrength strength __attribute__((unused))) {
    // No-op stub - SQLite will work without this since it's just a collation strength setter
    // In worst case, string comparisons might be slightly less precise, but data won't be corrupted
    return;
}
