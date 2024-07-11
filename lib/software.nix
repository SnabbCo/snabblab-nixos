{ pkgs, nixpkgs }:

# build* functions are responsible for building software given their source or version

rec {
  # Build Snabb using git version tag
  buildSnabb = version: hash:
    pkgs.snabbswitch.overrideDerivation (super: {
      name = "snabb-${version}";
      inherit version;
      src = pkgs.fetchFromGitHub {
        owner = "snabbco";
        repo = "snabb";
        rev = "v${version}";
        sha256 = hash;
      };
    });

 # Build snabb using nix store path provided by builtins.fetchTarball or Hydra git input
 buildNixSnabb = snabbSrc: version:
   if snabbSrc == null
   then null
   else
      ((import <nixpkgs> {}).callPackage snabbSrc {}).overrideDerivation (super:
        {
          name = super.name + version;
          inherit version;
        }
      );
}
