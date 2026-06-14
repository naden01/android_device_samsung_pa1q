# for building
BUILD_BROKEN_ELF_PREBUILT_PRODUCT_COPY_FILES := true
ALLOW_MISSING_DEPENDENCIES := true

DEVICE_PATH := device/samsung/pa3q

# Architecture
TARGET_ARCH := arm64
TARGET_ARCH_VARIANT := armv8-a
TARGET_CPU_ABI := arm64-v8a
TARGET_CPU_ABI2 := 
TARGET_CPU_VARIANT := generic
TARGET_CPU_VARIANT_RUNTIME := oryon

# Bootloader
TARGET_NO_BOOTLOADER := true
BOARD_VENDOR := samsung
TARGET_SOC := sun
TARGET_BOOTLOADER_BOARD_NAME := $(TARGET_SOC)
TARGET_BOARD_PLATFORM := $(TARGET_SOC)
QCOM_BOARD_PLATFORMS := $(TARGET_SOC)
TARGET_BOARD_PLATFORM_GPU := Adreno-830

# Board
BOARD_USES_QCOM_HARDWARE := true
BOARD_NO_RADIOIMAGE := true

# Display
TARGET_SCREEN_DENSITY := 560
TARGET_USES_VULKAN := true

# Kernel
TARGET_NO_KERNEL := true
BOARD_RAMDISK_USE_LZ4 := true
TARGET_PREBUILT_DTB := $(DEVICE_PATH)/prebuilt/dtb.img

# Kernel - Board values
BOARD_BOOT_HEADER_VERSION := 4
BOARD_KERNEL_BASE := 0x00000000
BOARD_KERNEL_OFFSET := 0x00008000
BOARD_PAGE_SIZE := 4096
BOARD_TAGS_OFFSET := 0x01e00000
BOARD_RAMDISK_OFFSET := 0x02000000
BOARD_DTB_SIZE := 4488060
BOARD_DTB_OFFSET := 0x01f00000
BOARD_VENDOR_BASE := 0x00000000
BOARD_VENDOR_CMDLINE += "video=vfb:640x400,bpp=32,memsize=3072000 printk.devkmsg=on firmware_class.path=/vendor/firmware_mnt/image bootconfig loop.max_part=7 androidboot.selinux=permissive"
BOARD_BOOTCONFIG += androidboot.hardware=qcom androidboot.memcg=1 androidboot.usbcontroller=a600000.dwc3 androidboot.load_modules_parallel=false androidboot.hypervisor.protected_vm.supported=true androidboot.vendor.qspa=true androidboot.serialconsole=0 androidboot.selinux=permissive
BOARD_KERNEL_CMDLINE += bootconfig

BOARD_MKBOOTIMG_ARGS += --dtb $(TARGET_PREBUILT_DTB)
BOARD_MKBOOTIMG_ARGS += --vendor_cmdline $(BOARD_VENDOR_CMDLINE)
BOARD_MKBOOTIMG_ARGS += --pagesize $(BOARD_PAGE_SIZE) --board "SRPXG11A004"
BOARD_MKBOOTIMG_ARGS += --kernel_offset $(BOARD_KERNEL_OFFSET)
BOARD_MKBOOTIMG_ARGS += --ramdisk_offset $(BOARD_RAMDISK_OFFSET)
BOARD_MKBOOTIMG_ARGS += --tags_offset $(BOARD_TAGS_OFFSET)
BOARD_MKBOOTIMG_ARGS += --header_version $(BOARD_BOOT_HEADER_VERSION)
BOARD_MKBOOTIMG_ARGS += --dtb_offset $(BOARD_DTB_OFFSET)

# Partitions
BOARD_FLASH_BLOCK_SIZE := 262144
BOARD_VENDOR_BOOTIMAGE_PARTITION_SIZE := 134217728
BOARD_SUPER_PARTITION_SIZE := 9126805504
BOARD_SUPER_PARTITION_GROUPS := samsung_dynamic_partitions
BOARD_SAMSUNG_DYNAMIC_PARTITIONS_PARTITION_LIST := \
    vendor_dlkm \
    system \
    product \
    system_ext \
    vendor \
    odm
