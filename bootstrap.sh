#!/bin/bash
# Take a fresh Mac from nothing to a working dev environment.
#
# THE END STATE: open WezTerm from the Dock, run `herdr`, and start `claude` in
# a pane -- with the stowed config, the Nerd Font, herdr's plugins and file
# links, Claude's statusline, and the agent layer (skills, instructions, MCP)
# all in place. Everything that state depends on is installed here or by the
# scripts this calls; nothing is a manual step except logging in. The run ends
# by checking that state and exits non-zero if any of it is missing.
#
#   /bin/bash -c "$(curl -fsSL <raw url of this file>)"
#
# Re-runnable: every step checks before it acts, so running it again on a
# set-up machine only pulls repos and reconciles.
#
# What it does, in order:
#   1. Xcode Command Line Tools, Homebrew, gh, bash, python
#   2. gh auth login (interactive, once) + gh as git's credential helper
#   3. clone (or pull) the fleet repos into $SRC_DIR
#   4. dotfiles/install.sh    layer 3: WezTerm, Nerd Font, herdr, terminal
#                             tools, stowed config
#   5. Claude Code            the agent harness (native installer)
#   6. apm + ~/.apm/apm.yml    layer 2: agent primitives via agent-packages,
#                             including Claude's statusline
#   7. project apm packages   apm install --frozen + worktree hook, per repo
#                             with an apm.yml
#   8. dotfiles/sync.sh        audit, the same path the daily job takes
#   9. end-state check
#  10. dotfiles/scripts/reload.sh --apply: reload what was running on old state
#
# This lives OUTSIDE dotfiles on purpose: dotfiles must never write the agent
# layer (~/.apm, ~/.claude), and step 6 does. It stays public so a machine
# with no credentials can curl it; it contains no secrets, only repo names.
#
# Environment overrides:
#   SRC_DIR=~/src            where repos are cloned
#   PROFILE=desktop          dotfiles profile (desktop | server)
#   EXTRA_REPOS="a b"        more sheilagithub repos to clone alongside
#   SKIP_SYNC=1              skip dotfiles/sync.sh; the end-state check still runs

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
# bash: macOS ships bash 3.2, and agent-packages' dev scripts need bash >= 4
# (mapfile, local -n). This only adds an interpreter for those scripts; the
# login shell stays zsh.
for p in gh git stow python bash; do
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
if grep -q 'gh auth git-credential' <<<"$(git config --get-all credential.https://github.com.helper 2>/dev/null)"; then
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

# install.sh installs herdr, hunk and backlog into ~/.local/bin; later steps
# and the end-state check need them on PATH.
export PATH="$HOME/.local/bin:$PATH"

# stow refuses to link over a real file. A machine set up partly by hand grows
# some before dotfiles arrives (herdr writes its own config.toml on first
# launch), so move those aside once. install.sh itself leaves them alone.
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

# ------------------------------------------------------------ Claude Code

# The agent harness, from its native installer (~/.local/bin/claude, which then
# updates itself). Installed before the agent layer so the residual deploy
# finds ~/.claude and sets up its statusline.
step "Claude Code"
if command -v claude >/dev/null 2>&1; then
    ok "claude $(claude --version 2>/dev/null | awk '{print $1}')"
else
    act "installing Claude Code"
    curl -fsSL https://claude.ai/install.sh | bash
fi
mkdir -p "$HOME/.claude"

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
# `apm install` holds a re-run to the lockfile, so a machine set up last month
# would never pick up newer agent-packages commits. Once a lockfile exists,
# `apm update` moves #main forward instead; both run the post-install deploy.
if [ -f "$HOME/.apm/apm.lock.yaml" ]; then
    (cd "$HOME/.apm" && apm update --global --yes) || warn "apm update --global failed (above)"
else
    (cd "$HOME/.apm" && apm install --global) || warn "apm install --global failed (above)"
fi

# Project scope: every cloned repo with an apm.yml gets its own packages,
# and its worktree hook if it ships one, so new worktrees install theirs too.
# --frozen when a lockfile exists: reproduce what the repo pinned.
step "Project apm packages"
for r in $REPOS; do
    dest="$SRC_DIR/$r"
    [ -f "$dest/apm.yml" ] || continue
    enable="$dest/dev/tools/enable_worktree_apm_bootstrap.sh"
    if [ -x "$dest/.githooks/post-checkout" ] && [ -f "$enable" ]; then
        if [ -n "$(git -C "$dest" config core.hooksPath)" ]; then
            ok "$r worktree hook enabled"
        elif (cd "$dest" && bash "$enable" >/dev/null); then
            act "$r: enabled worktree apm hook"
        else
            warn "$r: could not enable its worktree hook (see above)"
        fi
    fi
    # Install ONCE, when nothing is installed yet. apm 0.31 can re-resolve a
    # semver range on a repeat install even under --frozen, rewriting the
    # tracked lockfile (agent-packages E-21); a first install was clean every
    # time it was observed. Later updates belong to the repo's own workflow.
    if ! grep -q 'No APM dependencies installed' <<<"$(cd "$dest" && apm deps list 2>&1)"; then
        ok "$r packages already installed (not re-run; see E-21)"
        continue
    fi
    lock_clean=0
    git -C "$dest" diff --quiet -- apm.lock.yaml 2>/dev/null && lock_clean=1
    if [ -f "$dest/apm.lock.yaml" ]; then
        (cd "$dest" && apm install --frozen >/dev/null 2>&1) && act "$r: installed packages (frozen)" ||
            warn "$r: apm install --frozen failed; run it in $dest to see why"
    else
        (cd "$dest" && apm install >/dev/null 2>&1) && act "$r: installed packages" ||
            warn "$r: apm install failed; run it in $dest to see why"
    fi
    # Never leave a tracked lockfile rewritten behind: put it back and say so.
    # Only when it was clean before -- uncommitted edits of yours stay.
    if [ "$lock_clean" = 1 ] && ! git -C "$dest" diff --quiet -- apm.lock.yaml 2>/dev/null; then
        git -C "$dest" checkout -- apm.lock.yaml
        warn "$r: apm rewrote apm.lock.yaml during install (E-21); restored it. Deployed files may not match the lock: run 'apm audit' in $dest"
    fi
