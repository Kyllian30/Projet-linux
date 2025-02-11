#!/bin/bash

# Vérification des permissions root
if [ "$(id -u)" -ne 0 ]; then
    echo "Ce script doit être exécuté en tant que root."
    exit 1
fi

# Définition des variables
disk="/dev/sda"  # Adapter selon l'installation réelle
hostname="archlinux"
username="user"
son_username="son"
password="azerty123"

# Mise à jour de l'horloge
timedatectl set-ntp true

# Partitionnement du disque
echo -e "o\nn\n\n\n+512M\nef00\nn\n\n\n\nw" | gdisk $disk

# Formatage des partitions
mkfs.fat -F32 "${disk}1"

# Chiffrement du disque avec LUKS
cryptsetup luksFormat "${disk}2" --type luks2 --cipher aes-xts-plain64 --key-size 512 --hash sha512 --iter-time 5000
cryptsetup open "${disk}2" cryptroot

# Création de volumes LVM
pvcreate /dev/mapper/cryptroot
vgcreate vg0 /dev/mapper/cryptroot
lvcreate -L 10G -n encrypted vg0  # Volume chiffré manuel
lvcreate -L 20G -n root vg0
lvcreate -L 4G -n swap vg0
lvcreate -L 30G -n home vg0
lvcreate -L 10G -n virtualbox vg0
lvcreate -L 5G -n shared vg0

# Formatage des volumes
mkfs.ext4 /dev/vg0/root
mkfs.ext4 /dev/vg0/home
mkfs.ext4 /dev/vg0/virtualbox
mkfs.ext4 /dev/vg0/shared
mkswap /dev/vg0/swap

# Montage des partitions
mount /dev/vg0/root /mnt
mkdir -p /mnt/{boot,home,var,virtualbox,shared}
mount /dev/vg0/home /mnt/home
mount /dev/vg0/virtualbox /mnt/virtualbox
mount /dev/vg0/shared /mnt/shared
mount "${disk}1" /mnt/boot
swapon /dev/vg0/swap

# Installation du système
pacstrap /mnt base linux linux-firmware vim sudo networkmanager grub efibootmgr lvm2

# Configuration du système
genfstab -U /mnt >> /mnt/etc/fstab
arch-chroot /mnt /bin/bash <<EOF
ln -sf /usr/share/zoneinfo/Europe/Paris /etc/localtime
hwclock --systohc
echo "$hostname" > /etc/hostname
passwd root <<EOL
$password
$password
EOL

# Création des utilisateurs
useradd -m -G wheel -s /bin/bash $username
useradd -m -G users -s /bin/bash $son_username
echo "$username:$password" | chpasswd
echo "$son_username:$password" | chpasswd

# Configuration de sudo
echo "$username ALL=(ALL) ALL" >> /etc/sudoers

# Installation des logiciels demandés
pacman -S --noconfirm hyprland virtualbox firefox htop neofetch git open-vm-tools xf86-video-vmware 

# Activer les services essentiels
systemctl enable NetworkManager
systemctl enable vmtoolsd.service
systemctl enable vmware-vmblock-fuse.service

# Installation et configuration de GRUB
grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB
grub-mkconfig -o /boot/grub/grub.cfg
EOF

# Fin de l'installation
echo "Installation terminée ! Redémarrez après avoir éjecté le média d'installation."