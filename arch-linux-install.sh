#!/bin/bash
set -e

###############################################
# Vérifications et installation des dépendances
###############################################
if [[ $EUID -ne 0 ]]; then
    echo "Ce script doit être exécuté en tant que root."
    exit 1
fi

if ! grep -qi 'arch' /etc/os-release; then
    printf "Erreur : Ce script est conçu pour être lancé sur Arch Linux.\n"
    exit 1
fi

###############################################
# Vérification des dépendances
###############################################
check_dependencies() {
    apt update
    local dependencies=("arch-install-scripts" "parted" "cryptsetup" "lvm2" "grub-efi-amd64" "btop")
    for pkg in "${dependencies[@]}"; do
        if ! dpkg -l | grep -q "$pkg"; then
            echo "$pkg n'est pas installé. Installation en cours..."
            apt install -y "$pkg" || { printf "Erreur : Échec de l'installation de %s.\n" "$pkg"; exit 1; }
        fi
    done
}

###############################################
# Variables de configuration
###############################################
echo "Veuillez sélectionner le disque cible (ex: /dev/sda, /dev/sdb, etc.) : "
read DISK

# Validation de l'entrée utilisateur pour le disque
if [[ -z "$DISK" ]]; then
    printf "Erreur : Aucune entrée pour le disque. Veuillez entrer un disque valide.\n"
    exit 1
fi

# Vérification que le disque existe
if [[ ! -b "${DISK}" ]]; then
    printf "Erreur : Le disque %s n'existe pas. Veuillez vérifier votre sélection.\n" "${DISK}"
    cleanup
    exit 1
fi

# Vérification des dépendances avant l'installation
check_dependencies

MACHINE_HOSTNAME="defl3ct-archlinux"    # Nom d'hôte

LOG_NAME="arch-install.log"     # Nom du fichier de log
LOG_PATH="/var/log/${LOG_NAME}"  # Chemin du fichier de log

REPORT_NAME="rapport_installation.txt"  # Nom du rapport d'installation
REPORT_PATH="/root/${REPORT_NAME}"      # Chemin du rapport d'installation

# Mots de passe
LUKS_PASS="azerty123"           # Pour le chiffrement LUKS
ROOT_PASS="azerty123"           # Pour le compte root
PERE_PASS="azerty123"           # Pour l'utilisateur pere
FILS_PASS="azerty123"           # Pour l'utilisateur fils
GRUB_ADMIN_PASS="azerty123"     # Pour la protection de GRUB

# Noms d'utilisateurs
PERE_USER="pere"                # Pour l'utilisateur pere
FILS_USER="fils"                # Pour l'utilisateur fils
GRUB_ADMIN="grub-admin"         # Nom d'utilisateur GRUB

VG_NAME="vg_root"               # Nom du volume group LVM
SCRIPT_AUTHOR="Defl3ct"         # Auteur du script

# Calcul du hash PBKDF2 pour GRUB
GRUB_HASH=$(printf "${GRUB_ADMIN_PASS}\n${GRUB_ADMIN_PASS}\n" | grub-mkpasswd-pbkdf2 | grep "PBKDF2 hash" | awk '{print $NF}')

###############################################
# Fonction de nettoyage
###############################################
cleanup() {
    echo "Nettoyage en cours..."
    # mettre les etapes de nettoyage ici
    echo "Nettoyage terminé."
}

post-installation-cleanup() {
    echo "Nettoyage post-installation en cours..."
    # mettre les etapes de nettoyage ici
    echo "Nettoyage post-installation terminé."
}

# Appel de la fonction de nettoyage en cas d'échec
trap 'cleanup; exit 1' ERR

trap 'post-installation-cleanup' EXIT

###############################################
# Vérification de l'espace disque disponible
###############################################
if [[ $(lsblk -b -o SIZE -n "${DISK}") -lt 80000000000 ]]; then
    printf "Erreur : Espace disque insuffisant sur %s. Au moins 80 Go requis.\n" "${DISK}"
    cleanup
    exit 1
fi

###############################################
# Vérification que le disque n'est pas monté
###############################################
if mount | grep "${DISK}"; then
    printf "Avertissement : Le disque %s est monté. Tentative de démontage...\n" "${DISK}"
    if ! umount "${DISK}"; then
        printf "Erreur : Échec du démontage de %s. Veuillez le démonter manuellement.\n" "${DISK}"
        cleanup
        exit 1
    fi
