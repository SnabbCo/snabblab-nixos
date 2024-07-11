#!/usr/bin/env bash

numTimesRunBenchmark=20

repositoryA=snabbco/snabb
branchA=master
nameA=master

# repositoryB=eugeneia/snabb
# branchB=max-next
# nameB=max-next

repositoryB=eugeneia/snabb
branchB=max-next
nameB=max-next

# repositoryC=eugeneia/snabb
# branchC=timeline-raptorjit-disabled2
# nameC=timeline_off

# repositoryD=eugeneia/snabb
# branchD=configurable-pools-interlink
# nameD=interlink

#benchRelease='"basic" "interlink-single" "interlink-multi" "lwaftr-soft" "ipfix-probe" "iperf-base"'
benchRelease='"interlink-single" "interlink-multi" "lwaftr-soft" "ipfix-probe"'

# reports: basic, report-by-snabb, report-full-matrix, vita

nix-build --no-sandbox --max-jobs 1 --allow-new-privileges \
    --arg numTimesRunBenchmark "${numTimesRunBenchmark}" \
    --argstr snabbAname "${nameA}" \
    --arg snabbAsrc "builtins.fetchTarball https://github.com/${repositoryA}/tarball/${branchA}" \
    --argstr snabbBname "${nameB}" \
    --arg snabbBsrc "builtins.fetchTarball https://github.com/${repositoryB}/tarball/${branchB}" \
    --arg reports '["report-by-snabb"]' \
    --arg benchmarkNames "[ ${benchRelease} ]" \
    --arg qemuVersions '[ "2.6.2" ]' \
    --argstr hardware "nfg2" \
    --show-trace \
    -A benchmark-csv \
    -A benchmark-reports \
    jobsets/snabb-matrix.nix

#     -A benchmark-reports \

#     --arg keepShm true \
#     --argstr snabbBname "${nameB}" \
#    --arg snabbBsrc "builtins.fetchTarball https://github.com/${repositoryB}/tarball/${branchB}" \