done

if [ "${SKIP_SYNC:-0}" != 1 ]; then
    step "dotfiles sync.sh (audit)"
    SKIP_PULL=1 "$DOTFILES/sync.sh" || warn "sync reported failures; see $DOTFILES/logs/"
fi

# -------------------------------------------------------------- end state

# The point of the whole run. Each line is a thing the WezTerm + herdr + Claude
# session needs; a miss names what to fix.
step "End state"
missing=0
# A statusLine that exists is not enough: it must be a command entry with a
# non-empty command, and any path in that command must exist.
statusline_ok() {
    python3 - "$HOME/.claude/settings.json" <<'PYEOF'
import json, os, shlex, sys
try:
    with open(sys.argv[1], encoding="utf-8") as f:
        line = json.load(f).get("statusLine")
except (OSError, ValueError):
    sys.exit(1)
if not isinstance(line, dict) or line.get("type") != "command":
    sys.exit(1)
command = line.get("command")
if not isinstance(command, str) or not command.strip():
    sys.exit(1)
paths = [os.path.expanduser(t) for t in shlex.split(command) if "/" in t]
sys.exit(0 if all(os.path.exists(p) for p in paths) else 1)
PYEOF
}

# Each probe runs through eval, so it can be a small pipeline. Pipes into
# `grep -q` are avoided: under pipefail, grep exiting on its first match can
# SIGPIPE the producer and turn a hit into a failure.
check() {
    if eval "$2" >/dev/null 2>&1; then
        printf '   \033[32m✔\033[0m  %s\n' "$1"
    else
        printf '   \033[31m✘\033[0m  %s  -> %s\n' "$1" "$3"
        missing=$((missing + 1))
    fi
}
check "WezTerm app" "[ -d /Applications/WezTerm.app ]" "brew install --cask wezterm"
check "JetBrainsMono Nerd Font" "ls $HOME/Library/Fonts/JetBrainsMonoNerdFont* || ls /Library/Fonts/JetBrainsMonoNerdFont*" "brew install --cask font-jetbrains-mono-nerd-font"
check "~/.wezterm.lua from dotfiles" "[ -L $HOME/.wezterm.lua ] && [ -e $HOME/.wezterm.lua ]" "$DOTFILES/install.sh $PROFILE"
check "herdr" "command -v herdr" "$DOTFILES/install.sh $PROFILE"
check "herdr config from dotfiles" "[ -L $HOME/.config/herdr/config.toml ] && [ -e $HOME/.config/herdr/config.toml ]" "$DOTFILES/install.sh $PROFILE"
check "herdr plugins (worktree-layout, file-viewer)" "plugins=\$(herdr plugin list); grep -q sheilagithub.worktree-layout <<<\"\$plugins\" && grep -q herdr-file-viewer <<<\"\$plugins\"" "$DOTFILES/install.sh $PROFILE"
check "herdr agent integration for Claude" "grep -q '^claude: current' <<<\"\$(herdr integration status)\"" "cd ~/.apm && apm install --global"
check "Claude Code" "command -v claude" "curl -fsSL https://claude.ai/install.sh | bash"
check "Claude statusline" "statusline_ok" "cd ~/.apm && apm update --global --yes"
check "MCP servers match the roster" "python3 \"\$(find $HOME/.apm/apm_modules -path '*/user/scripts/verify_host_mcp.py' | head -n1)\"" "cd $AGENT_PACKAGES && make verify-host"
for r in $REPOS; do
    [ -f "$SRC_DIR/$r/apm.yml" ] || continue
    check "$r apm packages installed" "! grep -q 'No APM dependencies installed' <<<\"\$(cd $SRC_DIR/$r && apm deps list 2>&1)\"" "cd $SRC_DIR/$r && apm install --frozen"
done
check "login shell is zsh" "grep -q zsh <<<\"\$(dscl . -read /Users/\$(id -un) UserShell)\"" "chsh -s /bin/zsh"

if [ "$missing" -gt 0 ]; then
    printf '\n   \033[31m%s item(s) missing.\033[0m Fix the ones above, then re-run this script.\n' "$missing"
    exit 1
fi

# Programs already running keep what they loaded at start: WezTerm its fonts,
# a shell its PATH, herdr its plugins, claude its MCP servers. dotfiles'
# reload script finds each one that started before a change it depends on,
# runs the reloads that are safe from here, and prints the rest.
step "Reload"
if [ -x "$DOTFILES/scripts/reload.sh" ]; then
    "$DOTFILES/scripts/reload.sh" --apply
else
    warn "dotfiles has no scripts/reload.sh yet: restart WezTerm, herdr (herdr server stop && herdr) and open shells by hand"
fi
cat <<EOF

   Ready. Then: WezTerm -> \`herdr\` -> \`claude\` in a pane (a first run asks
   you to log in). Re-check reloads any time: dot reload

   Repos:     $SRC_DIR
   Optional:  cd $DOTFILES && just schedule    daily sync at 08:30 via launchd
EOF
}

main "$@"