BOARD_SAMSUNG_DYNAMIC_PARTITIONS_SIZE := 9122611200

BOARD_SYSTEMIMAGE_FILE_SYSTEM_TYPE := erofs
BOARD_USERDATAIMAGE_FILE_SYSTEM_TYPE := f2fs
BOARD_VENDORIMAGE_FILE_SYSTEM_TYPE := ext4

TARGET_COPY_OUT_SYSTEM := system
TARGET_COPY_OUT_VENDOR := vendor

# Properties
TARGET_SYSTEM_PROP += $(DEVICE_PATH)/system.prop
TARGET_SYSTEM_PROP += $(DEVICE_PATH)/vendor.prop

# Recovery
TARGET_RECOVERY_QCOM_RTC_FIX := true
BOARD_HAS_LARGE_FILESYSTEM := true
BOARD_USES_GENERIC_KERNEL_IMAGE := true
BOARD_HAS_NO_SELECT_BUTTON := true
BOARD_SUPPRESS_SECURE_ERASE := true
TARGET_NO_RECOVERY := true
RECOVERY_SDCARD_ON_DATA := true
TARGET_RECOVERY_PIXEL_FORMAT := RGBX_8888
TARGET_USERIMAGES_USE_EXT4 := true
TARGET_USERIMAGES_USE_F2FS := true

# Verified Boot
BOARD_AVB_ENABLE := true
BOARD_AVB_MAKE_VBMETA_IMAGE_ARGS += --flags 3
BOARD_AVB_VENDOR_BOOT_KEY_PATH := external/avb/test/data/testkey_rsa4096.pem
BOARD_AVB_VENDOR_BOOT_ALGORITHM := SHA256_RSA4096
BOARD_AVB_VENDOR_BOOT_ROLLBACK_INDEX := 1
BOARD_AVB_VENDOR_BOOT_ROLLBACK_INDEX_LOCATION := 1

# Hack: prevent anti rollback
PLATFORM_SECURITY_PATCH := 2099-12-31
VENDOR_SECURITY_PATCH := 2099-12-31
PLATFORM_VERSION := 12
# CRYPTO FULLY DISABLED in TWRP. This device's /data is A16 FBE + metadata encryption
# with HW-wrapped keys that TWRP's built-in (A12-base) crypto CANNOT handle. With these
# flags on, TWRP's FBE path runs at startup and does waitForService(KeyMint); the A12
# keystore2 SIGSEGV-loops and KeyMint never registers, so TWRP's `recovery` process
# blocks in futex_wait -> HANG ON THE LOGO (confirmed live: recovery.log stops at
# "Using additional fstab for decryption", recovery pid in futex_wait, init spamming
# "Could not find IKeystoreService"). Earlier WIPs hid this by auto-starting the A16
# stack at boot to satisfy TWRP's wait - but that auto-decrypt rewrote the /data
# metadata key (rot + KeyMint keyUpgrade of keymaster_key_blob) on EVERY boot, which
# real Android then cannot use -> bootloop -> "Format Data".
#
# The decrypt is now 100% self-contained in decrypt.sh: it runs the WHOLE A16 security
# stack + vold/vdc FROM THE FIRMWARE DUMP (/decrypt/...), reads the dump's own fstab for
# the /data crypto options, and mounts /data itself. It uses NO TWRP crypto module, so
# turning these OFF does not affect it. The only A12 services it touches are the base
# servicemanager (always present, not crypto-gated) and keystore2 (it ctl.stops it);
# with crypto off that stop is a harmless no-op and /dev/binder is free for the A16 sm.
# Net result: TWRP boots straight to its GUI (no startup decrypt, no hang) and /data is
# decrypted only on explicit  setprop twrp.decrypt.run 1  (decrypt.sh is non-destructive:
# it snapshots + restores the pristine metadata key so Android still boots afterwards).
#
# IMPORTANT: these are -D compile flags -> a CLEAN recovery build is REQUIRED, or a
# stale partitionmanager.o is reused and the change silently has no effect.
TW_INCLUDE_CRYPTO := false
TW_INCLUDE_CRYPTO_FBE := false
BOARD_USES_QCOM_FBE_DECRYPTION := false
TW_INCLUDE_FBE_METADATA_DECRYPT := false
BOARD_USES_METADATA_PARTITION := true

