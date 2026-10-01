#!/usr/bin/env bash
# Ubuntu 24.04 x86-64. Run as the development user, never with sudo bash.
set -euo pipefail
umask 077

NODE_VERSION=24.21.0
NODE_SHA=fd8e59d5a511510f6a298afb548f18c7d2b1be404d8b4a27d94fbe49f56cb2d6
NVIM_VERSION=0.12.5
NVIM_SHA=bce0f56eda1f1b1db6eee8f4133d7a38813ea07933837dd1777411ca384c6875
TS_VERSION=0.27.0
TS_SHA=20a1f39ec1c45f2211492dcb8881c802b643b554bb196869a29ac3778277fa77
CODEX_VERSION=0.159.3
NVIM_REF=8228efcd66ea2a6be3a379746c262a281412c65f
NVIM_REPO=https://github.com/Luiz-Filipe26/neovimrc.git
PROJECT_REPO=https://github.com/Luiz-Filipe26/ShellBlocks.git

packages=(git tmux ripgrep fd-find jq python3 less file patch curl ca-certificates
    rsync tree lsof strace sysstat htop ncdu bash-completion ncurses-term
    shellcheck procps psmisc iproute2 build-essential tar gzip xz-utils unzip
    bubblewrap dnsutils netcat-openbsd)

