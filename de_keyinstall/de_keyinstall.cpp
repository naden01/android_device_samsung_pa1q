/*
 * de_keyinstall - install the systemwide FBE "device" (DE) key into the kernel
 * keyring, for TWRP on the Android-12 base running the Android-16 security stack
 * from the firmware dump.
 *
 * WHY THIS EXISTS
 * ---------------
 * After decrypt.sh mounts the metadata layer (dm-default-key -> /data on dm-8), the
 * per-file FBE layer is still locked: /data/misc, /data/system_de/0 show encrypted
 * names and /proc/keys has zero fscrypt keys. The first FBE domino is the SYSTEMWIDE
 * DE key (no user credential). In a normal boot, init's `installkey /data` builtin
 * installs it BEFORE `init_user0`; we never ran that step, so init_user0 returns -8
 * (it can't even mkdir /data/misc/vold/user_keys - that dir is under the DE-locked
 * /data/misc). The A16 vdc has NO command for it (enablefilecrypto is not a vdc verb;
 * its IVold client surface is only mountFstab/encryptFstab). So we install it directly.
 *
 * The key material lives, plaintext-at-rest, in /data/unencrypted/key/ :
 *   keymaster_key_blob (541B)  - KeyMint storage-key blob (DER, the wrap KEK/storage key)
 *   encrypted_key      (671B)  - the wrapped fscrypt key material
 *   secdiscardable     (16384B)- entropy mixed into key derivation (secure-delete)
 * and the policy is /data/unencrypted/mode :
 *   aes-256-xts:aes-256-cts:v2+inlinecrypt_optimized+wrappedkey_v0
 * => v2 policy, HARDWARE-WRAPPED key (`wrappedkey_v0`): the raw key never exists in
 * software; KeyMint produces a per-boot "ephemeral wrapped key" that the kernel/UFS
 * inline-crypto (ICE) imports. Identifier (16B, v2): /data/unencrypted/ref.
 *
 * WHAT THIS DOES (WIP34 - first hypothesis test, NON-DESTRUCTIVE)
 * --------------------------------------------------------------
 * The simplest model (matches how dm-default-key consumes a storage key):
 *   1. IKeyMintDevice.convertStorageKeyToEphemeral(keymaster_key_blob) -> ephemeral key
 *   2. FS_IOC_ADD_ENCRYPTION_KEY on the /data mount fd, with FSCRYPT_ADD_KEY_FLAG_HW_WRAPPED
 *      and key_spec.type = IDENTIFIER (kernel derives the identifier and returns it).
 *   3. Verify the kernel-derived identifier == ref, then probe that /data/misc is readable.
 * Every step is logged (stdout -> decrypt.log, and logcat). If convertStorageKeyToEphemeral
 * or the ioctl fails, the log pinpoints exactly which step to fix next iteration (e.g. the
 * key may first need a KeyStorage AES-GCM unwrap of encrypted_key before conversion).
 *
 * NON-DESTRUCTIVE: adding a key to the keyring writes NOTHING to disk; hw-wrapped keys
 * are per-boot ephemeral (a reboot reverts). A wrong key is rejected by the kernel on
 * identifier mismatch, never silently mis-installed. We deliberately do NOT run init_user0
 * here - that comes only AFTER the DE key is confirmed in, or vold would regenerate
 * (= overwrite) the real user-0 keys.
 *
 * WHY libbinder_ndk (not C++ libbinder), run via hal_run.sh: identical to apexservice_stub
 * - this A12-built binary must talk to the A16 KeyMint over the A16 servicemanager that
 * owns /dev/binder. The NDK binder ABI is frozen across API levels; we associate a class
 * with the exact KeyMint descriptor and transact the stable method code by hand, so no
 * generated AIDL stubs (absent in the TWRP-12.1 tree) are needed.
 */

#define LOG_TAG "de_keyinstall"

#include <android/binder_ibinder.h>
#include <android/binder_manager.h>
#include <android/binder_parcel.h>
#include <android/binder_process.h>
#include <android/binder_status.h>
#include <android/log.h>

#include <fcntl.h>
#include <linux/ioctl.h>
#include <linux/types.h>
#include <sys/ioctl.h>
#include <unistd.h>

#include <cerrno>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

// ---- logging: to stdout (decrypt.sh captures) AND logcat -------------------
#define LINE(...)                                                       \
    do {                                                                \
        fprintf(stdout, __VA_ARGS__);                                   \
        fprintf(stdout, "\n");                                          \
        fflush(stdout);                                                 \
        __android_log_print(ANDROID_LOG_INFO, LOG_TAG, __VA_ARGS__);    \
    } while (0)

