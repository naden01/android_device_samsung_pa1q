/*
 * de_keyinstall - install the systemwide FBE "device" (DE) key into the kernel
 * keyring, for TWRP on the Android-12 base running the Android-16 security stack
 * from the firmware dump.
 *
 * WHY (see also git history WIP33): after decrypt.sh mounts the metadata layer
 * (dm-default-key -> /data on dm-8), the per-file FBE layer is still locked
 * (/data/misc, /data/system_de/0 show encrypted names, /proc/keys has 0 fscrypt
 * keys). The first FBE domino is the systemwide DE key. Normal boot installs it via
 * init's `installkey /data` BEFORE init_user0; the A16 vdc has no command for it.
 *
 * KEY MATERIAL (plaintext-at-rest in /data/unencrypted/key/):
 *   keymaster_key_blob (541B) - the KeyMint AES-GCM KEK (NOT a storage key: WIP33 proved
 *                               convertStorageKeyToEphemeral on it -> INVALID_KEY_BLOB)
 *   encrypted_key      (671B) - AES-256-GCM(storage-key-blob, KEK, appId) = [12B nonce][ct][16B tag]
 *   secdiscardable     (16384B) - personalised SHA512 -> appId (secure-delete entropy)
 * policy /data/unencrypted/mode = aes-256-xts:aes-256-cts:v2+inlinecrypt_optimized+wrappedkey_v0
 *   => v2 policy, HARDWARE-WRAPPED key. identifier (16B): /data/unencrypted/ref.
 *
 * WHAT THIS DOES (replicates vold KeyStorage::decryptWithKeystoreKey + FsCrypt install):
 *   1. appId  = SHA512( "Android secdiscardable SHA512" padded to 128B || secdiscardable )
 *   2. begin(DECRYPT, KEK, {BLOCK_MODE=GCM, MAC_LENGTH=128, NONCE=nonce, APPLICATION_ID=appId})
 *      (on KEY_REQUIRES_UPGRADE: upgradeKey in-memory, NOT persisted, and retry)
 *   3. update(ct+tag) + finish() -> storageKeyBlob (the unwrapped DE storage key)
 *   4. convertStorageKeyToEphemeral(storageKeyBlob) -> per-boot ephemeral wrapped key
 *      (fallback: if that returns INVALID_KEY_BLOB, the unwrapped key is already the
 *       long-term wrapped key -> use it directly)
 *   5. FS_IOC_ADD_ENCRYPTION_KEY on the /data fd, FSCRYPT_ADD_KEY_FLAG_HW_WRAPPED,
 *      key_spec.type=IDENTIFIER (kernel derives + returns the id); verify id == ref and
 *      that /data/misc now opens.
 *
 * NON-DESTRUCTIVE: keyring-only, per-boot ephemeral, NOTHING written to disk (the
 * in-memory upgraded blob is never persisted, unlike the metadata-key bootloop bug). A
 * wrong key is rejected on identifier mismatch. init_user0 is deliberately NOT run here.
 *
 * BUILD/RUN: KeyMint AIDL client (typed V1 NDK stubs, static-linked - the wire format of
 * KeyParameter unions / BeginResult is too easy to get wrong by hand), only libbinder_ndk
 * + libcrypto needed at runtime (both in the dump). Run via the A16 bootstrap linker
 * (decrypt.sh lrun) so the A12-built binary reaches the A16 KeyMint over the A16
 * servicemanager. V1 client + V3 service is wire-compatible for these stable methods.
 */

#define LOG_TAG "de_keyinstall"

#include <aidl/android/hardware/security/keymint/BeginResult.h>
#include <aidl/android/hardware/security/keymint/BlockMode.h>
#include <aidl/android/hardware/security/keymint/IKeyMintDevice.h>
#include <aidl/android/hardware/security/keymint/IKeyMintOperation.h>
#include <aidl/android/hardware/security/keymint/KeyParameter.h>
#include <aidl/android/hardware/security/keymint/KeyParameterValue.h>
#include <aidl/android/hardware/security/keymint/KeyPurpose.h>
#include <aidl/android/hardware/security/keymint/PaddingMode.h>
#include <aidl/android/hardware/security/keymint/Tag.h>
#include <android/binder_auto_utils.h>
#include <android/binder_ibinder.h>
#include <android/binder_manager.h>
#include <android/binder_parcel.h>
#include <android/binder_process.h>
#include <android/binder_status.h>
#include <android/log.h>
#include <openssl/evp.h>
#include <openssl/hmac.h>
#include <openssl/sha.h>
#include <sqlite3.h>

#include <fcntl.h>
#include <linux/ioctl.h>
#include <linux/types.h>
#include <sys/ioctl.h>
#include <unistd.h>

#include <algorithm>
#include <cerrno>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <optional>
#include <string>
#include <vector>

using aidl::android::hardware::security::keymint::BeginResult;
using aidl::android::hardware::security::keymint::BlockMode;
using aidl::android::hardware::security::keymint::IKeyMintDevice;
using aidl::android::hardware::security::keymint::IKeyMintOperation;
using aidl::android::hardware::security::keymint::KeyParameter;
using aidl::android::hardware::security::keymint::KeyParameterValue;
using aidl::android::hardware::security::keymint::KeyPurpose;
using aidl::android::hardware::security::keymint::PaddingMode;
using aidl::android::hardware::security::keymint::Tag;

#define LINE(...)                                                    \
    do {                                                             \
        fprintf(stdout, __VA_ARGS__);                                \
        fprintf(stdout, "\n");                                       \
        fflush(stdout);                                              \
        __android_log_print(ANDROID_LOG_INFO, LOG_TAG, __VA_ARGS__); \
    } while (0)

