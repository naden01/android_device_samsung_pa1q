# TWRP device tree for Samsung Galaxy S25 5G

## To build it:
```bash
. build/envsetup.sh
lunch twrp_pa1q-eng
mka vendorbootimage -j$(nproc --all)
```
