/*
 * de_keyinstall - install the systemwide FBE "device" (DE) key into the kernel
 * keyring, for TWRP on the Android-12 base running the Android-16 security stack
 * from the firmware dump.
 *
 * WHY (git history WIP33/34): after decrypt.sh mounts the metadata layer
 * (dm-default-key -> /data on dm-8), the per-file FBE layer is still locked
 * (/data/misc, /data/system_de/0 = encrypted names, /proc/keys = 0 fscrypt keys). Normal
 * boot installs the systemwide DE key via init's `installkey /data` BEFORE init_user0;
 * the A16 vdc has no command for it. WIP33 proved keymaster_key_blob is the AES-GCM KEK
 * (convertStorageKeyToEphemeral on it -> INVALID_KEY_BLOB); the storage key is INSIDE
 * encrypted_key and must be KeyStorage-unwrapped first.
 *
 * KEY MATERIAL (plaintext-at-rest in /data/unencrypted/key/):
 *   keymaster_key_blob (541B)  - the KeyMint AES-GCM KEK
 *   encrypted_key      (671B)  - AES-256-GCM(storage-key-blob, KEK, appId) = [12B nonce][ct][16B tag]
 *   secdiscardable     (16384B)- personalised SHA512 -> appId
 * policy /data/unencrypted/mode = aes-256-xts:aes-256-cts:v2+inlinecrypt_optimized+wrappedkey_v0
 *   => v2 policy, HARDWARE-WRAPPED key. identifier (16B): /data/unencrypted/ref.
 *
 * WHY HAND-MARSHALLED libbinder_ndk (no typed AIDL stubs): the TWRP-12.1 build tree does
 * not provide android.hardware.security.keymint-V1-ndk, and a prebuilt .so cannot supply
 * the C++ headers needed to COMPILE typed calls. So - exactly like apexservice_stub - we
 * talk to the A16 KeyMint with RAW binder transactions over libbinder_ndk (which builds
 * with zero extra deps). The on-the-wire bytes are identical to what the generated stubs
 * would emit; only the marshalling is by hand. Run via the A16 bootstrap linker
 * (decrypt.sh lrun) so this A12-built binary reaches the A16 KeyMint over the A16
 * servicemanager. KeyMint AIDL = V3 on this device; method codes are stable since V1.
 *
 * FLOW (replicates vold KeyStorage::decryptWithKeystoreKey + FsCrypt install):
 *   appId = SHA512( "Android secdiscardable SHA512" padded to 128B || secdiscardable )
 *   begin(DECRYPT, KEK, {BLOCK_MODE=GCM, MAC_LENGTH=128, NONCE, APPLICATION_ID=appId})
 *     [on KEY_REQUIRES_UPGRADE(-62): upgradeKey IN-MEMORY (never persisted) -> retry]
 *   update(ct+tag) + finish() -> storageKeyBlob
 *   convertStorageKeyToEphemeral(storageKeyBlob) -> per-boot ephemeral wrapped key
 *     [fallback: use the unwrapped key directly if INVALID_KEY_BLOB]
 *   FS_IOC_ADD_ENCRYPTION_KEY(HW_WRAPPED, id=IDENTIFIER) -> verify id==ref, /data/misc opens
 *
 * NON-DESTRUCTIVE: keyring-only, per-boot ephemeral, nothing written to disk (the upgraded
 * blob stays in memory). A wrong key is rejected on identifier mismatch. init_user0 is NOT
 * run here (only after the DE key is confirmed in, else vold regenerates the user-0 keys).
 */

#define LOG_TAG "de_keyinstall"

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

#include <cerrno>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <functional>
#include <string>
#include <vector>

#define LINE(...)                                                    \
    do {                                                             \
        fprintf(stdout, __VA_ARGS__);                                \
        fprintf(stdout, "\n");                                       \
        fflush(stdout);                                              \
        __android_log_print(ANDROID_LOG_INFO, LOG_TAG, __VA_ARGS__); \
    } while (0)

