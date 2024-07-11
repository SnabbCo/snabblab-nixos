This repository contains [Nix](http://nixos.org/nix/) code to run Snabb
test and benchmark campaigns.

# Requirements

## On non-NixOS hosts

You need to install [Nix](http://nixos.org/nix/).

Update nix.conf (if this is a single-user installation this is in `~/.config/nix`,
otherwise it is in `/etc/nix`).

```
sandbox = false
allow-new-privileges = true
max-jobs = 1
```

Ensure that the building users (in case of a multi-user installation this is `nixbld$i`)
can execute `sudo` without a password and are in the `kvm` group.

## On NixOS hosts

Copy `modules/sudo-in-builds.nix` to `/etc/nixos/`.
The module has been observed to work at least
on Nixos 19.09.1247.851d5bdfb04 (Loris).

Update `/etc/nixos/configuration.nix` and do a `nixos-rebuild switch`:

```
  imports =
    [
      # ...
      ./sudo-in-builds.nix
    ];
  nix.maxJobs = 1;
```

## Notes

We need `sudo` in builds to access system hardware. On non-NixOS hosts we pass
in the host sudo. Be aware that the host sudo will *not* inherit the Nix `PATH`.

# Examples

## Note

If your host `sudo` is not in `/usr/bin/sudo` (e.g., if you are on NixOS)
you have to pass the `sudo` argument to the commands below, i.e.:

```
--argstr sudo "/var/setuid-wrappers/sudo"
```

## Running a Benchmark campaign

This runs the *basic* benchmark 10 times each on two different versions of Snabb,
and produces an HTML report *report-by-snabb* comparing results between Snabb versions
(in `./result-2/report.html`).

```
nix-build \
    --arg numTimesRunBenchmark 10 \
    --argstr snabbAname "master" \
    --arg snabbAsrc "builtins.fetchTarball https://github.com/snabbco/snabb/tarball/master" \
    --argstr snabbBname "next" \
    --arg snabbBsrc "builtins.fetchTarball https://github.com/snabbco/snabb/tarball/next" \
    --arg benchmarkNames '[ "basic" ]' \
    --arg reports '["report-by-snabb"]' \
    --show-trace \
    -A benchmark-csv \
    -A benchmark-reports \
    jobsets/snabb-matrix.nix
```

The available benchmarks and reports can be found in `lib/benchmarks.nix`
and `lib/reports/` respectively.

## Running tests

This runs the Snabb test suite:

```
nix-build \
    --arg snabbSrc "builtins.fetchTarball https://github.com/snabbco/snabb/tarball/next" \
    --show-trace \
    -A tests \
    jobsets/snabb.nix
```

You can get into a shell enviroment that matches the test suite environment
by calling `nix-shell` instead of `nix-build`, navigating to the Snabb tree
you want to test, and evaluating `buildPhase`. I.e., to debug the SnabbNFV
test suite which depends on *test_env*:

```
$ nix-shell \
    --arg snabbSrc "builtins.fetchTarball https://github.com/snabbco/snabb/tarball/next" \
    --show-trace \
    -A tests \
    jobsets/snabb.nix
...
[nix-shell:~/snabblab-nixos]$ cd ~/eugeneia-snabb-7086845/
[nix-shell:/home/max/eugeneia-snabb-7086845]$ eval "$buildPhase"
ln: failed to create symbolic link 'src/snabb': File exists
mkdir: cannot create directory '/nix/store/npa03dssh14nw7i0dr1yknr8jbxh337g-snabb-tests': Permission denied
[nix-shell:/home/max/repro/eugeneia-snabb-7086845]$ cd src
[nix-shell:/home/max/repro/eugeneia-snabb-7086845/src]$ /usr/bin/sudo -E program/snabbnfv/selftest.sh
...
```

## Reproducible environments

One of the most important available arguments to the jobsets showcased above
is *nixpkgs*. The tests/benchmarks are run in a pinned Nixpkgs
software universe.

To use test specifc using a specific Nixpkgs commit you can for example use:

```
--arg nixpkgs "(builtins.fetchTarball https://github.com/NixOS/nixpkgs/archive/37e7e86ddd09d200bbdfd8ba8ec2fd2f0621b728.tar.gz)"
```