fi

###############################################
# Ajout d'une journalisation avec date et heure
###############################################
exec > >(tee -i ${LOG_PATH}) 2>&1
printf "=== Début de l'installation à %s ===\n" "$(date +%Y-%m-%d_%H:%M:%S)"

###############################################
# Confirmation de l'effacement des données
###############################################
printf "ATTENTION : Ce script effacera TOUTES les données sur %s.\n" "${DISK}"
read -p "Confirmez-vous l'installation sur ${DISK} ? (y/o pour oui, autre pour annuler) : " answer
if [[ "$answer" != "y" && "$answer" != "o" ]]; then
    printf "Installation annulée.\n"
    cleanup
    exit 1
fi

###############################################
# Effacement du disque
###############################################
printf "=== Effacement du disque %s ===\n" "${DISK}"
if lsblk | grep -q "${DISK}"; then
    printf "Des partitions existent déjà sur %s.\n" "${DISK}"
    read -p "Souhaitez-vous les supprimer ? (y/o pour oui, autre pour annuler) : " answer
    if [[ "$answer" != "y" && "$answer" != "o" ]]; then
        printf "Installation annulée.\n"
        cleanup
        exit 1
    fi
fi
if ! dd if=/dev/zero of="${DISK}" bs=1M count=100 oflag=direct; then
    printf "Erreur : Échec de l'effacement du disque %s.\n" "${DISK}"
    cleanup
    exit 1
fi

###############################################
# 1. Partitionnement du disque et configuration LUKS + LVM
###############################################
echo "=== Création d'une table de partition GPT sur ${DISK} ==="
parted -s "${DISK}" mklabel gpt

echo "=== Création de la partition EFI (1MiB à 513MiB) ==="
parted -s "${DISK}" mkpart ESP fat32 1MiB 513MiB
parted -s "${DISK}" set 1 boot on

echo "=== Création de la partition principale pour LUKS/LVM (513MiB à 100%) ==="
parted -s "${DISK}" mkpart primary ext4 513MiB 100%

echo "=== Formatage de la partition EFI (${DISK}1) en FAT32 ==="
mkfs.fat -F32 "${DISK}1"

echo "=== Configuration de LUKS sur la partition principale (${DISK}2) ==="
echo -n "${LUKS_PASS}" | cryptsetup luksFormat "${DISK}2" --key-file=-
echo -n "${LUKS_PASS}" | cryptsetup open "${DISK}2" cryptlvm --key-file=-

echo "=== Création du volume physique LVM sur /dev/mapper/cryptlvm ==="
pvcreate /dev/mapper/cryptlvm

echo "=== Création du groupe de volumes '${VG_NAME}' ==="
vgcreate "${VG_NAME}" /dev/mapper/cryptlvm

echo "=== Création des volumes logiques dans le VG '${VG_NAME}' ==="
# Volume destiné à être chiffré séparément (10G)
lvcreate -L 10G -n lv_manual "${VG_NAME}"
# Volume pour VirtualBox (20G)
lvcreate -L 20G -n lv_virtualbox "${VG_NAME}"
# Volume pour le dossier partagé (5G)
lvcreate -L 5G -n lv_shared "${VG_NAME}"
# Volume pour le swap (8G)
lvcreate -L 8G -n lv_swap "${VG_NAME}"
# Volume pour le répertoire home de pere (10G)
lvcreate -L 10G -n lv_home_pere "${VG_NAME}"
# Volume pour le répertoire home de fils (10G)
lvcreate -L 10G -n lv_home_fils "${VG_NAME}"
# Le reste pour la racine (ici 17G)
lvcreate -l 100%FREE -n lv_root "${VG_NAME}"

echo "=== Chiffrement du volume logique 'lv_manual' (10G) ==="
echo -n "${LUKS_PASS}" | cryptsetup luksFormat /dev/"${VG_NAME}"/lv_manual --key-file=-
echo -n "${LUKS_PASS}" | cryptsetup open /dev/"${VG_NAME}"/lv_manual secret_manual --key-file=-

###############################################
# 2. Formatage et montage des partitions / volumes
###############################################
echo "=== Formatage du volume racine (lv_root) en ext4 ==="
mkfs.ext4 /dev/"${VG_NAME}"/lv_root

echo "=== Formatage du volume VirtualBox (lv_virtualbox) en ext4 ==="
mkfs.ext4 /dev/"${VG_NAME}"/lv_virtualbox