// ---- KeyMint AIDL (V3 on device; method codes stable since V1) --------------
static const char* DESC_KEYMINT = "android.hardware.security.keymint.IKeyMintDevice";
static const char* INST_KEYMINT = "android.hardware.security.keymint.IKeyMintDevice/default";
static const char* DESC_OP = "android.hardware.security.keymint.IKeyMintOperation";

static const transaction_code_t TX_UPGRADE_KEY = 6;   // upgradeKey
static const transaction_code_t TX_BEGIN = 10;        // begin
static const transaction_code_t TX_CONVERT = 13;      // convertStorageKeyToEphemeral
static const transaction_code_t TX_OP_UPDATE = 2;     // IKeyMintOperation.update
static const transaction_code_t TX_OP_FINISH = 3;     // IKeyMintOperation.finish
static const transaction_code_t TX_OP_ABORT = 4;      // IKeyMintOperation.abort

// keymaster Tag = (TagType << 28) | id ; values written as int32 on the wire
static const uint32_t TAG_BLOCK_MODE = 0x20000004u;      // ENUM_REP | 4
static const uint32_t TAG_MAC_LENGTH = 0x300003EBu;      // UINT     | 1003
static const uint32_t TAG_NONCE = 0x900003E9u;           // BYTES    | 1001
static const uint32_t TAG_APPLICATION_ID = 0x90000259u;  // BYTES    | 601
// KeyParameterValue union field indices (declaration order)
static const int32_t KPV_blockMode = 2;
static const int32_t KPV_integer = 10;
static const int32_t KPV_blob = 13;
static const int32_t KEYPURPOSE_DECRYPT = 1;
static const int32_t BLOCKMODE_GCM = 32;
static const int32_t ERR_KEY_REQUIRES_UPGRADE = -62;

// ---- fscrypt uapi (defined locally; independent of the A12 header age) -------
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
const int kAppIdHashPersonLen = 128;  // SHA512_CBLOCK (matches vold's secdiscardable hash)

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

void writeBytes(AParcel* p, const std::vector<uint8_t>& v) {
    AParcel_writeByteArray(p, reinterpret_cast<const int8_t*>(v.data()),
                           static_cast<int32_t>(v.size()));
}
void writeNullByteArray(AParcel* p) { AParcel_writeByteArray(p, nullptr, -1); }
void writeNullParcelable(AParcel* p) { AParcel_writeInt32(p, 0); }  // @nullable parcelable = null

// Stable-AIDL parcelable/union: [int32 size placeholder][fields]; back-patch size (incl. itself).
void writeSizePrefixed(AParcel* p, const std::function<void()>& fields) {
    int32_t start = AParcel_getDataPosition(p);
    AParcel_writeInt32(p, 0);
    fields();
    int32_t end = AParcel_getDataPosition(p);
    AParcel_setDataPosition(p, start);
    AParcel_writeInt32(p, end - start);
    AParcel_setDataPosition(p, end);
}

// KeyParameter { Tag tag; KeyParameterValue value; } ; value is itself a size-prefixed union.
void writeKeyParam(AParcel* p, uint32_t tag, int32_t unionIdx,
                   const std::function<void()>& writeVal) {
    writeSizePrefixed(p, [&] {
        AParcel_writeInt32(p, static_cast<int32_t>(tag));
        writeSizePrefixed(p, [&] {
            AParcel_writeInt32(p, unionIdx);
            writeVal();
        });
    });
}

