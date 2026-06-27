#!/bin/bash
# =============================================================================
# shastenm dotfiles — full desktop installer — Slackware Linux 15
#
# Repos:
#   gitlab.com/shastenm/dotfiles-bsd        shell, configs, nvim, kitty, starship
#   gitlab.com/shastenm/dotfile-installation fonts
#   gitlab.com/shastenm/spectrwm-bsd         spectrwm config + dzen2 bar
#   gitlab.com/shastenm/wallpaper            wallpapers
#
# Run as root (or sudo) on an already-installed Slackware 15 system.
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

# =============================================================================
# Step 1 — System update
# =============================================================================
_section "Step 1 — System update (slackpkg)"

slackpkg update gpg || _warn "GPG key update skipped"
slackpkg update
slackpkg upgrade-all

# =============================================================================
# Step 2 — slackpkg packages
# =============================================================================
_section "Step 2 — slackpkg packages"

for pkg in git curl wget fontconfig neovim jq; do
    command -v "$pkg" >/dev/null 2>&1 \
        && _info "$pkg already present" \
        || slackpkg install "$pkg" || _warn "$pkg not in slackpkg — will try sbopkg"
done

# =============================================================================
# Step 3 — sbopkg
# =============================================================================
_section "Step 3 — sbopkg setup"

if ! command -v sbopkg >/dev/null 2>&1; then
    _info "Downloading sbopkg..."
    mkdir -p "$BUILD_DIR" && cd "$BUILD_DIR"
    wget -c "$SBOPKG_URL"
    installpkg "$SBOPKG_PKG"
else
    _info "sbopkg already installed"
fi

_info "Syncing SBo repo..."
sbopkg -r

# =============================================================================
# Step 4 — SBo packages
# =============================================================================
_section "Step 4 — SBo packages"

SBO_PKGS=(
    spectrwm nitrogen picom sxhkd conky dzen2 dmenu
    lxappearance pcmanfm kitty ripgrep fzf bat eza
    starship stow xlockmore xclip clipmenu
)

for pkg in "${SBO_PKGS[@]}"; do
    if ! command -v "$pkg" >/dev/null 2>&1 && \
       ! ls /var/log/packages/"$pkg"-* >/dev/null 2>&1; then
        _info "Installing $pkg from SBo..."
        sbopkg -i "$pkg" || _warn "$pkg build failed — install manually"
    else
        _info "$pkg already installed"
    fi
done

# =============================================================================
# Step 5 — dzen2 source fallback
# =============================================================================
_section "Step 5 — dzen2 source fallback"

if ! command -v dzen2 >/dev/null 2>&1; then
    _warn "dzen2 not found — building from source"
    slackpkg install libX11 libXft libXinerama libXpm || true
    mkdir -p "$BUILD_DIR" && cd "$BUILD_DIR"
    [ -d dzen ] || git clone https://github.com/robm/dzen.git
    cd dzen && make
    cp dzen2 /usr/local/bin/dzen2
    chmod +x /usr/local/bin/dzen2
    _info "dzen2 built from source"
else
    _info "dzen2 already present"
fi

# =============================================================================
# Step 6 — Starship
# =============================================================================
_section "Step 6 — Starship prompt"

mkdir -p "$LOCAL_BIN"
_info "Installing/updating starship via starship.rs installer..."
curl -sS "$STARSHIP_URL" | sh -s -- --yes --bin-dir "$LOCAL_BIN"

"$LOCAL_BIN/starship" --version >/dev/null 2>&1 \
    && _info "Starship $("$LOCAL_BIN/starship" --version) ready" \
    || { _err "Starship install failed"; exit 1; }

# =============================================================================
# Step 7 — Fonts
# =============================================================================
_section "Step 7 — Fonts"

mkdir -p "$BUILD_DIR"
_clone_or_pull "$INSTALL_REPO" "$BUILD_DIR/dotfile-installation"

mkdir -p "$FONT_DIR"
cp "$BUILD_DIR/dotfile-installation/fonts/"*.ttf "$FONT_DIR/" 2>/dev/null \
    || _warn "No .ttf files found in dotfile-installation/fonts/ — check repo"
fc-cache -fv

for face in "mononoki" "noto.*cjk" "joy"; do
    fc-list | grep -qi "$face" \
        && _info "  ✓ $face" \
        || _warn "  ✗ $face NOT found — install manually"
done

# =============================================================================
# Step 8 — Wallpapers
# =============================================================================
_section "Step 8 — Wallpapers"

