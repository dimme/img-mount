# img_mount.sh

A tool for mounting and unmounting partitions from disk image files.

Auto-detects GPT/MBR partition tables and sector sizes. Mounts all supported partitions read-only via loop devices.

## Usage

```bash
# Mount all partitions from an image
sudo ./img_mount.sh disk.img mount

# Check what's currently mounted
sudo ./img_mount.sh disk.img status

# Unmount and detach
sudo ./img_mount.sh disk.img umount

# Unmount all images managed by this script
sudo ./img_mount.sh umount-all
```

## Supported Filesystems

ext2, ext3, ext4, xfs, btrfs, f2fs, vfat, ntfs, squashfs, erofs
