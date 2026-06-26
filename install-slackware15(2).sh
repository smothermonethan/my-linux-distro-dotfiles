#!/bin/bash
# =============================================================================
# shastenm — Slackware 15 full auto installer
#
# PHASE 1 — Drive detection, partitioning (GPT/UEFI), format, mount
# PHASE 2 — Slackware base install via setup/installpkg
# PHASE 3 — dotfiles, starship, spectrwm full desktop (post-chroot)
#
# Layout:  ESP (512M, FAT32) + / (remaining, ext4)   — no swap
# Boot:    UEFI + GRUB
#
# Run from the Slackware 15 live/installer environment as root.
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Colours
# ---------------------------------------------------------------------------
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
_info()    { echo -e "${GREEN}[INFO]${NC}  $*"; }
_warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
_err()     { echo -e "${RED}[ERR]${NC}   $*" >&2; }
_section() { echo -e "\n${YELLOW}================================================================\n==> $*\n================================================================${NC}"; }
_die()     { _err "$*"; exit 1; }

# ---------------------------------------------------------------------------
# Must run as root
# ---------------------------------------------------------------------------
[ "$(id -u)" -eq 0 ] || _die "Run this script as root"

# ===========================================================================
# PHASE 1 — DRIVE AUTO-DETECTION, PARTITION, FORMAT, MOUNT
# ===========================================================================
_section "PHASE 1 — Drive detection"

# --------------------------------------------------------------------------
# Detect all physical block devices (exclude loops, rom, ram, dm)
# --------------------------------------------------------------------------
mapfile -t DRIVES < <(lsblk -dpno NAME,TYPE | awk '$2=="disk"{print $1}' | sort)

[ "${#DRIVES[@]}" -gt 0 ] || _die "No physical drives detected"

_info "Detected drives:"
for d in "${DRIVES[@]}"; do
    SIZE=$(lsblk -dno SIZE "$d")
    MODEL=$(lsblk -dno MODEL "$d" 2>/dev/null | xargs)
    _info "  $d  $SIZE  $MODEL"
done

# --------------------------------------------------------------------------
# Select target — prefer NVMe, then first drive found
# --------------------------------------------------------------------------
TARGET=""
for d in "${DRIVES[@]}"; do
    if [[ "$d" == *nvme* ]]; then TARGET="$d"; break; fi
done
[ -z "$TARGET" ] && TARGET="${DRIVES[0]}"

_info "Target drive: $TARGET"

# --------------------------------------------------------------------------
# Derive partition names (nvme0n1 -> nvme0n1p1/p2, sda -> sda1/sda2)
# --------------------------------------------------------------------------
if [[ "$TARGET" == *nvme* || "$TARGET" == *mmcblk* ]]; then
    PART_ESP="${TARGET}p1"
    PART_ROOT="${TARGET}p2"
else
    PART_ESP="${TARGET}1"
    PART_ROOT="${TARGET}2"
fi

_info "Partitions: ESP=$PART_ESP  ROOT=$PART_ROOT"

# Safety pause — last chance before destructive ops
echo ""
_warn "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
_warn "  ALL DATA ON $TARGET WILL BE DESTROYED IN 10 SECONDS"
_warn "  Press Ctrl-C NOW to abort"
_warn "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
sleep 10

# --------------------------------------------------------------------------
# Wipe + GPT partition table
# --------------------------------------------------------------------------
_section "Partitioning $TARGET (GPT/UEFI — no swap)"

wipefs -a "$TARGET"
sgdisk --zap-all "$TARGET"

# ESP: 512 MiB, type EF00
sgdisk -n 1:0:+512M -t 1:EF00 -c 1:"EFI System Partition" "$TARGET"
# Root: rest of disk, type 8300
sgdisk -n 2:0:0    -t 2:8300 -c 2:"Linux root"            "$TARGET"

partprobe "$TARGET"
sleep 2

_info "Partition table:"
sgdisk -p "$TARGET"

# --------------------------------------------------------------------------
# Format
# --------------------------------------------------------------------------
_section "Formatting partitions"

_info "Formatting ESP ($PART_ESP) as FAT32..."
mkfs.fat -F32 -n EFI "$PART_ESP"

_info "Formatting root ($PART_ROOT) as ext4..."
mkfs.ext4 -L slackware "$PART_ROOT"