case "${1:---plan}" in
    --plan|--help)
        printf '%s\n' 'No changes. To apply: bash bootstrap-oracle-dev.sh --apply'
        printf 'APT: %s\n' "${packages[*]}"
        printf '%s\n' "User tools: Node $NODE_VERSION; NeoVim $NVIM_VERSION; tree-sitter $TS_VERSION; Codex $CODEX_VERSION"
        printf '%s\n' 'Swap: complement active swap to approximately 4 GiB; persist only the dedicated new swap file.'
        printf '%s\n' 'Prepare ~/.config/nvim, ~/dev/ShellBlocks, isolated development shell and tmux socket.'
        printf '%s\n' 'No project dependency installation, server startup, SSH/firewall changes or production configuration.'
        exit 0 ;;
    --apply) [[ $# == 1 ]] || { echo 'Unexpected arguments' >&2; exit 1; } ;;
    *) echo 'Usage: bootstrap-oracle-dev.sh [--plan|--apply]' >&2; exit 1 ;;
esac

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
[[ $EUID != 0 ]] || fail 'Run as the development user, not root.'
# shellcheck source=/dev/null
. /etc/os-release
[[ $ID == ubuntu && $VERSION_ID == 24.04 ]] || fail 'Requires Ubuntu 24.04.'
[[ $(uname -m) == x86_64 ]] || fail 'Requires x86-64.'
[[ $HOME == /* && $HOME != / ]] || fail 'Invalid home directory.'
[[ -z ${XDG_CONFIG_HOME:-} && -z ${XDG_DATA_HOME:-} ]] || fail 'Use default XDG paths for this bootstrap.'
command -v sudo >/dev/null || fail 'sudo is required.'
command -v flock >/dev/null || fail 'flock (util-linux) is required.'

state="$HOME/.local/share/oracle-dev"
config="$HOME/.config/oracle-dev"
bin="$HOME/.local/bin"
mkdir -p "$state" "$config" "$bin"
exec 9>"$state/bootstrap.lock"
flock -n 9 || fail 'Another bootstrap is running.'
temp=$(mktemp -d)
trap 'rm -rf -- "$temp"' EXIT
sudo -n true || fail 'Non-interactive sudo is required; no password prompt will be opened.'
# Request reporting instead of automatic service restarts; no distribution upgrade.
sudo -n env NEEDRESTART_MODE=l apt-get update
sudo -n env NEEDRESTART_MODE=l apt-get install -y --no-install-recommends --no-upgrade "${packages[@]}"

swap_total() { swapon --show --bytes --noheadings --output SIZE | awk '{n += $1} END {printf "%.0f\n", n}'; }
swap_target=$((4 * 1024 * 1024 * 1024))
swap_file=/swapfile-oracle-dev
swap_current=$(swap_total)
if (( swap_current < swap_target - 16 * 1024 * 1024 )); then
    # Never replace, resize or deactivate an existing swap file.
    [[ ! -e $swap_file && ! -L $swap_file ]] || fail "$swap_file already exists; inspect it manually."
    fs=$(findmnt -n -o FSTYPE -T /)
    [[ $fs == ext4 || $fs == xfs ]] || fail 'Swap creation supports ext4/xfs only.'
    swap_mib=$(((swap_target - swap_current + 1048575) / 1048576))
    available=$(df --output=avail -B1 / | tail -n 1 | tr -d ' ')
    (( available > swap_mib * 1048576 + 1073741824 )) || fail 'Insufficient disk space for swap and 1 GiB reserve.'
    # Refuse an existing stale fstab entry before allocating anything.
    if awk -v p="$swap_file" '$1 == p {found=1} END {exit !found}' /etc/fstab; then
        fail 'Dedicated swap entry already in fstab; inspect manually.'
    fi
    sudo -n install -m 600 /dev/null "$swap_file"
    sudo -n dd if=/dev/zero of="$swap_file" bs=1M count="$swap_mib" status=progress conv=fsync
    sudo -n mkswap "$swap_file"
    sudo -n swapon "$swap_file"
    printf '%s none swap sw 0 0\n' "$swap_file" | sudo -n tee -a /etc/fstab >/dev/null
fi

download() {
    local url=$1 sha=$2 output=$3
    curl --fail --location --retry 3 --proto '=https' --tlsv1.2 "$url" -o "$output"
    printf '%s  %s\n' "$sha" "$output" | sha256sum --check --status || fail "Checksum mismatch: $url"
}

install_tar() {
    local name=$1 url=$2 sha=$3 destination=$4
    if [[ -d $destination ]]; then
        [[ -f $destination/.oracle-dev-sha256 ]] || fail "Unmanaged directory: $destination"
        [[ $(cat "$destination/.oracle-dev-sha256") == "$sha" ]] || fail "Unexpected artifact: $destination"
        return
    fi
    download "$url" "$sha" "$temp/$name.tar"
    mkdir "$temp/$name"
    tar -xf "$temp/$name.tar" --strip-components=1 -C "$temp/$name"
    printf '%s\n' "$sha" >"$temp/$name/.oracle-dev-sha256"
    mv "$temp/$name" "$destination"
}

node="$state/node-$NODE_VERSION"
nvim="$state/nvim-$NVIM_VERSION"
ts="$state/tree-sitter-$TS_VERSION"
codex="$state/codex-$CODEX_VERSION"
install_tar node "https://nodejs.org/dist/v$NODE_VERSION/node-v$NODE_VERSION-linux-x64.tar.xz" "$NODE_SHA" "$node"
install_tar nvim "https://github.com/neovim/neovim/releases/download/v$NVIM_VERSION/nvim-linux-x86_64.tar.gz" "$NVIM_SHA" "$nvim"
if [[ ! -d $ts ]]; then
    download "https://github.com/tree-sitter/tree-sitter/releases/download/v$TS_VERSION/tree-sitter-linux-x64.gz" "$TS_SHA" "$temp/tree-sitter.gz"
    mkdir "$temp/ts"
    gzip -dc "$temp/tree-sitter.gz" >"$temp/ts/tree-sitter"
    chmod 755 "$temp/ts/tree-sitter"
    mv "$temp/ts" "$ts"
fi
[[ $("$node/bin/node" --version) == "v$NODE_VERSION" ]] || fail 'Node version mismatch.'
"$nvim/bin/nvim" --version | sed -n '1p' | grep -Fx "NVIM v$NVIM_VERSION" >/dev/null || fail 'NeoVim version mismatch.'
"$ts/tree-sitter" --version | grep -Fx "tree-sitter $TS_VERSION" >/dev/null || fail 'Tree-sitter version mismatch.'
if [[ ! -x $codex/bin/codex ]]; then
    [[ ! -e $codex ]] || fail "Partial Codex installation: remove or inspect $codex manually."
    # Official npm package, private prefix. No production Node/npm global changes.
    env -u NODE_OPTIONS PATH="$node/bin:$PATH" "$node/bin/npm" install --global \
        --prefix "$codex" --cache "$state/npm-cache" --registry=https://registry.npmjs.org \
        --no-audit --no-fund "@openai/codex@$CODEX_VERSION"
fi
env PATH="$node/bin:$PATH" "$codex/bin/codex" --version | grep -Fx "codex-cli $CODEX_VERSION" >/dev/null || fail 'Codex version mismatch.'

clone_once() {
    local url=$1 destination=$2 ref=$3
    if [[ -e $destination ]]; then
        [[ -d $destination/.git && ! -L $destination ]] || fail "Not a regular Git checkout: $destination"
        [[ $(git -C "$destination" remote get-url origin) == "$url" ]] || fail "Unexpected origin: $destination"
        printf 'Preserving existing checkout: %s\n' "$destination"
        return
    fi
    mkdir -p "$(dirname "$destination")"
    git clone --no-checkout "$url" "$destination"
    git -C "$destination" checkout --detach "$ref"
}
clone_once "$NVIM_REPO" "$HOME/.config/nvim" "$NVIM_REF"
clone_once "$PROJECT_REPO" "$HOME/dev/ShellBlocks" origin/main
git -C "$HOME/.config/nvim" merge-base --is-ancestor "$NVIM_REF" HEAD || fail 'Existing NeoVim checkout lacks the thin-mode preparation commit; update it manually.'
[[ -f $HOME/.config/nvim/lazy-lock.json ]] || fail 'NeoVim checkout lacks lazy-lock.json; update it manually.'
# Pin lazy itself before first startup; preserve any existing installation.
lazy="$HOME/.local/share/nvim/lazy/lazy.nvim"
lazy_ref=$(jq -er '."lazy.nvim".commit' "$HOME/.config/nvim/lazy-lock.json")
if [[ ! -e $lazy ]]; then
    mkdir -p "$(dirname "$lazy")"
    git clone --no-checkout https://github.com/folke/lazy.nvim.git "$lazy"
    git -C "$lazy" checkout --detach "$lazy_ref"
fi

managed_write() {
    local path=$1
    if [[ -e $path || -L $path ]]; then
        [[ ! -L $path ]] || fail "Refusing symlink: $path"
        grep -q '^# Managed by bootstrap-oracle-dev.sh$' "$path" || fail "Refusing to overwrite unmanaged file: $path"
    fi
    cat >"$path"
}

{
    printf '%s\n' '# Managed by bootstrap-oracle-dev.sh'
    # Expand PATH in the generated development shell, not during bootstrap.
    # shellcheck disable=SC2016
    printf 'export PATH=%q:"$PATH"\n' "$node/bin:$nvim/bin:$ts:$codex/bin:$bin"
    printf '%s\n' 'export NVIM_THIN=1' 'export EDITOR=nvim' 'export VISUAL=nvim'
    printf '%s\n' '# APT calls fd-find fdfind; expose fd only inside this shell.'
    printf '%s\n' 'fd() { command fdfind "$@"; }'
} | managed_write "$config/env.sh"
{
    printf '%s\n' '# Managed by bootstrap-oracle-dev.sh'
    printf '%s\n' '[[ ! -f ~/.bashrc ]] || source ~/.bashrc'
    printf 'source %q\n' "$config/env.sh"
} | managed_write "$config/bashrc"
{
    printf '%s\n' '#!/usr/bin/env bash' '# Managed by bootstrap-oracle-dev.sh' 'set -euo pipefail'
    printf 'exec /bin/bash --rcfile %q -i "$@"\n' "$config/bashrc"
} | managed_write "$bin/oracle-dev-shell"
{
    printf '%s\n' '# Managed by bootstrap-oracle-dev.sh'
    printf '%s\n' 'set -g base-index 1' 'setw -g pane-base-index 1' 'set -g renumber-windows on'
    printf '%s\n' 'set -g default-terminal "tmux-256color"' "set -as terminal-features ',xterm*:RGB'"
    printf '%s\n' 'set -s escape-time 10' 'set -g history-limit 10000' 'set -g mouse on' 'setw -g mode-keys vi'
    printf '%s\n' 'set -s set-clipboard external' 'set -s copy-command ""'
    printf 'set -g default-command "\"%s\""\n' "$bin/oracle-dev-shell"
    printf '%s\n' 'bind -T copy-mode-vi v send-keys -X begin-selection' 'bind -T copy-mode-vi y send-keys -X copy-selection-and-cancel'
    printf '%s\n' 'bind c new-window -c "#{pane_current_path}"' "bind '\"' split-window -c \"#{pane_current_path}\"" 'bind % split-window -h -c "#{pane_current_path}"'
} | managed_write "$config/tmux.conf"
{
    printf '%s\n' '#!/usr/bin/env bash' '# Managed by bootstrap-oracle-dev.sh' 'set -euo pipefail'
    printf 'exec tmux -L oracle-dev -f %q new-session -A -s shellblocks -c %q\n' "$config/tmux.conf" "$HOME/dev/ShellBlocks"
} | managed_write "$bin/oracle-dev-tmux"
chmod 755 "$bin/oracle-dev-shell" "$bin/oracle-dev-tmux"
printf '%s\n' "Prepared. Enter with: $bin/oracle-dev-tmux"
printf '%s\n' 'Then provision NeoVim plugins, authenticate Codex and validate the development checkout manually; see scripts/README.md.'
