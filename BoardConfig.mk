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
# CRYPTO RE-ENABLED (WIP63) to fix two cosmetic side effects WIP59's crypto-off introduced.
# With crypto OFF, TWRP was UNAWARE that /data is encrypted, so it:
#   - tried to mount the raw, still-encrypted /data at startup -> "Failed to mount '/data'
#     (Invalid argument)" noise on the logo, and
#   - could not report the real storage size (Update_Size can't mount /data -> 0MB).
# With TW_INCLUDE_CRYPTO on, Setup_Data_Partition marks /data Is_Encrypted + Can_Be_Mounted=
# false, so TWRP no longer attempts the doomed raw mount -> the "Invalid argument" noise is gone.
# It also reads ro.crypto.fs_crypto_blkdev, which decrypt.sh now sets to the dm-default-key device
# after it mounts /data: TWRP then treats /data as ALREADY decrypted -> Decrypted_Block_Device =
# the dm, TW_IS_ENCRYPTED=0 (no "Decrypt Data" button) and Update_Size statfs's the dm -> the real
# storage size. This is the SAME flag set that booted to GUI in WIP32 (the startup
# waitForService(KeyMint) completes because decrypt.sh auto-starts the A16 stack). Our A16-stack
# decrypt never used TWRP's own crypto and is unchanged - this only adds TWRP's encryption
# AWARENESS, not its (A16-incompatible) decrypt. TW_INCLUDE_FBE_METADATA_DECRYPT stays OFF: that
# one is the fscrypt_mount_metadata_encrypted startup path that hangs.
# IMPORTANT: these are -D compile flags -> a CLEAN recovery build is REQUIRED, or a stale
# partitionmanager.o is reused and the change silently has no effect.
TW_INCLUDE_CRYPTO := true
TW_INCLUDE_CRYPTO_FBE := true
BOARD_USES_QCOM_FBE_DECRYPTION := true
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

# de_keyinstall: installs the systemwide FBE (DE) key into the kernel keyring (next FBE
# domino after the metadata mount). KeyMint client via libbinder_ndk, run through
# hal_run.sh; same system-binary + relink model as the apexservice stub above.
TW_RECOVERY_ADDITIONAL_RELINK_BINARY_FILES += $(TARGET_OUT_EXECUTABLES)/de_keyinstall

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
