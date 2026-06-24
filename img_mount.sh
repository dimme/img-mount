#!/usr/bin/env bash
set -euo pipefail

# GPT header signature: "EFI PART"
GPT_SIG="4546492050415254"

# Supported mountable filesystem types
MOUNTABLE_FS="ext4|ext3|ext2|xfs|btrfs|f2fs|vfat|ntfs|squashfs|erofs"

usage() {
    echo "A tool for mounting and unmounting partitions from disk image files."
    echo
    echo "Usage: $(basename "$0") <image_file> {mount|umount|status}"
    echo "       $(basename "$0") umount-all"
    echo
    echo "  mount      - Set up loop device and mount all mountable partitions (read-only)"
    echo "  umount     - Unmount all partitions and detach the loop device"
    echo "  status     - Show current mount status"
    echo "  umount-all - Unmount all images mounted by this script"
    echo
    echo "Example: $(basename "$0") disk.img mount"
    exit 1
}


# Resolve the calling user's UID/GID (works under sudo)
CALLER_UID="${SUDO_UID:-$(id -u)}"
CALLER_GID="${SUDO_GID:-$(id -g)}"

# Detect the correct sector size by locating the GPT header signature.
# The GPT header is always at LBA 1, so its byte offset equals the sector size.
detect_sector_size() {
    local file="$1"
    local size

    for size in 512 1024 2048 4096; do
        local sig
        sig=$(dd if="$file" bs=1 skip="$size" count=8 2>/dev/null | xxd -p | head -c 16)
        if [[ "$sig" == "$GPT_SIG" ]]; then
            echo "$size"
            return 0
        fi
    done

    # No GPT found — fall back to 512 (standard MBR or raw filesystem)
    echo "512"
    return 0
}

get_loop_device() {
    losetup -j "$IMAGE" 2>/dev/null | head -1 | cut -d: -f1
}

# Get a meaningful name for a partition, preferring PARTLABEL > LABEL > partition number
get_partition_name() {
    local dev="$1"
    local name
    name=$(blkid -s PARTLABEL -o value "$dev" 2>/dev/null || true)
    if [[ -z "$name" ]]; then
        name=$(blkid -s LABEL -o value "$dev" 2>/dev/null || true)
    fi
    if [[ -z "$name" ]]; then
        name=$(echo "$dev" | grep -oP 'p\K[0-9]+$' || basename "$dev")
    fi
    echo "$name"
}

