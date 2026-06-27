# A/B
AB_OTA_UPDATER := true

AB_OTA_PARTITIONS += \
    dtbo \
    boot \
    vendor_dlkm \
    init_boot \
    system \
    product \
    system_ext \
    vbmeta \
    system_dlkm \
    vendor \
    vbmeta_system \
    odm \
    vendor_boot

AB_OTA_POSTINSTALL_CONFIG += \
    RUN_POSTINSTALL_system=true \
    POSTINSTALL_PATH_system=system/bin/otapreopt_script \
    FILESYSTEM_TYPE_system=erofs \
    POSTINSTALL_OPTIONAL_system=true

# Boot control
PRODUCT_PACKAGES += \
    android.hardware.boot@1.2-impl-qti.recovery \
    bootctrl.sun.recovery

# fastbootd
PRODUCT_PACKAGES += \
    android.hardware.fastboot@1.1-impl-mock \
    fastbootd

# apexservice stub for the A16-stack /data decrypt (built as a system binary; relinked
# into the recovery ramdisk via TW_RECOVERY_ADDITIONAL_RELINK_BINARY_FILES in
# BoardConfig.mk). See apexservice_stub/ and recovery/root/system/bin/decrypt.sh.
PRODUCT_PACKAGES += \
    apexservice_stub

# de_keyinstall - installs the systemwide FBE (DE) key into the kernel keyring after the
# metadata layer is mounted (next FBE domino). Same system-binary + relink model as the
# apexservice stub. See de_keyinstall/ and recovery/root/system/bin/decrypt.sh.
PRODUCT_PACKAGES += \
    de_keyinstall

# Recovery scripts for the device tree (decrypt.sh is the main A16-stack orchestrator;
# pre_restore_data.sh is a hook TWRP calls before Restore /data to setup dm-default-key
# + FBE keys so file-based restore writes through the metadata-encryption layer).
# remount_data/remount_watcher handle GUI unmount/remount without rebooting.
# password is the CE-unlock helper for PIN/password credentials.
# All copied to recovery /system/bin/ (already in recovery/root/system/bin/).

# Partitions
PRODUCT_USE_DYNAMIC_PARTITIONS := true

# Soong namespaces
PRODUCT_SOONG_NAMESPACES += \
    $(LOCAL_PATH)

PRODUCT_COPY_FILES += \
    $(call find-copy-subdir-files,*,device/samsung/pa1q/prebuilt/modules,$(TARGET_COPY_OUT_VENDOR_RAMDISK)/lib/modules) \
    $(LOCAL_PATH)/prebuilt/fstab.qcom:$(TARGET_COPY_OUT_VENDOR_RAMDISK)/first_stage_ramdisk/fstab.qcom