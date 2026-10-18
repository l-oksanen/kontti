#!/bin/sh
# kontti: run Claude Code in an apptainer container that sees only its
# own home directory. Installed as ~/bin/kontti by `kontti install
# HOST`; POSIX sh, so that the host needs no fish.

usage() {
    cat <<'EOF'
Run Claude Code in a container that sees only its own home directory

USAGE
    kontti claude [ARG...]
        Claude Code, installed into the home first if missing
    kontti shell
        bash
    kontti exec COMMAND [ARG...]
        COMMAND
    kontti config [home | image]
        Print the settings (home and image), or one of them

The container's home is a directory of the host (default ~/claude),
mounted at the same path; nothing else of the host is visible, nor its
environment. The working directory is the current one if it is in the
home, the home otherwise. /tmp is ${TMPDIR:-/tmp}/kontti-$USER of the
host, shared by the containers of the user.

Settings, in ${XDG_CONFIG_HOME:-~/.config}/kontti/config, lines NAME=VALUE
(a leading ~/ is the home of the host):
    home=~/claude
    image=${XDG_DATA_HOME:-~/.local/share}/kontti/kontti.sif
`kontti install` makes ~/images/kontti.sif the default image on the
host.
EOF
}

die() {
    echo "kontti: $*" >&2
    exit 1
}

usage_error() {
    echo "Usage: $*" >&2
    exit 1
}

# kontti install replaces the line of image
home=~/claude
image=${XDG_DATA_HOME:-$HOME/.local/share}/kontti/kontti.sif
config=${XDG_CONFIG_HOME:-$HOME/.config}/kontti/config
if [ -f "$config" ]; then
    while IFS='=' read -r name value; do
        case $value in
            '~/'*) value=$HOME/${value#'~/'} ;;
        esac
        case $name in
            home) home=$value ;;
            image) image=$value ;;
            '' | '#'*) ;;
            *) die "unknown setting '$name' in $config" ;;
        esac
    done <"$config"
fi

case $1 in
    -h | --help)
        usage
        exit 0
        ;;
    config)
        case $#:$2 in
            1:) printf 'home=%s\nimage=%s\n' "$home" "$image" ;;
            2:home) printf '%s\n' "$home" ;;
            2:image) printf '%s\n' "$image" ;;
            *) usage_error 'kontti config [home | image]' ;;
        esac
        exit 0
        ;;
    claude) ;;
    shell) [ $# -eq 1 ] || usage_error 'kontti shell' ;;
    exec) [ $# -ge 2 ] || usage_error 'kontti exec COMMAND [ARG...]' ;;
    *)
        usage >&2
        exit 1
        ;;
esac
command=$1
shift

if [ ! -f "$image" ]; then
    echo "kontti: no image $image" >&2
    exit 2
fi
command -v apptainer >/dev/null || die 'apptainer not found'

# Others may share the host: the home holds Claude Code's login
mkdir -p "$home" || exit 1
chmod 700 "$home" || exit 1
# Symlinks resolved, so that the working directory can be compared
home=$(cd "$home" && pwd -P) || exit 1
case $home/ in
    /tmp/* | /var/tmp/*) die "the home $home would be hidden by the container's /tmp" ;;
esac

# A name others can guess: they could create it first, or as a symlink
tmp=${TMPDIR:-/tmp}/kontti-$(id -un)
mkdir -m 700 "$tmp" 2>/dev/null
if [ -L "$tmp" ] || [ ! -d "$tmp" ] || [ ! -O "$tmp" ]; then
    die "$tmp is not a directory of mine"
fi
chmod 700 "$tmp" || exit 1

here=$(pwd -P)
case $here/ in
    "$home"/*) ;;
    *) here=$home ;;
esac

# Replaces the shell: in a subshell for anything but the last command
# --no-mount bind-paths drops the site's binds, and with them the name
# resolution and time zone files that apptainer would otherwise copy in
container() {
    exec apptainer exec --containall --no-mount bind-paths \
        --bind /etc/resolv.conf:/etc/resolv.conf:ro,/etc/hosts:/etc/hosts:ro,/etc/localtime:/etc/localtime:ro \
        --home "$home" --workdir "$tmp" ${COLORTERM:+--env "COLORTERM=$COLORTERM"} "$@"
}
case $command in
    claude)
        if [ ! -x "$home/.local/bin/claude" ]; then
            echo 'kontti: installing Claude Code into the home' >&2
            (container --pwd "$home" "$image" sh -c 'curl -fsSL https://claude.ai/install.sh | bash') ||
                exit 1
        fi
        # The image's environment puts ~/.local/bin on PATH
        container --pwd "$here" "$image" claude "$@"
        ;;
    shell) container --pwd "$here" "$image" bash ;;
    exec) container --pwd "$here" "$image" "$@" ;;
esac
