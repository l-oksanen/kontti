function kontti
    argparse --stop-nonopt h/help -- $argv
    or return 1
    if set -q _flag_help
        _kontti_help
        return
    end
    set -l dir (status dirname)
    switch "$argv[1]"
        case build
            if set -q argv[2]
                echo 'Usage: kontti build' >&2
                return 1
            end
            _kontti_build $dir
        case install
            if test (count $argv) -ne 2
                echo 'Usage: kontti install HOST' >&2
                return 1
            end
            _kontti_install $dir $argv[2]
        case claude shell exec config
            sh $dir/kontti.sh $argv
        case '*'
            _kontti_help >&2
            return 1
    end
end

function _kontti_help
    echo 'Build and install the container of kontti, and run its launcher

USAGE
    kontti build
        Build the image from kontti.def, where the launcher here looks
        for it
    kontti install HOST
        Install the launcher as ~/bin/kontti on HOST (over ssh), with
        ~/images/kontti.sif as its default image, and the image where
        the launcher there looks for it; also the git identity of
        Claude and the terminfo entry of $TERM, if missing there
    kontti claude | shell | exec | config ...
        Run the launcher here

The launcher (kontti.sh, POSIX sh):
'
    sh (status dirname)/kontti.sh --help
end

function _kontti_build --argument-names dir
    set -l image (sh $dir/kontti.sh config image)
    or return 1
    mkdir -p (path dirname -- $image)
    or return 1
    # Built next to the image and renamed: running containers keep the
    # old one
    apptainer build --force --fakeroot $image.new $dir/kontti.def
    and mv $image.new $image
    or begin
        rm -f $image.new
        return 1
    end
    echo "Built $image"
end

function _kontti_install --argument-names dir host
    set -l image (sh $dir/kontti.sh config image)
    or return 1
    if not test -f $image
        echo "kontti: no image $image (kontti build)" >&2
        return 2
    end
    _kontti_launcher $dir | ssh $host 'mkdir -p bin && cat >bin/kontti.new &&
        chmod 755 bin/kontti.new && mv bin/kontti.new bin/kontti'
    if test "$pipestatus" != '0 0'
        return 1
    end
    echo "Installed $host:bin/kontti"
    set -l remote (ssh $host bin/kontti config image)
    or return 1
    set -l q (_kontti_quote $remote)
    set -l qdir (_kontti_quote (path dirname -- $remote))
    set -l sum (sha256sum <$image | string split -f 1 ' ')
    if test "$(ssh $host "sha256sum $q 2>/dev/null" | string split -f 1 ' ')" = $sum
        echo "$host:$remote is up to date"
    else
        ssh $host "mkdir -p $qdir && cat >$q.new && mv $q.new $q" <$image
        or return 1
        echo "Installed $host:$remote"
    end

    # tmux and other ncurses programs of the host refuse a terminal they
    # have no entry for (kitty's xterm-kitty, say)
    if set -q TERM[1]; and set -l entry (infocmp -x $TERM 2>/dev/null | string collect)
        echo $entry | ssh $host sh -c (_kontti_quote '
            if infocmp "$1" >/dev/null 2>&1; then
                cat >/dev/null
            else
                # tic warns about entries that it installs well enough
                t=$(mktemp) && cat >"$t" && tic -x -o ~/.terminfo "$t" 2>"$t.err" &&
                    echo "Installed the terminfo entry of $1 in ~/.terminfo"
                s=$?
                [ $s -eq 0 ] || cat "$t.err" >&2
                rm -f "$t" "$t.err"
                exit $s
            fi' | string collect) sh (_kontti_quote $TERM)
        or return 1
    end

    # The identity of Claude's commits, unless one is set
    ssh $host bin/kontti exec sh -c (_kontti_quote '
        git config --global user.name >/dev/null ||
            git config --global user.name Claude || exit 1
        git config --global user.email >/dev/null ||
            git config --global user.email noreply@anthropic.com' | string collect)
    or return 1
end

function _kontti_launcher --argument-names dir
    # The launcher for a host, whose default image is ~/images/kontti.sif
    if test (string match -r -- '^image=' <$dir/kontti.sh | count) -ne 1
        echo "kontti: $dir/kontti.sh has not one line image=" >&2
        return 1
    end
    string replace -r -- '^image=.*' 'image=~/images/kontti.sif' <$dir/kontti.sh
end

function _kontti_quote --description 'Quote arguments for a POSIX shell'
    # One line per argument: an argument with newlines needs string collect
    for arg in $argv
        printf "'%s'\n" "$(string replace -a "'" "'\\''" -- $arg)"
    end
end