// Generic: transact a two-way method, write args via writeArgs, read the AIDL Status.
// On success and if `ret` != null, read the trailing byte[] return value. Returns true on
// EX_NONE; on a service-specific error, *serviceSpecific holds the KeyMint ErrorCode.
bool callMethod(AIBinder* b, transaction_code_t code,
                const std::function<void(AParcel*)>& writeArgs, std::vector<uint8_t>* ret,
                int32_t* serviceSpecific, const char* tag) {
    if (serviceSpecific) *serviceSpecific = 0;
    AParcel* in = nullptr;
    if (AIBinder_prepareTransaction(b, &in) != STATUS_OK) {
        LINE("  %s: prepareTransaction failed", tag);
        return false;
    }
    writeArgs(in);
    AParcel* out = nullptr;
    binder_status_t tst = AIBinder_transact(b, code, &in, &out, 0);
    if (tst != STATUS_OK) {
        LINE("  %s: transport error %d", tag, tst);
        return false;
    }
    AStatus* st = nullptr;
    if (AParcel_readStatusHeader(out, &st) != STATUS_OK) {
        LINE("  %s: readStatusHeader failed", tag);
        AParcel_delete(out);
        return false;
    }
    bool ok = AStatus_isOk(st);
    if (!ok) {
        if (serviceSpecific) *serviceSpecific = AStatus_getServiceSpecificError(st);
        LINE("  %s: ex=%d serviceSpecific=%d msg=%s", tag, AStatus_getExceptionCode(st),
             AStatus_getServiceSpecificError(st),
             AStatus_getMessage(st) ? AStatus_getMessage(st) : "(none)");
    }
    AStatus_delete(st);
    if (ok && ret) {
        if (AParcel_readByteArray(out, ret, byteArrayAllocator) != STATUS_OK) {
            LINE("  %s: readByteArray(return) failed", tag);
            ok = false;
        }
    }
    AParcel_delete(out);
    return ok;
}

