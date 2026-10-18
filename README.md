# kontti

Run Claude Code in an [apptainer](https://apptainer.org) container that
sees only its own home directory: for hosts shared with others, such as
an HPC cluster, where files of other users may be writable by anyone,
and where Claude Code would otherwise run with all your files and
credentials.

The container's home is a directory of the host, `~/claude` by default,
mounted at the same path. Nothing else of the host is visible: not your
home, not the site's own binds (`/scratch`, `/projappl`, ...), not your
environment (`SSH_AUTH_SOCK` among it; only `TERM`, `COLORTERM`, the
proxy settings, `LEAN_NUM_THREADS` and the job information of Slurm
`SLURM_JOB_ID`, `SLURM_CPUS_PER_TASK`, `SLURM_MEM_PER_NODE`,
`SLURM_JOB_END_TIME` pass: Lean would count the cores of the node, not
of the allocation, without `LEAN_NUM_THREADS`). The network is open, as Claude
Code needs its API. Claude Code, its login and the toolchains live in
the home, and Claude Code updates itself there. The image has elan (the
Lean toolchain manager; new versions come with a new image), which
installs the toolchain a project names in `lean-toolchain` into
`~/.elan` of the home when it is first used: about 3 GB per Lean
version. Likewise uv for Python: `uv sync` installs the Python of
`requires-python` (`.python-version`) into the home and the project's
dependencies into its `.venv`. `examples/` has a Hello world of each.

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
`kontti install` also gives Claude's commits an identity (`Claude
<noreply@anthropic.com>`, unless the home has one), copies the
terminfo entry of `$TERM` into `~/.terminfo` of the host if the host
lacks it (tmux refuses a terminal it does not know, e.g. kitty's), and
skips the image if the host has the same one.
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

1. `kontti install HOST` (here), then on the host `kontti exec sh -c
   'ls / ~ /home/$USER; env'`: `/` lists only the image, `~` is the
   home, the directory above it holds only the home, and the
   environment has nothing of the host's (no `SSH_*`, no work or
   project directories). Look for the site's own directories too
   (CSC: `/scratch`, `/projappl`; Turso: `/wrk*`, `/proj*`): they must
   be missing. A site may forbid `--no-mount bind-paths`; then kontti
   fails, and must not be used there as it is.
2. `kontti claude` in a directory under the home (Claude Code asks for
   trust in the home itself at every start): installs Claude Code; log
   in with the URL it prints.
3. Sessions that outlive the connection: tmux on the host, e.g. `tmux
   new -A -s NAME 'kontti claude'`. On a cluster, long sessions may have
   to run in a job: tmux on the login node, and in it e.g. `srun --pty
   ... kontti claude`. Check that apptainer and the network work on the
   compute nodes; proxy settings (`http_proxy` and the like, e.g. from a
   module) reach the container. For 24-bit colours in tmux, tmux must
   know that the terminal takes them, and Claude Code needs
   `COLORTERM=truecolor` (ssh does not pass it), e.g. in `~/.tmux.conf`
   of the host (here for kitty; `mouse` scrolls with the wheel):

   ```
   set -sa terminal-overrides ',xterm-kitty:Tc'
   set-environment -g COLORTERM truecolor
   set -g mouse on
   ```
4. Hooks stay inside: in a repo of the home, a `post-receive` hook that
   writes a file outside the home must fail when pushed to as above.
   Check on the host, not in the hook's output: inside the container,
   the directories above the home are scratch directories of apptainer.
