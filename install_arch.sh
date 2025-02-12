#!/bin/bash

# Vérification que le script est exécuté en root
if [ "$(id -u)" -ne 0 ]; then
    echo "Ce script doit être exécuté en tant que root."
    exit 1
fi

### Définition des variables
DISK="/dev/sda"
HOSTNAME="archlinux"
USERNAME="user"
SON_USERNAME="son"
PASSWORD="azerty123"

### Mise à jour de l'horloge
timedatectl set-ntp true

### Partitionnement du disque avec GPT
echo -e "o\nn\n\n\n+512M\nt\n1\nn\n\n\n\nw" | fdisk $DISK

# Création des partitions
mkfs.fat -F32 "${DISK}1"
cryptsetup luksFormat "${DISK}2"
cryptsetup open "${DISK}2" cryptroot

# Création du volume LVM
pvcreate /dev/mapper/cryptroot
vgcreate vg0 /dev/mapper/cryptroot
lvcreate -L 10G -n encrypted vg0  # Volume chiffré manuel
lvcreate -L 20G -n root vg0
lvcreate -L 2G -n swap vg0
lvcreate -L 40G -n home vg0
lvcreate -L 5G -n shared vg0  # Volume partagé avec son fils
lvcreate -L 3G -n virtualbox vg0  # Volume pour VirtualBox

# Formatage et montage
mkfs.ext4 /dev/vg0/root
mkfs.ext4 /dev/vg0/home
mkfs.ext4 /dev/vg0/shared
mkfs.ext4 /dev/vg0/virtualbox
mkswap /dev/vg0/swap
swapon /dev/vg0/swap

mount /dev/vg0/root /mnt
mkdir -p /mnt/{boot,home,shared,virtualbox}
mount /dev/vg0/home /mnt/home
mount /dev/vg0/shared /mnt/shared
mount /dev/vg0/virtualbox /mnt/virtualbox
mount "${DISK}1" /mnt/boot

### Installation du système de base
pacstrap /mnt base linux linux-firmware vim sudo networkmanager grub efibootmgr lvm2

### Configuration du système
genfstab -U /mnt >> /mnt/etc/fstab

arch-chroot /mnt /bin/bash <<EOF
# Configuration locale et fuseau horaire
ln -sf /usr/share/zoneinfo/Europe/Paris /etc/localtime
hwclock --systohc
echo "$HOSTNAME" > /etc/hostname
sed -i 's/#fr_FR.UTF-8 UTF-8/fr_FR.UTF-8 UTF-8/' /etc/locale.gen
locale-gen
echo "LANG=fr_FR.UTF-8" > /etc/locale.conf

# Configuration des utilisateurs
useradd -m -G wheel -s /bin/bash $USERNAME
useradd -m -G users -s /bin/bash $SON_USERNAME
echo "$USERNAME:$PASSWORD" | chpasswd
echo "$SON_USERNAME:$PASSWORD" | chpasswd

# Configuration sudo
echo "$USERNAME ALL=(ALL) ALL" >> /etc/sudoers

# Installation des logiciels demandés
pacman -S --noconfirm hyprland kitty firefox htop neofetch git open-vm-tools xdg-user-dirs

# Configuration de Hyprland
mkdir -p /home/$USERNAME/.config/hypr
cat <<EOL > /home/$USERNAME/.config/hypr/hyprland.conf
exec-once = waybar &
input {
    kb_layout = fr
}
EOL
chown -R $USERNAME:$USERNAME /home/$USERNAME/.config

# Configuration de VirtualBox
pacman -S --noconfirm virtualbox virtualbox-host-modules-arch
gpasswd -a $USERNAME vboxusers

# Installation et configuration du chargeur de démarrage GRUB
grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB
grub-mkconfig -o /boot/grub/grub.cfg

# Activer les services
systemctl enable NetworkManager.service
systemctl enable vmtoolsd.service

exit
EOF

echo "Installation terminée. Vous pouvez redémarrer la machine."
