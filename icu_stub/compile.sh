#!/bin/bash
# Quick compile script for testing - replace with proper AOSP build later

# Using system gcc to create ARM64 shared library
# This is a quick test - proper build should use Android toolchain

aarch64-linux-gnu-gcc -shared -fPIC -o libicu_stub.so ucol_stub.c 2>/dev/null || \
  echo "aarch64-linux-gnu-gcc not found. You need to build this with AOSP build system:"
  echo "  cd \$ANDROID_BUILD_TOP"
  echo "  source build/envsetup.sh"
  echo "  lunch twrp_pa1q-eng"
  echo "  m libicu_stub"
