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
    exit_code="$1"
    shift
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
######### Error codes #########
###############################
declare -r ERR_BADCLI=2
declare -r ERR_WININSTFAILED=3
declare -r ERR_LINUXINSTFAILED=4
declare -r ERR_NOCOMMONFILES=5
declare -r ERR_ALLCOMMONFILES=6

###############################
########## Utilities ##########
###############################

# Placeholder for delta script header size. Will be replaced by the mount of
# script data before the compressed archive. Must be at leass as long as the decimal
# representation of the size of header code.
declare -r size_placeholder=XXXXXXXXX

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
    sed -z -u q | tr -d '\0'
    printf '\n'
}

###############################
############ Main #############
###############################

# Override exit codes for terminations caused by set -e to 1, while allowing us
# to return specific codes for specific errors.
exit_code=1
clean_signal() {
    set +e
    [ -n "$outputsymlink" ] && rm -f "$outputsymlink"
    teardown_loggers
}

clean_exit() {
    clean_signal
    exit "$exit_code"
}

trap 'clean_exit' EXIT
trap 'clean_signal' INT QUIT TERM
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

[ -z "$wininstaller" ] && fatal $ERR_BADCLI "The Windows installer file must be specified with -w"
[ -z "$linuxinstaller" ] && fatal $ERR_BADCLI "The Linux installer file must be specified with -l"
[ -z "$outputdir" ] && fatal $ERR_BADCLI "The output folder must be specified with -o"
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
# Important rules:
# folder base names should only contains chars that can go in a sed
# basic regexp unescaped, so avoid things like dots. This rule does not apply to files.
md5dir="$outputdir/digests"
patchdir="$outputdir/patches"
windir="$outputdir/windows"
linuxdir="$outputdir/linux"
junkdir="$outputdir/junk"
script="$outputdir/gogdiff_delta.sh"
# The Linux installer doesn't like spaces in the destination folder path, so
# we create a symlink under /tmp that points to the installation directory and
# remove it on exit. The link should again be usable in a sed expression without escaping.
outputsymlink="$(mktemp -p /tmp tmpXXXXXXXXXX)"
ln -sf "$outputdir" "$outputsymlink"
# Folder for setup-generated files we want to throw away
junksymlink="$outputsymlink/$(basename "$junkdir")"
linuxsymlink="$outputsymlink/$(basename "$linuxdir")"
patchsymlink="$outputsymlink/$(basename "$patchdir")"

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
        WINEPREFIX="$windir" WINEDLLOVERRIDES=winemenubuilder.exe=d wine "$wininstaller" \
            /NOICONS /DIR='c:\goggame' ||
            fatal $ERR_WININSTFAILED "The Windows installer failed. Aborting."
        info "Windows installer returned OK. Continuing."
    enter_tagged_logging
}

step_linux_installer() {
    info "Launching the Linux installer. Installation is fully automated."
    rm -rf "$linuxdir" "$junkdir"
    mkdir -p "$linuxdir" "$junkdir"

    # Run the Linux installer
    enter_tagged_logging LINUX
        env HOME="$junksymlink" "$linuxinstaller" --noprogress -- \
            --i-agree-to-all-licenses --noreadme --nooptions \
            --noprompt --destination "$linuxsymlink" ||
            fatal $ERR_LINUXINSTFAILED "The Linux installer failed. Aborting."
        info "Linux installer returned OK. Continuing."
    enter_tagged_logging
}

