# TWRP device tree for Samsung Galaxy S25Ultra (pa3q)

Official released unknown

# Maintainers
- [Teamwin Recovery Project](https://github.com/teamwin) - developer manifest
- [Jamie](https://github.com/SavedByLight) - developer
- [Naden](https://github.com/naden01) - developer 
- [Maxim](https://github.com/Maxim-Root) - developer 
- [Archer](https://github.com/archer0305) - developer
- [Ahmed](https://github.com/GitFASTBOOT) - developer
- [Carlo](https://github.com/cd-Crypton) - developer

# Samsung S25Ultra
<p align="left" width="100%">
<img width="33%" src="https://github.com/Maxim-Root/Picture/blob/Samsung/S25Ultra.jpg"> 
</p>






# Device Specifications

| Basic                        | Spec Sheet                                                                    |
| ---------------------------: | :-----------------------------------------------------------------------------|
| Chipset                      | Qualcomm Snapdragon 8 Elite for Galaxy (SM8750)                               |
| CPU                          | Octa-core (2x Oryon Prime 4.47 GHz 6x Oryon Performance 3.53 GHz)            |
| GPU                          | Adreno 830                                                                    |
| Memory                       | 12 GB RAM (LPDDR5X)                                                           |
| Shipped OS                   | Android 15 (One UI 7.0)                                                       |
| Storage                      | 256/512/1024 GB (UFS 4.0)                                                  |
| SIM                          | dual Nano-SIM, eSIM                                                           |
| MicroSD                      | No                                                                            |
| Battery                      | 5000mAh Li-ion (non-removable), 45W fast charge                               |
| Dimensions                   | 162.8 x 77.6 x 8.2 mm                                                         |
| Display                      | 6.9" 3120x1440 pixels, 19.5:9 ratio, Dynamic AMOLED 2X, 120Hz (~500 ppi)     |
| Rear Camera 1                | 200 MP, f1.7 OIS                                                              |
| Rear Camera 2                | 50 MP, f/1.9                                                                  |
| Rear Camera 3                | 50 MP, f/2.4,                                                          |
| Rear Camera 4                | 10 MP, f/3.4, (macro)                                                         |
| Front Camera                 | 12 MP, f/2.2                                                                  |
| Fingerprint                  | under display, optical                                                        |
| Sensors                      | accelerometer, barometer, gyroscope, Hall sensor, light sensor, proximity sensor|
| Extras                       | Dual speakers, NFC, HDR10+ support, Always on Display                           |





# Checks
Blocking checks
- [✔] Correct screen/recovery size
- [✔] Working Touch, screen
- [✖] Backup to internal/microSD (No SD card slot)
- [✖] Restore from internal/microSD (No SD card slot)
- [✔] reboot to system
- [✔] ADB

Medium checks
- [✔] update.zip sideload
- [✔] UI colors (red/blue inversions)
- [✔] Screen goes off and on
- [✔] F2FS/EXT4 Support, exFAT/NTFS where supported
- [✔] all important partitions listed in mount/backup lists
- [✔] backup/restore to/from external (USB-OTG) storage
- [✖] decrypt /data
- [✔] Correct date
- [✖] USB-OTG (flash drive)

Minor checks
- [✔] MTP export
- [✔] reboot to bootloader
- [✔] reboot to recovery
- [✔] poweroff
- [✔] battery level
- [✔] temperature
- [✔] encrypted backups
- [✔] input devices via USB (USB-OTG) - keyboard and mouse
- [✔] USB mass storage export
- [✔] set brightness
- [✖] vibrate
- [✔] screenshot
- [✖] partition SD card (No SD card slot)
- [✔] Fastbootd


## Clone manifest twrp-12.1 
```bash
repo init -u https://github.com/minimal-manifest-twrp/platform_manifest_twrp_aosp.git -b twrp-12.1
```
## Sync manifest twrp-12.1
```bash
repo sync
```
## Cloning the device tree
```bash
git clone https://github.com/naden01/android_device_samsung_pa1q.git -b S25Ultra device/samsung/pa3q
```
## Build
```bash
export ALLOW_MISSING_DEPENDENCIES=true; . build/envsetup.sh; lunch twrp_pa3q-eng; mka vendorbootimage
```



