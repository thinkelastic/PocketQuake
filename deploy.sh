#!/bin/bash
# Quick deploy script for PocketQuake
# Syncs release files to Pocket SD card, only copying changed files.
# Auto-detects the SD card mount point by looking for the Analogue Pocket
# directory structure under /run/media/.
#
set -e

# Build release/ with latest binaries
make package

DID_MOUNT=0

# Find the Pocket SD card: look for a mount with Cores/ and Assets/ dirs
find_pocket_sd() {
    for mount in /run/media/"$USER"/*; do
        if [ -d "$mount/Cores" ] && [ -d "$mount/Assets" ]; then
            echo "$mount"
            return
        fi
    done
}

POCKET_SD="$(find_pocket_sd)"

# If not mounted, try to find and mount an unmounted SD card partition
if [ -z "$POCKET_SD" ]; then
    echo "No mounted Pocket SD card found, looking for unmounted partitions..."
    for dev in /dev/sd*1 /dev/mmcblk*p1; do
        [ -b "$dev" ] || continue
        # Skip if already mounted
        if mountpoint -q "$dev" 2>/dev/null || mount | grep -q "^$dev "; then
            continue
        fi
        # Check if removable (SD card reader)
        base_dev="$(lsblk -no PKNAME "$dev" 2>/dev/null)"
        [ -n "$base_dev" ] || continue
        if [ "$(cat /sys/block/"$base_dev"/removable 2>/dev/null)" = "1" ]; then
            echo "Found unmounted removable partition: $dev — mounting..."
            udisksctl mount -b "$dev" --no-user-interaction
            sleep 1
            POCKET_SD="$(find_pocket_sd)"
            if [ -n "$POCKET_SD" ]; then
                DID_MOUNT=1
                break
            else
                # Mounted but not a Pocket SD, unmount
                udisksctl unmount -b "$dev" --no-user-interaction
            fi
        fi
    done
fi

if [ -z "$POCKET_SD" ]; then
    echo "Error: No Analogue Pocket SD card found"
    exit 1
fi

echo "Found Pocket SD card at: $POCKET_SD"

rsync -av --checksum release/ "$POCKET_SD/"

sync

# Unmount if we mounted it
if [ "$DID_MOUNT" = "1" ]; then
    echo "Unmounting $POCKET_SD..."
    udisksctl unmount -b "$dev" --no-user-interaction
fi

echo "Deploy complete"
