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
        the launcher there looks for it
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
    ssh $host "mkdir -p $qdir && cat >$q.new && mv $q.new $q" <$image
    or return 1
    echo "Installed $host:$remote"
    ssh $host bin/kontti exec true
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
    for arg in $argv
        printf "'%s'\n" "$(string replace -a "'" "'\\''" -- $arg)"
    end
end