// begin(DECRYPT, kek, params, null authToken) -> reads BeginResult, returns its operation
// binder (+1 ref, caller decStrong). *serviceSpecific gets the error code on failure.
AIBinder* beginDecrypt(AIBinder* km, const std::vector<uint8_t>& kek,
                       const std::vector<uint8_t>& nonce, const std::vector<uint8_t>& appId,
                       int32_t* serviceSpecific) {
    if (serviceSpecific) *serviceSpecific = 0;
    AParcel* in = nullptr;
    if (AIBinder_prepareTransaction(km, &in) != STATUS_OK) return nullptr;
    AParcel_writeInt32(in, KEYPURPOSE_DECRYPT);  // purpose
    writeBytes(in, kek);                         // keyBlob
    AParcel_writeInt32(in, 4);                   // KeyParameter[] count
    writeKeyParam(in, TAG_BLOCK_MODE, KPV_blockMode,
                  [&] { AParcel_writeInt32(in, BLOCKMODE_GCM); });
    writeKeyParam(in, TAG_MAC_LENGTH, KPV_integer, [&] { AParcel_writeInt32(in, 128); });
    writeKeyParam(in, TAG_NONCE, KPV_blob, [&] { writeBytes(in, nonce); });
    writeKeyParam(in, TAG_APPLICATION_ID, KPV_blob, [&] { writeBytes(in, appId); });
    writeNullParcelable(in);  // @nullable HardwareAuthToken authToken = null

    AParcel* out = nullptr;
    if (AIBinder_transact(km, TX_BEGIN, &in, &out, 0) != STATUS_OK) {
        LINE("  begin: transport error");
        return nullptr;
    }
    AStatus* st = nullptr;
    AParcel_readStatusHeader(out, &st);
    bool ok = AStatus_isOk(st);
    if (!ok) {
        if (serviceSpecific) *serviceSpecific = AStatus_getServiceSpecificError(st);
        LINE("  begin: ex=%d serviceSpecific=%d", AStatus_getExceptionCode(st),
             AStatus_getServiceSpecificError(st));
    }
    AStatus_delete(st);
    AIBinder* op = nullptr;
    if (ok) {
        // BeginResult { long challenge; KeyParameter[] params; IKeyMintOperation operation; }
        int32_t bsize = 0;
        AParcel_readInt32(out, &bsize);  // parcelable size header (consume)
        int64_t challenge = 0;
        AParcel_readInt64(out, &challenge);
        int32_t pcount = 0;
        AParcel_readInt32(out, &pcount);
        for (int32_t i = 0; i < pcount; i++) {  // skip each size-prefixed KeyParameter
            int32_t pstart = AParcel_getDataPosition(out);
            int32_t psz = 0;
            AParcel_readInt32(out, &psz);
            AParcel_setDataPosition(out, pstart + psz);
        }
        if (AParcel_readStrongBinder(out, &op) != STATUS_OK) {
            LINE("  begin: readStrongBinder(operation) failed");
            op = nullptr;
        }
    }
    AParcel_delete(out);
    return op;
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

    LINE("material: KEK=%zuB encrypted_key=%zuB secdiscardable=%zuB ref=%zuB", kek.size(),
         encKey.size(), secdisc.size(), ref.size());
    if (!mode.empty())
        LINE("policy: %.*s", static_cast<int>(mode.size()), reinterpret_cast<char*>(mode.data()));
    if (haveRef && ref.size() == KEY_IDENTIFIER_SIZE)
        LINE("expected identifier (ref): %s", hex(ref.data(), ref.size()).c_str());
    if (!haveKek || !haveEnc || !haveSec ||
        static_cast<int>(encKey.size()) <= kGcmNonceLen + 16) {
        LINE("FATAL: missing/short key material (is /data mounted, are we root?)");
        return 1;
    }

    ABinderProcess_setThreadPoolMaxThreadCount(1);
    ABinderProcess_startThreadPool();

    AIBinder_Class* kmClass = AIBinder_Class_define(
        DESC_KEYMINT, [](void* a) { return a; }, [](void*) {},
        [](AIBinder*, transaction_code_t, const AParcel*, AParcel*) {
            return STATUS_UNKNOWN_TRANSACTION;
        });
    AIBinder_Class* opClass = AIBinder_Class_define(
        DESC_OP, [](void* a) { return a; }, [](void*) {},
        [](AIBinder*, transaction_code_t, const AParcel*, AParcel*) {
            return STATUS_UNKNOWN_TRANSACTION;
        });

    AIBinder* km = AServiceManager_getService(INST_KEYMINT);
    if (km == nullptr || !AIBinder_associateClass(km, kmClass)) {
        LINE("FATAL: KeyMint not found / class mismatch - is decrypt-keymint up?");
        return 1;
    }
    LINE("connected to KeyMint (%s)", INST_KEYMINT);

    // appId + GCM nonce / body split
    std::vector<uint8_t> appId = secdiscardableAppId(secdisc);
    LINE("appId (SHA512[0:8]): %s", hex(appId.data(), 8).c_str());
    std::vector<uint8_t> nonce(encKey.begin(), encKey.begin() + kGcmNonceLen);
    std::vector<uint8_t> body(encKey.begin() + kGcmNonceLen, encKey.end());

    // begin(DECRYPT) with in-memory upgrade-on-(-62) retry
    LINE("begin(DECRYPT) on the KEK...");
    int32_t ss = 0;
    AIBinder* op = beginDecrypt(km, kek, nonce, appId, &ss);
    if (op == nullptr && ss == ERR_KEY_REQUIRES_UPGRADE) {
        LINE("KEY_REQUIRES_UPGRADE -> upgradeKey in-memory (not persisted)");
        std::vector<uint8_t> upgraded;
        int32_t uss = 0;
        bool uok = callMethod(
            km, TX_UPGRADE_KEY,
            [&](AParcel* p) {
                writeBytes(p, kek);
                AParcel_writeInt32(p, 1);  // upgradeParams: [APPLICATION_ID]
                writeKeyParam(p, TAG_APPLICATION_ID, KPV_blob, [&] { writeBytes(p, appId); });
            },
            &upgraded, &uss, "upgradeKey");
        if (uok && !upgraded.empty()) {
            LINE("upgraded KEK: %zuB; retrying begin", upgraded.size());
            op = beginDecrypt(km, upgraded, nonce, appId, &ss);
        }
    }
    if (op == nullptr) {
        LINE("UNWRAP FAILED at begin (serviceSpecific=%d).", ss);
        LINE("  -33 INVALID_KEY_BLOB => KEK wants APPLICATION_DATA too, or wrong appId");
        LINE("===== de_keyinstall done (begin failed) =====");
        AIBinder_decStrong(km);
        return 2;
    }
    if (!AIBinder_associateClass(op, opClass)) {
        LINE("FATAL: operation binder class mismatch");
        AIBinder_decStrong(op);
        AIBinder_decStrong(km);
        return 2;
    }

    // update(ct+tag) + finish() -> storage key blob
    std::vector<uint8_t> part1, part2;
    if (!callMethod(op, TX_OP_UPDATE,
                    [&](AParcel* p) {
                        writeBytes(p, body);     // input
                        writeNullParcelable(p);  // authToken
                        writeNullParcelable(p);  // timeStampToken
                    },
                    &part1, nullptr, "update")) {
        callMethod(op, TX_OP_ABORT, [](AParcel*) {}, nullptr, nullptr, "abort");
        AIBinder_decStrong(op);
        AIBinder_decStrong(km);
        LINE("===== de_keyinstall done (update failed) =====");
        return 2;
    }
    int32_t fss = 0;
    bool fok = callMethod(op, TX_OP_FINISH,
                          [](AParcel* p) {
                              writeNullByteArray(p);   // input
                              writeNullByteArray(p);   // signature
                              writeNullParcelable(p);  // authToken
                              writeNullParcelable(p);  // timeStampToken
                              writeNullByteArray(p);   // confirmationToken
                          },
                          &part2, &fss, "finish");
    AIBinder_decStrong(op);
    if (!fok) {
        LINE("UNWRAP FAILED at finish (serviceSpecific=%d).", fss);
        LINE("  -30 VERIFICATION_FAILED => GCM tag/body split wrong");
        LINE("===== de_keyinstall done (finish failed) =====");
        AIBinder_decStrong(km);
        return 2;
    }
    std::vector<uint8_t> storageKey;
    storageKey.insert(storageKey.end(), part1.begin(), part1.end());
    storageKey.insert(storageKey.end(), part2.begin(), part2.end());
    LINE("storage key unwrapped: %zuB", storageKey.size());

    // storage key -> per-boot ephemeral wrapped key (FBE uses the ephemeral form)
    std::vector<uint8_t> installKey, ephemeral;
    int32_t cs = 0;
    bool conv = callMethod(km, TX_CONVERT, [&](AParcel* p) { writeBytes(p, storageKey); },
                           &ephemeral, &cs, "convertStorageKeyToEphemeral");
    AIBinder_decStrong(km);
    if (conv && !ephemeral.empty()) {
        LINE("convertStorageKeyToEphemeral OK: %zuB", ephemeral.size());
        installKey = std::move(ephemeral);
    } else {
        LINE("convert failed/empty (ss=%d) -> using unwrapped key as long-term wrapped", cs);
        installKey = storageKey;
    }

    // install into the kernel keyring, hardware-wrapped
    LINE("FS_IOC_ADD_ENCRYPTION_KEY (HW_WRAPPED, raw=%zuB)...", installKey.size());
    int dfd = open("/data", O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    if (dfd < 0) {
        LINE("FATAL: open(/data): %s", strerror(errno));
        return 3;
    }
    size_t argSize = sizeof(struct fscrypt_add_key_arg_local) + installKey.size();
    std::vector<uint8_t> argBuf(argSize, 0);
    auto* arg = reinterpret_cast<struct fscrypt_add_key_arg_local*>(argBuf.data());
    arg->key_spec.type = KEY_SPEC_TYPE_IDENTIFIER;
    arg->raw_size = static_cast<__u32>(installKey.size());
    arg->__flags = ADD_KEY_FLAG_HW_WRAPPED;
    memcpy(arg->raw, installKey.data(), installKey.size());
    int rc = ioctl(dfd, FS_IOC_ADD_ENCRYPTION_KEY_LOCAL, arg);
    int e = errno;
    close(dfd);
    if (rc != 0) {
        LINE("  ioctl FS_IOC_ADD_ENCRYPTION_KEY failed: errno=%d (%s)", e, strerror(e));
        LINE("  EINVAL => wrong key form (flip ephemeral<->long-term)");
        LINE("===== de_keyinstall done (ioctl failed) =====");
        return 3;
    }
    std::string gotId = hex(arg->key_spec.u.identifier, KEY_IDENTIFIER_SIZE);
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
