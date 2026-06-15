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
#include <android/binder_manager.h>
#include <android/binder_process.h>
#include <android/log.h>
#include <openssl/sha.h>

#include <fcntl.h>
#include <linux/ioctl.h>
#include <linux/types.h>
#include <sys/ioctl.h>
#include <unistd.h>

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
    __u32 __flags;
    __u32 __reserved[7];
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

// appId = SHA512( "Android secdiscardable SHA512" zero-padded to 128B || secdiscardable )
std::vector<uint8_t> secdiscardableAppId(const std::vector<uint8_t>& sd) {
    SHA512_CTX c;
    SHA512_Init(&c);
    char person[kAppIdHashPersonLen];
    memset(person, 0, sizeof(person));
    const char* prefix = "Android secdiscardable SHA512";
    memcpy(person, prefix, strlen(prefix));
    SHA512_Update(&c, person, sizeof(person));
    SHA512_Update(&c, sd.data(), sd.size());
    std::vector<uint8_t> out(SHA512_DIGEST_LENGTH);
    SHA512_Final(out.data(), &c);
    return out;
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

}  // namespace

int main() {
    LINE("===== de_keyinstall start =====");

    const std::string kdir = "/data/unencrypted/key/";
    std::vector<uint8_t> kek, encKey, secdisc, ref, mode;
    bool haveKek = readFile(kdir + "keymaster_key_blob", &kek);
    bool haveEnc = readFile(kdir + "encrypted_key", &encKey);
    bool haveSec = readFile(kdir + "secdiscardable", &secdisc);
    bool haveRef = readFile("/data/unencrypted/ref", &ref);
    readFile("/data/unencrypted/mode", &mode);

    LINE("material: KEK=%zuB encrypted_key=%zuB secdiscardable=%zuB ref=%zuB",
         kek.size(), encKey.size(), secdisc.size(), ref.size());
    if (!mode.empty())
        LINE("policy: %.*s", static_cast<int>(mode.size()), reinterpret_cast<char*>(mode.data()));
    if (haveRef && ref.size() == KEY_IDENTIFIER_SIZE)
        LINE("expected identifier (ref): %s", hex(ref.data(), ref.size()).c_str());
    if (!haveKek || !haveEnc || !haveSec) {
        LINE("FATAL: missing key material (is /data mounted, are we root?)");
        return 1;
    }

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

    // step 1+2+3: derive appId, unwrap the storage key from encrypted_key via the KEK
    std::vector<uint8_t> appId = secdiscardableAppId(secdisc);
    LINE("appId (SHA512): %s", hex(appId.data(), 8).c_str());
    LINE("unwrapping storage key (begin/update/finish AES-256-GCM)...");
    std::vector<uint8_t> storageKey;
    if (!unwrapStorageKey(km, kek, encKey, appId, &storageKey)) {
        LINE("UNWRAP FAILED - see status above.");
        LINE("  INVALID_KEY_BLOB(-33) => KEK needs APPLICATION_DATA too, or wrong appId hash");
        LINE("  VERIFICATION_FAILED(-30) => GCM tag/body split wrong (tag handling)");
        LINE("===== de_keyinstall done (unwrap failed) =====");
        return 2;
    }
    LINE("storage key unwrapped: %zuB", storageKey.size());

    // step 4: storage key -> per-boot ephemeral wrapped key (FBE uses the ephemeral form)
    std::vector<uint8_t> installKey;
    std::vector<uint8_t> ephemeral;
    auto cst = km->convertStorageKeyToEphemeral(storageKey, &ephemeral);
    if (cst.isOk()) {
        LINE("convertStorageKeyToEphemeral OK: %zuB", ephemeral.size());
        installKey = std::move(ephemeral);
    } else {
        logStatus("convertStorageKeyToEphemeral", cst);
        LINE("  -> falling back to the unwrapped key as the long-term wrapped key");
        installKey = storageKey;
    }

    // step 5: install into the kernel keyring, hardware-wrapped
    LINE("FS_IOC_ADD_ENCRYPTION_KEY (HW_WRAPPED, raw=%zuB)...", installKey.size());
    std::string gotId;
    int rc = addHwWrappedKey(installKey, &gotId);
    if (rc != 0) {
        LINE("  EINVAL => wrong key form (try the other of ephemeral/long-term)");
        LINE("===== de_keyinstall done (ioctl failed) =====");
        return 3;
    }
    LINE("KEY INSTALLED. kernel-derived identifier: %s", gotId.c_str());
    if (haveRef && ref.size() == KEY_IDENTIFIER_SIZE) {
        std::string want = hex(ref.data(), ref.size());
        LINE("identifier %s ref (%s)", gotId == want ? "==" : "!=", want.c_str());
    }

    int mfd = open("/data/misc", O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    if (mfd >= 0) {
        close(mfd);
        LINE("VERIFY: /data/misc now opens - DE layer UNLOCKED");
    } else {
        LINE("VERIFY: /data/misc still %s", strerror(errno));
    }
    LINE("===== de_keyinstall done (installed) =====");
    return 0;
}