echo "=== Formatage du volume partagé (lv_shared) en ext4 ==="
mkfs.ext4 /dev/"${VG_NAME}"/lv_shared

echo "=== Formatage du volume home pour pere (lv_home_pere) en ext4 ==="
mkfs.ext4 /dev/"${VG_NAME}"/lv_home_pere

echo "=== Formatage du volume home pour fils (lv_home_fils) en ext4 ==="
mkfs.ext4 /dev/"${VG_NAME}"/lv_home_fils

echo "=== Formatage du volume manuel chiffré (/dev/mapper/secret_manual) en ext4 ==="
mkfs.ext4 /dev/mapper/secret_manual

echo "=== Formatage du volume swap (lv_swap) ==="
mkswap /dev/"${VG_NAME}"/lv_swap

echo "=== Montage du volume racine sur /mnt ==="
mount /dev/"${VG_NAME}"/lv_root /mnt

echo "=== Création des points de montage supplémentaires ==="
mkdir -p /mnt/boot /mnt/vbox /mnt/shared /mnt/home/pere /mnt/home/fils

echo "=== Montage de la partition EFI sur /mnt/boot ==="
mount "${DISK}1" /mnt/boot

echo "=== Montage du volume VirtualBox sur /mnt/vbox ==="
mount /dev/"${VG_NAME}"/lv_virtualbox /mnt/vbox

echo "=== Montage du volume partagé sur /mnt/shared ==="
mount /dev/"${VG_NAME}"/lv_shared /mnt/shared

echo "=== Montage des volumes home sur /mnt/home ==="
mount /dev/"${VG_NAME}"/lv_home_pere /mnt/home/pere
mount /dev/"${VG_NAME}"/lv_home_fils /mnt/home/fils

# Le volume 'lv_manual' reste non monté (il sera monté manuellement par l'utilisateur si besoin)
# Le volume 'lv_swap' n'est pas monté mais sera activé via fstab.

###############################################
# 3. Installation du système de base et des paquets
###############################################
echo "=== Installation du système de base avec pacstrap ==="
pacstrap /mnt base linux linux-firmware vim nano networkmanager grub efibootmgr lvm2 cryptsetup base-devel hyprland wofi firefox virtualbox base-devel git btop i3 tmux glances iotop neofetch unzip gunzip gcc make cmake python python-pip python-setuptools python-wheel python-virtualenv python-pyqt5 python-pyqt5-sip python-pyqt5-common python-pyqt5-tools python-pyqt5-doc

echo "=== Génération du fichier fstab ==="
genfstab -U /mnt >> /mnt/etc/fstab

# Ajout manuel d'entrées pour swap et pour les partitions home
cat <<EOF >> /mnt/etc/fstab
/dev/mapper/${VG_NAME}-lv_swap    none    swap    defaults    0 0
/dev/mapper/${VG_NAME}-lv_home_pere    /home/pere    ext4    defaults    0 2
/dev/mapper/${VG_NAME}-lv_home_fils    /home/fils    ext4    defaults    0 2
EOF

###############################################
# 4. Configuration dans le chroot
###############################################
# Nous utilisons un heredoc non cité pour permettre l'expansion des variables définies ci-dessus.
arch-chroot /mnt /bin/bash <<EOF
set -e

#############################
# Configuration système de base (en français, timezone Paris)
#############################
ln -sf /usr/share/zoneinfo/Europe/Paris /etc/localtime
hwclock --systohc

# Localisation en français
sed -i 's/#fr_FR.UTF-8 UTF-8/fr_FR.UTF-8 UTF-8/' /etc/locale.gen
locale-gen
echo "LANG=fr_FR.UTF-8" > /etc/locale.conf

# Nom d'hôte et résolution
echo ${MACHINE_HOSTNAME} > /etc/hostname
cat <<EOL > /etc/hosts
127.0.0.1   localhost
::1         localhost
127.0.1.1   ${MACHINE_HOSTNAME}.localdomain ${MACHINE_HOSTNAME}
EOL

#############################
# Génération de l'initramfs
#############################
# Ajout des hooks pour le chiffrement et LVM.
sed -i 's/HOOKS=(base udev autodetect modconf block filesystems)/HOOKS=(base udev autodetect modconf block encrypt lvm2 filesystems)/' /etc/mkinitcpio.conf
mkinitcpio -P

