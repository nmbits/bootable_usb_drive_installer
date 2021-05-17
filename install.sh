#!/bin/sh

# DRYRUN=echo

check_dev()
{
    local dev=$1
    if [ ! -e "$dev" ]; then
	echo "error: $dev not found." >&2
	return 1
    fi
    file $dev | grep "block special" >/dev/null
    if [ $? -ne 0 ]; then
	echo "error: $dev is not a block device." >&2
	return 1
    fi
    return 0
}

make_partitions()
{
    local dev=$1
    if [ -z "$dev" ]; then
	echo "error: no device specified." >&2
	return 1
    fi
    n=`lsblk -l -n -o name $dev | wc -l`
    if [ $n -gt 1 ]; then
 	echo "error: $dev has one or more partitions." >&2
	return 1
    fi

    $DRYRUN sfdisk $DEV <<EOF
label: gpt
,64MiB,U
,,
EOF
    if [ $? -ne 0 ]; then
	echo "error: sfdisk returned code $?." >&2
    fi

    sleep 5

    return $?
}

make_filesystems()
{
    local dev_efi=$1
    local dev_btr=$2

    if [ -z $dev_efi ]; then
	echo "error: no device specified for efi." >&2
	return 1
    fi
    if [ -z $dev_btr ]; then
	echo "error: no device specified for efi." >&2
	return 1
    fi
    
    $DRYRUN mkfs.vfat -F 32 $dev_efi
    if [ $? -ne 0 ]; then
	ret=$?
	echo "error: mkfs.vfat $dev_efi failed ($ret)." >&2
	return $ret
    fi

    $DRYRUN mkfs.btrfs -f $dev_btr
    if [ $? -ne 0 ]; then
	ret=$?
	echo "error: mkfs.btrfs failed ($ret)." >&2
	return $ret
    fi

    return 0
}

mount_btrfs()
{
    local dev_btr=$1
    local btrfs=$2
    local subvol=$3

    if [ -z $dev_btr ]; then
	echo "error: no btrfs device specified." >&2
	return 1
    fi
    if [ -z "$btrfs" ]; then
	echo "error: no btrfs mountpoint specified." >&2
	return 1
    fi
    if [ -z "$subvol" ]; then
	subvol=/
    fi

    if [ ! -d "$btrfs" ]; then
	echo "error: $btrfs is not a directory." >&2
	return 1
    fi

    $DRYRUN mount $dev_btr -o subvol=$subvol $btrfs
    ret=$?
    if [ $ret -ne 0 ]; then
	echo "error: failed to mount $dev_btr on $btrfs ($ret)." >&2
	return $ret
    fi
    return 0
}

umount_btrfs()
{
    local btrfs=$1
    if [ -z "$btrfs" ]; then
	echo "error: no btrfs mountpoint specified." >&2
	return 1
    fi

    $DRYRUN umount $btrfs
    ret=$?

    return $ret
}

make_subvol()
{
    local dev_btr=$1
    local subvol=$2
    if [ -z $dev_btr ]; then
	echo "error: no btrfs device specified." >&2
	return 1
    fi
    if [ -z $subvol ]; then
	subvol=@
    fi
    local mountpoint=`mktemp -d`
    mount_btrfs $dev_btr $mountpoint
    ret=$?
    if [ $ret -ne 0 ]; then
	rmdir $mountpoint
	return $ret
    fi

    $DRYRUN btrfs subvolume create $mountpoint/$subvol
    ret=$?
    if [ $ret -ne 0 ]; then
	echo "error: failed to create subvol ($ret)." >&2
    fi

    umount_btrfs $mountpoint
    rmdir $mountpoint
    return $ret
}

