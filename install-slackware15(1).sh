#!/bin/bash
# =============================================================================
# shastenm dotfiles — full desktop installer — Slackware Linux 15
#
# Repos:
#   gitlab.com/shastenm/dotfiles-bsd        shell, configs, nvim, kitty, starship
#   gitlab.com/shastenm/dotfile-installation fonts, spectrwm source
#   gitlab.com/shastenm/spectrwm-bsd         spectrwm config + dzen2 bar
#   gitlab.com/shastenm/wallpaper            wallpapers
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Repos / dirs
# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
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
# 1. System update
# =============================================================================
_section "Step 1 — System update (slackpkg)"

sudo slackpkg update gpg  || _warn "GPG key update skipped"
sudo slackpkg update
sudo slackpkg upgrade-all

# =============================================================================
# 2. slackpkg packages (available in official repos)
# =============================================================================
_section "Step 2 — slackpkg packages"

SLACKPKG_PKGS=(git curl wget fontconfig neovim jq)

for pkg in "${SLACKPKG_PKGS[@]}"; do
    if ! command -v "$pkg" >/dev/null 2>&1; then
        _info "Installing $pkg..."
        sudo slackpkg install "$pkg" || _warn "$pkg not found in slackpkg — will try sbopkg later"
    else
        _info "$pkg already present"
    fi
done

# =============================================================================
# 3. sbopkg — install if missing, then sync
# =============================================================================
_section "Step 3 — sbopkg setup"

if ! command -v sbopkg >/dev/null 2>&1; then
    _info "Downloading sbopkg..."
    mkdir -p "$BUILD_DIR" && cd "$BUILD_DIR"
    wget -c "$SBOPKG_URL"
    sudo installpkg "$SBOPKG_PKG"
else
    _info "sbopkg already installed"
fi

_info "Syncing SBo repo..."
sudo sbopkg -r

# =============================================================================
# 4. SBo packages (rice tooling not in official repos)
# =============================================================================
_section "Step 4 — SBo packages"

# Build/install each one; sbopkg -i handles deps via REQUIRES in .info files.
# spectrwm and dzen2 first since the DE depends on them.
SBO_PKGS=(
    spectrwm
    nitrogen
    picom
    sxhkd
    conky
    dzen2
    dmenu
    lxappearance
    pcmanfm
    kitty
    ripgrep
    fzf
    bat
    eza
    starship
    stow
    xlockmore
    xclip
    clipmenu
)

for pkg in "${SBO_PKGS[@]}"; do
    if ! command -v "$pkg" >/dev/null 2>&1 && ! ls /var/log/packages/"$pkg"-* >/dev/null 2>&1; then
        _info "Installing $pkg from SBo..."
        sudo sbopkg -i "$pkg" || _warn "$pkg SBo build failed — install manually"
    else
        _info "$pkg already installed"
    fi
done

# =============================================================================
# 5. dzen2 fallback — build from source if SBo failed
# =============================================================================
_section "Step 5 — dzen2 source build (fallback)"

if ! command -v dzen2 >/dev/null 2>&1; then
    _warn "dzen2 not found — building from source"
    sudo slackpkg install libX11 libXft libXinerama libXpm || true
    mkdir -p "$BUILD_DIR" && cd "$BUILD_DIR"
    [ -d dzen ] || git clone https://github.com/robm/dzen.git
    cd dzen
    make
    sudo cp dzen2 /usr/local/bin/dzen2
    sudo chmod +x /usr/local/bin/dzen2
    _info "dzen2 $(dzen2 -v 2>&1 | head -1) installed from source"
else
    _info "dzen2 already present"
fi

# =============================================================================
# 6. starship — install via official installer into ~/.local/bin
#    (ensures latest version even if SBo starship is older)
# =============================================================================
_section "Step 6 — Starship prompt"

mkdir -p "$LOCAL_BIN"
_info "Installing/updating starship via starship.rs installer..."
curl -sS "$STARSHIP_URL" | sh -s -- --yes --bin-dir "$LOCAL_BIN"

if "$LOCAL_BIN/starship" --version >/dev/null 2>&1; then
    _info "Starship $("$LOCAL_BIN/starship" --version) ready"
else
    _err "Starship install failed"
    exit 1
fi

# =============================================================================
# 7. Fonts — clone dotfile-installation and copy TTFs
# =============================================================================
_section "Step 7 — Fonts"

mkdir -p "$BUILD_DIR"
_clone_or_pull "$INSTALL_REPO" "$BUILD_DIR/dotfile-installation"

sudo mkdir -p "$FONT_DIR"
sudo cp "$BUILD_DIR/dotfile-installation/fonts/"*.ttf "$FONT_DIR/" 2>/dev/null \
    || _warn "No .ttf files found in dotfile-installation/fonts/ — check repo"
fc-cache -fv

_info "Verifying required fonts..."
for face in "mononoki" "noto.*cjk" "joy"; do
    if fc-list | grep -qi "$face"; then
        _info "  ✓ $face"
    else
        _warn "  ✗ $face NOT found — install manually"
    fi
done

# =============================================================================
# 8. Wallpapers
# =============================================================================
_section "Step 8 — Wallpapers"

mkdir -p "$HOME/Pictures"
_clone_or_pull "$WALLPAPER_REPO" "$HOME/Pictures/wallpaper"

# =============================================================================
# 9. dotfiles-bsd — clone / pull, then stow
# =============================================================================
_section "Step 9 — dotfiles-bsd + GNU Stow"

_clone_or_pull "$DOTFILES_REPO" "$DOTFILES_DIR"

cd "$DOTFILES_DIR"

# Back up real files that stow would conflict with
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
# 10. Verify starship config symlink
# =============================================================================
_section "Step 10 — Starship config"