// ---- KeyMint AIDL (V3 on this device) --------------------------------------
static const char* kKeyMintDescriptor =
    "android.hardware.security.keymint.IKeyMintDevice";
static const char* kKeyMintInstance =
    "android.hardware.security.keymint.IKeyMintDevice/default";
// IKeyMintDevice method order is stable/append-only since V1; convertStorageKeyToEphemeral
// is the 13th method -> FIRST_CALL_TRANSACTION(1) + index 12 = code 13.
static const transaction_code_t TX_convertStorageKeyToEphemeral = 13;

// ---- fscrypt uapi (define locally so we don't depend on A12 header age) -----
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

// ----------------------------------------------------------------------------
namespace {

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

// AParcel byte[] reader: NDK needs an allocator callback that resizes our vector.
bool byteArrayAllocator(void* arrayData, int32_t length, int8_t** outBuffer) {
    auto* vec = static_cast<std::vector<uint8_t>*>(arrayData);
    if (length < 0) {  // AIDL null array
        *outBuffer = nullptr;
        return true;
    }
    vec->resize(length);
    *outBuffer = reinterpret_cast<int8_t*>(vec->data());
    return true;
}

// IKeyMintDevice.convertStorageKeyToEphemeral(byte[] storageKeyBlob) -> byte[]
bool convertStorageKeyToEphemeral(AIBinder* km, const std::vector<uint8_t>& storageKey,
                                  std::vector<uint8_t>* ephemeral) {
    AParcel* in = nullptr;
    binder_status_t st = AIBinder_prepareTransaction(km, &in);
    if (st != STATUS_OK) {
        LINE("  prepareTransaction failed: %d", st);
        return false;
    }
    st = AParcel_writeByteArray(in, reinterpret_cast<const int8_t*>(storageKey.data()),
                                static_cast<int32_t>(storageKey.size()));
    if (st != STATUS_OK) {
        LINE("  writeByteArray(storageKeyBlob) failed: %d", st);
        AParcel_delete(in);
        return false;
    }
    AParcel* out = nullptr;
    st = AIBinder_transact(km, TX_convertStorageKeyToEphemeral, &in, &out, 0 /*flags*/);
    if (st != STATUS_OK) {
        LINE("  transact(convertStorageKeyToEphemeral=13) transport error: %d", st);
        return false;
    }
    AStatus* status = nullptr;
    st = AParcel_readStatusHeader(out, &status);
    if (st != STATUS_OK) {
        LINE("  readStatusHeader failed: %d", st);
        AParcel_delete(out);
        return false;
    }
    bool ok = AStatus_isOk(status);
    if (!ok) {
        LINE("  KeyMint returned exception: code=%d serviceSpecific=%d msg=%s",
             AStatus_getExceptionCode(status), AStatus_getServiceSpecificError(status),
             AStatus_getMessage(status) ? AStatus_getMessage(status) : "(none)");
    }
    AStatus_delete(status);
    if (ok) {
        st = AParcel_readByteArray(out, ephemeral, byteArrayAllocator);
        if (st != STATUS_OK) {
            LINE("  readByteArray(ephemeral) failed: %d", st);
            ok = false;
        }
    }
    AParcel_delete(out);
    return ok;
}

// Stubs: we are a CLIENT; the associated class never receives inbound transactions.
void* OnCreate(void* args) { return args; }
void OnDestroy(void*) {}
binder_status_t OnTransact(AIBinder*, transaction_code_t, const AParcel*, AParcel*) {
    return STATUS_UNKNOWN_TRANSACTION;
}

}  // namespace