do_debootstrap()
{
    local dev_btr=$1
    local suite=$2
    local subvol=$3

    if [ -z "$dev_btr" ]; then
	echo "error: no btrfs device specified." >&2
	return 1
    fi
    if [ -z "$suite" ]; then
	echo "error: no suite specified." >&2
	return 1
    fi

    local mountpoint=`mktemp -d`
    mount_btrfs $dev_btr $mountpoint $subvol
    ret=$?
    if [ $ret -ne 0 ]; then
	rmdir $mountpoint
	return $ret
    fi

    $DRYRUN debootstrap --include busybox,rsync,btrfs-progs,linux-image-amd64,grub-efi-amd64 $suite $mountpoint
    ret=$?
    if [ $ret -ne 0 ]; then
	echo "error: debootstrap failed ($ret)." >&2
    fi
    umount_btrfs $mountpoint
    rmdir $mountpoint
    return $ret
}

copy_scripts()
{
    local dev_btr=$1
    local subvol=$2

    if [ -z "$dev_btr" ]; then
	echo "error: no btrfs device specified." >&2
	return 1
    fi
    local mountpoint=`mktemp -d`
    mount_btrfs $dev_btr $mountpoint $subvol
    ret=$?
    if [ $ret -ne 0 ]; then
	rmdir $mountpoint
	return $ret
    fi

    local irft=$mountpoint/etc/initramfs-tools
    local script_dir=$PWD/`dirname $0`
    $DRYRUN cp $script_dir/overlayroot     $irft/scripts/init-bottom
    $DRYRUN cp $script_dir/overlayss       $irft/hooks
    $DRYRUN cp $script_dir/ssroot          $mountpoint/usr/local/sbin
    $DRYRUN cp $script_dir/ssroot.service  $mountpoint/etc/systemd/system
    $DRYRUN cp $script_dir/ssroot_premount $irft/scripts/local-premount/
    $DRYRUN chmod 755 $irft/scripts/init-bottom/overlayroot
    $DRYRUN chmod 755 $irft/hooks/overlayss
    $DRYRUN chmod 755 $mountpoint/usr/local/sbin/ssroot
    $DRYRUN chmod 644 $mountpoint/ssroot.conf
    $DRYRUN chmod 644 $mountpoint/etc/systemd/system/ssroot.service
    $DRYRUN chmod 755 $irft/scripts/local-premount/ssroot_premount
    if [ -z $DRYRUN ]; then
	echo "overlay" >> $irft/modules
	echo "btrfs"   >> $irft/modules
    fi

    umount_btrfs $mountpoint
    rmdir $mountpoint
    return $ret
}

do_chroot()
{
    local dev_efi=$1
    local dev_btr=$2
    local subvol=$3

    if [ -z "$dev_btr" ]; then
	echo "error: no btrfs device specified." >&2
	return 1
    fi

    if [ -z "$dev_efi" ]; then
	echo "error: no efi device specified." >&2
	return 1
    fi

    if [ -z "$subvol" ]; then
	subvol=@
    fi

    local dir=`mktemp -d`

    local key=`od -vAn --width=4 -tu4 -N4 </dev/urandom`
    key=`echo -n $key`
    
    $DRYRUN mount -t btrfs -o subvol=$subvol $dev_btr $dir
    $DRYRUN mkdir -p $dir/boot/efi
    $DRYRUN mount             $dev_efi $dir/boot/efi
    $DRYRUN mount -t proc     proc     $dir/proc
    $DRYRUN mount -t sysfs    sys      $dir/sys
    $DRYRUN mount -t devtmpfs dev      $dir/dev
    $DRYRUN mount -t devpts   devpts   $dir/dev/pts
    $DRYRUN mount -t tmpfs    tmpfs    $dir/dev/shm
    $DRYRUN mount -t tmpfs    tmpfs    $dir/tmp
    $DRYRUN cp $PWD/$0 $dir/tmp
    $DRYRUN touch $dir/tmp/$key
    $DRYRUN chroot $dir sh /tmp/$(basename $0) -c $key $dev_efi $dev_btr
    ret=$?
    $DRYRUN umount $dir/tmp
    $DRYRUN umount $dir/dev/shm
    $DRYRUN umount $dir/dev/pts
    $DRYRUN umount $dir/dev
    $DRYRUN umount $dir/sys
    $DRYRUN umount $dir/proc
    $DRYRUN umount $dir/boot/efi
    $DRYRUN umount $dir

    rmdir $dir
    return $ret
}

