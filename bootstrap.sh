#!/bin/bash
# Take a fresh Mac from nothing to a working dev environment.
#
#   /bin/bash -c "$(curl -fsSL <raw url of this file>)"
#
# Re-runnable: every step checks before it acts, so running it again on a
# set-up machine only pulls repos and reconciles.
#
# What it does, in order:
#   1. Xcode Command Line Tools, Homebrew, gh
#   2. gh auth login (interactive, once) + gh as git's credential helper
#   3. clone (or pull) the fleet repos into $SRC_DIR
#   4. herdr (self-updating, so installed here rather than by dotfiles)
#   5. dotfiles/install.sh    layer 3: terminal tools + stowed config
#   6. apm + ~/.apm/apm.yml    layer 2: agent primitives via agent-packages
#   7. dotfiles/sync.sh        compile + audit, same path the daily job takes
#
# This lives OUTSIDE dotfiles on purpose: dotfiles must never write the agent
# layer (~/.apm, ~/.claude), and step 6 does. It stays public so a machine
# with no credentials can curl it; it contains no secrets, only repo names.
#
# Environment overrides:
#   SRC_DIR=~/src            where repos are cloned
#   PROFILE=desktop          dotfiles profile (desktop | server)
#   EXTRA_REPOS="a b"        more sheilagithub repos to clone alongside
#   SKIP_SYNC=1              stop after the global apm install

