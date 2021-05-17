# Bootable USB drive installer

## Introduction
This script creates a bootable USB drive suitable for long-term operation such as a file server.

## Features
1. The USB drive is protected by overlayfs (overlayroot). Changes to the USB drive are stored in tmpfs and no data is written to the USB drive.
2. The changes stored in tmpfs will be applied to the USB drive at shutdown.

## Prerequisites
* PC used for installation: Debian amd64 system with a USB port. btrfs-progs, debootstrap must be installed.
* USB Drive: USB drive of about 1GB (increase or decrease depending on the purpose)
* PC to boot USB Drive:
  * X86_64 with UEFI
  * Memory that can store at least the amount of changes to the root filesystem (maximum: filesystem size)

## Usage
1. Store all files in this directory in any one directory.
2. Prepare a USB drive and delete all its partitions.
3. Execute the following command:
   > sudo sh install.sh /path/to/USB/drive/device_file
4. When asked for the password, enter the root password to be set on the USB drive.
5. When the script is finished, insert the USB into the desired PC and boot from the USB drive.
6. Set up the network and install the required packages.
7. Shutdown to apply the changes to the USB drive.
8. Reboot with the USB drive and make sure the changes are reflected.

## Note
1. A snapshot of the root file system is created with each shutdown. The name of the snapshot is @. Number. The number will be the maximum of the current snapshot + 1.
2. At boot time, the snapshot with the highest number is used as the root file system.
3. Old snapshots are not deleted automatically. Delete the snapshot if necessary.

## License
GPL v2