do_mount() {
    if [[ ! -f "$IMAGE" ]]; then
        echo "Error: Image not found: $IMAGE"
        exit 1
    fi

    local loop
    loop=$(get_loop_device)
    if [[ -n "$loop" ]]; then
        echo "Image is already attached to $loop"
    else
        local sector_size
        sector_size=$(detect_sector_size "$IMAGE")
        echo "Detected sector size: $sector_size bytes"

        loop=$(losetup --find --show --partscan --sector-size "$sector_size" "$IMAGE")
        echo "Attached $IMAGE to $loop"
        sleep 1

        # Verify partitions were found; if not, retry with other sector sizes
        if ! ls "$loop"p* &>/dev/null; then
            echo "No partitions detected with sector size $sector_size, trying alternatives..."
            losetup -d "$loop"
            local found=false
            for try_size in 512 1024 2048 4096; do
                [[ "$try_size" == "$sector_size" ]] && continue
                loop=$(losetup --find --show --partscan --sector-size "$try_size" "$IMAGE")
                sleep 1
                if ls "$loop"p* &>/dev/null; then
                    echo "Detected sector size: $try_size bytes (fallback)"
                    found=true
                    break
                fi
                losetup -d "$loop"
            done
            if [[ "$found" != "true" ]]; then
                # Last resort: attach without partition scan (raw filesystem image)
                loop=$(losetup --find --show "$IMAGE")
                echo "Attached as raw image (no partition table) to $loop"
            fi
        fi
    fi

    # Collect mountable devices: partitions if present, otherwise the loop device itself
    local devices=()
    if ls "$loop"p* &>/dev/null; then
        for dev in "$loop"p*; do
            [[ -b "$dev" ]] && devices+=("$dev")
        done
    else
        devices=("$loop")
    fi

    local count=0
    for dev in "${devices[@]}"; do
        local fstype
        fstype=$(blkid -s TYPE -o value "$dev" 2>/dev/null || true)
        if [[ ! "$fstype" =~ ^($MOUNTABLE_FS)$ ]]; then
            continue
        fi

        local label
        label=$(get_partition_name "$dev")
        local mnt="${MOUNT_BASE}/${label}"

        # Handle duplicate partition names by appending a suffix
        if mountpoint -q "$mnt" 2>/dev/null; then
            local orig_mnt="$mnt"
            local suffix=2
            while mountpoint -q "$mnt" 2>/dev/null; do
                mnt="${orig_mnt}_${suffix}"
                suffix=$((suffix + 1))
            done
        fi

        mkdir -p "$mnt"

        # For filesystems that support uid/gid mount options, use them directly.
        # For POSIX filesystems (ext4, xfs, etc.), mount to a staging dir and
        # use bindfs to present files as owned by the calling user.
        local mount_ok=false
        case "$fstype" in
            vfat|ntfs)
                if mount -o "ro,uid=${CALLER_UID},gid=${CALLER_GID},umask=0222" "$dev" "$mnt" 2>/dev/null; then
                    mount_ok=true
                fi
                ;;
            *)
                local stage="${STAGE_BASE}/${label}"
                if mountpoint -q "$stage" 2>/dev/null; then
                    local orig_stage="$stage"
                    local ssuffix=2
                    while mountpoint -q "$stage" 2>/dev/null; do
                        stage="${orig_stage}_${ssuffix}"
                        ssuffix=$((ssuffix + 1))
                    done
                fi
                mkdir -p "$stage"
                if mount -o ro "$dev" "$stage" 2>/dev/null; then
                    if bindfs -r --force-user="$CALLER_UID" --force-group="$CALLER_GID" --perms=a+rX "$stage" "$mnt" 2>/dev/null; then
                        mount_ok=true
                    else
                        echo "  Warning: bindfs failed for $label, falling back to direct mount"
                        umount "$stage" 2>/dev/null
                        rmdir "$stage" 2>/dev/null || true
                        if mount -o ro "$dev" "$mnt" 2>/dev/null; then
                            mount_ok=true
                        fi
                    fi
                fi
                ;;
        esac

        if $mount_ok; then
            echo "  Mounted: $dev ($label, $fstype) -> $mnt"
            count=$((count + 1))
        else
            echo "  Failed:  $dev ($label, $fstype)"
            rmdir "$mnt" 2>/dev/null || true
        fi
    done

    echo "Done. $count partition(s) mounted under $MOUNT_BASE/"
}

do_umount_all() {
    local total=0

    # Find all loop devices backed by .img files
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        local loop img
        loop=$(echo "$line" | cut -d: -f1)
        img=$(echo "$line" | sed 's/.*(\(.*\))/\1/')

        local img_name
        img_name="$(basename "$img" .img)"
        local mbase="/mnt/${img_name}"
        local sbase="/mnt/.${img_name}_stage"

        echo "Image: $img ($loop)"

        # Unmount bindfs / user-facing mounts
        if [[ -d "$mbase" ]]; then
            for mnt in "$mbase"/*/; do
                [[ -d "$mnt" ]] || continue
                if mountpoint -q "$mnt" 2>/dev/null; then
                    umount "$mnt"
                    echo "  Unmounted: $mnt"
                    total=$((total + 1))
                fi
                rmdir "$mnt" 2>/dev/null || true
            done
            rmdir "$mbase" 2>/dev/null || true
        fi

        # Unmount staging mounts
        if [[ -d "$sbase" ]]; then
            for mnt in "$sbase"/*/; do
                [[ -d "$mnt" ]] || continue
                if mountpoint -q "$mnt" 2>/dev/null; then
                    umount "$mnt"
                fi
                rmdir "$mnt" 2>/dev/null || true
            done
            rmdir "$sbase" 2>/dev/null || true
        fi

        # Detach loop device
        losetup -d "$loop" 2>/dev/null
        echo "  Detached: $loop"

    done < <(losetup -l -n -O NAME,BACK-FILE 2>/dev/null | awk '{print $1 ":(" $2 ")"}')

    echo "Done. $total partition(s) unmounted across all images."
}

