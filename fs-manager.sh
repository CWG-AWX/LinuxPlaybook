#!/bin/bash
# fs-manager.sh
# CWG Intelligent File-System Manager
# Interactive LVM + Filesystem Manager for RHEL-family and Ubuntu-family systems
#
# Behavior:
# - Detects OS family and prints it (no auto-install).
# - Optionally partitions disks with fdisk (user chooses size and LVM type).
# - Automatically detects created partition (fdisk chooses partition number).
# - Creates PVs, VGs, LVs, filesystems, mounts, and adds UUID-based /etc/fstab entries.
# - Asks user for mount points and creates directories when needed.
#
# Run as root.

set -o errexit
set -o nounset
set -o pipefail

echo "=========================================================="
echo "Hi, welcome to CWG intelligent file-system manager"
echo "=========================================================="
sleep 1

check_success() {
    if [ $? -ne 0 ]; then
        echo "ERROR: $1 failed. Exiting..."
        exit 1
    fi
}

# ====== OS Detection (no installs) ======
detect_os() {
    if [ -f /etc/redhat-release ]; then
        OS="RHEL"
        PKG_MANAGER="yum"
        echo "Detected OS: Red Hat-based system (RHEL/CentOS/Rocky/Alma)"
    elif [ -f /etc/lsb-release ] || [ -f /etc/debian_version ]; then
        OS="DEBIAN"
        PKG_MANAGER="apt-get"
        echo "Detected OS: Debian-based system (Ubuntu/Debian)"
    else
        echo "❌ Unsupported OS. Exiting..."
        exit 1
    fi
    echo "Package manager set to: $PKG_MANAGER (no automatic installs will be performed)"
}

# ====== Tool checks (warn only) ======
check_tools() {
    local missing=0
    for cmd in pvcreate vgcreate lvcreate mkfs.xfs mkfs.ext4 blkid lvs vgs lsblk fdisk partprobe; do
        if ! command -v "${cmd%% *}" >/dev/null 2>&1; then
            echo "⚠️  Warning: required command not found: $cmd"
            missing=1
        fi
    done
    if [ "$missing" -eq 1 ]; then
        echo ""
        echo "NOTE: Some commands are missing. The script will not auto-install them."
        echo "If you need them please install using your package manager (sudo $PKG_MANAGER install <pkg>)."
        echo ""
        read -p "Proceed anyway? (yes/no) [no]: " ans
        ans=${ans:-no}
        if [[ "$ans" != "yes" ]]; then
            echo "Exiting. Install required packages and re-run."
            exit 1
        fi
    fi
}

# ====== Utility ======
list_raw_disks() {
    echo "Available block devices (disks and sizes):"
    # show non-loop, non-ram, non-ro devices
    lsblk -dpno NAME,SIZE,TYPE | awk '$3=="disk"{print $1" ("$2")"}' | grep -v '^$' || true
}

# ====== Disk partition helper (fdisk) ======
# Creates a new partition on $1 with optional size and LVM flag.
# Returns the partition path in TARGET_PV global var.
partition_disk_with_fdisk() {
    local DISK="$1"
    TARGET_PV=""

    echo ""
    echo "Do you want to partition $DISK with fdisk before using it for LVM? (yes/no)"
    read -p "Answer: " PART_CHOICE
    PART_CHOICE=${PART_CHOICE:-no}
    PART_CHOICE=$(echo "$PART_CHOICE" | tr '[:upper:]' '[:lower:]')

    if [[ "$PART_CHOICE" != "yes" ]]; then
        echo "Skipping partitioning for $DISK; will use raw disk."
        TARGET_PV="$DISK"
        return 0
    fi

    echo ""
    echo "Partitioning $DISK using fdisk. Example size format: +10G, +500M. Leave blank for full disk."
    read -p "Enter partition size (or press Enter to use full disk): " PART_SIZE
    PART_SIZE="${PART_SIZE:-}"

    echo ""
    echo "Do you want to set the partition type to Linux LVM (8e)? (yes/no)"
    read -p "Answer: " LVM_ANS
    LVM_ANS=${LVM_ANS:-no}
    LVM_ANS=$(echo "$LVM_ANS" | tr '[:upper:]' '[:lower:]')

    echo ""
    echo "Running fdisk to create a new partition on $DISK..."
    # Pipe commands to fdisk: n p (auto number) default start, size or default, optionally t then 8e, then w
    {
        printf "n\n"        # new partition
        printf "p\n"        # primary
        printf "\n"         # accept default partition number (next available)
        printf "\n"         # accept default first sector
        if [[ -n "$PART_SIZE" ]]; then
            printf "%s\n" "$PART_SIZE"
        else
            printf "\n"     # accept default last sector (use full)
        fi

        if [[ "$LVM_ANS" == "yes" ]]; then
            printf "t\n"   # change type
            printf "\n"    # operate on last partition (fdisk default)
            # set to 8e -- for GPT fdisk sometimes expects different code, try 8e
            printf "8e\n"
        fi
        printf "w\n"       # write changes
    } | fdisk "$DISK" >/dev/null 2>&1 || {
        echo "⚠️ fdisk returned an error. Attempting to continue."
    }

    # Ensure kernel rereads partition table
    if command -v partprobe >/dev/null 2>&1; then
        partprobe "$DISK" >/dev/null 2>&1 || true
    else
        # try blockdev to reread
        blockdev --rereadpt "$DISK" >/dev/null 2>&1 || true
    fi
    sleep 1

    # Detect the newest partition on the disk
    # lsblk -ln /dev/sdc output includes disk then partitions; take last partition name
    local newest
    newest=$(lsblk -ln -o NAME "$DISK" | tail -n1 || true)
    if [[ -z "$newest" || "$newest" == "$(basename "$DISK")" ]]; then
        # fallback: search for first partition
        newest=$(lsblk -ln -o NAME "$DISK" | sed -n '2p' || true)
    fi

    if [[ -n "$newest" ]]; then
        TARGET_PV="/dev/$newest"
        echo "✅ Detected new partition: $TARGET_PV"
    else
        echo "ERROR: Could not detect created partition on $DISK. Using raw disk: $DISK"
        TARGET_PV="$DISK"
    fi

    return 0
}