// ---- fscrypt uapi (defined locally; independent of the A12 header age) ------
#define KEY_SPEC_TYPE_IDENTIFIER 2u
#define ADD_KEY_FLAG_HW_WRAPPED 0x00000001u
#define KEY_IDENTIFIER_SIZE 16

struct fscrypt_key_specifier_local {
    __u32 type;
    __u32 __reserved;
    union {
        __u8 __reserved2[32];
        __u8 descriptor[8];
        __u8 identifier[16];
    } u;
};
struct fscrypt_add_key_arg_local {
    struct fscrypt_key_specifier_local key_spec;
    __u32 raw_size;
    __u32 key_id;
    // EXACT order from the device kernel uapi (bionic .../fscrypt.h): __reserved[7] comes
    // BEFORE __flags (Qualcomm repurposed the LAST reserved word as __flags, offset 76).
    // Getting this order wrong made the kernel read HW_WRAPPED as a non-zero __reserved
    // word -> EINVAL, and see __flags as 0 (not hw-wrapped). Total fixed size = 80B either
    // way, so the _IOWR number is unchanged.
    __u32 __reserved[7];
    __u32 __flags;
    __u8 raw[];
};
#define FS_IOC_ADD_ENCRYPTION_KEY_LOCAL \
    _IOWR('f', 23, struct fscrypt_add_key_arg_local)

