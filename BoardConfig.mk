# for building
BUILD_BROKEN_ELF_PREBUILT_PRODUCT_COPY_FILES := true
ALLOW_MISSING_DEPENDENCIES := true

DEVICE_PATH := device/samsung/pa1q

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
TARGET_SCREEN_DENSITY := 480
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
# DEBUG: turn init's silent fatal-reboot into a kernel panic so the 3.5s bootloop
# leaves a readable log in pstore/ramoops (a clean init reboot writes nothing).
# Read /sys/fs/pstore after the bootloop to see WHY init aborts. Remove once fixed.
BOARD_BOOTCONFIG += androidboot.init_fatal_panic=true
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
# NOTE: removed the old 'PLATFORM_VERSION := 12' override. The build base is now
# Android 16 (matches the device vendor), so the platform version must be the
# base default (16). Forcing 12 was the hack for the old A12 base and would break
# the A16 servicemanager/keystore2/keymint version match we switched bases to get.
# Crypto (FBE v2 + metadata encryption, HW-wrapped keys, AIDL KeyMint).
# On this matching Android-16 base TWRP's own decrypt path runs against the device's
# ABI-compatible A16 KeyMint/keystore2, so the built-in flow is used directly - no
# manual HAL injection. fscrypt_mount_metadata_encrypted() -> KeyMint unwraps the
# keymaster_key_blob in /metadata/vold/metadata_encryption and /data is mounted.
# (TWRP's keymaster-version probe still logs version '' because it looks for the old
# HIDL android.hardware.keymaster while this device is AIDL KeyMint; that string is
# not used by the keystore2/KeyMint decrypt path, so it is harmless. Re-add
# TW_FORCE_KEYMASTER_VER + a keymaster_ver prop only if a probe actually blocks.)
# A CLEAN recovery build is required when changing these -D flags.
# TEMPORARILY DISABLED for bringup isolation: get a MINIMAL recovery that boots
# first. Crypto pulls keystore2/servicemanager/keymint into the image; if a
# crash-looping keystore2 (or the crypto path) is what reboots TWRP at startup,
# disabling this will boot. If it STILL bootloops with crypto off, crypto is ruled
# out and the cause is graphics/core init. Re-enable once the recovery boots.
TW_INCLUDE_CRYPTO := false
TW_INCLUDE_CRYPTO_FBE := false
BOARD_USES_QCOM_FBE_DECRYPTION := false
TW_INCLUDE_FBE_METADATA_DECRYPT := false
BOARD_USES_METADATA_PARTITION := false

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
TW_DEVICE_VERSION := Jamie_Naden_Maxim_Archer_Ahmed_Carlo | pa1q
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
