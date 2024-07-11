#!/usr/bin/env bash

repository=eugeneia/snabb
branch=max-next

nix-build --no-sandbox --max-jobs 1 --allow-new-privileges \
    --arg snabbSrc "builtins.fetchTarball https://github.com/${repository}/tarball/${branch}" \
    --argstr hardware "nfg2" \
    --show-trace \
    -A tests \
    jobsets/snabb.nix