namespace {

const int kGcmNonceLen = 12;
const int kAppIdHashPersonLen = 128;  // SHA512_CBLOCK, matches vold's secdiscardable hash

bool readFile(const std::string& path, std::vector<uint8_t>* out) {
    int fd = open(path.c_str(), O_RDONLY | O_CLOEXEC);
    if (fd < 0) return false;
    out->clear();
    uint8_t buf[8192];
    ssize_t n;
    while ((n = read(fd, buf, sizeof(buf))) > 0) out->insert(out->end(), buf, buf + n);
    close(fd);
    return n >= 0;
}

// Write data to path with the given mode (tmpfs SP cache). Best-effort.
bool writeFileMode(const std::string& path, const std::vector<uint8_t>& data, int mode) {
    int fd = open(path.c_str(), O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, mode);
    if (fd < 0) return false;
    ssize_t w = write(fd, data.data(), data.size());
    close(fd);
    return w == static_cast<ssize_t>(data.size());
}

std::string hex(const uint8_t* p, size_t n) {
    static const char* d = "0123456789abcdef";
    std::string s;
    s.reserve(n * 2);
    for (size_t i = 0; i < n; i++) {
        s.push_back(d[p[i] >> 4]);
        s.push_back(d[p[i] & 0xf]);
    }
    return s;
}

// LSS SyntheticPasswordCrypto.personalizedHash: SHA-512( pad128(personalization) || data... ).
// Same recipe vold uses for the secdiscardable appId (just a different personalization string).
std::vector<uint8_t> personalizedHash(const std::string& personalization,
                                      const std::vector<uint8_t>& data) {
    SHA512_CTX c;
    SHA512_Init(&c);
    char person[kAppIdHashPersonLen];
    memset(person, 0, sizeof(person));
    memcpy(person, personalization.data(),
           std::min(personalization.size(), static_cast<size_t>(kAppIdHashPersonLen)));
    SHA512_Update(&c, person, sizeof(person));
    SHA512_Update(&c, data.data(), data.size());
    std::vector<uint8_t> out(SHA512_DIGEST_LENGTH);
    SHA512_Final(out.data(), &c);
    return out;
}

// vold KeyStorage secdiscardable appId = personalizedHash with vold's fixed prefix.
std::vector<uint8_t> secdiscardableAppId(const std::vector<uint8_t>& sd) {
    return personalizedHash("Android secdiscardable SHA512", sd);
}

// --- self-contained discovery (no hardcoded handle / prebuilt blob) ----------------------

// Current SP protector handle for user 0 = sp-handle (int64 decimal) in locksettings.db,
// formatted as 16 lowercase hex digits (matches the spblob filename + keystore alias).
bool getCurrentProtectorHandle(std::string* handleHex) {
    sqlite3* db = nullptr;
    if (sqlite3_open_v2("file:/data/system/locksettings.db?mode=ro&immutable=1", &db,
                        SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nullptr) != SQLITE_OK) {
        if (db) sqlite3_close(db);
        return false;
    }
    sqlite3_stmt* stmt = nullptr;
    bool ok = false;
    if (sqlite3_prepare_v2(db, "SELECT value FROM locksettings WHERE name='sp-handle' AND user=0",
                           -1, &stmt, nullptr) == SQLITE_OK &&
        sqlite3_step(stmt) == SQLITE_ROW) {
        const char* v = reinterpret_cast<const char*>(sqlite3_column_text(stmt, 0));
        if (v != nullptr) {
            uint64_t h = strtoull(v, nullptr, 10);
            char buf[24];
            snprintf(buf, sizeof(buf), "%016llx", static_cast<unsigned long long>(h));
            *handleHex = buf;
            ok = true;
        }
    }
    sqlite3_finalize(stmt);
    sqlite3_close(db);
    return ok;
}

// KeyMint blob (subcomponent_type 0) of the keystore2 key "synthetic_password_<handle>"
// from the user's persistent.sqlite (LOCKSETTINGS namespace). Read-only/immutable: safe
// because our recovery keystore2 uses /tmp/misc/keystore, not /data/misc/keystore.
bool getSpKeystoreBlob(const std::string& handleHex, std::vector<uint8_t>* blob) {
    std::string alias = "synthetic_password_" + handleHex;
    sqlite3* db = nullptr;
    if (sqlite3_open_v2("file:/data/misc/keystore/persistent.sqlite?mode=ro&immutable=1", &db,
                        SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nullptr) != SQLITE_OK) {
        if (db) sqlite3_close(db);
        return false;
    }
    sqlite3_stmt* stmt = nullptr;
    bool ok = false;
    const char* sql =
        "SELECT b.blob FROM blobentry b JOIN keyentry k ON b.keyentryid=k.id "
        "WHERE k.alias=? AND b.subcomponent_type=0";
    if (sqlite3_prepare_v2(db, sql, -1, &stmt, nullptr) == SQLITE_OK &&
        sqlite3_bind_text(stmt, 1, alias.c_str(), -1, SQLITE_TRANSIENT) == SQLITE_OK &&
        sqlite3_step(stmt) == SQLITE_ROW) {
        const uint8_t* p = static_cast<const uint8_t*>(sqlite3_column_blob(stmt, 0));
        int n = sqlite3_column_bytes(stmt, 0);
        if (p != nullptr && n > 0) {
            blob->assign(p, p + n);
            ok = true;
        }
    }
    sqlite3_finalize(stmt);
    sqlite3_close(db);
    return ok;
}

// Weaver slot for a protector: <handle>.weaver = [version:1][slot: big-endian int32].
int getWeaverSlot(const std::string& handleHex) {
    std::vector<uint8_t> w;
    if (!readFile("/data/system_de/0/spblob/" + handleHex + ".weaver", &w) || w.size() < 5)
        return -1;
    return (w[1] << 24) | (w[2] << 16) | (w[3] << 8) | w[4];
}

// AParcel byte[] reader (for hand-marshalled IWeaver replies).
[[maybe_unused]] bool byteArrayAllocator(void* arrayData, int32_t length, int8_t** outBuffer) {
    auto* vec = static_cast<std::vector<uint8_t>*>(arrayData);
    if (length < 0) {
        *outBuffer = nullptr;
        return true;
    }
    vec->resize(length);
    *outBuffer = reinterpret_cast<int8_t*>(vec->data());
    return true;
}

// Empty-LSKF stretched credential (A16): "default-password" zero-padded to 32B (no scrypt).
std::vector<uint8_t> emptyStretchedLskf() {
    std::vector<uint8_t> s(32, 0);
    const char* dp = "default-password";
    memcpy(s.data(), dp, strlen(dp));
    return s;
}

// LockPatternUtils credential types.
enum { CRED_NONE = -1, CRED_PATTERN = 1, CRED_PIN = 3, CRED_PASSWORD = 4 };

// Parse /data/system_de/0/spblob/<handle>.pwd (A16 PasswordData, big-endian):
//   int credentialType; byte scryptLogN; byte scryptLogR; byte scryptLogP;
//   int saltLength; byte[] salt; int gatekeeperHandleLength; byte[] gkHandle;
//   [int pinLength]  (Samsung auto-confirm extension; ignored)
// Returns false if the .pwd is absent (=> empty LSKF, no credential).
bool readPasswordData(const std::string& handleHex, int32_t* credType, int* logN, int* logR,
                      int* logP, std::vector<uint8_t>* salt) {
    std::vector<uint8_t> d;
    if (!readFile("/data/system_de/0/spblob/" + handleHex + ".pwd", &d) || d.size() < 11)
        return false;
    auto be32 = [&](size_t o) -> int32_t {
        return (int32_t)(((uint32_t)d[o] << 24) | ((uint32_t)d[o + 1] << 16) |
                         ((uint32_t)d[o + 2] << 8) | (uint32_t)d[o + 3]);
    };
    *credType = be32(0);
    *logN = d[4];
    *logR = d[5];
    *logP = d[6];
    int32_t saltLen = be32(7);
    if (saltLen < 0 || (size_t)(11 + saltLen) > d.size()) return false;
    salt->assign(d.begin() + 11, d.begin() + 11 + saltLen);
    return true;
}

// stretchLskf for a real credential: scrypt(credential, salt, N=1<<logN, r=1<<logR, p=1<<logP)
// -> 32B (A16 LSS SyntheticPasswordCrypto/PasswordData; STRETCHED_LSKF_LENGTH=32).
bool scryptStretch(const std::string& credential, const std::vector<uint8_t>& salt, int logN,
                   int logR, int logP, std::vector<uint8_t>* out) {
    out->assign(32, 0);
    uint64_t N = 1ull << logN, r = 1ull << logR, p = 1ull << logP;
    return EVP_PBE_scrypt(credential.data(), credential.size(), salt.data(), salt.size(), N, r, p,
                          64ull * 1024 * 1024, out->data(), 32) == 1;
}

// Software AES-256-GCM decrypt (libcrypto) of [ct||16B tag] with a 32B key + 12B IV.
// Used for the SP blob INNER layer (SyntheticPasswordCrypto.decrypt - not keystore-backed).
bool swGcmDecrypt(const std::vector<uint8_t>& key32, const std::vector<uint8_t>& iv12,
                  const std::vector<uint8_t>& ctAndTag, std::vector<uint8_t>* out) {
    if (key32.size() != 32 || iv12.size() != 12 || ctAndTag.size() < 16) return false;
    size_t ctLen = ctAndTag.size() - 16;
    const uint8_t* tag = ctAndTag.data() + ctLen;
    EVP_CIPHER_CTX* ctx = EVP_CIPHER_CTX_new();
    if (ctx == nullptr) return false;
    out->assign(ctLen, 0);
    int outl = 0, finl = 0;
    bool ok = EVP_DecryptInit_ex(ctx, EVP_aes_256_gcm(), nullptr, nullptr, nullptr) == 1 &&
              EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_GCM_SET_IVLEN, 12, nullptr) == 1 &&
              EVP_DecryptInit_ex(ctx, nullptr, nullptr, key32.data(), iv12.data()) == 1 &&
              EVP_DecryptUpdate(ctx, out->data(), &outl, ctAndTag.data(),
                                static_cast<int>(ctLen)) == 1 &&
              EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_GCM_SET_TAG, 16,
                                  const_cast<uint8_t*>(tag)) == 1 &&
              EVP_DecryptFinal_ex(ctx, out->data() + outl, &finl) == 1;
    EVP_CIPHER_CTX_free(ctx);
    if (ok) out->resize(outl + finl);
    return ok;
}