# ====== VG Functions ======

create_vg() {
    echo ""
    echo "=== Create New VG ==="
    echo ""
    list_raw_disks
    echo ""
    read -p "Enter new VG name: " VG_NAME
    echo ""
    read -p "Enter PV(s) to include (space-separated, e.g., /dev/sdb /dev/sdc): " PV_LIST
    echo ""

    FINAL_PVS=()

    for PV in $PV_LIST; do
        echo ""
        echo "Preparing $PV for LVM..."
        echo "----------------------------------"
        partition_disk_with_fdisk "$PV"
        echo ""
        read -p "Enter device to use for PV creation (raw or partition), e.g. $PV or ${PV}1: " TARGET_PV
        TARGET_PV=${TARGET_PV:-$PV}
        # Sanitize existence
        if [ ! -b "$TARGET_PV" ]; then
            echo "ERROR: device $TARGET_PV does not exist or is not a block device. Skipping."
            continue
        fi
        echo "Creating PV on $TARGET_PV..."
        pvcreate "$TARGET_PV" >/dev/null 2>&1 || { echo "ERROR: pvcreate failed for $TARGET_PV"; exit 1; }
        FINAL_PVS+=("$TARGET_PV")
    done

    if [ ${#FINAL_PVS[@]} -eq 0 ]; then
        echo "No PVs created. Aborting VG creation."
        return 1
    fi

    echo "Creating VG '$VG_NAME' with PV(s): ${FINAL_PVS[*]} ..."
    vgcreate "$VG_NAME" "${FINAL_PVS[@]}" >/dev/null 2>&1 || { echo "ERROR: vgcreate failed"; exit 1; }

    echo ""
    echo "✅ VG '$VG_NAME' created successfully with PV(s): ${FINAL_PVS[*]}"
    echo ""
}

extend_vg() {
    echo ""
    echo "=== Extend Existing VG ==="
    echo ""
    echo "Available Volume Groups:"
    vgs
    echo ""
    read -p "Enter VG name to extend: " VG_NAME
    echo ""
    echo "Available raw disks (not in any VG):"
    list_raw_disks
    echo ""
    read -p "Enter PV(s) to add (space-separated, e.g., /dev/sdb /dev/sdc): " PV_LIST
    echo ""

    FINAL_PVS=()

    for PV in $PV_LIST; do
        echo ""
        echo "Preparing $PV for VG extension..."
        echo "----------------------------------"
        partition_disk_with_fdisk "$PV"
        echo ""
        read -p "Enter device to use for PV creation (raw or partition), e.g. $PV or ${PV}1: " TARGET_PV
        TARGET_PV=${TARGET_PV:-$PV}
        if [ ! -b "$TARGET_PV" ]; then
            echo "ERROR: device $TARGET_PV does not exist or is not a block device. Skipping."
            continue
        fi
        pvcreate "$TARGET_PV" >/dev/null 2>&1 || { echo "ERROR: pvcreate failed for $TARGET_PV"; exit 1; }
        vgextend "$VG_NAME" "$TARGET_PV" >/dev/null 2>&1 || { echo "ERROR: vgextend failed"; exit 1; }
        FINAL_PVS+=("$TARGET_PV")
    done

    if [ ${#FINAL_PVS[@]} -eq 0 ]; then
        echo "No PVs added. VG not extended."
        return 1
    fi

    echo ""
    echo "✅ VG '$VG_NAME' extended successfully with new PV(s): ${FINAL_PVS[*]}"
    echo ""
}

# ====== LV Functions ======
create_lvs() {
    echo "=== Create Logical Volumes ==="
    vgs
    read -p "Enter VG name to use: " VG_NAME
    read -p "How many LVs to create? " LV_COUNT

    for ((i=1;i<=LV_COUNT;i++)); do
        read -p "Enter LV #$i name: " LV_NAME
        read -p "Enter LV #$i size (e.g., 100G, 1T): " LV_SIZE
        read -p "Filesystem type (xfs/ext4, default xfs): " FS_TYPE
        FS_TYPE=${FS_TYPE:-xfs}
        read -p "Enter mount point (full path, e.g., /data or /oracle): " MOUNT_POINT

        lvcreate -L "$LV_SIZE" -n "$LV_NAME" "$VG_NAME" >/dev/null 2>&1 || { echo "ERROR: lvcreate failed"; exit 1; }
        if [ "$FS_TYPE" == "xfs" ]; then
            mkfs.xfs -f "/dev/$VG_NAME/$LV_NAME" >/dev/null 2>&1 || { echo "ERROR: mkfs.xfs failed"; exit 1; }
        else
            mkfs.ext4 -F "/dev/$VG_NAME/$LV_NAME" >/dev/null 2>&1 || { echo "ERROR: mkfs.ext4 failed"; exit 1; }
        fi

        if [ ! -d "$MOUNT_POINT" ]; then
            mkdir -p "$MOUNT_POINT" || { echo "ERROR: could not create mount point $MOUNT_POINT"; exit 1; }
            echo "Created mount directory: $MOUNT_POINT"
        fi

        mount "/dev/$VG_NAME/$LV_NAME" "$MOUNT_POINT" || { echo "ERROR: mount failed"; exit 1; }

        # Write UUID-based fstab entry
        UUID=$(blkid -s UUID -o value "/dev/$VG_NAME/$LV_NAME" || true)
        if [ -n "$UUID" ]; then
            grep -q "UUID=$UUID" /etc/fstab || echo "UUID=$UUID  $MOUNT_POINT  $FS_TYPE  defaults  0 0" >> /etc/fstab
        else
            # fallback to device path
            grep -q "/dev/$VG_NAME/$LV_NAME" /etc/fstab || echo "/dev/$VG_NAME/$LV_NAME  $MOUNT_POINT  $FS_TYPE  defaults  0 0" >> /etc/fstab
        fi

        echo "✅ LV $LV_NAME created, formatted as $FS_TYPE, mounted at $MOUNT_POINT, added to fstab."
    done
}

extend_lv() {
    echo "=== Extend Logical Volume ==="
    lvs
    read -p "Enter VG name: " VG_NAME
    read -p "Enter LV name to extend: " LV_NAME
    read -p "Enter additional size (e.g., 100G, 1T): " EXT_SIZE

    lv_path="/dev/$VG_NAME/$LV_NAME"
    if [ ! -e "$lv_path" ]; then
        echo "❌ LV $lv_path not found."
        return
    fi

    echo "Extending $lv_path by $EXT_SIZE..."
    lvextend -L +"$EXT_SIZE" "$lv_path" >/dev/null 2>&1 || { echo "ERROR: lvextend failed"; exit 1; }

    # Auto-detect filesystem type and resize
    FS_TYPE=$(blkid -o value -s TYPE "$lv_path" || true)
    MOUNT_POINT=$(findmnt -nr -o TARGET "$lv_path" || true)

    if [ "$FS_TYPE" == "xfs" ]; then
        echo "Detected filesystem: XFS"
        # xfs_growfs requires mount point
        if [ -n "$MOUNT_POINT" ]; then
            xfs_growfs "$MOUNT_POINT" >/dev/null 2>&1 || { echo "ERROR: xfs_growfs failed"; exit 1; }
        else
            echo "WARNING: LV not mounted; cannot run xfs_growfs automatically."
        fi
    elif [ "$FS_TYPE" == "ext4" ]; then
        echo "Detected filesystem: EXT4"
        resize2fs "$lv_path" >/dev/null 2>&1 || { echo "ERROR: resize2fs failed"; exit 1; }
    else
        echo "⚠️ Unknown or no filesystem detected ($FS_TYPE). Skipping resize."
    fi

    echo "✅ LV $LV_NAME extended successfully by $EXT_SIZE and filesystem resized (if applicable)."
}

# ====== Full Clean Setup ======
full_setup() {
    echo ""
    echo "=== Full LVM + Filesystem Clean Setup ==="
    echo "------------------------------------------------------"
    list_raw_disks
    echo ""
    read -p "Enter new VG name: " VG_NAME
    echo ""
    read -p "Enter PV(s) to include in VG (space-separated, e.g., /dev/sdb /dev/sdc): " PV_LIST
    echo ""

    FINAL_PVS=()

    for PV in $PV_LIST; do
        echo ""
        echo "Preparing $PV for LVM..."
        echo "----------------------------------"
        partition_disk_with_fdisk "$PV"
        echo ""
        read -p "Enter device to use for PV creation (raw or partition), e.g. $PV or ${PV}1: " TARGET_PV
        TARGET_PV=${TARGET_PV:-$PV}
        if [ ! -b "$TARGET_PV" ]; then
            echo "ERROR: device $TARGET_PV does not exist or is not a block device. Skipping."
            continue
        fi
        pvcreate "$TARGET_PV" >/dev/null 2>&1 || { echo "ERROR: pvcreate failed for $TARGET_PV"; exit 1; }
        FINAL_PVS+=("$TARGET_PV")
    done

    if [ ${#FINAL_PVS[@]} -eq 0 ]; then
        echo "No PVs available; aborting."
        return 1
    fi

    vgcreate "$VG_NAME" "${FINAL_PVS[@]}" >/dev/null 2>&1 || { echo "ERROR: vgcreate failed"; exit 1; }
    echo ""
    echo "✅ Volume Group '$VG_NAME' created successfully with PV(s): ${FINAL_PVS[*]}"
    echo ""

    read -p "How many LVs do you want to create? " LV_COUNT
    echo ""
    for ((i=1;i<=LV_COUNT;i++)); do
        echo ""
        echo "---- LV #$i Configuration ----"
        read -p "Enter LV name: " LV_NAME
        read -p "Enter LV size (e.g., 100G, 1T): " LV_SIZE
        read -p "Filesystem type (xfs/ext4, default xfs): " FS_TYPE
        FS_TYPE=${FS_TYPE:-xfs}
        read -p "Enter mount point (e.g., /data, /backup): " MOUNT_POINT

        lvcreate -L "$LV_SIZE" -n "$LV_NAME" "$VG_NAME" >/dev/null 2>&1 || { echo "ERROR: lvcreate failed"; exit 1; }

        if [[ "$FS_TYPE" == "xfs" ]]; then
            mkfs.xfs -f "/dev/$VG_NAME/$LV_NAME" >/dev/null 2>&1 || { echo "ERROR: mkfs.xfs failed"; exit 1; }
        else
            mkfs.ext4 -F "/dev/$VG_NAME/$LV_NAME" >/dev/null 2>&1 || { echo "ERROR: mkfs.ext4 failed"; exit 1; }
        fi

        if [ ! -d "$MOUNT_POINT" ]; then
            mkdir -p "$MOUNT_POINT" || { echo "ERROR: could not create mount point $MOUNT_POINT"; exit 1; }
            echo "Created mount directory: $MOUNT_POINT"
        fi

        mount "/dev/$VG_NAME/$LV_NAME" "$MOUNT_POINT" || { echo "ERROR: mount failed"; exit 1; }

        UUID=$(blkid -s UUID -o value "/dev/$VG_NAME/$LV_NAME" || true)
        if [ -n "$UUID" ]; then
            grep -q "UUID=$UUID" /etc/fstab || echo "UUID=$UUID  $MOUNT_POINT  $FS_TYPE  defaults  0 0" >> /etc/fstab
        else
            grep -q "/dev/$VG_NAME/$LV_NAME" /etc/fstab || echo "/dev/$VG_NAME/$LV_NAME  $MOUNT_POINT  $FS_TYPE  defaults  0 0" >> /etc/fstab
        fi

        echo "✅ Mounted /dev/$VG_NAME/$LV_NAME at $MOUNT_POINT and added to fstab."
    done

    echo ""
    echo "🎉 Full clean setup completed successfully!"
    echo "VG: $VG_NAME"
    echo "LV(s) created and mounted successfully."
    echo "------------------------------------------------------"
    echo ""
}

# ====== Main Menu ======
detect_os
check_tools

while true; do
    echo "================ CWG Intelligent File-System Manager ================"
    echo "1) Create New VG"
    echo "2) Extend Existing VG"
    echo "3) Create LV(s) + FS + Mount"
    echo "4) Extend Existing LV + Auto-Resize FS"
    echo "5) Full Clean Setup (new VG + multiple LVs)"
    echo "6) Exit"
    read -p "Select an option [1-6]: " CHOICE

    case $CHOICE in
        1) create_vg ;;
        2) extend_vg ;;
        3) create_lvs ;;
        4) extend_lv ;;
        5) full_setup ;;
        6) echo "Goodbye!"; exit 0 ;;
        *) echo "Invalid option. Try again." ;;
    esac
done
