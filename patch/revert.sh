#!/bin/zsh
# Undo apply.sh: restore the AMDRadeonVADriver.bundle that was backed up before patching and bless a new snapshot.
# Usage:  sudo zsh revert.sh          then reboot
set -e
[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }

BACKUP=/Users/Shared/tahiti-vce-backup/AMDRadeonVADriver.bundle
MNT=/System/Volumes/Update/mnt1
[ -d $BACKUP ] || { echo "no backup at $BACKUP"; exit 1; }

ROOTSNAP=$(diskutil info / | awk -F': *' '/Device Node/ {print $2}')
DEV=${ROOTSNAP%s[0-9]*}
mkdir -p $MNT
mount | grep -q " on $MNT " || mount -o nobrowse -t apfs "$DEV" $MNT

B=$MNT/System/Library/Extensions/AMDRadeonVADriver.bundle
rm -rf $B
cp -Rp $BACKUP $B
bless --folder $MNT/System/Library/CoreServices --bootefi --create-snapshot
umount $MNT || true
echo "Restored. Reboot."