// NIST SP800-108 counter-mode KDF (HmacSHA256, single 32B block) as used by LSS
// SyntheticPassword.deriveSubkey for v3: HMAC-SHA256(key, [BE32(1)][label][0x00][context]
// [BE32(len(context)*8)][BE32(256)]).
std::vector<uint8_t> sp800Derive(const std::vector<uint8_t>& key, const std::string& label,
                                 const std::string& context) {
    std::vector<uint8_t> fixed;
    auto be32 = [&](uint32_t v) {
        fixed.push_back((v >> 24) & 0xff);
        fixed.push_back((v >> 16) & 0xff);
        fixed.push_back((v >> 8) & 0xff);
        fixed.push_back(v & 0xff);
    };
    be32(1);  // counter
    fixed.insert(fixed.end(), label.begin(), label.end());
    fixed.push_back(0);
    fixed.insert(fixed.end(), context.begin(), context.end());
    be32(static_cast<uint32_t>(context.size()) * 8);  // context bit-length
    be32(256);                                        // L (output bits)
    uint8_t mac[32];
    unsigned int maclen = sizeof(mac);
    HMAC(EVP_sha256(), key.data(), static_cast<int>(key.size()), fixed.data(), fixed.size(), mac,
         &maclen);
    return std::vector<uint8_t>(mac, mac + maclen);
}

// Client-side AIBinder_Class stubs for the hand-marshalled IWeaver proxy (we never receive
// inbound calls). Named functions (not lambdas) so the onTransact return type is exactly
// binder_status_t for the function-pointer typedef.
void* WeaverOnCreate(void* args) { return args; }
void WeaverOnDestroy(void* /*userData*/) {}
binder_status_t WeaverOnTransact(AIBinder* /*b*/, transaction_code_t /*code*/,
                                 const AParcel* /*in*/, AParcel* /*out*/) {
    return STATUS_UNKNOWN_TRANSACTION;
}

// IWeaver V2 (android.hardware.weaver) read for the EMPTY-LSKF protector. Hand-marshalled
// over libbinder_ndk (no typed weaver stub in the TWRP-12.1 tree). Derivation (A16 LSS):
//   stretchedLskf = "default-password" zero-padded to 32B (no scrypt; empty LSKF)
//   weaverKey     = personalizedHash("weaver-key", stretchedLskf)[:keySize]
//   read(slot 0, weaverKey) -> WeaverReadResponse{ long timeout; byte[] value; status }
// Returns true + the weaver value on WeaverReadStatus.OK(0).
bool readWeaverSlot(int slot, const std::vector<uint8_t>& stretchedLskf,
                    std::vector<uint8_t>* outValue) {
    ::ndk::SpAIBinder wb(AServiceManager_getService("android.hardware.weaver.IWeaver/default"));
    AIBinder* weaver = wb.get();
    if (weaver == nullptr) {
        LINE("  weaver: IWeaver/default not found - is decrypt-hermes running?");
        return false;
    }
    AIBinder_Class* clazz = AIBinder_Class_define("android.hardware.weaver.IWeaver", WeaverOnCreate,
                                                  WeaverOnDestroy, WeaverOnTransact);
    if (!AIBinder_associateClass(weaver, clazz)) {
        LINE("  weaver: associateClass mismatch (remote is not IWeaver)");
        return false;
    }

    // getConfig() = tx 1 -> WeaverConfig{ int slots; int keySize; int valueSize; }
    int32_t keySize = 0, slots = 0, valueSize = 0;
    {
        AParcel* in = nullptr;
        if (AIBinder_prepareTransaction(weaver, &in) != STATUS_OK) return false;
        AParcel* out = nullptr;
        if (AIBinder_transact(weaver, 1, &in, &out, 0) != STATUS_OK) {
            LINE("  weaver: getConfig transport error");
            return false;
        }
        AStatus* st = nullptr;
        AParcel_readStatusHeader(out, &st);
        bool ok = AStatus_isOk(st);
        AStatus_delete(st);
        if (ok) {
            int32_t nonNull = 0, psize = 0;
            AParcel_readInt32(out, &nonNull);  // NDK non-null parcelable marker (1)
            AParcel_readInt32(out, &psize);    // parcelable size
            AParcel_readInt32(out, &slots);
            AParcel_readInt32(out, &keySize);
            AParcel_readInt32(out, &valueSize);
        }
        AParcel_delete(out);
        if (!ok) {
            LINE("  weaver: getConfig returned an exception");
            return false;
        }
    }
    LINE("  weaver config: slots=%d keySize=%d valueSize=%d", slots, keySize, valueSize);
    if (keySize <= 0 || keySize > 128) return false;

    // weaverKey = personalizedHash("weaver-key", stretchedLskf)[:keySize]. stretchedLskf is the
    // empty-LSKF "default-password" pad OR scrypt(PIN/password) - computed by the caller.
    std::vector<uint8_t> weaverKey = personalizedHash("weaver-key", stretchedLskf);
    weaverKey.resize(keySize);
    LINE("  weaverKey[:8]=%s", hex(weaverKey.data(), 8).c_str());

    // read(slotId=0, key) = tx 2 -> WeaverReadResponse{ long timeout; byte[] value; status }
    AParcel* in = nullptr;
    if (AIBinder_prepareTransaction(weaver, &in) != STATUS_OK) return false;
    AParcel_writeInt32(in, slot);  // slotId
    AParcel_writeByteArray(in, reinterpret_cast<const int8_t*>(weaverKey.data()),
                           static_cast<int32_t>(weaverKey.size()));
    AParcel* out = nullptr;
    if (AIBinder_transact(weaver, 2, &in, &out, 0) != STATUS_OK) {
        LINE("  weaver: read transport error");
        return false;
    }
    AStatus* st = nullptr;
    AParcel_readStatusHeader(out, &st);
    bool ok = AStatus_isOk(st);
    AStatus_delete(st);
    if (!ok) {
        LINE("  weaver: read returned an exception");
        AParcel_delete(out);
        return false;
    }
    // WeaverReadResponse reply framing (decoded from raw words): NDK writes a non-null
    // parcelable marker (1) + size, THEN the fields in declaration order:
    //   [int32 nonNull=1][int32 size][int64 timeout][byte[] value][int32 status]
    int32_t nonNull = 0, psize = 0, status = -1;
    int64_t timeout = 0;
    std::vector<uint8_t> value;
    AParcel_readInt32(out, &nonNull);                        // non-null marker
    AParcel_readInt32(out, &psize);                          // parcelable size
    AParcel_readInt64(out, &timeout);                        // long timeout
    AParcel_readByteArray(out, &value, byteArrayAllocator);  // byte[] value
    AParcel_readInt32(out, &status);                         // WeaverReadStatus
    AParcel_delete(out);

    const char* sname = status == 0   ? "OK"
                        : status == 1 ? "FAILED"
                        : status == 2 ? "INCORRECT_KEY"
                        : status == 3 ? "THROTTLE"
                                      : "?";
    LINE("  weaver read slot %d: status=%d(%s) value=%zuB timeout=%lld", slot, status, sname,
         value.size(), static_cast<long long>(timeout));
    if (status != 0) return false;
    LINE("  weaver value[:8]=%s", value.empty() ? "(empty)" : hex(value.data(), 8).c_str());
    *outValue = std::move(value);
    return true;
}