# Custom recovery binary: apexservice stub for the A16-stack /data decrypt. The A16
# keystore2 (run from the firmware dump by decrypt.sh) blocks during startup on
# waitForService("apexservice") - apexd can't run in recovery - so this tiny native
# service answers getActivePackages() empty and lets keystore2 finish.
# Built as a SYSTEM binary (apexservice_stub/, via PRODUCT_PACKAGES in device.mk):
# this tree has no recovery variant of libbinder, so relink the system binary + its
# .so deps into the recovery ramdisk instead of forcing a recovery build.
TW_RECOVERY_ADDITIONAL_RELINK_BINARY_FILES += $(TARGET_OUT_EXECUTABLES)/apexservice_stub

# Display
TW_BRIGHTNESS_PATH := "/sys/class/backlight/panel0-backlight/brightness"
TW_FRAMERATE := 120
TW_DEFAULT_BRIGHTNESS := 1000

# TWRP Configs
TW_EXCLUDE_APEX := true
TW_EXTRA_LANGUAGES := true
TW_THEME := portrait_hdpi
TARGET_USES_MKE2FS := true
TW_NO_LEGACY_PROPS := true
TW_NO_BIND_SYSTEM := true
TW_NO_HAPTICS := true
TW_USE_NEW_MINADBD := true
TW_SCREEN_BLANK_ON_BOOT := true
TW_NO_BIND_SYSTEM := true
TW_USE_MODEL_HARDWARE_ID_FOR_DEVICE_ID := true
TW_DEVICE_VERSION := Jamie_Naden_Maxim_Archer_Ahmed_Carlo | pa3q
TW_BACKUP_EXCLUSIONS := /data/fonts
TW_EXTRA_LANGUAGES := true
TW_USE_TOOLBOX := true
TARGET_RECOVERY_FSTAB := $(DEVICE_PATH)/recovery.fstab
#OnageFox
TW_MAX_BRIGHTNESS := 1500
# fastbootD
TW_INCLUDE_FASTBOOTD := true

# Tools
TW_INCLUDE_FB2PNG := true
TW_INCLUDE_NTFS_3G := true
TW_INCLUDE_REPACKTOOLS := true
TW_INCLUDE_RESETPROP := true
TW_INCLUDE_LPTOOLS := true
TW_INCLUDE_LPDUMP := true
TW_INCLUDE_LIBRESETPROP := true
TW_EXCLUDE_DEFAULT_USB_INIT := true

# USB OTG
TW_USB_STORAGE := true

# log
TWRP_EVENT_LOGGING := true
TWRP_INCLUDE_LOGCAT := true
TARGET_USES_LOGD := true

# Samsung reboot menu
TW_NO_REBOOT_BOOTLOADER := true
TW_HAS_DOWNLOAD_MODE := true

# vendor_boot
TW_LOAD_VENDOR_BOOT_MODULES := true
BOARD_MOVE_GSI_AVB_KEYS_TO_VENDOR_BOOT := true
BOARD_MOVE_RECOVERY_RESOURCES_TO_VENDOR_BOOT := true
BOARD_INCLUDE_RECOVERY_RAMDISK_IN_VENDOR_BOOT := true

# StatusBar
# Statusbar icons flags
TW_STATUS_ICONS_ALIGN := center
TW_CUSTOM_CPU_POS := 580
TW_CUSTOM_CLOCK_POS := 50
TW_CUSTOM_BATTERY_POS := 800

# Treble
PRODUCT_ENFORCE_VINTF_MANIFEST := true
PRODUCT_FULL_TREBLE := true
