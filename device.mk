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

# Partitions
PRODUCT_USE_DYNAMIC_PARTITIONS := true

# Soong namespaces
PRODUCT_SOONG_NAMESPACES += \
    $(LOCAL_PATH)

PRODUCT_COPY_FILES += \
    $(call find-copy-subdir-files,*,device/samsung/psq/prebuilt/modules,$(TARGET_COPY_OUT_VENDOR_RAMDISK)/lib/modules) \
    $(LOCAL_PATH)/prebuilt/fstab.qcom:$(TARGET_COPY_OUT_VENDOR_RAMDISK)/first_stage_ramdisk/fstab.qcom
