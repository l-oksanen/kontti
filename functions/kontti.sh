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
    kontti config [home | image | network]
        Print the settings, or one of them

The container's home is a directory of the host (default ~/claude),
mounted at the same path; nothing else of the host is visible, nor its
environment, but TERM, COLORTERM, LEAN_NUM_THREADS and the job's
SLURM_JOB_ID, SLURM_CPUS_PER_TASK, SLURM_MEM_PER_NODE and
SLURM_JOB_END_TIME. The working directory is the current one if it is in the
home, the home otherwise. /tmp is ${TMPDIR:-/tmp}/kontti-$USER of the
host, shared by the containers of the user.

The network:
    isolated  The container has only a loopback of its own, and reaches
              the internet through a proxy that the launcher runs
              (http_proxy, https_proxy), which connects to public
              addresses only: not to the services of the host, nor to
              its sockets (X, D-Bus, kitty), which let in any process of
              the user. Needs python3 on the host.
    host      The network of the host, and its proxy settings.

Settings, in ${XDG_CONFIG_HOME:-~/.config}/kontti/config, lines NAME=VALUE
(a leading ~/ is the home of the host):
    home=~/claude
    image=${XDG_DATA_HOME:-~/.local/share}/kontti/kontti.sif
    network=isolated
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
network=isolated
config=${XDG_CONFIG_HOME:-$HOME/.config}/kontti/config
if [ -f "$config" ]; then
    while IFS='=' read -r name value; do
        case $value in
            '~/'*) value=$HOME/${value#'~/'} ;;
        esac
        case $name in
            home) home=$value ;;
            image) image=$value ;;
            network) network=$value ;;
            '' | '#'*) ;;
            *) die "unknown setting '$name' in $config" ;;
        esac
    done <"$config"
fi
case $network in
    isolated | host) ;;
    *) die "network is isolated or host, not '$network' (in $config)" ;;
esac

case $1 in
    -h | --help)
        usage
        exit 0
        ;;
    config)
        case $#:$2 in
            1:) printf 'home=%s\nimage=%s\nnetwork=%s\n' "$home" "$image" "$network" ;;
            2:home) printf '%s\n' "$home" ;;
            2:image) printf '%s\n' "$image" ;;
            2:network) printf '%s\n' "$network" ;;
            *) usage_error 'kontti config [home | image | network]' ;;
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

# Passed into the clean environment, if set: values without commas.
# Lean counts the cores of the node, not of a Slurm allocation, unless
# LEAN_NUM_THREADS says otherwise.
env=
for name in COLORTERM LEAN_NUM_THREADS SLURM_JOB_ID SLURM_CPUS_PER_TASK \
    SLURM_MEM_PER_NODE SLURM_JOB_END_TIME; do
    eval "value=\${$name-}"
    [ -n "$value" ] && env=$env${env:+,}$name=$value
done

# The proxy of network=isolated, on a Unix socket: CONNECT, and plain
# HTTP with absolute URLs. A name is refused if any of its addresses is
# not public, and the connection goes to an address checked, so that a
# name cannot resolve to a public address for the check and to a local
# one for the connection.
proxy=$(
    cat <<'EOF'
import asyncio, ipaddress, socket, sys, urllib.parse

class Refused(Exception):
    pass

class Unreachable(Exception):
    pass

async def open_public(host, port):
    try:
        infos = await asyncio.get_running_loop().getaddrinfo(
            host, port, type=socket.SOCK_STREAM)
    except OSError:
        raise Unreachable(f'cannot resolve {host}')
    for info in infos:
        ip = ipaddress.ip_address(info[4][0].split('%')[0])
        if not ip.is_global:
            raise Refused(f'{host} is not a public address ({ip})')
    error = None
    for info in infos:
        try:
            return await asyncio.open_connection(info[4][0], info[4][1])
        except OSError as e:
            error = e
    raise Unreachable(f'cannot connect to {host}: {error}')

async def respond(writer, code, reason, text):
    body = f'kontti: {text}\n'.encode()
    writer.write(f'HTTP/1.1 {code} {reason}\r\nContent-Type: text/plain\r\n'
                 f'Content-Length: {len(body)}\r\nConnection: close\r\n\r\n'
                 .encode() + body)
    await writer.drain()

async def pipe(reader, writer):
    try:
        while data := await reader.read(65536):
            writer.write(data)
            await writer.drain()
        if writer.can_write_eof():
            writer.write_eof()
    except OSError:
        pass

async def handle(reader, writer):
    upstream = None
    try:
        try:
            head = await reader.readuntil(b'\r\n\r\n')
        except (asyncio.IncompleteReadError, asyncio.LimitOverrunError):
            return
        line, _, fields = head[:-4].partition(b'\r\n')
        try:
            method, target, version = line.decode('latin-1').split(' ')
            if method == 'CONNECT':
                host, _, port = target.rpartition(':')
                host, port = host.strip('[]'), int(port)
            else:
                url = urllib.parse.urlsplit(target)
                if url.scheme != 'http' or not url.hostname:
                    raise ValueError
                host, port = url.hostname, url.port or 80
        except ValueError:
            await respond(writer, 400, 'Bad Request',
                          'only CONNECT and http:// URLs')
            return
        upstream = await open_public(host, port)
        if method == 'CONNECT':
            writer.write(b'HTTP/1.1 200 Connection established\r\n\r\n')
        else:
            # One request per connection: the next could be for another host
            path = url.path or '/'
            if url.query:
                path += '?' + url.query
            kept = [f + b'\r\n' for f in fields.split(b'\r\n') if f and not
                    f.lower().startswith((b'proxy-', b'connection:', b'keep-alive:'))]
            upstream[1].write(f'{method} {path} {version}\r\n'.encode('latin-1')
                              + b''.join(kept) + b'Connection: close\r\n\r\n')
        await asyncio.gather(pipe(reader, upstream[1]), pipe(upstream[0], writer))
    except Refused as e:
        await respond(writer, 403, 'Forbidden', str(e))
    except Unreachable as e:
        await respond(writer, 502, 'Bad Gateway', str(e))
    except OSError:
        pass
    finally:
        writer.close()
        if upstream:
            upstream[1].close()

async def main(path):
    server = await asyncio.start_unix_server(handle, path, limit=65536)
    async with server:
        await server.serve_forever()

asyncio.run(main(sys.argv[1]))
EOF
)

