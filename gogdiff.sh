#!/usr/bin/env bash

set -eo pipefail

###############################
###### Logging functions ######
###############################

# stderr and stdout are sent to two processes which prepend
# tags to every line.

# The original stdout and stderr are moved to these two fds
orig_stdout=11
orig_stderr=12

error() {
    echo "$@" >&2
}

info() {
    echo "$@"
}

# Read stdin line by line and print them to stderr, prepending
# $1 and "[ERROR]" to each one.
error_stream() {
    exec >&-
    while read -r line; do
        echo "$1[ERROR]" "$line" >&2
    done
}

# Read stdin line by line and print them to stdout, prepending
# $1 and "[INFO]" to each one.
info_stream() {
    exec 2>&-
    while read -r line; do
        echo "$1[INFO]" "$line"
    done
}

# Print the arguments to stderr and exit
fatal() {
    error "$@"
    exit 1
}

# Move stderr to orig_stderr, stdout to orig_stdout,
# and reopn fds 1 and 2 connected to processes appending tags
setup_loggers() {
    eval "exec $orig_stdout>&1 $orig_stderr>&2"
    enter_tagged_logging
}

# Close stdout and stderr, then wait for logging processes to flush them
teardown_loggers() {
    exec >&- 2>&-
    wait
}

# Start logging processes, using $1 as the tag to prepend
enter_tagged_logging() {
    local tag="${1:+[$1]}"
    teardown_loggers
    exec > >(info_stream "$tag" >&$orig_stdout) 2> >(error_stream "$tag" 2>&$orig_stderr)
}


###############################
########## Utilities ##########
###############################

# Count regular files under $1
count_files() {
    find "${1:?"BUG! Missing parameter"}" -type f -printf x | wc -c
}

# Computes the MD5s of every file under folder $1, and prints them sorted by
# MD5 using NUL as the delimiter.
write_sorted_md5sums() {
    # Here, we cd to the folder first, so that paths in the MD5 lines are relative
    # to $1
    (
        cd "${1:?"BUG! Missing parameter"}"
        find . -type f -print0 | xargs -r -0 md5sum -b -z | sort -z -f -k 1,1
    )
}

# Given two files $1 and $2 produced by "md5sum -b -z" sorted by hash, compute the difference
# $1 - $2, yielding the paths (the MD5 is stripped) of files in $1 that are not present in $2.
# Paths are separated by NUL.
md5_difference() {
    : "${1:?"BUG! Missing parameter"}"
    : "${2:?"BUG! Missing parameter"}"
    join -z -i -j 1 -t ' ' -v 1 "$1" "$2" | sed -z 's/^[^*]*\*//'
}

# Given two files $1 and $2 produced by "md5sum -b -z" sorted by hash, compute their intersection,
# yielding the MD5s (paths are stripped) that appear in both files. The digests are separated by \n.
md5_intersection() {
    : "${1:?"BUG! Missing parameter"}"
    : "${2:?"BUG! Missing parameter"}"
    join -z -i -j 1 -t ' ' -o 1.1 "$1" "$2" | tr '\0' '\n' | uniq
}

# Given an MD5 $1 and a file $2 produced by "md5sum -b -z", prints all pathnames whose MD5s match $1
md5_find_all_matches() {
    : "${1:?"BUG! Missing parameter"}"
    : "${2:?"BUG! Missing parameter"}"
    sed -z -n 's/^'"$1"' \*//ip' "$2"
}

# Reads a single line from stdin and prints it to stdout, where "lines" are
# actually terminated by \0 rather than \n.  It looks trivial, but head -z -n1
# buffers its input, making it infeasible when reading from a stream, since it
# "eats" lots of lines instead of just one.
# sed with unbuffered input (-u) seems the way, we just tell it to exit after one iteration.
readline_null_terminated() {
    sed -z -u q 
}

###############################
############ Main #############
###############################

# On clean exit or signals, flush loggers
trap 'teardown_loggers' EXIT INT QUIT TERM
setup_loggers

OPTIND=1
while [ $OPTIND -le $# ]; do
    getopts ":w:l:o:c:s:" OPT
    case "$OPT" in
    w) wininstaller="$OPTARG"
       ;;
    l) linuxinstaller="$OPTARG"
       ;;
    o) outputdir="$OPTARG"
       ;;
    c) compressopts="$OPTARG"
       ;;
    s) firststep="$OPTARG"
       ;;
    *) 
        cat << EOF