#############################
# Installation et configuration de GRUB (avec protection par mot de passe)
#############################
# Récupération de l'UUID de la partition chiffrée principale (sur ${DISK}2)
CRYPT_UUID=\$(blkid -s UUID -o value ${DISK}2)

cat <<EOL > /etc/default/grub
GRUB_DEFAULT=0
GRUB_TIMEOUT=3
GRUB_DISTRIBUTOR="${SCRIPT_AUTHOR} - Arch Linux"
GRUB_CMDLINE_LINUX="cryptdevice=UUID=\${CRYPT_UUID}:cryptlvm root=/dev/${VG_NAME}/lv_root rw"
EOL

# Installation de GRUB en mode EFI
grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB

# Configuration de la protection par mot de passe dans GRUB
cat <<EOL > /etc/grub.d/40_custom
set superusers="${GRUB_ADMIN}"
password_pbkdf2 ${GRUB_ADMIN} ${GRUB_HASH}
EOL

# Génération de la configuration de GRUB
grub-mkconfig -o /boot/grub/grub.cfg

#############################
# Activation des services
#############################
systemctl enable NetworkManager

#############################
# Configuration des comptes et du système
#############################
# Définition du mot de passe root
echo "root:${ROOT_PASS}" | chpasswd

# Création de l'utilisateur "pere"
useradd -m -G wheel,video,virtualbox -s /bin/bash ${PERE_USER}
echo "${PERE_USER}:${PERE_PASS}" | chpasswd

# Création de l'utilisateur "fils"
useradd -m -G wheel,video -s /bin/bash ${FILS_USER}
echo "${FILS_USER}:${FILS_PASS}" | chpasswd

# Autoriser les membres du groupe wheel à utiliser sudo
sed -i 's/^# %wheel ALL=(ALL) ALL/%wheel ALL=(ALL) ALL/' /etc/sudoers

# Activation du swap
swapon /dev/${VG_NAME}/lv_swap

#############################
# Ajustement des droits des répertoires home
#############################
# Les volumes pour /home/pere et /home/fils sont montés via fstab ; il faut s'assurer que
# leurs droits soient correctement définis.
chown ${PERE_USER}:${PERE_USER} /home/pere
chown ${FILS_USER}:${FILS_USER} /home/fils

#############################
# Configuration du dossier partagé
#############################
groupadd shared
usermod -aG shared ${PERE_USER}
usermod -aG shared ${FILS_USER}

# Le volume logique monté sur /mnt/shared sera utilisé comme dossier partagé.
# (Si besoin, créer un point de montage /shared ou adapter en conséquence)
mkdir -p /shared
mount --bind /mnt/shared /shared
chown root:shared /shared
chmod 2775 /shared

#############################
# Configuration minimale de Hyprland pour l'utilisateur "pere"
#############################
mkdir -p /home/${PERE_USER}/.config/hypr
cat <<EOL > /home/${PERE_USER}/.config/hypr/hyprland.conf
# Exemple de configuration pour Hyprland
monitor=DP-1,1920x1080,1,1
background=\$HOME/.config/hypr/wallpaper.jpg
EOL
chown -R ${PERE_USER}:${PERE_USER} /home/${PERE_USER}/.config/hypr

#############################
# Création d'un rapport d'installation
#############################
echo "Création du rapport d'installation dans ${REPORT_PATH}..."
{
  echo "=== lsblk -f ==="
  lsblk -f
  echo ""
  echo "=== /etc/passwd ==="
  cat /etc/passwd
  echo ""
  echo "=== /etc/group ==="
  cat /etc/group
  echo ""
  echo "=== /etc/fstab ==="
  cat /etc/fstab
  echo ""
  echo "=== /etc/mtab ==="
  cat /etc/mtab
  echo ""
  echo "=== HOSTNAME ==="
  echo \$HOSTNAME
  echo ""
  echo "=== Pacman Log (installed packages) ==="
  grep -i installed /var/log/pacman.log
} > ${REPORT_PATH}

EOF

# Appel de la fonction de nettoyage à la fin du script
post-installation-cleanup

echo "=== Installation terminée ! ==="
echo "Vous pouvez redémarrer sur votre nouvelle installation Arch Linux."
echo "Un rapport d'installation est disponible dans ${REPORT_PATH}. Les logs sont disponibles dans ${LOG_PATH}."

# Sortie du script avec succès
exit 0