STARSHIP_DST="$HOME/.config/starship.toml"
STARSHIP_SRC="$DOTFILES_DIR/.config/starship.toml"

if [ -L "$STARSHIP_DST" ]; then
    _info "~/.config/starship.toml symlinked by stow ✓"
elif [ -f "$STARSHIP_SRC" ]; then
    _warn "Not a symlink — linking manually"
    mkdir -p "$HOME/.config"
    ln -sf "$STARSHIP_SRC" "$STARSHIP_DST"
else
    _warn "No starship.toml in dotfiles — starship will use defaults"
fi

# Guard: ensure starship init is in .bashrc (stowed .bashrc already has it,
# but if for any reason it's absent we append it)
BASHRC="$HOME/.bashrc"
if ! grep -q 'starship init bash' "$BASHRC" 2>/dev/null; then
    _warn "starship init missing from .bashrc — appending..."
    cat >> "$BASHRC" <<'EOF'

# Starship prompt
if command -v starship >/dev/null 2>&1; then
    eval "$(starship init bash)"
fi
EOF
fi

# Ensure ~/.local/bin on PATH
if ! grep -q 'HOME/.local/bin' "$BASHRC" 2>/dev/null; then
    echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$BASHRC"
fi

# =============================================================================
# 11. spectrwm config — clone spectrwm-bsd, copy into ~/.config/spectrwm
# =============================================================================
_section "Step 11 — spectrwm-bsd config"

_clone_or_pull "$SPECTRWM_REPO" "$SPECTRWM_DIR"

mkdir -p "$SPECTRWM_CONF"
cp -r "$SPECTRWM_DIR/"* "$SPECTRWM_CONF/"

# Make all scripts executable
SCRIPTS=(
    autostart.sh
    baraction.sh
    dzen2/bar
    scripts/toggle-panel
    scripts/toggle-spectrwm-keys
    scripts/toggle-sxhkd-keys
    dzen2/scripts/docs
    dzen2/scripts/dots
)
for s in "${SCRIPTS[@]}"; do
    [ -f "$SPECTRWM_CONF/$s" ] && chmod +x "$SPECTRWM_CONF/$s" \
        || _warn "Script not found: $SPECTRWM_CONF/$s"
done
_info "spectrwm scripts marked executable"

# =============================================================================
# 12. Fix spectrwm.conf — disable built-in bar, comment out bar_action
# =============================================================================
_section "Step 12 — spectrwm.conf (disable built-in bar)"

SWCONF="$SPECTRWM_CONF/spectrwm.conf"

if [ -f "$SWCONF" ]; then
    # Comment out bar_action if it's uncommented
    sed -i 's|^\(bar_action\s*=.*\)|# \1|' "$SWCONF"
    # Set bar_enabled = 0 (replace existing or append)
    if grep -q '^bar_enabled' "$SWCONF"; then
        sed -i 's|^bar_enabled\s*=.*|bar_enabled = 0|' "$SWCONF"
    else
        echo "bar_enabled = 0" >> "$SWCONF"
    fi
    _info "spectrwm.conf: bar_action commented out, bar_enabled = 0"
else
    _warn "spectrwm.conf not found at $SWCONF — skipping"
fi

# =============================================================================
# 13. Fix autostart.sh — ensure dzen2 is launched, pkill at top
# =============================================================================
_section "Step 13 — autostart.sh"

AUTOSTART="$SPECTRWM_CONF/autostart.sh"

cat > "$AUTOSTART" <<'EOF'
#!/bin/sh

# Kill any leftover dzen2 from previous session
pkill dzen2

# Background processes
clipmenud &
nitrogen --restore &
picom -b &
sxhkd -c ~/.config/spectrwm/sxhkdrc &
xfsettingsd &
xset -dpms &
conky -c ~/.config/spectrwm/conky/spectr-keys.conf &

# Launch dzen2 bar (sleep gives X a moment to settle)
sleep 1
~/.config/spectrwm/dzen2/bar &
EOF

chmod +x "$AUTOSTART"
_info "autostart.sh written"

# =============================================================================
# 14. Fix dzen2 bar — replace ubuntu-mono-10 with Mononoki Nerd Font
# =============================================================================
_section "Step 14 — dzen2 bar font fix"

DZEN_BAR="$SPECTRWM_CONF/dzen2/bar"

if [ -f "$DZEN_BAR" ]; then
    # Replace any occurrence of ubuntu-mono-<size> font string
    sed -i "s|-fn 'ubuntu-mono-[^']*'|-fn '-*-mononoki nerd font-medium-r-*-*-14-*-*-*-*-*-*-*'|g" "$DZEN_BAR"
    _info "dzen2/bar font updated to Mononoki Nerd Font"
else
    _warn "dzen2/bar not found at $DZEN_BAR — skipping font fix"
fi

# =============================================================================
# 15. xinitrc — ensure spectrwm is set as the WM
# =============================================================================
_section "Step 15 — ~/.xinitrc"

XINITRC="$HOME/.xinitrc"
if [ ! -f "$XINITRC" ] || ! grep -q 'exec spectrwm' "$XINITRC"; then
    echo "exec spectrwm" >> "$XINITRC"
    _info "Added 'exec spectrwm' to ~/.xinitrc"
else
    _info "~/.xinitrc already has exec spectrwm"
fi

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
_info "  1. Set wallpaper:   nitrogen ~/Pictures/wallpaper  (pick one, click Apply)"
_info "  2. Reload shell:    source ~/.bashrc"
_info "  3. Start spectrwm:  startx   — or select it from your display manager"
echo ""
_warn "If xfsettingsd is not available (no XFCE), remove that line from autostart.sh"
_warn "Nearly all rice tooling on Slackware 15 is SBo-only — check sbopkg if anything is missing"
