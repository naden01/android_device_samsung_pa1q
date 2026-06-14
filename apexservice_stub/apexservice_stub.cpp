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
 * Verified live (2026-06-14): that wait was the exact wall.
 *
 * keystore2 only needs ONE answer from it: an empty active-package list. So this tiny
 * binary registers the name "apexservice" with the (A16) servicemanager and answers
 * every call with a no-exception, empty-vector reply. keystore2 reads an empty apex
 * list, finishes startup, registers IKeystoreService, and the vold->keystore2->KeyMint
 * decrypt chain proceeds. It is NOT a real apexd and activates nothing.
 *
 * Built as a recovery cc_binary (see Android.bp) so Soong pulls the recovery variants
 * of libbinder/etc. into the recovery ramdisk. The kernel binder ABI and the
 * android.os.IServiceManager.addService() AIDL are stable across API levels, so this
 * A12-built binary registers fine with the A16 servicemanager that owns /dev/binder.
 */

#define LOG_TAG "apexservice_stub"

#include <binder/Binder.h>
#include <binder/IPCThreadState.h>
#include <binder/IServiceManager.h>
#include <binder/Parcel.h>
#include <binder/ProcessState.h>
#include <log/log.h>
#include <utils/String16.h>

using namespace android;

namespace {

class ApexServiceStub : public BBinder {
public:
    const String16& getInterfaceDescriptor() const override {
        static const String16 kDescriptor(u"android.apex.IApexService");
        return kDescriptor;
    }

protected:
    status_t onTransact(uint32_t code, const Parcel& data, Parcel* reply,
                        uint32_t flags) override {
        // Answer any real method call (getActivePackages, getAllPackages, ...) with the
        // AIDL success shape: a no-exception Status followed by a zero-length vector.
        // The caller (keystore2) reads an empty list and moves on.
        if (code >= IBinder::FIRST_CALL_TRANSACTION &&
            code <= IBinder::LAST_CALL_TRANSACTION) {
            if (reply != nullptr) {
                reply->writeInt32(0);  // binder::Status EX_NONE (no exception)
                reply->writeInt32(0);  // length 0 -> empty array (e.g. ApexInfo[])
            }
            return NO_ERROR;
        }
        // INTERFACE/DUMP/PING/etc. - let BBinder handle normally.
        return BBinder::onTransact(code, data, reply, flags);
    }
};

}  // namespace

int main() {
    sp<ProcessState> ps(ProcessState::self());
    ps->setThreadPoolMaxThreadCount(2);
    ps->startThreadPool();

    sp<IServiceManager> sm(defaultServiceManager());
    if (sm == nullptr) {
        ALOGE("apexservice_stub: no servicemanager");
        return 1;
    }

    sp<ApexServiceStub> svc(new ApexServiceStub());
    status_t st = sm->addService(String16("apexservice"), svc, false /*allowIsolated*/,
                                 IServiceManager::DUMP_FLAG_PRIORITY_DEFAULT);
    ALOGI("apexservice_stub: addService(apexservice) -> %d", st);
    if (st != NO_ERROR) {
        return 1;
    }

    IPCThreadState::self()->joinThreadPool();
    return 0;
}