do_apt_kernel()
{
    # $DRYRUN apt update
    # $DRYRUN apt install -y btrfs-progs linux-image-amd64 grub-efi-amd64
    return 0
}

install_grub()
{
    $DRYRUN grub-install —target=x86_64-efi
    if [ -z "$DRYRUN" ]; then
	echo "GRUB_DISABLE_OS_PROBER=true" >> /etc/default/grub
	echo "GRUB_CMDLINE_LINUX=\"ssroot=y\"" >> /etc/default/grub
    fi
    $DRYRUN update-grub
    $DRYRUN mkdir /boot/efi/EFI/BOOT
    $DRYRUN cp /boot/efi/EFI/debian/grubx64.efi /boot/efi/EFI/BOOT/BOOTX64.EFI
}

make_fstab()
{
    local dev_efi=$1
    local dev_btr=$2
    local subvol=$3

    if [ -z "$dev_efi" ]; then
	echo "error: no efi device specified." >&2
	return 1
    fi
    if [ -z "$dev_btr" ]; then
	echo "error: no btrfs device specified." >&2
	return 1
    fi
    if [ -z "$subvol" ]; then
	subvol=@
    fi

    $DRYRUN mkdir /btrfs
    if [ -z "$DRYRUN" ]; then
	cat <<EOF > /etc/fstab
UUID=$( blkid -s UUID -o value $dev_btr ) /         btrfs subvol=$subvol,defaults 0 0
UUID=$( blkid -s UUID -o value $dev_efi ) /boot/efi vfat  umask=0077              0 0
EOF
    fi

    return 0
}

enable_ssroot()
{
    $DRYRUN update-initramfs -u
    $DRYRUN systemctl enable ssroot
    return $?
}

main()
{
    ret=0
    DEV=$1
    EFI=${DEV}1
    BTR=${DEV}2
    phase=$2
    if [ -z "$phase" ]; then
	phase=0
    fi
    while : ;do
	echo ">>>> phase $phase..." >&2
	case $phase in
	    0)
		check_dev $DEV
		ret=$?
		;;
	    1)
		make_partitions $DEV
		ret=$?
		;;
	    2)
		make_filesystems $EFI $BTR
		;;
	    3)
		make_subvol $BTR @
		;;
	    4)
		do_debootstrap $BTR buster @
		;;
	    5)
		copy_scripts $BTR @
		;;
	    6)
		do_chroot $EFI $BTR
		;;
	    *)
		break
		;;
	esac
	if [ $ret -ne 0 ]; then
	    break
	fi
	phase=`expr $phase + 1`
    done
    return $ret
}

child()
{
    ret=0
    KEY=$1
    EFI=$2
    BTR=$3
    phase=0

    if [ -z $KEY ]; then
	echo "error: invalid child process." >&2
	return 1
    fi

    if [ ! -e /tmp/$KEY ]; then
	echo "error: invalid key $KEY." >&2
	return 1
    fi

    while : ;do
	echo ">>>> child phase $phase..." >&2
	case $phase in
	    0)
		do_apt_kernel
		ret=$?
		;;
	    1)
		install_grub
		ret=$?
		;;
	    2)
		make_fstab $EFI $BTR
		ret=$?
		;;
	    3)
		enable_ssroot
		;;
	    4)
		passwd
		ret=$?
		;;
	    *)
		break
		;;
	esac
	if [ $ret -ne 0 ]; then
	    break
	fi
	phase=`expr $phase + 1`
    done
    return $ret
}

if [ -z "$1" ]; then
    echo "usage: $0 dev [phase]" >&2
    exit 1
fi

if [ $1 = "-c" ]; then
    child $2 $3 $4
    exit $?
else
    main $1 $2
fi
