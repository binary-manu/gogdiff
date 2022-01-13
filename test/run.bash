#!/usr/bin/env bash

set -e

die() {
    echo "$@" >&2
    exit 1
}

rm -f test.log

for i in [0-9][0-9][0-9][0-9]; do (
    echo -n "Running test $i: "; cat "$i/README.txt"

    tmpdir="$(mktemp -d)"
    trap 'rm -rf "$tmpdir"' EXIT TERM QUIT INT

    # Create the two folders if they do not exist, most likely
    # because Git cannot track empty folders, but some tests
    # require them
    mkdir -p "$i/windows" "$i/linux"

    real_exit=0
    ../gogdiff.sh -w "$i/windows" -l "$i/linux" -o "$tmpdir/output" || real_exit=$?
    read -r expected_exit < "$i/exit"
    # Check exit status
    if [ "$real_exit" -ne "$expected_exit" ]; then
        die "Execution failed: exit status $real_exit != $expected_exit"
    fi

    # Check if a delta script was produced while unexpoected or
    # it was not produced when expected
    expected_delta="$(test -f "$i/no_delta"; echo $?)"
    real_delta="$(test -f "$tmpdir/output/gogdiff_delta.sh"; echo $?)"
    if [ "$expected_delta" = "$real_delta" ]; then
        die "A delta script was produced when unexpected (or the other way around)"
    fi
    # If we correctly didn't get a delta script, we're done
    [ "$expected_delta" -eq 0 ] && exit 0

    # Prepare a copy a the test windows directory to run the delta script into
    cp -r "$i/windows" "$tmpdir/modified"
    real_exit=0
    env -C "$tmpdir/modified" GOGDIFF_VERBOSE=1 "$tmpdir/output/gogdiff_delta.sh" || real_exit=$?
    if [ "$real_exit" -ne 0 ]; then
        die "Delta script failed"
    fi
    if ! diff -rq "$tmpdir/modified" "$i/linux"; then
        die "The original and modified Windows directories are not equal"
    fi
) &>> test.log; done
