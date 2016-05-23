 # Make a matrix out of Snabb + DPDK + QEMU + Linux (for iperf) 
{}:

with (import <nixpkgs> {});
with (import ../lib.nix);
with vmTools;

let
  # Snabb fixtures

  # modules and NixOS config for plain qemu image
  modules = [
    <nixpkgs/nixos/modules/profiles/qemu-guest.nix>
    ({config, pkgs, ...}: {
      environment.systemPackages = with pkgs; [ screen python pciutils ethtool tcpdump netcat iperf ];
      fileSystems."/".device = "/dev/disk/by-label/nixos";
      boot.loader.grub.device = "/dev/sda";
    })
  ];
  config = (import <nixpkgs/nixos/lib/eval-config.nix> { inherit modules; }).config;
  # modules and NixOS config gor dpdk qmemu image
  modules_dpdk = modules ++ [({config, pkgs, lib, ...}: {
    # TODO
  })];
  config_dpdk = (import <nixpkgs/nixos/lib/eval-config.nix> { modules = modules_dpdk; }).config;
  # files needed for some tests
  test_env_nix = runCommand "test-env-nix" {} ''
    mkdir -p $out
    ln -s ${qemu_img}/nixos.qcow2 $out/qemu.img
    ln -s ${qemu_dpdk_img}/nixos.qcow2 $out/qemu-dpdk.img
    ln -s ${config.system.build.kernel}/bzImage $out/bzImage
  '';
  qemu_img = lib.makeOverridable (import <nixpkgs/nixos/lib/make-disk-image.nix>) {
    inherit lib config pkgs;
    partitioned = true;
    format = "qcow2";
    diskSize = 2 * 1024;
  };
  qemu_dpdk_img = qemu_img.override { config = config_dpdk; };

  # build the matrix 

  buildSnabb = version: hash:
     snabbswitch.overrideDerivation (super: {
       name = "snabb-${version}";
       inherit version;
       src = fetchFromGitHub {
          owner = "snabbco";
          repo = "snabb";
          rev = "v${version}";
          sha256 = hash;
        };
     });
  buildQemu = version: hash:
     qemu.overrideDerivation (super: {
       name = "qemu-${version}";
       inherit version;
       src = fetchurl {
         url = "http://wiki.qemu.org/download/qemu-${version}.tar.bz2";
         sha256 = hash;
       };
       # TODO: fails on 2.6.0 and 2.3.1: https://hydra.snabb.co/eval/1181#tabs-still-fail
       #patches = super.patches ++ [ (pkgs.fetchurl {
       #  url = "https://github.com/SnabbCo/qemu/commit/f393aea2301734647fdf470724433f44702e3fb9.patch";
       #  sha256 = "0hpnfdk96rrdaaf6qr4m4pgv40dw7r53mg95f22axj7nsyr8d72x";
       #})];
     });
  snabbs = [
    (buildSnabb "2016.03" "0wr54m0vr49l51pqj08z7xnm2i97x7183many1ra5bzzg5c5waky")
    (buildSnabb "2016.04" "1b5g477zy6cr5d9171xf8zrhhq6wxshg4cn78i5bki572q86kwlx")
    (buildSnabb "2016.05" "1xd926yplqqmgl196iq9lnzg3nnswhk1vkav4zhs4i1cav99ayh8")
  ];
  dpdks = [
  ];
  qemus = [
    # TODO: https://hydra.snabb.co/build/4596
    #(buildQemu "2.3.1" "0px1vhkglxzjdxkkqln98znv832n1sn79g5inh3aw72216c047b6")
    (buildQemu "2.4.1" "0xx1wc7lj5m3r2ab7f0axlfknszvbd8rlclpqz4jk48zid6czmg3")
    (buildQemu "2.5.1" "0b2xa8604absdmzpcyjs7fix19y5blqmgflnwjzsp1mp7g1m51q2")
    (buildQemu "2.6.0" "1v1lhhd6m59hqgmiz100g779rjq70pik5v4b3g936ci73djlmb69")
  ];
  images = [
  ];
in (listDrvToAttrs snabbs)
// (listDrvToAttrs qemus)