KeyParameter kpEnum(Tag tag, KeyParameterValue v) { return KeyParameter{tag, std::move(v)}; }

void logStatus(const char* what, const ::ndk::ScopedAStatus& st) {
    LINE("  %s: ex=%d serviceSpecific=%d msg=%s", what, st.getExceptionCode(),
         st.getServiceSpecificError(),
         st.getMessage() ? st.getMessage() : "(none)");
}

// vold KeyStorage::decryptWithKeystoreKey: AES-256-GCM decrypt encrypted_key with the KEK.
// KeyMint AES-256-GCM decrypt of a vold-format blob [12B nonce][ct+16B tag] using a KeyMint
// keyblob (the KEK for DE keys, or the keystore2 SP key for the spblob outer layer). appId
// optional: pass the APPLICATION_ID for vold KeyStorage keys (DE), nullptr for the SP key
// (NO_AUTH_REQUIRED, no appid binding). In-memory upgradeKey on KEY_REQUIRES_UPGRADE.
bool kmGcmDecrypt(const std::shared_ptr<IKeyMintDevice>& km, std::vector<uint8_t> keyblob,
                  const std::vector<uint8_t>& encryptedKey, const std::vector<uint8_t>* appId,
                  std::vector<uint8_t>* out) {
    if (static_cast<int>(encryptedKey.size()) <= kGcmNonceLen + 16) {
        LINE("  gcm blob too small (%zuB)", encryptedKey.size());
        return false;
    }
    std::vector<uint8_t> nonce(encryptedKey.begin(), encryptedKey.begin() + kGcmNonceLen);
    std::vector<uint8_t> body(encryptedKey.begin() + kGcmNonceLen, encryptedKey.end());

    std::vector<KeyParameter> params;
    params.push_back(kpEnum(Tag::BLOCK_MODE,
                            KeyParameterValue::make<KeyParameterValue::blockMode>(BlockMode::GCM)));
    params.push_back(kpEnum(Tag::PADDING,
                            KeyParameterValue::make<KeyParameterValue::paddingMode>(PaddingMode::NONE)));
    params.push_back(kpEnum(Tag::MAC_LENGTH,
                            KeyParameterValue::make<KeyParameterValue::integer>(128)));
    params.push_back(kpEnum(Tag::NONCE,
                            KeyParameterValue::make<KeyParameterValue::blob>(nonce)));
    if (appId)
        params.push_back(kpEnum(Tag::APPLICATION_ID,
                                KeyParameterValue::make<KeyParameterValue::blob>(*appId)));

    BeginResult begun;
    auto st = km->begin(KeyPurpose::DECRYPT, keyblob, params, std::nullopt, &begun);
    if (st.getServiceSpecificError() == -62 /*KEY_REQUIRES_UPGRADE*/) {
        LINE("  begin -> KEY_REQUIRES_UPGRADE; upgrading keyblob in-memory (not persisted)");
        std::vector<uint8_t> upgraded;
        std::vector<KeyParameter> upParams;
        if (appId)
            upParams.push_back(kpEnum(Tag::APPLICATION_ID,
                                      KeyParameterValue::make<KeyParameterValue::blob>(*appId)));
        auto ust = km->upgradeKey(keyblob, upParams, &upgraded);
        if (!ust.isOk()) {
            logStatus("upgradeKey", ust);
            return false;
        }
        keyblob = std::move(upgraded);
        st = km->begin(KeyPurpose::DECRYPT, keyblob, params, std::nullopt, &begun);
    }
    if (!st.isOk() || begun.operation == nullptr) {
        logStatus("begin(DECRYPT)", st);
        return false;
    }

    std::vector<uint8_t> partial;
    st = begun.operation->update(body, std::nullopt, std::nullopt, &partial);
    if (!st.isOk()) {
        logStatus("operation.update", st);
        begun.operation->abort();
        return false;
    }
    std::vector<uint8_t> tail;
    st = begun.operation->finish(std::nullopt, std::nullopt, std::nullopt, std::nullopt,
                                 std::nullopt, &tail);
    if (!st.isOk()) {
        logStatus("operation.finish (GCM tag verify)", st);
        return false;
    }
    out->clear();
    out->insert(out->end(), partial.begin(), partial.end());
    out->insert(out->end(), tail.begin(), tail.end());
    return true;
}