do_umount() {
    local loop
    loop=$(get_loop_device)

    # Unmount everything under MOUNT_BASE (bindfs mounts)
    local count=0
    if [[ -d "$MOUNT_BASE" ]]; then
        for mnt in "$MOUNT_BASE"/*/; do
            [[ -d "$mnt" ]] || continue
            if mountpoint -q "$mnt" 2>/dev/null; then
                umount "$mnt"
                echo "  Unmounted: $mnt"
                count=$((count + 1))
            fi
            rmdir "$mnt" 2>/dev/null || true
        done
        rmdir "$MOUNT_BASE" 2>/dev/null || true
    fi

    # Unmount staging mounts (underlying device mounts for bindfs)
    if [[ -d "$STAGE_BASE" ]]; then
        for mnt in "$STAGE_BASE"/*/; do
            [[ -d "$mnt" ]] || continue
            if mountpoint -q "$mnt" 2>/dev/null; then
                umount "$mnt"
            fi
            rmdir "$mnt" 2>/dev/null || true
        done
        rmdir "$STAGE_BASE" 2>/dev/null || true
    fi

    # Detach loop device
    if [[ -n "$loop" ]]; then
        losetup -d "$loop"
        echo "  Detached loop device: $loop"
    fi

    echo "Done. $count partition(s) unmounted."
}

do_status() {
    local loop
    loop=$(get_loop_device)

    if [[ -z "$loop" ]]; then
        echo "Image is not attached to any loop device."
        return
    fi

    echo "Image: $IMAGE"
    echo "Loop device: $loop"
    echo

    # Collect devices
    local devices=()
    if ls "$loop"p* &>/dev/null; then
        for dev in "$loop"p*; do
            [[ -b "$dev" ]] && devices+=("$dev")
        done
    else
        devices=("$loop")
    fi

    echo "Partitions:"
    local mounted=0 total=0
    for dev in "${devices[@]}"; do
        local fstype
        fstype=$(blkid -s TYPE -o value "$dev" 2>/dev/null || true)
        if [[ ! "$fstype" =~ ^($MOUNTABLE_FS)$ ]]; then
            continue
        fi
        total=$((total + 1))

        local label
        label=$(get_partition_name "$dev")

        # Find if this device is mounted anywhere under MOUNT_BASE
        local mnt
        mnt=$(findmnt -n -o TARGET "$dev" 2>/dev/null | head -1 || true)

        if [[ -n "$mnt" ]]; then
            local usage
            usage=$(df -h "$mnt" | tail -1 | awk '{print $3 "/" $2 " (" $5 ")"}')
            printf "  %-24s %-14s %-8s %s\n" "$label" "$dev" "$fstype" "$usage"
            mounted=$((mounted + 1))
        else
            printf "  %-24s %-14s %-8s (not mounted)\n" "$label" "$dev" "$fstype"
        fi
    done

    echo
    echo "$mounted/$total mountable partition(s) currently mounted."
}

if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root (sudo)."
    exit 1
fi

if [[ $# -lt 1 ]]; then
    usage
fi

# Handle umount-all (no image file needed)
if [[ "$1" == "umount-all" ]]; then
    do_umount_all
    exit 0
fi

if [[ $# -lt 2 ]]; then
    usage
fi

IMAGE="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
IMAGE_NAME="$(basename "$IMAGE" .img)"
MOUNT_BASE="/mnt/${IMAGE_NAME}"
STAGE_BASE="/mnt/.${IMAGE_NAME}_stage"

case "${2:-}" in
    mount)  do_mount  ;;
    umount) do_umount ;;
    status) do_status ;;
    *)      usage     ;;
esac