step_compute_md5() {
    info "Now we'll look for duplicate files within the two installations."
    info "We'll need to compute the MD5 digests of all files, so this may take a while."
    info "The Windows installation contains $(count_files "$wingamedir") files"
    info "The Linux installation contains $(count_files "$linuxgamedir") files"

    rm -rf "$md5dir" "$patchdir"
    mkdir -p "$md5dir" "$patchdir"

    write_sorted_md5sums "$wingamedir" > "$md5dir/windows.md5"
    write_sorted_md5sums "$linuxgamedir" > "$md5dir/linux.md5"

    # Extract the pathnames of files that exists on Linux or Windows only
    md5_difference "$md5dir/windows.md5" "$md5dir/linux.md5"   > "$md5dir/windows.path"
    md5_difference "$md5dir/linux.md5"   "$md5dir/windows.md5" > "$md5dir/linux.path"
    # Extract the set of common MD5s between Linux and Windows
    md5_intersection "$md5dir/windows.md5" "$md5dir/linux.md5" > "$md5dir/common.md5"

    # Look for file with the same basename, which could be used to compute patches with
    # xdelta3
    local npatch
    npatch=0
    : > "$md5dir/wpatches.path"
    : > "$md5dir/lpatches.path"
    printf '%s\0' "$linuxpath" >> "$md5dir/lpatches.path"
    while :; do
        base="$(readline_null_terminated)"
        [ -z "$base" ] && break
        npatch=$((npatch + 1))
        (
            cd "$wingamedir"
            winpath="$(find . -type f -name "$base" -print0 | readline_null_terminated)"
            cd "$linuxgamedir"
            linuxpath="$(find . -type f -name "$base" -print0 | readline_null_terminated)"
            install -d "$(dirname "$patchdir/$linuxpath")"
            xdelta3 -e -s "$wingamedir/$winpath" "$linuxgamedir/$linuxpath" "$patchdir/$linuxpath"

            # Save the paths of patched files to a file. It will be used to track which files do not need
            # to be stored in the delta archive.
            printf '%s\0' "$winpath" >> "$md5dir/wpatches.path"
            printf '%s\0' "$linuxpath" >> "$md5dir/lpatches.path"
        )
    done < <( sort -z /proc/self/fd/10 /proc/self/fd/11 \
        10< <(sed -z 's|^.*/||' "$md5dir/windows.path" | sort -zu) \
        11< <(sed -z 's|^.*/||' "$md5dir/linux.path" | sort -zu) |
        uniq -zd)

    # Let's filter some corner cases that make a delta script useless.
    # We don't want to go head if:
    #  1) the two folders are identical: clearly there is no advantage is a script
    #     that has nothing to add, remove or just rename;
    #  2) no files are common or patchable: we have just two completely unrelated folders
    #     and can just keep their installers
    local ncommon
    ncommon="$(wc -l "$md5dir/common.md5" | cut -d ' ' -f 1)"
    info "There are $ncommon common files between the two game releases and $npatch patchable files."
    [ "$ncommon" -eq 0 -a "$npatch" -eq 0 ] && fatal $ERR_NOCOMMONFILES "Not producing a delta script with no common or patchable files."
    if cmp -s "$md5dir/windows.md5" "$md5dir/linux.md5"; then
        fatal $ERR_ALLCOMMONFILES "The folders are identical! You don't need a delta script."
    fi
}

step_create_script() {
    info "Creating restore script; note that compressing Linux-only files may take a while"

    # Create a temporary directory name that is unique in both $wingamedir and $linuxgamedir
    local stagingdir
    while [ -e "$linuxgamedir/$stagingdir" ]; do
        stagingdir="$(basename "$(mktemp -d -q -u -p "$wingamedir")")"
    done
    escstagingdir="$(printf %q "$stagingdir")"

    # Create a temporary directory name that is unique in both $wingamedir and $linuxgamedir
    local stagingpatchdir
    while [ -e "$linuxgamedir/$stagingpatchdir" ]; do
        stagingpatchdir="$(basename "$(mktemp -d -q -u -p "$wingamedir")")"
    done
    escstagingpatchdir="$(printf %q "$stagingpatchdir")"

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
    local workdir
    workdir="$1"
    dd skip='"$size_placeholder"' iflag=skip_bytes if="$0" status=none |
        tar -x ${GOGDIFF_VERBOSE:+-v} ${workdir:+-C "$workdir"} '"$compressopts"' -f-
}

verify() {
    if [ -z "$GOGDIFF_VERBOSE" ]; then
        md5sum -c --quiet
    else
        md5sum -c
    fi
}

patch_file() {
    install -d '"$escstagingpatchdir"'/"$(dirname "$2")"
    xdelta3 -d -s "$1" '"$escstagingdir"'/"$2" '"$escstagingpatchdir"'/"$2"
}

if [ -n "$GOGDIFF_EXTRACTONLY" ]; then
    extract
    exit
fi