// FS_IOC_ADD_ENCRYPTION_KEY with the hardware-wrapped flag; returns the kernel-derived id.
int addHwWrappedKey(const std::vector<uint8_t>& key, std::string* gotId) {
    int dfd = open("/data", O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    if (dfd < 0) {
        LINE("  open(/data) failed: %s", strerror(errno));
        return -1;
    }
    size_t argSize = sizeof(struct fscrypt_add_key_arg_local) + key.size();
    std::vector<uint8_t> argBuf(argSize, 0);
    auto* arg = reinterpret_cast<struct fscrypt_add_key_arg_local*>(argBuf.data());
    arg->key_spec.type = KEY_SPEC_TYPE_IDENTIFIER;
    arg->raw_size = static_cast<__u32>(key.size());
    arg->__flags = ADD_KEY_FLAG_HW_WRAPPED;
    memcpy(arg->raw, key.data(), key.size());
    int rc = ioctl(dfd, FS_IOC_ADD_ENCRYPTION_KEY_LOCAL, arg);
    int e = errno;
    if (rc == 0) *gotId = hex(arg->key_spec.u.identifier, KEY_IDENTIFIER_SIZE);
    close(dfd);
    if (rc != 0) {
        LINE("  ioctl FS_IOC_ADD_ENCRYPTION_KEY failed: errno=%d (%s)", e, strerror(e));
        return e;
    }
    return 0;
}

// storage key blob -> per-boot ephemeral wrapped key, with in-memory upgrade on -62.
bool toEphemeral(const std::shared_ptr<IKeyMintDevice>& km, const std::vector<uint8_t>& storageKey,
                 std::vector<uint8_t>* out) {
    std::vector<uint8_t> eph;
    auto cst = km->convertStorageKeyToEphemeral(storageKey, &eph);
    if (cst.getServiceSpecificError() == -62 /*KEY_REQUIRES_UPGRADE*/) {
        LINE("  convert -> KEY_REQUIRES_UPGRADE; upgrading storage key in-memory");
        std::vector<uint8_t> up;
        auto ust = km->upgradeKey(storageKey, std::vector<KeyParameter>{}, &up);
        if (ust.isOk() && !up.empty()) {
            cst = km->convertStorageKeyToEphemeral(up, &eph);
        } else {
            logStatus("upgradeKey(storage)", ust);
        }
    }
    if (!cst.isOk()) {
        logStatus("convertStorageKeyToEphemeral", cst);
        return false;
    }
    *out = std::move(eph);
    return true;
}

// Install one hardware-wrapped fscrypt key from a vold KeyStorage dir (kEmptyAuthentication
// form: keymaster_key_blob + encrypted_key + secdiscardable). Unlocks whatever the key's
// policy protects. NON-DESTRUCTIVE (keyring only). Returns true on install.
bool installKeyDir(const std::shared_ptr<IKeyMintDevice>& km, const std::string& dir,
                   const char* label, const std::vector<uint8_t>* expectedRef) {
    LINE("--- install %s [%s] ---", label, dir.c_str());
    std::vector<uint8_t> kek, encKey, sec;
    if (!readFile(dir + "/keymaster_key_blob", &kek) || !readFile(dir + "/encrypted_key", &encKey) ||
        !readFile(dir + "/secdiscardable", &sec)) {
        LINE("  missing key material in %s", dir.c_str());
        return false;
    }
    std::vector<uint8_t> appId = secdiscardableAppId(sec);
    std::vector<uint8_t> storageKey;
    if (!kmGcmDecrypt(km, kek, encKey, &appId, &storageKey)) return false;
    LINE("  storage key unwrapped: %zuB", storageKey.size());
    std::vector<uint8_t> ephemeral;
    if (!toEphemeral(km, storageKey, &ephemeral)) return false;
    LINE("  ephemeral wrapped key: %zuB", ephemeral.size());
    std::string gotId;
    if (addHwWrappedKey(ephemeral, &gotId) != 0) return false;
    LINE("  KEY INSTALLED, kernel id=%s", gotId.c_str());
    if (expectedRef && expectedRef->size() == KEY_IDENTIFIER_SIZE) {
        std::string want = hex(expectedRef->data(), expectedRef->size());
        LINE("  id %s ref(%s)", gotId == want ? "==" : "!=", want.c_str());
    }
    return true;
}

// CE stage 2: unwrap the synthetic password from the LSKF-based weaver protector.
//   protectorSecret = stretchedLskf(32) ‖ personalizedHash("weaver-pwd", weaverValue)(64)
//   spblob.mContent = spblob[2:]  (skip version+protectorType bytes)
//   OUTER: KeyMint AES-256-GCM decrypt(mContent) with the keystore2 SP key  -> intermediate
//   INNER: software AES-256-GCM decrypt(intermediate) with
//          key = personalizedHash("application-id", protectorSecret)[:32]  -> the SP
// Self-contained: the keystore2 SP keyblob comes from getSpKeystoreBlob(handle) (parses
// persistent.sqlite) and the spblob path is built from the discovered protector handle.
bool unwrapSyntheticPassword(const std::shared_ptr<IKeyMintDevice>& km,
                             const std::vector<uint8_t>& weaverValue, const std::string& handleHex,
                             const std::vector<uint8_t>& stretchedLskf, std::vector<uint8_t>* sp) {
    std::vector<uint8_t> spKeyBlob;
    if (!getSpKeystoreBlob(handleHex, &spKeyBlob) || spKeyBlob.empty()) {
        LINE("  SP keystore key (synthetic_password_%s) not found in persistent.sqlite",
             handleHex.c_str());
        return false;
    }
    LINE("  SP keystore keyblob: %zuB", spKeyBlob.size());
    std::vector<uint8_t> spblob;
    if (!readFile("/data/system_de/0/spblob/" + handleHex + ".spblob", &spblob) ||
        spblob.size() < 3) {
        LINE("  spblob missing/short");
        return false;
    }
    LINE("  spblob: %zuB version=%d protectorType=%d", spblob.size(), spblob[0], spblob[1]);
    std::vector<uint8_t> mContent(spblob.begin() + 2, spblob.end());

    std::vector<uint8_t> protectorSecret = stretchedLskf;                    // 32B (empty or scrypt)
    std::vector<uint8_t> wpw = personalizedHash("weaver-pwd", weaverValue);  // 64B
    protectorSecret.insert(protectorSecret.end(), wpw.begin(), wpw.end());   // 96B

    // OUTER (keystore2 SP key, no appId / NO_AUTH_REQUIRED)
    std::vector<uint8_t> intermediate;
    if (!kmGcmDecrypt(km, spKeyBlob, mContent, nullptr, &intermediate)) {
        LINE("  spblob OUTER (keystore key) decrypt failed");
        return false;
    }
    LINE("  spblob outer decrypted: %zuB", intermediate.size());

    // INNER (software, key from protectorSecret)
    std::vector<uint8_t> innerKey = personalizedHash("application-id", protectorSecret);
    innerKey.resize(32);
    if (intermediate.size() < kGcmNonceLen + 16) {
        LINE("  intermediate too small for inner GCM");
        return false;
    }
    std::vector<uint8_t> iv(intermediate.begin(), intermediate.begin() + kGcmNonceLen);
    std::vector<uint8_t> ct(intermediate.begin() + kGcmNonceLen, intermediate.end());
    if (!swGcmDecrypt(innerKey, iv, ct, sp)) {
        LINE("  spblob INNER (software) GCM decrypt failed (wrong protectorSecret/appId?)");
        return false;
    }
    LINE("  SYNTHETIC PASSWORD recovered: %zuB sp[:8]=%s", sp->size(),
         sp->empty() ? "(empty)" : hex(sp->data(), 8).c_str());
    return true;
}

// CE stages 3+4: SP -> FBE disk key -> unwrap + install the user-0 CE key.
//   STAGE 3: fbeKey = SP800Derive(SP, "fbe-key", "android-synthetic-password-personalization-context")
//   STAGE 4: vold KeyStorage decryptWithoutKeystore on ce/0/current/encrypted_key:
//     ce/0/current has no secdiscardable => secdiscardable_hash="" => appId = "" + secret(fbeKey)
//     kek = SHA512(pad128("Android key wrapping key generation SHA512") || appId)[:32]
//     CE storage key = AES-256-GCM decrypt(encrypted_key=[12B IV][ct+tag], kek)  [software]
//     then (hw-wrapped, like DE): convertStorageKeyToEphemeral -> FS_IOC_ADD_ENCRYPTION_KEY
//   (no storage binding seed set on this device - proven by the DE keys unwrapping with
//    appId=secdiscardable_hash only.)
bool installCeKey(const std::shared_ptr<IKeyMintDevice>& km, const std::vector<uint8_t>& sp) {
    std::vector<uint8_t> fbeKey =
        sp800Derive(sp, "fbe-key", "android-synthetic-password-personalization-context");
    LINE("  fbeKey (disk decryption key)[:8]=%s", hex(fbeKey.data(), 8).c_str());

    std::vector<uint8_t> encKey;
    if (!readFile("/data/misc/vold/user_keys/ce/0/current/encrypted_key", &encKey) ||
        encKey.size() < kGcmNonceLen + 16) {
        LINE("  ce/0/current/encrypted_key missing/short");
        return false;
    }
    std::vector<uint8_t> kek =
        personalizedHash("Android key wrapping key generation SHA512", fbeKey);  // appId = fbeKey
    kek.resize(32);
    std::vector<uint8_t> iv(encKey.begin(), encKey.begin() + kGcmNonceLen);
    std::vector<uint8_t> ct(encKey.begin() + kGcmNonceLen, encKey.end());
    std::vector<uint8_t> ceStorageKey;
    if (!swGcmDecrypt(kek, iv, ct, &ceStorageKey)) {
        LINE("  CE encrypted_key GCM decrypt failed (wrong fbeKey / storage binding seed set?)");
        return false;
    }
    LINE("  CE storage key decrypted: %zuB", ceStorageKey.size());

    std::vector<uint8_t> ephemeral;
    if (!toEphemeral(km, ceStorageKey, &ephemeral)) {
        LINE("  CE convertStorageKeyToEphemeral failed");
        return false;
    }
    std::string gotId;
    if (addHwWrappedKey(ephemeral, &gotId) != 0) {
        LINE("  CE FS_IOC_ADD failed");
        return false;
    }
    LINE("  CE KEY INSTALLED, kernel id=%s", gotId.c_str());
    return true;
}

}  // namespace

