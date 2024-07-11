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

  buildQemu = version: hash: applySnabbPatch:
    let
      src = pkgs.fetchurl {
        url = "http://wiki.qemu.org/download/qemu-${version}.tar.bz2";
        sha256 = hash;
      };
    in buildQemuFromSrc version src applySnabbPatch;

  buildQemuFromSrc = version: src: applySnabbPatch:
    let
      snabbPatch = pkgs.fetchurl {
        url = "https://github.com/SnabbCo/qemu/commit/f393aea2301734647fdf470724433f44702e3fb9.patch";
        sha256 = "07jbnxj97p8cvhbxxyfylqa5ppsflrr0kxn3d82bdylns82cyfm6";
        name = "snabb-patch";
      };
    in pkgs.qemu.overrideDerivation (super: {
      name = "qemu-${version}" + pkgs.lib.optionalString applySnabbPatch "-with-snabbpatch";
      version = version + pkgs.lib.optionalString applySnabbPatch "-with-snabbpatch";
      inherit src;
      patchPhase = ''
        substituteInPlace Makefile --replace \
          "install-datadir install-localstatedir" \
          "install-datadir" \
          --replace "install-sysconfig " ""
      '' + pkgs.lib.optionalString applySnabbPatch ''
        patch -p1 < ${snabbPatch}
      '';
    });

  # Define software stacks using a list

  qemus = [
    (buildQemu "2.1.3" "0h0ayrlr4kj74fb920mv0wh9d11d0nvnm70wplwijh3cdw7gss4v" true)
    (buildQemu "2.1.3" "0h0ayrlr4kj74fb920mv0wh9d11d0nvnm70wplwijh3cdw7gss4v" false)
    (buildQemu "2.2.1" "181m2ddsg3adw8y5dmimsi8x678imn9f6i5p20zbhi7pdr61a5s6" false)
    (buildQemu "2.3.1" "0px1vhkglxzjdxkkqln98znv832n1sn79g5inh3aw72216c047b6" false)
    (buildQemu "2.4.1" "0xx1wc7lj5m3r2ab7f0axlfknszvbd8rlclpqz4jk48zid6czmg3" false)
    (buildQemu "2.5.1" "0b2xa8604absdmzpcyjs7fix19y5blqmgflnwjzsp1mp7g1m51q2" false)
    (buildQemu "2.6.2" "18zsjz11fxnv8yh2nfc59ifrp1kiwbmh03j11ibix7kv2i7wczls" false)
#    (buildQemu "2.7.1" "13wm4941r0qp48l4r4raf7annpa9a0mv68529fsb1g39xf46fqv8" false)
#    (buildQemu "2.8.0" "0qjy3rcrn89n42y5iz60kgr0rrl29hpnj8mq2yvbc1wrcizmvzfs" false)
  ];

  kernelPackages = [
    pkgs.linuxPackages_3_14
    pkgs.linuxPackages_3_18
    pkgs.linuxPackages_4_1
    pkgs.linuxPackages_4_3
    pkgs.linuxPackages_4_4
  ];
}