mkdir -p '"$escstagingdir"'
mkdir -p '"$escstagingpatchdir"'
'


        # Generate code that renames common files from their Windows name to the Linux name.
        # A file with a given MD5 may appear multiple times on both systems.
        local wpath
        local lpath
        while read -r common; do
            {
                # The first Windows pathname is simply moved to the correponding first Linux pathname
                wpath="$(readline_null_terminated <&11)"
                lpath="$(readline_null_terminated <&12)"
                printf 'move_file %q %q/%q\n' "$wpath" "$stagingdir" "$lpath"
                
                # All other Windows pathnames for the same MD5 are deleted
                xargs -0 -r -I'{}' printf 'remove_file %q\n' '{}' <&11

                # All other Linux pathnames for the same MD5 are symlinked or copied
                xargs -0 -r -I'{}' printf 'copy_file %q/%q %q/%q\n' "$stagingdir" "$lpath" "$stagingdir" '{}' <&12
            } 11< <(md5_find_all_matches "$common" "$md5dir/windows.md5") 12< <(md5_find_all_matches "$common" "$md5dir/linux.md5") 
        done < "$md5dir/common.md5"

        # Unpack the Linux only files, which are stored in a compressed tar just after the code
        # They are placed into the staging directory
        printf 'extract %q\n' "$stagingdir"

        while :; do
            wpath="$(readline_null_terminated <&11)"
            lpath="$(readline_null_terminated <&12)"
            [ -z "$wpath" ] && break
            printf 'patch_file %q %q\n' "$wpath" "$lpath"
        done 11< "$md5dir/wpatches.path" 12< "$md5dir/lpatches.path" 

        # Delete Windows-only files
        xargs -0 -r -I'{}' printf 'remove_file %q\n' '{}' < "$md5dir/windows.path"

        # Delete folders that are now empty
        printf 'find . -type d -empty -delete\n'

        # Move files from the staging patch directory to the PWD, since there can no longer be conflicts
        printf '(cd %q; find . -mindepth 1 -maxdepth 1 -print0 | xargs -I"{}" -0 -r mv -t .. "{}")\n' "$stagingdir"
        printf 'rm ${GOGDIFF_VERBOSE:+-v} -rf %q\n' "$stagingdir" 

        # Move files from the staging patch directory to the PWD, overwriting the patches with the same names
        # Here we take advantage of the fact that the target file already exists.
        printf '(cd %q; find . -type f -print0 | xargs -I"{}" -0 -r mv "{}" "../{}")\n' "$stagingpatchdir"
        printf 'rm ${GOGDIFF_VERBOSE:+-v} -rf %q\n' "$stagingpatchdir" 

        # After unpacking, perform MD5 checks on the final files
        # We translate the zero-terminated format to the line-oriented escaped format, since
        # md5sum does not allow -z and -c at the same time.
        # shellcheck disable=SC2016 # variables should be expanded in the script, not here
        printf '%s\n' '[ -z "$GOGDIFF_SKIPDIGESTS" ] && verify << EOF'
        sed -z -E '/[\n\r]/ { s/\\/\\\\/g; s/\n/\\n/g; s/\r/\\r/g; s/(.*)/\\\1/; }' "$md5dir/linux.md5" | tr '\0' '\n'
        printf 'EOF\n'

        # Ensure we don't try to execute the tar at the end
        printf 'exit\n'
    } > "$script"

    # We are done with $script, replace the header size placeholder
    sed -i '/^\s*dd skip=/ s/'"$size_placeholder"/"$(printf %-${#size_placeholder}d "$(stat -c %s "$script")")"/ "$script"

    # Append Linux-only files and patches while skipping the files from which the patches were made
    # We should also save symlinks, as they were not hashed and do not appear in linux.path
    # Patch files are taken from the symlink, so that they all contain a fixed prefix which
    # cab easily be stripped off with sed and which by construction cannot will not contain chars
    # that need escaping
    (
        cd "$linuxgamedir"
        { 
            find . -type l -print0
            sort -z "$md5dir/linux.path" "$md5dir/lpatches.path" | uniq -zu
            find "$patchsymlink" -type f -print0
        } | tar -c $compressopts -P --transform='s|^'"$patchsymlink"'/||' --null -T- --owner=root:0 --group=root:0
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
*)
    fatal $ERR_BADCLI "Unknown step '$firststep'"
esac

info "Done! You can now use $script to turn a Windows installation of this game into its Linux equivalent"
exit_code=0