# Inside, from the port of the proxy settings to the proxy, before the
# command
forward='socat TCP-LISTEN:3128,bind=127.0.0.1,reuseaddr,fork UNIX-CONNECT:/run/kontti/proxy.sock 2>/dev/null &
i=0
until grep -q "^ *[0-9]*: 0100007F:0C38 00000000:0000 0A" /proc/net/tcp; do
    i=$((i + 1))
    [ $i -le 100 ] || { echo "kontti: the forwarder to the proxy did not start" >&2; exit 1; }
    sleep 0.05
done
exec "$@"'

if [ $network = isolated ]; then
    command -v python3 >/dev/null || die 'python3 not found (needed by network=isolated)'
    # Not in the home nor in $tmp, which the container sees: Claude
    # could put a socket of its own in the place of the proxy's
    net=$(mktemp -d "${TMPDIR:-/tmp}/kontti-net.XXXXXX") || exit 1
    proxy_pid=
    trap 'kill $proxy_pid 2>/dev/null; rm -rf "$net"' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    trap 'exit 129' HUP
    python3 -c "$proxy" "$net/proxy.sock" </dev/null 2>"$net/proxy.log" &
    proxy_pid=$!
    i=0
    while [ ! -S "$net/proxy.sock" ]; do
        if ! kill -0 $proxy_pid 2>/dev/null || [ $i -ge 100 ]; then
            cat "$net/proxy.log" >&2
            die 'the proxy did not start'
        fi
        i=$((i + 1))
        sleep 0.05
    done
    # The host's proxy settings would pass otherwise; no_proxy has commas,
    # which --env does not take
    for name in http_proxy https_proxy HTTP_PROXY HTTPS_PROXY; do
        echo "$name=http://127.0.0.1:3128"
    done >"$net/env"
    for name in no_proxy NO_PROXY; do
        echo "$name=localhost,127.0.0.1,::1"
    done >>"$net/env"
fi

# --no-mount bind-paths drops the site's binds, and with them the name
# resolution and time zone files that apptainer would otherwise copy in
container() {
    dir=$1
    shift
    set -- --containall --no-mount bind-paths \
        --bind /etc/resolv.conf:/etc/resolv.conf:ro,/etc/hosts:/etc/hosts:ro,/etc/localtime:/etc/localtime:ro \
        --home "$home" --workdir "$tmp" ${env:+--env "$env"} --pwd "$dir" "$@"
    if [ $network = isolated ]; then
        apptainer exec --net --network none --bind "$net:/run/kontti:ro" \
            --env-file "$net/env" "$@"
    else
        apptainer exec "$@"
    fi
}
# The command, after the image
run() {
    dir=$1
    shift
    if [ $network = isolated ]; then
        container "$dir" "$image" sh -c "$forward" kontti "$@"
    else
        container "$dir" "$image" "$@"
    fi
}
case $command in
    claude)
        if [ ! -x "$home/.local/bin/claude" ]; then
            echo 'kontti: installing Claude Code into the home' >&2
            run "$home" sh -c 'curl -fsSL https://claude.ai/install.sh | bash' || exit 1
        fi
        # The image's environment puts ~/.local/bin on PATH
        run "$here" claude "$@"
        ;;
    shell) run "$here" bash ;;
    exec) run "$here" "$@" ;;
esac
