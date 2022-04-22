#!/usr/bin/env -S bash -e

# Cleaning the TTY.
clear

# Updating the live environment usually causes more problems than its worth, and quite often can't be done without remounting cowspace with more capacity, especially at the end of any given month.
pacman -Sy

# Installing curl
pacman -S --noconfirm curl

# Selecting the kernel flavor to install.
kernel_selector () {
    echo "List of kernels:"
    echo "1) Stable — Vanilla Linux kernel and modules, with a few patches applied."
    echo "2) Hardened — A security-focused Linux kernel."
    echo "3) Longterm — Long-term support (LTS) Linux kernel and modules."
    echo "4) Zen Kernel — Optimized for desktop usage."
    read -r -p "Insert the number of the corresponding kernel: " choice
    echo "$choice will be installed"
    case $choice in
        1 ) kernel=linux
            ;;
        2 ) kernel=linux-hardened
            ;;
        3 ) kernel=linux-lts
            ;;
        4 ) kernel=linux-zen
            ;;
        * ) echo "You did not enter a valid selection."
            kernel_selector
    esac
}

# Checking the microcode to install.
CPU=$(grep vendor_id /proc/cpuinfo)
if [[ $CPU == *"AuthenticAMD"* ]]; then
    microcode=amd-ucode
else
    microcode=intel-ucode
fi

# Selecting the target for the installation.
PS3="Select the disk where Arch Linux is going to be installed: "
select ENTRY in $(lsblk -dpnoNAME|grep -P "/dev/sd|nvme|vd");
do
    DISK=$ENTRY
    echo "Installing Arch Linux on $DISK."
    break
done

# Deleting old partition scheme.
read -r -p "This will delete the current partition table on $DISK. Do you agree [y/N]? " response
response=${response,,}
if [[ "$response" =~ ^(yes|y)$ ]]; then
    wipefs -af "$DISK" &>/dev/null
    sgdisk -Zo "$DISK" &>/dev/null
else
    echo "Quitting."
    exit
fi

# Creating a new partition scheme.
echo "Creating new partition scheme on $DISK."
parted -s "$DISK" \
    mklabel gpt \
    mkpart ESP fat32 1MiB 512MiB \
    set 1 esp on \
    mkpart cryptroot 512MiB 100% \

ESP="/dev/disk/by-partlabel/ESP"
cryptroot="/dev/disk/by-partlabel/cryptroot"

# Informing the Kernel of the changes.
echo "Informing the Kernel about the disk changes."
partprobe "$DISK"

# Formatting the ESP as FAT32.
echo "Formatting the EFI Partition as FAT32."
mkfs.fat -F 32 $ESP &>/dev/null

# Creating a LUKS Container for the root partition.
echo "Creating LUKS Container for the root partition."
cryptsetup luksFormat --type luks2 $cryptroot
echo "Opening the newly created LUKS Container."
cryptsetup open $cryptroot cryptroot
BTRFS="/dev/mapper/cryptroot"

# Formatting the LUKS Container as BTRFS.
echo "Formatting the LUKS container as BTRFS."
mkfs.btrfs $BTRFS &>/dev/null
mount -o clear_cache,nospace_cache $BTRFS /mnt

# Creating BTRFS subvolumes.
echo "Creating BTRFS subvolumes."
btrfs su cr /mnt/@ &>/dev/null
btrfs su cr /mnt/@/.snapshots &>/dev/null
mkdir -p /mnt/@/.snapshots/1 &>/dev/null
btrfs su cr /mnt/@/.snapshots/1/snapshot &>/dev/null
btrfs su cr /mnt/@/boot/ &>/dev/null
btrfs su cr /mnt/@/home &>/dev/null
btrfs su cr /mnt/@/root &>/dev/null
btrfs su cr /mnt/@/srv &>/dev/null
btrfs su cr /mnt/@/var_log &>/dev/null
btrfs su cr /mnt/@/var_pkg $>/dev/null
btrfs su cr /mnt/@/machines $>/dev/null
btrfs su cr /mnt/@/images $>/dev/null

#Set the default BTRFS Subvol to Snapshot 1 before pacstrapping
btrfs subvolume set-default "$(btrfs subvolume list /mnt | grep "@/.snapshots/1/snapshot" | grep -oP '(?<=ID )[0-9]+')" /mnt

cat << EOF >> /mnt/@/.snapshots/1/info.xml
<?xml version="1.0"?>
<snapshot>
  <type>single</type>
  <num>1</num>
  <date>1999-03-31 0:00:00</date>
  <description>First Root Filesystem</description>
  <cleanup>number</cleanup>
</snapshot>
EOF

chmod 600 /mnt/@/.snapshots/1/info.xml

# Mounting the newly created subvolumes.
umount /mnt
echo "Mounting the newly created subvolumes."
mount -o ssd,noatime,space_cache=v2,compress=zstd $BTRFS /mnt
mkdir -p /mnt/{boot,root,home,.snapshots,srv,/var/log,/var/cache/pacman,/var/lib/libvirt/images,/var/lib/machines}
mount -o ssd,noatime,space_cache=v2,compress=zstd,subvol=@/boot $BTRFS /mnt/boot
mount -o ssd,noatime,space_cache=v2,compress=zstd,subvol=@/root $BTRFS /mnt/root
mount -o ssd,noatime,space_cache=v2.compress=zstd,subvol=@/home $BTRFS /mnt/home
mount -o ssd,noatime,space_cache=v2,compress=zstd,subvol=@/.snapshots $BTRFS /mnt/.snapshots
mount -o ssd,noatime,space_cache=v2,compress=zstd,subvol=@/srv $BTRFS /mnt/srv
mount -o ssd,noatime,space_cache=v2,compress=zstd,subvol=@/var_log $BTRFS /mnt/var/log
mount -o ssd,noatime,space_cache=v2,compress=zstd,subvol=@/var_cache $BTRFS /mnt/var/cache

mount -o ssd,noatime,space_cache=v2,compress=zstd,subvol=@/var_lib_libvirt_images $BTRFS /mnt/var/lib/libvirt/images
mount -o ssd,noatime,space_cache=v2,compress=zstd,subvol=@/var_lib_machines $BTRFS /mnt/var/lib/machines

mkdir -p /mnt/boot/efi
mount $ESP /mnt/boot/efi

kernel_selector

# Pacstrap (setting up a base sytem onto the new root).
echo "Installing the base system (it may take a while)."
pacstrap /mnt base base-devel ${kernel} ${microcode} linux-firmware grub grub-btrfs snapper snap-pac efibootmgr networkmanager python-psutil nano

# Generating /etc/fstab.
echo "Generating a new fstab."
genfstab -U /mnt >> /mnt/etc/fstab
sed -i 's#,subvolid=258,subvol=/@/.snapshots/1/snapshot,subvol=@/.snapshots/1/snapshot##g' /mnt/etc/fstab

# Finishing up
echo "Done, you may now wish to continue manually (further changes can be done by chrooting into /mnt)."
exit
