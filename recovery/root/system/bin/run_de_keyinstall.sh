#!/system/bin/sh
# WIP110: thin wrapper that runs the A16 de_keyinstall binary under the A16 bootstrap linker.
# de_keyinstall is an A16 ELF that links the A16 libc++/libbinder from the mounted firmware dump
# (/decrypt) - it CANNOT be exec'd directly from the A12 TWRP base (wrong linker/libs) and it must
# reach the A16 KeyMint via binder, which decrypt.sh has already brought up by restore time.
# This mirrors the `lrun` helper in decrypt.sh. Called from partition.cpp::Restore_Tar() (the
# staged FBE key preload) AND usable standalone. Any args are forwarded to de_keyinstall
# (e.g. a PIN/password, or setpolicy/getpolicy subcommands).
SYS=/decrypt
LK="$SYS/system/bin/bootstrap/linker64"
LIBS="$SYS/system/lib64/bootstrap:$SYS/system/lib64:/vendor/lib64:/vendor/lib64/hw"
if [ -e "$LK" ]; then
    export LD_LIBRARY_PATH="$LIBS" ANDROID_DATA=/data ANDROID_ROOT=/system
    exec "$LK" /system/bin/de_keyinstall "$@"
else
    # Fallback: no A16 dump mounted (shouldn't happen post-decrypt) - try direct exec.
    exec /system/bin/de_keyinstall "$@"
fi