$0 -w <wininst> -l <linuxinst> -o <outdir> [-c <compopts>] [-s <firststep>]

<wininst> is either the path to a GOG Windows game installer executable
or the path to a folder where such a game has already been installed (this is
where you would find "gog.ico").

<linuxinst> is either the path to a GOG Linux game installer executable or
the path to a folder where such a game has already been installed (this is
where you would find "gameinfo")

<outdir> points to a folder under which temporary games installations (if
required) are placed, plus which any files needed by this script. The final
delta script is also stored there, named gogdiff_delta.sh.

<compopts> are passed to tar when compressing Linux-only files, and also
stored in the delta script. The default is -z, which result in an gzipped tar.

<firststep> is the script step where to start. It can be used to skip
steps such as game installations, that have already been done. Steps are:
windows, linuz, digest, script.
EOF
        exit 1
       ;;
    esac
done

[ -z "$wininstaller" ] && fatal "The Windows installer file must be specified with -w"
[ -z "$linuxinstaller" ] && fatal "The Linux installer file must be specified with -l"
[ -z "$outputdir" ] && fatal "The output folder must be specified with -o"
if [ -z "$compressopts" ]; then
    compressopts="-z"
    info "Compression options were not specified, defaulting to $compressopts"
fi
if [ -z "$firststep" ]; then
    firststep="windows"
    info "The initial step was not specified, restarting from the beginning"
fi

wininstaller="$(realpath -e "$wininstaller")"
linuxinstaller="$(realpath -e "$linuxinstaller")"
outputdir="$(realpath -m "$outputdir")"
md5dir="$outputdir/digests"
script="$outputdir/gogdiff_delta.sh"
windir="$outputdir/windows"
linuxdir="$outputdir/linux"
# Folder for setup-generated files we want to throw away
junkdir="$outputdir/junk"

if [ -d "$wininstaller" ]; then
    info "The Windows installer is actually a folder: using its contents for the Windows game installation"
    wingamedir="$wininstaller"
else
    # The installer will be configured to place files in this subdir
    wingamedir="$windir/drive_c/goggame"
fi
info "Windows game files will be fetched from $wingamedir"

if [ -d "$linuxinstaller" ]; then
    info "The Linux installer is actually a folder: using its contents for the Linux game installation"
    linuxgamedir="$linuxinstaller"
else
    # The installer will be configured to place files here
    linuxgamedir="$linuxdir"
fi
info "Linux game files will be fetched from $linuxgamedir"

step_windows_installer() {
    ## Run the Windows installer
    info "Launching the Windows installer, please DON'T change the installation folder and DON'T run the game"
    rm -rf "$windir"
    mkdir -p "$windir"

    enter_tagged_logging WINDOWS
        WINEPREFIX="$windir" wine "$wininstaller" \
            /NOICONS /DIR='c:\goggame' ||
            fatal "The Windows installer failed. Aborting."
        info "Windows installer returned OK. Continuing."
    enter_tagged_logging
}

step_linux_installer() {
    info "Launching the Linux installer. Installation is fully automated."
    rm -rf "$linuxdir" "$junkdir"
    mkdir -p "$linuxdir" "$junkdir"

    # Run the Linux installer
    enter_tagged_logging LINUX
        env HOME="$junkdir" "$linuxinstaller" --noprogress -- \
            --i-agree-to-all-licenses --noreadme --nooptions \
            --noprompt --destination "$linuxdir" ||
            fatal "The Linux installer failed. Aborting."
        info "Linux installer returned OK. Continuing."
    enter_tagged_logging
}

step_compute_md5() {
    info "Now we'll look for duplicate files within the two installations."
    info "We'll need to compute the MD5 digests of all files, so this may take a while."
    info "The Windows installation contains $(count_files "$wingamedir") files"
    info "The Linux installation contains $(count_files "$linuxgamedir") files"

    rm -rf "$md5dir"
    mkdir -p "$md5dir"

    write_sorted_md5sums "$wingamedir" > "$md5dir/windows.md5"
    write_sorted_md5sums "$linuxgamedir" > "$md5dir/linux.md5"

    # Extract the pathnames of files that exists on Linux or Windows only
    md5_difference "$md5dir/windows.md5" "$md5dir/linux.md5"   > "$md5dir/windows.path"
    md5_difference "$md5dir/linux.md5"   "$md5dir/windows.md5" > "$md5dir/linux.path"
    # Extract the set of common MD5s between Linux and Windows
    md5_intersection "$md5dir/windows.md5" "$md5dir/linux.md5" > "$md5dir/common.md5"
}

