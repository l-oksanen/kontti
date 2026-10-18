# kontti

Run Claude Code in an [apptainer](https://apptainer.org) container that
sees only its own home directory: for hosts shared with others, such as
an HPC cluster, where files of other users may be writable by anyone,
and where Claude Code would otherwise run with all your files and
credentials.

The container's home is a directory of the host, `~/claude` by default,
mounted at the same path. Nothing else of the host is visible: not your
home, not the site's own binds (`/scratch`, `/projappl`, ...), not your
environment (`SSH_AUTH_SOCK` among it). The network is open, as Claude
Code needs its API. Claude Code, its login and the toolchains (e.g.
elan) live in the home, and Claude Code updates itself there.

A fish package (fisher layout): `kontti build` and `kontti install` run
on your machine; the launcher `kontti.sh` is POSIX sh, so the host
needs only apptainer.

## Install

```fish
fisher install l-oksanen/kontti
```

Building needs apptainer with `--fakeroot` (unprivileged; Ubuntu:
`ppa:apptainer/ppa`, and a range in `/etc/subuid`, added with `sudo
apptainer config fakeroot --add $USER`).

## Use

```fish
kontti build          # the image, from kontti.def
kontti install HOST   # ~/bin/kontti and ~/images/kontti.sif on HOST, over ssh
```

On the host (`~/bin/kontti`, unless `~/bin` is on `PATH`):

```sh
kontti claude [ARG...]      # Claude Code, installed at the first run
kontti shell                # bash, e.g. to install toolchains
kontti exec COMMAND [ARG...]
kontti config               # the settings
```

The working directory is the current one if it is inside the home, the
home otherwise. `/tmp` is `${TMPDIR:-/tmp}/kontti-$USER` of the host.
The settings, with their defaults, can be changed in
`~/.config/kontti/config` of each machine (`~/` allowed):

```
home=~/claude
image=~/.local/share/kontti/kontti.sif
```

The image is in `$XDG_DATA_HOME` if that is set. `kontti install` makes
`~/images/kontti.sif` the default image of the launcher on the host.
`kontti build` writes the image where the local launcher looks for it,
`kontti install` where the launcher on the host does.
The launcher and the image stay outside the home, where Claude could
change them.

## Git in the home

Run git in a repo of the home only inside the container (`kontti exec
git ...`). A repo can make git run commands (`core.fsmonitor`,
`core.pager`, hooks); git run on the host would run them outside the
container. The same goes for pushing into a repo of the home over ssh,
which runs its hooks: give git the launcher, and the absolute path,
which is the same inside and outside:

```sh
git push --receive-pack='bin/kontti exec git-receive-pack' HOST:/home/me/claude/work/repo ...
git fetch --upload-pack='bin/kontti exec git-upload-pack' HOST:/home/me/claude/work/repo ...
```

## Checking a new host

1. `kontti install HOST` (here), then on the host `kontti exec ls / ~ /scratch /appl`:
   `/` lists only the image, `~` is the home, and the site's directories
   are missing. A site may forbid `--no-mount bind-paths`; then kontti
   fails, and must not be used there as it is.
2. `kontti claude`: installs Claude Code; log in with the URL it prints.
3. `kontti exec git config --global user.name ...` (and `user.email`)
   for Claude's commits.
4. Sessions that outlive the connection: `tmux new -A -s NAME 'kontti
   claude'` on the host. On a cluster, long sessions may have to run in
   a job, e.g. `srun --pty ... kontti claude` inside tmux: check that
   apptainer and the network work on the compute nodes.
5. Hooks stay inside: in a repo of the home, a `post-receive` hook that
   writes a file outside the home must fail when pushed to as above.
