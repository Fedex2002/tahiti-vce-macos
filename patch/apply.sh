#!/bin/zsh
# Enable the VCE 1.0 hardware H.264 encoder of AMD "Tahiti"-family GPUs (FirePro D300/D500/D700, HD 7870/7950/7970,
# R9 280/280X, ...) on macOS 26 "Tahoe" patched with OpenCore Legacy Patcher ("AMD Legacy GCN" patch set).
#
# It applies three one-byte changes to the userspace video plugin that OCLP installs
# (/System/Library/Extensions/AMDRadeonVADriver.bundle, version 4.8.101 from macOS 12.5):
#
#   1. 0x4de6: 3f -> 7f   VAAcceleratorInfo::getExtraIdInfo(): set bit 22 in the capability mask of families 0-2
#                         (Tahiti/Pitcairn/Verde) so the plugin advertises AVD function 0x20/0x800 (general-purpose
#                         H.264 encode), the only one AppleGVA accepts for VideoToolbox encoding.
#   2. 0x28c92: 14 -> 6c  AVDAvcEncDataProcessor::ProcessEncodeStatus(): write the frame's bit count where the
#   3. 0x28cab: 14 -> 6c  AppleGVA shipped with macOS 26 reads it (stats+0x6c instead of the macOS 12 layout, +0x14).
#
# Nothing is changed unless every byte matches the expected original. A backup of the bundle is kept, the bundle is
# ad-hoc re-signed and a new boot snapshot is blessed (same flow OCLP uses). No kernel extension is touched.
#
# Usage:  sudo zsh apply.sh          then reboot
set -e
[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }

BACKUP_DIR=/Users/Shared/tahiti-vce-backup
MNT=/System/Volumes/Update/mnt1

ROOTSNAP=$(diskutil info / | awk -F': *' '/Device Node/ {print $2}')
DEV=${ROOTSNAP%s[0-9]*}                       # /dev/diskXsYs1 (booted snapshot) -> /dev/diskXsY (system volume)
echo "system volume: $DEV"
mkdir -p $MNT
mount | grep -q " on $MNT " || mount -o nobrowse -t apfs "$DEV" $MNT

B=$MNT/System/Library/Extensions/AMDRadeonVADriver.bundle
X=$B/Contents/MacOS/AMDRadeonVADriver
[ -f $X ] || { echo "AMDRadeonVADriver.bundle not found: is the OCLP 'AMD Legacy GCN' root patch installed?"; umount $MNT; exit 1; }

# offset : expected original bytes : patched bytes
PATCHES=(
  "0x4de2:48b80dff3f0400020000:48b80dff7f0400020000"
  "0x28c8f:41894f14:41894f6c"
  "0x28ca8:41894f14:41894f6c"
)

todo=0
for p in $PATCHES; do
  off=${p%%:*}; rest=${p#*:}; orig=${rest%%:*}; new=${rest#*:}
  cur=$(xxd -s $((off)) -l $(( ${#orig} / 2 )) -p $X)
  if [ "$cur" = "$orig" ]; then todo=1
  elif [ "$cur" != "$new" ]; then
    echo "unexpected bytes at $off: $cur (this is not the plugin build this patch was made for; nothing changed)"
    umount $MNT; exit 1
  fi
done

if [ $todo = 0 ]; then
  echo "already patched"
  umount $MNT; exit 0
fi

mkdir -p $BACKUP_DIR
[ -d $BACKUP_DIR/AMDRadeonVADriver.bundle ] || cp -Rp $B $BACKUP_DIR/

for p in $PATCHES; do
  off=${p%%:*}; rest=${p#*:}; orig=${rest%%:*}; new=${rest#*:}
  print -n "$new" | xxd -r -p | dd of=$X bs=1 seek=$((off)) conv=notrunc 2>/dev/null
  echo "$off: $orig -> $(xxd -s $((off)) -l $(( ${#orig} / 2 )) -p $X)"
done

codesign -f -s - $B
bless --folder $MNT/System/Library/CoreServices --bootefi --create-snapshot
umount $MNT || true
echo
echo "Done. Reboot, then check with tools/vtenc (see README)."
echo "On a real Mac Pro (Late 2013) you also need, once, as your user:"
echo "    defaults write com.apple.AppleGVA gvaForceAMDAVCEncode -bool YES"