# --------------------------------------------------------------------------
# Mount
# --------------------------------------------------------------------------
_section "Mounting"

MNTROOT="/mnt/slackware"
mkdir -p "$MNTROOT"
mount "$PART_ROOT" "$MNTROOT"
mkdir -p "$MNTROOT/boot/efi"
mount "$PART_ESP" "$MNTROOT/boot/efi"

_info "Mounts:"
findmnt "$MNTROOT"
findmnt "$MNTROOT/boot/efi"

# ===========================================================================
# PHASE 2 — SLACKWARE BASE INSTALL
# ===========================================================================
_section "PHASE 2 — Slackware base install"

# --------------------------------------------------------------------------
# Locate the Slackware package tree
# Supports: DVD mount, USB mount, or a pre-mounted path at /slackware
# --------------------------------------------------------------------------
SLACK_SRC=""

# Try common mount points for Slackware media
for candidate in /slackware /mnt/cdrom /mnt/dvd /mnt/usb /run/media/*/*; do
    if [ -d "${candidate}/slackware64" ] || [ -d "${candidate}/slackware" ]; then
        SLACK_SRC="$candidate"
        break
    fi
done

if [ -z "$SLACK_SRC" ]; then
    # Try auto-mounting optical/usb
    for dev in /dev/sr0 /dev/sr1 /dev/sdb /dev/sdc; do
        if [ -b "$dev" ]; then
            _info "Trying to mount $dev..."
            mkdir -p /mnt/media
            mount -o ro "$dev" /mnt/media 2>/dev/null && {
                if [ -d "/mnt/media/slackware64" ] || [ -d "/mnt/media/slackware" ]; then
                    SLACK_SRC="/mnt/media"
                    break
                fi
                umount /mnt/media 2>/dev/null || true
            }
        fi
    done
fi

[ -n "$SLACK_SRC" ] || _die "Cannot find Slackware package tree. Mount your install media and re-run."

# Determine package subdir (slackware64 on 64-bit installs)
if   [ -d "$SLACK_SRC/slackware64" ]; then PKG_DIR="$SLACK_SRC/slackware64"
elif [ -d "$SLACK_SRC/slackware"   ]; then PKG_DIR="$SLACK_SRC/slackware"
else _die "No slackware/slackware64 directory found under $SLACK_SRC"
fi

_info "Package source: $PKG_DIR"

# --------------------------------------------------------------------------
# Install package series into chroot
# A  — base system (required)
# AP — admin/text tools
# D  — development (compilers, make — needed to build SBo packages later)
# L  — libraries
# N  — networking (curl, wget, openssh)
# X  — X11 (needed for spectrwm/dzen2/kitty)
# XAP— X applications
# XFCE— XFCE (provides xfsettingsd)
# --------------------------------------------------------------------------
SERIES=(a ap d l n x xap xfce)

for series in "${SERIES[@]}"; do
    SDIR="$PKG_DIR/$series"
    if [ -d "$SDIR" ]; then
        _info "Installing series: $series"
        for pkg in "$SDIR"/*.t?z; do
            [ -f "$pkg" ] || continue
            installpkg --root "$MNTROOT" "$pkg" || _warn "Failed: $pkg"
        done
    else
        _warn "Series $series not found at $SDIR — skipping"
    fi
done

# --------------------------------------------------------------------------
# /etc/fstab
# --------------------------------------------------------------------------
_section "Writing /etc/fstab"

ROOT_UUID=$(blkid -s UUID -o value "$PART_ROOT")
ESP_UUID=$(blkid  -s UUID -o value "$PART_ESP")

cat > "$MNTROOT/etc/fstab" <<EOF
# /etc/fstab — generated by shastenm installer
UUID=$ROOT_UUID  /          ext4  defaults,noatime  1 1
UUID=$ESP_UUID   /boot/efi  vfat  umask=0077        0 2
tmpfs            /tmp       tmpfs defaults,nosuid,nodev  0 0
EOF

_info "/etc/fstab written (root UUID=$ROOT_UUID)"

# --------------------------------------------------------------------------
# GRUB (UEFI)
# --------------------------------------------------------------------------
_section "Installing GRUB (UEFI)"

# Bind mounts for chroot
for d in proc sys dev dev/pts; do
    mount --bind "/$d" "$MNTROOT/$d"
done

chroot "$MNTROOT" /bin/bash <<CHROOT_GRUB
grub-install --target=x86_64-efi \
             --efi-directory=/boot/efi \
             --bootloader-id=Slackware \
             --recheck
grub-mkconfig -o /boot/grub/grub.cfg
CHROOT_GRUB

_info "GRUB installed"

# --------------------------------------------------------------------------
# Root password placeholder (user should change on first boot)
# --------------------------------------------------------------------------
echo "root:slackware" | chroot "$MNTROOT" chpasswd
_warn "Root password set to 'slackware' — change it on first boot with: passwd"

# --------------------------------------------------------------------------
# Hostname
# --------------------------------------------------------------------------
echo "slackware" > "$MNTROOT/etc/hostname"
cat > "$MNTROOT/etc/hosts" <<EOF
127.0.0.1   localhost
127.0.1.1   slackware.localdomain slackware
::1         localhost ip6-localhost ip6-loopback
EOF

# --------------------------------------------------------------------------
# Network (DHCP on first ethernet via rc.inet1.conf)
# --------------------------------------------------------------------------
ETH=$(ip -o link show | awk -F': ' '$2!~/lo|docker|veth/{print $2; exit}')
if [ -n "$ETH" ] && [ -f "$MNTROOT/etc/rc.d/rc.inet1.conf" ]; then
    IFACE_VAR="${ETH//[^A-Za-z0-9]/_}"
    sed -i "s/^IPADDR\[0\]=\"\"/IPADDR[0]=\"\"/"       "$MNTROOT/etc/rc.d/rc.inet1.conf"
    sed -i "s/^USE_DHCP\[0\]=\"\"/USE_DHCP[0]=\"yes\"/" "$MNTROOT/etc/rc.d/rc.inet1.conf"
    _info "DHCP enabled for first interface"
fi

# --------------------------------------------------------------------------
# Timezone
# --------------------------------------------------------------------------
chroot "$MNTROOT" ln -sf /usr/share/zoneinfo/America/Indiana/Indianapolis \
    /etc/localtime 2>/dev/null || true
_info "Timezone set to America/Indiana/Indianapolis"

# ===========================================================================
# PHASE 3 — DOTFILES INSTALLER (injected into chroot, runs as root user)
#            Will need to re-run as the actual user post-boot for $HOME paths.
#            Here we place the script and a firstboot service to auto-run it.
# ===========================================================================
_section "PHASE 3 — Injecting dotfiles installer into chroot"

# --------------------------------------------------------------------------
# Copy this script into the new system for first-boot use
# --------------------------------------------------------------------------
SCRIPT_DEST="$MNTROOT/root/install-dotfiles.sh"

cat > "$SCRIPT_DEST" << 'DOTFILES_INSTALLER'
#!/bin/bash
# =============================================================================
# shastenm dotfiles — full desktop setup
# Run as the target user after first boot, or as root for /root home.
# =============================================================================

set -euo pipefail

DOTFILES_REPO="https://gitlab.com/shastenm/dotfiles-bsd.git"
INSTALL_REPO="https://gitlab.com/shastenm/dotfile-installation.git"
SPECTRWM_REPO="https://gitlab.com/shastenm/spectrwm-bsd.git"
WALLPAPER_REPO="https://gitlab.com/shastenm/wallpaper.git"

DOTFILES_DIR="$HOME/dotfiles-bsd"
BUILD_DIR="$HOME/Desktop/build"
SPECTRWM_DIR="$HOME/spectrwm-bsd"
LOCAL_BIN="$HOME/.local/bin"
FONT_DIR="/usr/share/fonts/TTF"
SPECTRWM_CONF="$HOME/.config/spectrwm"
STARSHIP_URL="https://starship.rs/install.sh"
SBOPKG_PKG="sbopkg-0.38.2-noarch-1_wsr.tgz"
SBOPKG_URL="https://sbopkg.org/sbopkg/${SBOPKG_PKG}"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
_info()    { echo -e "${GREEN}[INFO]${NC}  $*"; }
_warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
_err()     { echo -e "${RED}[ERR]${NC}   $*" >&2; }
_section() { echo -e "\n${YELLOW}================================================================\n==> $*\n================================================================${NC}"; }

_clone_or_pull() {
    local repo="$1" dir="$2"
    if [ -d "$dir/.git" ]; then
        _info "$(basename "$dir") exists — pulling..."
        git -C "$dir" pull --ff-only || { _warn "ff-only failed, fetching only"; git -C "$dir" fetch; }
    else
        _info "Cloning $repo -> $dir"
        git clone "$repo" "$dir"
    fi
}

# ---------------------------------------------------------------------------
# Step 1 — System update
# ---------------------------------------------------------------------------
_section "Step 1 — System update"
slackpkg update gpg  || _warn "GPG update skipped"
slackpkg update
slackpkg upgrade-all

# ---------------------------------------------------------------------------
# Step 2 — slackpkg packages
# ---------------------------------------------------------------------------
_section "Step 2 — slackpkg packages"
for pkg in git curl wget fontconfig neovim jq; do
    command -v "$pkg" >/dev/null 2>&1 \
        && _info "$pkg present" \
        || slackpkg install "$pkg" || _warn "$pkg not in slackpkg — try sbopkg"
done

# ---------------------------------------------------------------------------
# Step 3 — sbopkg
# ---------------------------------------------------------------------------
_section "Step 3 — sbopkg"
if ! command -v sbopkg >/dev/null 2>&1; then
    mkdir -p "$BUILD_DIR" && cd "$BUILD_DIR"
    wget -c "$SBOPKG_URL"
    installpkg "$SBOPKG_PKG"
fi
sbopkg -r

# ---------------------------------------------------------------------------
# Step 4 — SBo packages
# ---------------------------------------------------------------------------
_section "Step 4 — SBo packages"
SBO_PKGS=(
    spectrwm nitrogen picom sxhkd conky dzen2 dmenu
    lxappearance pcmanfm kitty ripgrep fzf bat eza
    starship stow xlockmore xclip clipmenu
)
for pkg in "${SBO_PKGS[@]}"; do
    if ! command -v "$pkg" >/dev/null 2>&1 && \
       ! ls /var/log/packages/"$pkg"-* >/dev/null 2>&1; then
        sbopkg -i "$pkg" || _warn "$pkg build failed — install manually"
    else
        _info "$pkg already installed"
    fi
done

# ---------------------------------------------------------------------------
# Step 5 — dzen2 source fallback
# ---------------------------------------------------------------------------
_section "Step 5 — dzen2 source fallback"
if ! command -v dzen2 >/dev/null 2>&1; then
    slackpkg install libX11 libXft libXinerama libXpm || true
    mkdir -p "$BUILD_DIR" && cd "$BUILD_DIR"
    [ -d dzen ] || git clone https://github.com/robm/dzen.git
    cd dzen && make
    cp dzen2 /usr/local/bin/dzen2
    chmod +x /usr/local/bin/dzen2
    _info "dzen2 built from source"
else
    _info "dzen2 present"
fi

# ---------------------------------------------------------------------------
# Step 6 — Starship
# ---------------------------------------------------------------------------
_section "Step 6 — Starship"
mkdir -p "$LOCAL_BIN"
curl -sS "$STARSHIP_URL" | sh -s -- --yes --bin-dir "$LOCAL_BIN"
"$LOCAL_BIN/starship" --version >/dev/null 2>&1 \
    && _info "Starship $("$LOCAL_BIN/starship" --version) ready" \
    || { _err "Starship install failed"; exit 1; }

# ---------------------------------------------------------------------------
# Step 7 — Fonts
# ---------------------------------------------------------------------------
_section "Step 7 — Fonts"
mkdir -p "$BUILD_DIR"
_clone_or_pull "$INSTALL_REPO" "$BUILD_DIR/dotfile-installation"
mkdir -p "$FONT_DIR"
cp "$BUILD_DIR/dotfile-installation/fonts/"*.ttf "$FONT_DIR/" 2>/dev/null \
    || _warn "No .ttf found in dotfile-installation/fonts/"
fc-cache -fv
for face in "mononoki" "noto.*cjk" "joy"; do
    fc-list | grep -qi "$face" && _info "  ✓ $face" || _warn "  ✗ $face missing"
done

# ---------------------------------------------------------------------------
# Step 8 — Wallpapers
# ---------------------------------------------------------------------------
_section "Step 8 — Wallpapers"
mkdir -p "$HOME/Pictures"
_clone_or_pull "$WALLPAPER_REPO" "$HOME/Pictures/wallpaper"

# ---------------------------------------------------------------------------
# Step 9 — dotfiles-bsd + stow
# ---------------------------------------------------------------------------
_section "Step 9 — dotfiles-bsd + GNU Stow"
_clone_or_pull "$DOTFILES_REPO" "$DOTFILES_DIR"
cd "$DOTFILES_DIR"

_bak() {
    local t="$HOME/$1"
    [ -e "$t" ] && [ ! -L "$t" ] && { _warn "Backing up $t -> ${t}.bak"; mv "$t" "${t}.bak"; }
}
_bak ".bashrc"
_bak ".bash_profile"

stow --adopt --target="$HOME" --dir="$DOTFILES_DIR" . 2>&1 | grep -v '^$' || true
git -C "$DOTFILES_DIR" checkout .
stow --restow --target="$HOME" --dir="$DOTFILES_DIR" .
_info "Stow complete"

# ---------------------------------------------------------------------------
# Step 10 — Starship config + .bashrc guards
# ---------------------------------------------------------------------------
_section "Step 10 — Starship config"
STARSHIP_DST="$HOME/.config/starship.toml"
STARSHIP_SRC="$DOTFILES_DIR/.config/starship.toml"
if   [ -L "$STARSHIP_DST" ]; then _info "starship.toml symlinked ✓"
elif [ -f "$STARSHIP_SRC" ]; then
    mkdir -p "$HOME/.config"
    ln -sf "$STARSHIP_SRC" "$STARSHIP_DST"
    _info "starship.toml linked manually"
else _warn "No starship.toml found — starship uses defaults"
fi

BASHRC="$HOME/.bashrc"
grep -q 'starship init bash' "$BASHRC" 2>/dev/null || cat >> "$BASHRC" <<'EOF'

# Starship prompt
if command -v starship >/dev/null 2>&1; then
    eval "$(starship init bash)"
fi
EOF

grep -q 'HOME/.local/bin' "$BASHRC" 2>/dev/null \
    || echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$BASHRC"

# ---------------------------------------------------------------------------
# Step 11 — spectrwm-bsd config
# ---------------------------------------------------------------------------
_section "Step 11 — spectrwm-bsd"
_clone_or_pull "$SPECTRWM_REPO" "$SPECTRWM_DIR"
mkdir -p "$SPECTRWM_CONF"
cp -r "$SPECTRWM_DIR/"* "$SPECTRWM_CONF/"

SCRIPTS=(
    autostart.sh baraction.sh dzen2/bar
    scripts/toggle-panel scripts/toggle-spectrwm-keys scripts/toggle-sxhkd-keys
    dzen2/scripts/docs dzen2/scripts/dots
)
for s in "${SCRIPTS[@]}"; do
    [ -f "$SPECTRWM_CONF/$s" ] && chmod +x "$SPECTRWM_CONF/$s" \
        || _warn "Script not found: $SPECTRWM_CONF/$s"
done

# ---------------------------------------------------------------------------
# Step 12 — spectrwm.conf
# ---------------------------------------------------------------------------
_section "Step 12 — spectrwm.conf"
SWCONF="$SPECTRWM_CONF/spectrwm.conf"
if [ -f "$SWCONF" ]; then
    sed -i 's|^\(bar_action\s*=.*\)|# \1|'           "$SWCONF"
    if grep -q '^bar_enabled' "$SWCONF"; then
        sed -i 's|^bar_enabled\s*=.*|bar_enabled = 0|' "$SWCONF"
    else
        echo "bar_enabled = 0" >> "$SWCONF"
    fi
    _info "spectrwm.conf patched"
else
    _warn "spectrwm.conf not found — skipping"
fi

# ---------------------------------------------------------------------------
# Step 13 — autostart.sh
# ---------------------------------------------------------------------------
_section "Step 13 — autostart.sh"
AUTOSTART="$SPECTRWM_CONF/autostart.sh"
cat > "$AUTOSTART" <<'EOF'
#!/bin/sh
pkill dzen2
clipmenud &
nitrogen --restore &
picom -b &
sxhkd -c ~/.config/spectrwm/sxhkdrc &
xfsettingsd &
xset -dpms &
conky -c ~/.config/spectrwm/conky/spectr-keys.conf &
sleep 1
~/.config/spectrwm/dzen2/bar &
EOF
chmod +x "$AUTOSTART"
_info "autostart.sh written"

# ---------------------------------------------------------------------------
# Step 14 — dzen2 bar font
# ---------------------------------------------------------------------------
_section "Step 14 — dzen2 bar font"
DZEN_BAR="$SPECTRWM_CONF/dzen2/bar"
if [ -f "$DZEN_BAR" ]; then
    sed -i "s|-fn 'ubuntu-mono-[^']*'|-fn '-*-mononoki nerd font-medium-r-*-*-14-*-*-*-*-*-*-*'|g" "$DZEN_BAR"
    _info "dzen2/bar font patched"
else
    _warn "dzen2/bar not found — skipping"
fi

# ---------------------------------------------------------------------------
# Step 15 — ~/.xinitrc
# ---------------------------------------------------------------------------
_section "Step 15 — ~/.xinitrc"
XINITRC="$HOME/.xinitrc"
grep -q 'exec spectrwm' "$XINITRC" 2>/dev/null \
    || { echo "exec spectrwm" >> "$XINITRC"; _info "exec spectrwm added to .xinitrc"; }

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
_section "Desktop setup complete"
_info "Starship:   $("$LOCAL_BIN/starship" --version)"
_info "dotfiles:   $DOTFILES_DIR  ->  $HOME"
_info "spectrwm:   $SPECTRWM_CONF"
_info "Wallpapers: $HOME/Pictures/wallpaper"
echo ""
_info "Run:  nitrogen ~/Pictures/wallpaper   (set wallpaper)"
_info "Then: startx   or select spectrwm from your display manager"
_warn "Change root password:  passwd"
_warn "If xfsettingsd unavailable, remove it from autostart.sh"
DOTFILES_INSTALLER

chmod +x "$SCRIPT_DEST"
_info "Dotfiles installer written to $SCRIPT_DEST"

# --------------------------------------------------------------------------
# Firstboot rc script — runs install-dotfiles.sh on first boot as root
# then removes itself so it only fires once
# --------------------------------------------------------------------------
FIRSTBOOT="$MNTROOT/etc/rc.d/rc.firstboot"
cat > "$FIRSTBOOT" << 'FIRSTBOOT_SCRIPT'
#!/bin/bash
# Runs once on first boot to complete desktop setup
MARKER="/root/.dotfiles-installed"
INSTALLER="/root/install-dotfiles.sh"

[ -f "$MARKER" ] && exit 0
[ -f "$INSTALLER" ] || exit 0

# Wait for network
for i in $(seq 1 30); do
    ping -c1 -W2 8.8.8.8 >/dev/null 2>&1 && break
    sleep 2
done

bash "$INSTALLER" >> /root/install-dotfiles.log 2>&1
touch "$MARKER"
FIRSTBOOT_SCRIPT

chmod +x "$FIRSTBOOT"

# Hook into rc.local
RCLOCAL="$MNTROOT/etc/rc.d/rc.local"
if [ -f "$RCLOCAL" ]; then
    grep -q 'rc.firstboot' "$RCLOCAL" \
        || echo -e "\n# First-boot desktop setup\n[ -x /etc/rc.d/rc.firstboot ] && /etc/rc.d/rc.firstboot" >> "$RCLOCAL"
else
    echo -e "#!/bin/bash\n[ -x /etc/rc.d/rc.firstboot ] && /etc/rc.d/rc.firstboot" > "$RCLOCAL"
    chmod +x "$RCLOCAL"
fi
_info "First-boot hook registered in rc.local"

# ===========================================================================
# Cleanup / unmount
# ===========================================================================
_section "Unmounting"

# Unbind chroot mounts
for d in dev/pts dev proc sys; do
    umount "$MNTROOT/$d" 2>/dev/null || true
done

sync
umount "$MNTROOT/boot/efi"
umount "$MNTROOT"

# ===========================================================================
# Done
# ===========================================================================
_section "Install complete"

echo ""
_info "Drive:      $TARGET"
_info "ESP:        $PART_ESP  (FAT32, /boot/efi)"
_info "Root:       $PART_ROOT (ext4,  /)"
_info "Bootloader: GRUB UEFI — EFI entry: Slackware"
echo ""
_info "On first boot the dotfiles installer will run automatically"
_info "and log to /root/install-dotfiles.log"
_info "You can also run it manually at any time: bash /root/install-dotfiles.sh"
echo ""
_warn "Root password is 'slackware' — change it immediately: passwd"
_warn "Remove install media, then reboot"