static bool dirReadable(const char* path) {
    int fd = open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    if (fd < 0) return false;
    close(fd);
    return true;
}

int main(int argc, char** argv) {
    // Optional arg: the lockscreen credential (PIN/password). Empty => empty-LSKF path.
    std::string pin = (argc > 1 && argv[1] != nullptr) ? std::string(argv[1]) : std::string();
    LINE("===== de_keyinstall start =====");

    ABinderProcess_setThreadPoolMaxThreadCount(1);
    ABinderProcess_startThreadPool();
    ::ndk::SpAIBinder binder(
        AServiceManager_getService("android.hardware.security.keymint.IKeyMintDevice/default"));
    std::shared_ptr<IKeyMintDevice> km = IKeyMintDevice::fromBinder(binder);
    if (km == nullptr) {
        LINE("FATAL: IKeyMintDevice/default not found - is decrypt-keymint up?");
        return 1;
    }
    int32_t kmVer = 0;
    km->getInterfaceVersion(&kmVer);
    LINE("connected to KeyMint (interface V%d)", kmVer);

    // Layer 1: systemwide DE key (/data/unencrypted/key). Unlocks /data/misc - which is
    // where the per-user keys live, so this MUST go first to even read layer 2.
    std::vector<uint8_t> ref;
    bool haveRef = readFile("/data/unencrypted/ref", &ref);
    bool sysOk = installKeyDir(km, "/data/unencrypted/key", "systemwide DE",
                               haveRef ? &ref : nullptr);
    LINE("VERIFY: /data/misc %s", dirReadable("/data/misc") ? "READABLE (DE unlocked)" : "locked");

    // Layer 2: user-0 DE key (/data/misc/vold/user_keys/de/0). Same kEmptyAuthentication
    // format - readable only now that layer 1 unlocked /data/misc. Unlocks /data/system_de/0
    // and /data/user_de/0, exposing the spblob needed for the CE layer.
    if (sysOk && dirReadable("/data/misc/vold/user_keys/de/0")) {
        installKeyDir(km, "/data/misc/vold/user_keys/de/0", "user-0 DE", nullptr);
        LINE("VERIFY: /data/system_de/0 %s",
             dirReadable("/data/system_de/0") ? "READABLE (user-0 DE unlocked)" : "locked");
    } else if (sysOk) {
        LINE("user-0 DE key dir not present/readable at /data/misc/vold/user_keys/de/0");
    }

    // Layer 3: user-0 CE key (the actual user content). Self-contained: discover the current
    // SP protector handle + its Weaver slot, then weaver-read -> SP-blob unwrap -> fbe-key ->
    // install. Empty LSKF (no lockscreen) only; a real PIN/password is not derivable here.
    if (sysOk && dirReadable("/data/system_de/0")) {
        std::string handle;
        int slot = -1;
        if (getCurrentProtectorHandle(&handle)) slot = getWeaverSlot(handle);
        if (handle.empty() || slot < 0) {
            LINE("CE: could not discover SP protector handle/weaver slot (sp-handle=%s slot=%d)",
                 handle.empty() ? "?" : handle.c_str(), slot);
        } else {
            LINE("--- CE: protector %s, weaver slot %d ---", handle.c_str(), slot);
            std::vector<uint8_t> sp;
            // FAST PATH: a cached synthetic password from a successful unlock earlier this boot
            // (/tmp/.ce_sp, tmpfs, root-only, wiped on reboot). Lets a remount after a TWRP GUI
            // unmount restore CE with NO credential and NO weaver round-trip.
            if (readFile("/tmp/.ce_sp", &sp) && sp.size() == 128) {
                LINE("  CE: using cached synthetic password (/tmp/.ce_sp) - no credential needed");
            } else {
                sp.clear();
                // stretchedLskf: empty-LSKF default-password pad, OR scrypt(credential) when the
                // protector has a PasswordData (.pwd) with a real credential (PIN/password).
                std::vector<uint8_t> stretchedLskf;
                int32_t credType = CRED_NONE;
                int lN = 0, lR = 0, lP = 0;
                std::vector<uint8_t> salt;
                bool havePwd = readPasswordData(handle, &credType, &lN, &lR, &lP, &salt);
                bool ceOk = true;
                if (!havePwd || credType == CRED_NONE) {
                    stretchedLskf = emptyStretchedLskf();
                    LINE("  credential: NONE (empty LSKF)");
                } else if (credType == CRED_PATTERN) {
                    LINE("CE: protector is PATTERN-based (type=1) - not supported, skipping CE.");
                    ceOk = false;
                } else if (pin.empty()) {
                    LINE("CE: protector is credential-protected (type=%d, %s) - PIN/password REQUIRED.",
                         credType, credType == CRED_PIN ? "PIN" : "password");
                    LINE("    Run in the TWRP terminal:   password <your-PIN>");
                    ceOk = false;
                } else if (!scryptStretch(pin, salt, lN, lR, lP, &stretchedLskf)) {
                    LINE("CE: scrypt(credential) failed");
                    ceOk = false;
                } else {
                    LINE("  credential type=%d scrypt(N=%d,r=%d,p=%d) stretchedLskf[:8]=%s", credType,
                         1 << lN, 1 << lR, 1 << lP, hex(stretchedLskf.data(), 8).c_str());
                }
                std::vector<uint8_t> weaverValue;
                if (ceOk && readWeaverSlot(slot, stretchedLskf, &weaverValue) &&
                    unwrapSyntheticPassword(km, weaverValue, handle, stretchedLskf, &sp)) {
                    /* sp is now set from the credential path */
                } else {
                    sp.clear();
                    if (ceOk)
                        LINE("CE: weaver/SP unwrap failed (wrong PIN/password? throttled? see above)");
                }
            }
            if (sp.empty()) {
                // CE not unlocked (no credential / wrong / pattern) - message already printed
            } else if (!installCeKey(km, sp)) {
                LINE("CE stage 3+4 failed: fbe-key / CE install (see status above)");
            } else {
                writeFileMode("/tmp/.ce_sp", sp, 0600);  // cache SP for no-credential remounts
                int mfd = open("/data/data", O_RDONLY | O_DIRECTORY | O_CLOEXEC);
                bool dataOpen = mfd >= 0;
                if (mfd >= 0) close(mfd);
                LINE("CE DONE: user-0 CE key installed; /data/data %s",
                     dataOpen ? "opens - CE LAYER UNLOCKED" : "open-failed (check)");
            }
        }
    }

    LINE("===== de_keyinstall done =====");
    return sysOk ? 0 : 2;
}