step_create_script() {
    info "Creating restore script; note that compressing Linux-only files may take a while"

    {
        # Script header with helper functions
        # shellcheck disable=SC2016 # variables should be expanded in the script, not here
        printf "%s\n" '#!/bin/sh

set -e

move_file() {
    install -d "$(dirname "$2")"
    mv ${GOGDIFF_VERBOSE:+-v} -n "$1" "$2"
}

copy_file() {
    install -d "$(dirname "$2")"
    if [ -n "$GOGDIFF_NOSYMLINKS" ]; then
        cp ${GOGDIFF_VERBOSE:+-v} "$1" "$2"
    else
        ln ${GOGDIFF_VERBOSE:+-v} -s -r "$1" "$2"
    fi
}

remove_file() {
    rm ${GOGDIFF_VERBOSE:+-v} "$1"
}

extract() {
    dd skip=XXXXXXXXX iflag=skip_bytes if="$0" | tar -x '"$compressopts"' -f-
}

if [ -n "$GOGDIFF_EXTRACTONLY" ]; then
    extract
    exit
fi
'

        # Delete Windows-only files
        xargs -0 -r -I'{}' printf 'remove_file %q\n' '{}' < "$md5dir/windows.path"

        # Generate code that renames common files from their Windows name to the Linux name.
        # A file with a given MD5 may appear multiple times on both systems.
        while read -r common; do
            {
                # The first Windows pathname is simply moved to the correponding first Linux pathname
                wpath="$(readline_null_terminated <&11 | xargs -0 printf %q)"
                lpath="$(readline_null_terminated <&12 | xargs -0 printf %q)"
                # Actual moving is delayed after deleting other files with the same MD5, to avoid
                # clashes between Windows filenames to delete and the new Linux path.
                
                # All other Windows pathnames for the same MD5 are deleted
                xargs -0 -r -I'{}' printf 'remove_file %q\n' '{}' <&11

                printf 'move_file %s %s\n' "$wpath" "$lpath"

                # All other Linux pathnames for the same MD5 are symlinked or copied
                xargs -0 -r -I'{}' printf 'copy_file %s %q\n' "$lpath" '{}' <&12
            } 11< <(md5_find_all_matches "$common" "$md5dir/windows.md5") 12< <(md5_find_all_matches "$common" "$md5dir/linux.md5") 
        done < "$md5dir/common.md5"

        # Delete folders that are now empty
        printf 'find . -type d -empty -delete\n'

        # Unpack the Linux only files, which are stored in a compressed tar just after the code
        printf 'extract\n'

        # After unpacking, perform MD5 checks on the final files
        # We translate the zero-terminated format to the line-oriented escaped format, since
        # md5sum does not allow -z and -c at the same time.
        printf '%s\n' '[ -z "$GOGDIFF_SKIPDIGESTS" ] && md5sum -c << EOF'
        sed -z -E 's/\\/\\\\/g; s/\n/\\n/g; s/\r/\\r/g; s/(.*)/\\\1/' "$md5dir/linux.md5" | tr '\0' '\n'
        printf 'EOF\n'

        # Ensure we don't try to execute the tar at the end
        printf 'exit\n'
    } > "$script"

    # We are done with $script, replace the header size placeholder
    sed -i '/^\s*dd skip=/ s/XXXXXXXXX/'"$(printf %-9d "$(stat -c %s "$script")")"/ "$script"

    # Append Linux-only files
    # We should also save symlinks, as they were not hashed and do not appear in linux.path
    (
        cd "$linuxgamedir"
        { find . -type l -print0; cat "$md5dir/linux.path"; } | tar -c $compressopts --verbatim-files-from --null -T-
    ) >> "$script"

    chmod a+x "$script"
}

case "$firststep" in
windows)
    info "Starting step 'windows'"
    if [ ! -d "$wininstaller" ]; then
        step_windows_installer
    fi
    ;&
linux)
    info "Starting step 'linux'"
    if [ ! -d "$linuxinstaller" ]; then
        step_linux_installer
    fi
    ;&
digest)
    info "Starting step 'digest'"
    step_compute_md5
    ;&
script)
    info "Starting step 'script'"
    step_create_script
    ;;
esac

info "Done! You can now use $script to turn a Windows installation of this game into its Linux equivalent"
