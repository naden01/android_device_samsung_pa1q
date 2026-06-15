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
#include <openssl/sha.h>

#include <fcntl.h>
#include <linux/ioctl.h>
#include <linux/types.h>
#include <sys/ioctl.h>
#include <unistd.h>

#include <algorithm>
#include <cerrno>
#include <cstdint>
#include <cstdio>
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

// AParcel byte[] reader (for hand-marshalled IWeaver replies).
bool byteArrayAllocator(void* arrayData, int32_t length, int8_t** outBuffer) {
    auto* vec = static_cast<std::vector<uint8_t>*>(arrayData);
    if (length < 0) {
        *outBuffer = nullptr;
        return true;
    }
    vec->resize(length);
    *outBuffer = reinterpret_cast<int8_t*>(vec->data());
    return true;
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
bool readWeaverSlot0(std::vector<uint8_t>* outValue) {
    (void)outValue;  // debug build dumps raw reply and returns false; outValue unused for now
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
            int32_t psize = 0;
            AParcel_readInt32(out, &psize);  // parcelable size header
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

    // stretchedLskf = "default-password" zero-padded to 32B; weaverKey = hash[:keySize]
    std::vector<uint8_t> stretchedLskf(32, 0);
    const char* dp = "default-password";
    memcpy(stretchedLskf.data(), dp, strlen(dp));
    std::vector<uint8_t> weaverKey = personalizedHash("weaver-key", stretchedLskf);
    weaverKey.resize(keySize);
    LINE("  weaverKey[:8]=%s (from empty-LSKF)", hex(weaverKey.data(), 8).c_str());

    // read(slotId=0, key) = tx 2 -> WeaverReadResponse{ long timeout; byte[] value; status }
    AParcel* in = nullptr;
    if (AIBinder_prepareTransaction(weaver, &in) != STATUS_OK) return false;
    AParcel_writeInt32(in, 0);  // slotId
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
    // DEBUG: dump the raw reply words to nail the WeaverReadResponse wire framing.
    int32_t startPos = AParcel_getDataPosition(out);
    int32_t endPos = AParcel_getDataSize(out);
    LINE("  weaver reply raw (pos=%d size=%d):", startPos, endPos);
    std::string words;
    for (int32_t p = startPos; p + 4 <= endPos; p += 4) {
        AParcel_setDataPosition(out, p);
        int32_t w = 0;
        AParcel_readInt32(out, &w);
        char buf[16];
        snprintf(buf, sizeof(buf), "%08x ", static_cast<uint32_t>(w));
        words += buf;
    }
    LINE("  words: %s", words.c_str());
    AParcel_delete(out);
    return false;  // debug build - just dump, don't proceed
}

KeyParameter kpEnum(Tag tag, KeyParameterValue v) { return KeyParameter{tag, std::move(v)}; }

void logStatus(const char* what, const ::ndk::ScopedAStatus& st) {
    LINE("  %s: ex=%d serviceSpecific=%d msg=%s", what, st.getExceptionCode(),
         st.getServiceSpecificError(),
         st.getMessage() ? st.getMessage() : "(none)");
}

// vold KeyStorage::decryptWithKeystoreKey: AES-256-GCM decrypt encrypted_key with the KEK.
bool unwrapStorageKey(const std::shared_ptr<IKeyMintDevice>& km, std::vector<uint8_t> kek,
                      const std::vector<uint8_t>& encryptedKey,
                      const std::vector<uint8_t>& appId, std::vector<uint8_t>* out) {
    if (static_cast<int>(encryptedKey.size()) <= kGcmNonceLen + 16) {
        LINE("  encrypted_key too small (%zuB)", encryptedKey.size());
        return false;
    }
    std::vector<uint8_t> nonce(encryptedKey.begin(), encryptedKey.begin() + kGcmNonceLen);
    std::vector<uint8_t> body(encryptedKey.begin() + kGcmNonceLen, encryptedKey.end());

    std::vector<KeyParameter> params;
    params.push_back(kpEnum(Tag::BLOCK_MODE,
                            KeyParameterValue::make<KeyParameterValue::blockMode>(BlockMode::GCM)));
    // vold's GcmModeMacLen sets PADDING=NONE alongside GCM+MAC_LENGTH; omitting it makes
    // KeyMint reject begin with UNSUPPORTED_PADDING_MODE(-10).
    params.push_back(kpEnum(Tag::PADDING,
                            KeyParameterValue::make<KeyParameterValue::paddingMode>(PaddingMode::NONE)));
    params.push_back(kpEnum(Tag::MAC_LENGTH,
                            KeyParameterValue::make<KeyParameterValue::integer>(128)));
    params.push_back(kpEnum(Tag::NONCE,
                            KeyParameterValue::make<KeyParameterValue::blob>(nonce)));
    params.push_back(kpEnum(Tag::APPLICATION_ID,
                            KeyParameterValue::make<KeyParameterValue::blob>(appId)));

    BeginResult begun;
    auto st = km->begin(KeyPurpose::DECRYPT, kek, params, std::nullopt, &begun);
    if (st.getServiceSpecificError() == -62 /*KEY_REQUIRES_UPGRADE*/) {
        LINE("  begin -> KEY_REQUIRES_UPGRADE; upgrading KEK in-memory (not persisted)");
        std::vector<uint8_t> upgraded;
        std::vector<KeyParameter> upParams;
        upParams.push_back(kpEnum(Tag::APPLICATION_ID,
                                  KeyParameterValue::make<KeyParameterValue::blob>(appId)));
        auto ust = km->upgradeKey(kek, upParams, &upgraded);
        if (!ust.isOk()) {
            logStatus("upgradeKey", ust);
            return false;
        }
        kek = std::move(upgraded);
        st = km->begin(KeyPurpose::DECRYPT, kek, params, std::nullopt, &begun);
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
    if (!unwrapStorageKey(km, kek, encKey, appId, &storageKey)) return false;
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

}  // namespace

static bool dirReadable(const char* path) {
    int fd = open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    if (fd < 0) return false;
    close(fd);
    return true;
}

int main() {
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

    // CE stage 1: read Weaver slot 0 with the empty-LSKF-derived key. A status of OK proves
    // the whole empty-credential derivation (stretchedLskf -> weaverKey) is correct and gives
    // us the weaver value needed for the synthetic-password unwrap (stages 2-4, next).
    if (sysOk && dirReadable("/data/system_de/0")) {
        LINE("--- CE stage 1: Weaver slot 0 read ---");
        std::vector<uint8_t> weaverValue;
        if (readWeaverSlot0(&weaverValue)) {
            LINE("CE stage 1 OK: weaver slot 0 unlocked (%zuB) - empty-LSKF derivation correct",
                 weaverValue.size());
        } else {
            LINE("CE stage 1: weaver read did not return OK (see status above)");
        }
    }

    LINE("===== de_keyinstall done =====");
    return sysOk ? 0 : 2;
}
