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
        Install the launcher as ~/.local/bin/kontti on HOST (over ssh),
        and the image where the launcher there looks for it
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
    ssh $host 'mkdir -p .local/bin && cat >.local/bin/kontti.new &&
        chmod 755 .local/bin/kontti.new && mv .local/bin/kontti.new .local/bin/kontti' \
        <$dir/kontti.sh
    or return 1
    echo "Installed $host:.local/bin/kontti"
    set -l remote (ssh $host .local/bin/kontti config image)
    or return 1
    set -l q (_kontti_quote $remote)
    set -l qdir (_kontti_quote (path dirname -- $remote))
    ssh $host "mkdir -p $qdir && cat >$q.new && mv $q.new $q" <$image
    or return 1
    echo "Installed $host:$remote"
    ssh $host .local/bin/kontti exec true
    or return 1
end

function _kontti_quote --description 'Quote arguments for a POSIX shell'
    for arg in $argv
        printf "'%s'\n" "$(string replace -a "'" "'\\''" -- $arg)"
    end
end
