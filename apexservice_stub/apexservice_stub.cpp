/*
 * apexservice_stub - minimal stand-in for android.apex.IApexService, for TWRP.
 *
 * Why this exists: when we run the full Android-16 security stack from the firmware
 * dump inside the Android-12 TWRP base to decrypt /data, the A16 keystore2 blocks
 * during startup on waitForService("apexservice") -> IApexService.getActivePackages().
 * In a normal boot that service is provided by apexd, but apexd cannot run in TWRP
 * (it crashes on apex activation - no real /data, loop/dm-verity, runtime apex linker
 * namespace). With apexservice never appearing, keystore2 never registers
 * IKeystoreService, so vold can never fetch the metadata key and /data never mounts.
 *
 * keystore2 only needs ONE answer from it: an empty active-package list. So this tiny
 * binary registers the name "apexservice" with the (A16) servicemanager and answers
 * every call with a no-exception, empty-vector reply. keystore2 reads an empty apex
 * list, finishes startup, registers IKeystoreService, and the vold->keystore2->KeyMint
 * decrypt chain proceeds. It is NOT a real apexd and activates nothing.
 *
 * CRITICAL - why libbinder_ndk and not C++ libbinder: this binary is built in the
 * Android-12 TWRP tree but must register with the Android-16 servicemanager that owns
 * /dev/binder. The C++ libbinder android.os.IServiceManager.addService() WIRE FORMAT
 * is NOT stable A12<->A16: an A12-marshalled addService made the A16 servicemanager
 * reply EX_BAD_PARCELABLE (status_t -2) and the stub exited, so keystore2 spun forever
 * on waitForService. The NDK binder ABI (libbinder_ndk) IS frozen across API levels,
 * so we use AServiceManager_addService() and run this via hal_run.sh (bootstrap linker
 * + the A16 libbinder_ndk.so from the dump): our A12-compiled NDK calls bind to the
 * A16 exports and the A16 library does the version-correct marshalling. Every other
 * daemon in this decrypt stack (keymint, keystore2, vold) is likewise an A16 binary
 * run through the bootstrap linker - this stub now matches that model.
 */

#define LOG_TAG "apexservice_stub"

#include <android/binder_ibinder.h>
#include <android/binder_manager.h>
#include <android/binder_parcel.h>
#include <android/binder_process.h>
#include <android/binder_status.h>
#include <android/log.h>

namespace {

// No per-instance state: the stub is stateless.
void* OnCreate(void* /*args*/) { return nullptr; }
void OnDestroy(void* /*userData*/) {}

// libbinder_ndk only routes real method calls (FIRST_CALL..LAST_CALL) here; PING,
// DUMP and INTERFACE transactions are handled below us. Answer ANY method
// (getActivePackages, getAllPackages, ...) with the AIDL success shape: a no-exception
// Status (int32 0) followed by a zero-length vector (int32 0). The caller (keystore2)
// reads an empty list and moves on.
binder_status_t OnTransact(AIBinder* /*binder*/, transaction_code_t /*code*/,
                           const AParcel* /*in*/, AParcel* out) {
    if (out != nullptr) {
        AParcel_writeInt32(out, 0);  // binder Status: EX_NONE (no exception)
        AParcel_writeInt32(out, 0);  // length 0 -> empty array (e.g. ApexInfo[])
    }
    return STATUS_OK;
}

}  // namespace

int main() {
    ABinderProcess_setThreadPoolMaxThreadCount(2);
    ABinderProcess_startThreadPool();

    AIBinder_Class* clazz = AIBinder_Class_define(
        "android.apex.IApexService", OnCreate, OnDestroy, OnTransact);
    if (clazz == nullptr) {
        __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, "AIBinder_Class_define failed");
        return 1;
    }

    AIBinder* binder = AIBinder_new(clazz, nullptr);
    if (binder == nullptr) {
        __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, "AIBinder_new failed");
        return 1;
    }

    binder_status_t st = AServiceManager_addService(binder, "apexservice");
    __android_log_print(ANDROID_LOG_INFO, LOG_TAG, "addService(apexservice) -> %d", st);
    if (st != STATUS_OK) {
        AIBinder_decStrong(binder);
        return 1;
    }

    ABinderProcess_joinThreadPool();

    AIBinder_decStrong(binder);  // not reached
    return 0;
}
