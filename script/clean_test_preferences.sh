#!/bin/sh
set -eu

# cfprefsd can write empty domains after the test host exits. Run this as the
# scheme's test post-action, after per-test TestDefaults teardown and host exit.
# This fixed container is never the real app's container.
preferences="$HOME/Library/Containers/com.fahlsing.Chunksee.Tests/Data/Library/Preferences"
[ -d "$preferences" ] || exit 0
[ ! -L "$preferences" ] || exit 1
for file in "$preferences"/ChunkseeTests-*.plist; do
    [ -f "$file" ] || continue
    rm -- "$file"
done