# Everything lives in main(), called on the last line, so a truncated download
# runs nothing instead of half a script.
main() {
set -euo pipefail

GH_OWNER=sheilagithub
SRC_DIR=${SRC_DIR:-$HOME/src}
PROFILE=${PROFILE:-desktop}
CORE_REPOS="dotfiles agent-packages"
REPOS="$CORE_REPOS ${EXTRA_REPOS:-}"
STAMP=$(date +%Y%m%d-%H%M%S)

step() { printf '\n\033[36m== %s\033[0m\n' "$1"; }
ok()   { printf '   \033[90mOK      %s\033[0m\n' "$1"; }
act()  { printf '   \033[32mCHANGE  %s\033[0m\n' "$1"; }
warn() { printf '   \033[33mWARN    %s\033[0m\n' "$1"; }
die()  { printf '   \033[31mFAIL    %s\033[0m\n' "$1"; exit 1; }

[ "$(uname -s)" = Darwin ] || die "macOS only. Linux hosts: clone dotfiles and run install.sh directly."

# ------------------------------------------------------------- prerequisites

step "Xcode Command Line Tools"
if xcode-select -p >/dev/null 2>&1; then
    ok "present"
else
    act "xcode-select --install (finish the dialog; this waits for it)"
    xcode-select --install || true
    until xcode-select -p >/dev/null 2>&1; do sleep 10; done
fi

step "Homebrew"
BREW=/opt/homebrew/bin/brew
[ "$(uname -m)" = arm64 ] || BREW=/usr/local/bin/brew
if [ -x "$BREW" ]; then
    ok "present"
else
    act "installing Homebrew (asks for your password)"
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
fi
eval "$("$BREW" shellenv)"
# Login shells need brew on PATH too. dotfiles' .zshrc does not set it, and
# .zprofile is not a dotfiles-managed file, so it is seeded here, once.
SHELLENV_LINE="eval \"\$($BREW shellenv)\""
if grep -qsF "$BREW shellenv" "$HOME/.zprofile"; then
    ok "~/.zprofile loads brew"
else
    printf '%s\n' "$SHELLENV_LINE" >> "$HOME/.zprofile"
    act "added brew shellenv to ~/.zprofile"
fi

step "Bootstrap packages"
for p in gh git stow python; do
    if brew list --formula "$p" >/dev/null 2>&1; then ok "$p"; else act "brew install $p"; brew install "$p"; fi
done

# ---------------------------------------------------------------------- auth

step "GitHub auth"
if gh auth status >/dev/null 2>&1; then
    ok "gh authenticated"
else
    act "gh auth login"
    gh auth login --hostname github.com --git-protocol https --web
fi
# Needed for the clones below on a first run, before dotfiles' gitconfig (which
# carries the same helper) is in place. Skipped after that: setup-git writes
# into ~/.gitconfig, which install.sh generates, so running it every time makes
# install.sh rewrite the stub on every run.
if git config --get-all credential.https://github.com.helper 2>/dev/null | grep -q 'gh auth git-credential'; then
    ok "gh is git's credential helper"
else
    act "gh auth setup-git"
    gh auth setup-git
fi

# --------------------------------------------------------------------- repos

step "Repos -> $SRC_DIR"
mkdir -p "$SRC_DIR"
for r in $REPOS; do
    dest="$SRC_DIR/$r"
    if [ -d "$dest/.git" ]; then
        if git -C "$dest" pull --ff-only --quiet; then ok "$r (pulled)"; else warn "$r: pull failed, using what is checked out"; fi
    else
        act "clone $GH_OWNER/$r"
        gh repo clone "$GH_OWNER/$r" "$dest" -- --quiet
    fi
done
DOTFILES="$SRC_DIR/dotfiles"
AGENT_PACKAGES="$SRC_DIR/agent-packages"

# -------------------------------------------------------------- layer 3: OS

step "herdr"
export PATH="$HOME/.local/bin:$PATH"
if command -v herdr >/dev/null 2>&1; then
    ok "herdr $(herdr --version 2>/dev/null | awk '{print $2}')"
else
    act "installing herdr"
    curl -fsSL https://herdr.dev/install.sh | sh
fi

# stow refuses to link over a real file. A new machine grows some before
# dotfiles arrives (herdr writes its own config.toml on first launch), so move
# those aside once. install.sh itself leaves them alone on purpose.
step "Files stow would conflict with"
for pkg in zsh herdr hunk lazygit glow wezterm; do
    [ -d "$DOTFILES/$pkg" ] || continue
    # stow exits non-zero when it finds conflicts; those are what we want.
    { stow --no --target="$HOME" --dir="$DOTFILES" "$pkg" 2>&1 || true; } |
        sed -n 's/.*over existing target \(.*\) since neither a link nor a directory.*/\1/p' |
        while IFS= read -r rel; do
            mv "$HOME/$rel" "$HOME/$rel.pre-dotfiles-$STAMP"
            printf '   \033[32mCHANGE  moved ~/%s -> %s.pre-dotfiles-%s\033[0m\n' "$rel" "$(basename "$rel")" "$STAMP"
        done
done
ok "checked"

step "dotfiles install.sh $PROFILE"
"$DOTFILES/install.sh" "$PROFILE" || warn "install.sh reported problems (above); continuing"

# ------------------------------------------------------ layer 2: agent prims

step "apm"
if brew list --formula apm >/dev/null 2>&1; then ok "apm $(apm --version 2>/dev/null | head -n1)"; else act "brew install apm"; brew install apm; fi

step "Global apm manifest"
mkdir -p "$HOME/.apm"
if [ -f "$HOME/.apm/apm.yml" ]; then
    ok "~/.apm/apm.yml (left alone)"
else
    cp "$AGENT_PACKAGES/user/examples/user-scope-apm.example.yml" "$HOME/.apm/apm.yml"
    act "seeded ~/.apm/apm.yml from agent-packages/user/examples"
fi

step "dotfiles sync.local.sh"
if [ -f "$DOTFILES/sync.local.sh" ]; then
    ok "present (left alone)"
else
    cat > "$DOTFILES/sync.local.sh" <<EOF
# Per-host sync.sh settings for $(scutil --get LocalHostName 2>/dev/null || hostname).
# Seeded by bootstrap.sh; gitignored, never overwritten.
SYNC_PROFILE=$PROFILE
SYNC_REPOS="$AGENT_PACKAGES"
SYNC_APM_TARGETS=claude,codex,copilot
EOF
    act "seeded sync.local.sh"
fi

# deploy_host_residual.py (the manifest's post-install hook) needs PyYAML to
# sync Codex MCP servers, and brew's python has none. --user keeps it out of
# the brew-managed site-packages.
if python3 -c 'import yaml' 2>/dev/null; then
    ok "PyYAML"
else
    act "pip install --user pyyaml"
    python3 -m pip install --quiet --user --break-system-packages pyyaml
fi

step "apm install --global"
# apm >= 0.31 skips lifecycle scripts until the manifest is trusted, and the
# trust is pinned to the manifest's hash. This manifest is our own template,
# so trusting it here is what makes post-install (the residual deploy) run.
# Edit ~/.apm/apm.yml later and apm will ask for trust again.
(cd "$HOME/.apm" && apm lifecycle trust >/dev/null)
(cd "$HOME/.apm" && apm install --global) || warn "apm install --global failed (above)"

if [ "${SKIP_SYNC:-0}" != 1 ]; then
    step "dotfiles sync.sh (compile + audit)"
    SKIP_PULL=1 "$DOTFILES/sync.sh" || warn "sync reported failures; see $DOTFILES/logs/"
fi

# ------------------------------------------------------------------- done

step "Done"
cat <<EOF
   Repos:     $SRC_DIR
   Open a new terminal (or: exec zsh -l) to pick up .zshrc and brew.

   Optional, once:
     cd $DOTFILES && just schedule      daily sync at 08:30 via launchd
EOF
}

main "$@"
