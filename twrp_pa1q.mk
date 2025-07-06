# Inherit from those products. Most specific first.
$(call inherit-product, $(SRC_TARGET_DIR)/product/core_64_bit.mk)
$(call inherit-product, $(SRC_TARGET_DIR)/product/full_base_telephony.mk)

# Inherit some common twrp stuff.
$(call inherit-product, vendor/twrp/config/common.mk)

# Enable project quotas and casefolding for emulated storage without sdcardfs
$(call inherit-product, $(SRC_TARGET_DIR)/product/emulated_storage.mk)

# Inherit from pa1q device
$(call inherit-product, device/samsung/pa1q/device.mk)

PRODUCT_DEVICE := pa1q
PRODUCT_NAME := twrp_pa1q
PRODUCT_BRAND := samsung
PRODUCT_MODEL := SM-S931B
PRODUCT_MANUFACTURER := samsung

PRODUCT_GMS_CLIENTID_BASE := android-samsung-ss

PRODUCT_BUILD_PROP_OVERRIDES += \
    PRIVATE_BUILD_DESC="pa1qxxx-user 15 AP3A.240905.015.A2 S931BXXS4AYF2 release-keys"

BUILD_FINGERPRINT := samsung/pa1qxxx/qssi_64:15/AP3A.240905.015.A2/S931BXXS4AYF2:user/release-keys
