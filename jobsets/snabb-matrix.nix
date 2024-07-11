# Make a matrix benchmark out of Snabb versions
# and generate a report based on the logs

# Specify how many times each benchmark is repeated
{ numTimesRunBenchmark ? 1
# Collection of Nix packages used
, nixpkgs ? (fetchTarball https://github.com/NixOS/nixpkgs/archive/37e7e86ddd09d200bbdfd8ba8ec2fd2f0621b728.tar.gz)
# Up to 6 different Snabb branches specified using source and name
, snabbAsrc
, snabbBsrc ? null
, snabbCsrc ? null
, snabbDsrc ? null
, snabbEsrc ? null
, snabbFsrc ? null
, snabbAname
, snabbBname ? null
, snabbCname ? null
, snabbDname ? null
, snabbEname ? null
, snabbFname ? null
# snabbPatches is a list of patches to be applied to all snabb versions
# (hash is extracted using $ nix-prefetch-url https://patch-diff.githubusercontent.com/raw/snabbco/snabb/pull/969.patch)
# example: snabbPatches = [ "https://patch-diff.githubusercontent.com/raw/snabbco/snabb/pull/969.patch 0fcp1yzkjhgrm7rlq2lpcb71nnhih3cwa189b3f14xv2k5yrsbmh"];
, snabbPatches ? []
# Which benchmarks to execute
# For possible values see keys in the bottom of lib/benchmarks.nix, e.g. [ "iperf-base" ]
, benchmarkNames ? [ ]
# Name of reports to be generated
# For possible values see lib/reports/, e.g. "report-by-snabb"
, reports ? []
# Optionally keep the shm folders
, keepShm ? false
# sudo to use in tests
, sudo ? "/usr/bin/sudo"
# which hardware are we using
, hardware ? "murren"
}:

with (import nixpkgs {});
with (import ../lib { pkgs = (import nixpkgs {}); inherit nixpkgs; });

let
  # Legacy naming
  times = numTimesRunBenchmark;

  # Build all specified Snabb branches
  snabbs = lib.filter (snabb: snabb != null) [
    (buildNixSnabb snabbAsrc snabbAname)
    (buildNixSnabb snabbBsrc snabbBname)
    (buildNixSnabb snabbCsrc snabbCname)
    (buildNixSnabb snabbDsrc snabbDname)
    (buildNixSnabb snabbEsrc snabbEname)
    (buildNixSnabb snabbFsrc snabbFname)
  ];

  # Benchmarks using a matrix of software and a number of repeats
  benchmarks-list = with lib;
    if (benchmarkNames == [])
    then throw "'benchmarkNames' input list should contain at least one element of: ${concatStringsSep ", " (builtins.attrNames benchmarks)}"
    else
      mergeAttrsMap (snabb:
        selectBenchmarks benchmarkNames { inherit snabb times keepShm sudo hardware; }
      ) snabbs;

in rec {
  # All versions of software used in benchmarks
  software = listDrvToAttrs (snabbs);
  benchmarks = benchmarks-list;
  benchmark-csv = mkBenchmarkCSV (builtins.attrValues benchmarks-list);
  benchmark-reports =
    if (reports == [])
    then throw "'reports' input list should contain at least one element of: ${lib.concatStringsSep ", " listReports}"
    else lib.listToAttrs (map (reportName:
      { name = reportName;
        value = mkBenchmarkReport "${benchmark-csv}/bench.csv" (builtins.attrValues benchmarks-list) reportName;
      }) reports);
}