mkdir -p "$HOME/Pictures"
_clone_or_pull "$WALLPAPER_REPO" "$HOME/Pictures/wallpaper"

# =============================================================================
# Step 9 — dotfiles-bsd + GNU Stow
# =============================================================================
_section "Step 9 — dotfiles-bsd + GNU Stow"

_clone_or_pull "$DOTFILES_REPO" "$DOTFILES_DIR"
cd "$DOTFILES_DIR"

_bak() {
    local t="$HOME/$1"
    [ -e "$t" ] && [ ! -L "$t" ] && { _warn "Backing up $t -> ${t}.bak"; mv "$t" "${t}.bak"; }
}
_bak ".bashrc"
_bak ".bash_profile"

_info "stow --adopt (absorb conflicts)..."
stow --adopt --target="$HOME" --dir="$DOTFILES_DIR" . 2>&1 | grep -v '^$' || true

_info "git checkout . (restore repo versions)..."
git -C "$DOTFILES_DIR" checkout .

_info "stow --restow (ensure all symlinks correct)..."
stow --restow --target="$HOME" --dir="$DOTFILES_DIR" .

_info "Stow complete"

# =============================================================================
# Step 10 — Starship config + .bashrc guards
# =============================================================================
_section "Step 10 — Starship config"

STARSHIP_DST="$HOME/.config/starship.toml"
STARSHIP_SRC="$DOTFILES_DIR/.config/starship.toml"

if   [ -L "$STARSHIP_DST" ]; then _info "~/.config/starship.toml symlinked by stow ✓"
elif [ -f "$STARSHIP_SRC" ]; then
    _warn "Not a symlink — linking manually"
    mkdir -p "$HOME/.config"
    ln -sf "$STARSHIP_SRC" "$STARSHIP_DST"
else
    _warn "No starship.toml in dotfiles — starship will use defaults"
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

# =============================================================================
# Step 11 — spectrwm-bsd config
# =============================================================================
_section "Step 11 — spectrwm-bsd config"

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
_info "spectrwm scripts marked executable"

# =============================================================================
# Step 12 — spectrwm.conf
# =============================================================================
_section "Step 12 — spectrwm.conf (disable built-in bar)"

SWCONF="$SPECTRWM_CONF/spectrwm.conf"
if [ -f "$SWCONF" ]; then
    sed -i 's|^\(bar_action\s*=.*\)|# \1|' "$SWCONF"
    if grep -q '^bar_enabled' "$SWCONF"; then
        sed -i 's|^bar_enabled\s*=.*|bar_enabled = 0|' "$SWCONF"
    else
        echo "bar_enabled = 0" >> "$SWCONF"
    fi
    _info "spectrwm.conf patched"
else
    _warn "spectrwm.conf not found — skipping"
fi

# =============================================================================
# Step 13 — autostart.sh
# =============================================================================
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

# =============================================================================
# Step 14 — dzen2 bar font
# =============================================================================
_section "Step 14 — dzen2 bar font fix"

DZEN_BAR="$SPECTRWM_CONF/dzen2/bar"
if [ -f "$DZEN_BAR" ]; then
    sed -i "s|-fn 'ubuntu-mono-[^']*'|-fn '-*-mononoki nerd font-medium-r-*-*-14-*-*-*-*-*-*-*'|g" "$DZEN_BAR"
    _info "dzen2/bar font patched to Mononoki Nerd Font"
else
    _warn "dzen2/bar not found — skipping font fix"
fi

# =============================================================================
# Step 15 — ~/.xinitrc
# =============================================================================
_section "Step 15 — ~/.xinitrc"

XINITRC="$HOME/.xinitrc"
grep -q 'exec spectrwm' "$XINITRC" 2>/dev/null \
    || { echo "exec spectrwm" >> "$XINITRC"; _info "exec spectrwm added"; }

# =============================================================================
# Done
# =============================================================================
_section "Installation complete"

echo ""
_info "Starship:   $("$LOCAL_BIN/starship" --version)"
_info "dotfiles:   $DOTFILES_DIR  ->  stowed to $HOME"
_info "spectrwm:   $SPECTRWM_CONF"
_info "Wallpapers: $HOME/Pictures/wallpaper"
echo ""
_info "Next steps:"
_info "  1. Set wallpaper:  nitrogen ~/Pictures/wallpaper"
_info "  2. Reload shell:   source ~/.bashrc"
_info "  3. Start desktop:  startx"
echo ""
_warn "If xfsettingsd is unavailable, remove it from autostart.sh"
_warn "All rice tooling is SBo-only — check sbopkg if anything is missing"