int main() {
    LINE("===== de_keyinstall start =====");

    // --- read the on-disk DE key material -----------------------------------
    const std::string kdir = "/data/unencrypted/key/";
    std::vector<uint8_t> kmBlob, encKey, secdisc, ref, mode;
    bool haveBlob = readFile(kdir + "keymaster_key_blob", &kmBlob);
    readFile(kdir + "encrypted_key", &encKey);
    readFile(kdir + "secdiscardable", &secdisc);
    bool haveRef = readFile("/data/unencrypted/ref", &ref);
    readFile("/data/unencrypted/mode", &mode);

    LINE("material: keymaster_key_blob=%zuB encrypted_key=%zuB secdiscardable=%zuB ref=%zuB",
         kmBlob.size(), encKey.size(), secdisc.size(), ref.size());
    if (!mode.empty())
        LINE("policy mode: %.*s", static_cast<int>(mode.size()),
             reinterpret_cast<char*>(mode.data()));
    if (haveRef && ref.size() == KEY_IDENTIFIER_SIZE)
        LINE("expected fscrypt identifier (ref): %s", hex(ref.data(), ref.size()).c_str());

    if (!haveBlob || kmBlob.empty()) {
        LINE("FATAL: cannot read keymaster_key_blob - is /data mounted and are we root?");
        return 1;
    }

    // --- connect to A16 KeyMint over the A16 servicemanager -----------------
    ABinderProcess_setThreadPoolMaxThreadCount(1);
    ABinderProcess_startThreadPool();

    AIBinder_Class* clazz =
        AIBinder_Class_define(kKeyMintDescriptor, OnCreate, OnDestroy, OnTransact);
    AIBinder* km = AServiceManager_getService(kKeyMintInstance);
    if (km == nullptr) {
        LINE("FATAL: %s not found - is decrypt-keymint up?", kKeyMintInstance);
        return 1;
    }
    if (!AIBinder_associateClass(km, clazz)) {
        LINE("FATAL: associateClass mismatch - remote is not %s", kKeyMintDescriptor);
        AIBinder_decStrong(km);
        return 1;
    }
    LINE("connected to KeyMint (%s)", kKeyMintInstance);

    // --- hypothesis A: storage key blob -> ephemeral wrapped key ------------
    LINE("convertStorageKeyToEphemeral(keymaster_key_blob, %zuB)...", kmBlob.size());
    std::vector<uint8_t> ephemeral;
    bool converted = convertStorageKeyToEphemeral(km, kmBlob, &ephemeral);
    AIBinder_decStrong(km);

    if (!converted) {
        LINE("convertStorageKeyToEphemeral FAILED.");
        LINE("=> next iteration: encrypted_key likely needs a KeyStorage AES-GCM unwrap");
        LINE("   (begin/update/finish, appId=hash(secdiscardable)) before conversion.");
        LINE("===== de_keyinstall done (convert failed) =====");
        return 2;
    }
    LINE("ephemeral wrapped key obtained: %zuB", ephemeral.size());

    // --- install into the kernel keyring with the HW-wrapped flag -----------
    int dfd = open("/data", O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    if (dfd < 0) {
        LINE("FATAL: open(/data) failed: %s", strerror(errno));
        return 3;
    }
    size_t argSize = sizeof(struct fscrypt_add_key_arg_local) + ephemeral.size();
    std::vector<uint8_t> argBuf(argSize, 0);
    auto* arg = reinterpret_cast<struct fscrypt_add_key_arg_local*>(argBuf.data());
    arg->key_spec.type = KEY_SPEC_TYPE_IDENTIFIER;  // kernel derives & returns the id
    arg->raw_size = static_cast<__u32>(ephemeral.size());
    arg->__flags = ADD_KEY_FLAG_HW_WRAPPED;
    memcpy(arg->raw, ephemeral.data(), ephemeral.size());

    LINE("FS_IOC_ADD_ENCRYPTION_KEY (HW_WRAPPED, raw=%zuB)...", ephemeral.size());
    int rc = ioctl(dfd, FS_IOC_ADD_ENCRYPTION_KEY_LOCAL, arg);
    int e = errno;
    close(dfd);
    if (rc != 0) {
        LINE("ioctl FAILED: rc=%d errno=%d (%s)", rc, e, strerror(e));
        LINE("  EINVAL/EOPNOTSUPP => wrong key form (try long-term wrapped, not ephemeral)");
        LINE("  ENOTTY/EOPNOTSUPP => kernel lacks hw-wrapped fscrypt support on this fd");
        LINE("===== de_keyinstall done (ioctl failed) =====");
        return 4;
    }

    std::string gotId = hex(arg->key_spec.u.identifier, KEY_IDENTIFIER_SIZE);
    LINE("KEY INSTALLED. kernel-derived identifier: %s", gotId.c_str());
    if (haveRef && ref.size() == KEY_IDENTIFIER_SIZE) {
        std::string want = hex(ref.data(), ref.size());
        LINE("identifier %s ref (%s)", gotId == want ? "==" : "!=", want.c_str());
        if (gotId != want)
            LINE("  WARNING: id != ref - key installed but is NOT the DE key for this policy");
    }

    // --- prove it: /data/misc should now be readable (was ENOKEY) -----------
    int mfd = open("/data/misc", O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    if (mfd >= 0) {
        close(mfd);
        LINE("VERIFY: /data/misc now opens - DE layer UNLOCKED");
    } else {
        LINE("VERIFY: /data/misc still %s (id may not match the policy)", strerror(errno));
    }
    LINE("===== de_keyinstall done (installed) =====");
    return 0;
}
