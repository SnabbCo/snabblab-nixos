{ config, pkgs, lib, ... }:

with lib;

let
  # can't upgrade further due to https://github.com/NixOS/hydra/commit/4151be7e69957d22af712dd5410b5ad8aa3a2289
  # We use our own fork with some modifications
  hydraSrc = builtins.fetchTarball https://github.com/domenkozar/hydra/tarball/23ec21778b8326ec8f6a691dd4d5b3df6bd41f2b;
  commonBuildMachineOpt = {
    speedFactor = 1;
    sshKey = "/etc/nix/id_buildfarm";
    sshUser = "root";
    system = "x86_64-linux";
    supportedFeatures = [ "kvm" "nixos-test" ];
  };
in {
  imports = [ "${hydraSrc}/hydra-module.nix" ];

  # make sure we're using the platform on which hydra is supposed to run
  assertions = lib.singleton {
    assertion = pkgs.system == "x86_64-linux";
    message = "unsupported system ${pkgs.system}";
  };

  environment.etc = lib.singleton {
    target = "nix/id_buildfarm";
    source = ../secrets/id_buildfarm;
    uid = config.ids.uids.hydra;
    gid = config.ids.gids.hydra;
    mode = "0440";
  };

  nix = {
    distributedBuilds = true;
    buildCores = 0;
    buildMachines = [
      (commonBuildMachineOpt // {
        hostName = "lugano-2.snabb.co";
        maxJobs = 1;
        mandatoryFeatures = [ "lugano" ];
      })
      (commonBuildMachineOpt // {
        hostName = "lugano-4.snabb.co";
        maxJobs = 1;
        mandatoryFeatures = [ "lugano" ];
      })
      (commonBuildMachineOpt // {
        hostName = "grindelwald";
        maxJobs = 1;
        mandatoryFeatures = [ "openstack" ];
      })
    ] ++ (map (i:
      (commonBuildMachineOpt // {
        hostName = "build-${toString i}.snabb.co";
        maxJobs = 8;
      })
    ) (range 1 4))
    ++ (map (i:
      (commonBuildMachineOpt // {
        hostName = "murren-${toString i}.snabb.co";
        maxJobs = 1;
        supportedFeatures = [ "murren" ] ++ commonBuildMachineOpt.supportedFeatures;
      })
    ) (range 1 10));
      #(commonBuildMachineOpt // {
      #  hostName = "localhost";
      #  maxJobs = 2;
      #  supportedFeatures = [ ];  # let's not build tests here
      #})
    extraOptions = "auto-optimise-store = true";
  };


  # let's auto-accept fingerprints on first connection
  programs.ssh.extraConfig = ''
    StrictHostKeyChecking no
  '';

  services.hydra = {
    enable = true;
    hydraURL = "http://hydra.snabb.co";
    notificationSender = "hydra@hydra.snabb.co";
    port = 8080;
    # max output is 4GB because of openstack image
    extraConfig = ''
      binary_cache_secret_key_file = /etc/nix/hydra.snabb.co-1/secret
      max_output_size = 4294967296
    '';
    logo = (pkgs.fetchurl {
      url    = "http://snabb.co/snabb_screen.png";
      sha256 = "0xz0qr59b4fi2x9rwszlrj3020isbzqir68gvsj0yfab0jpj8mbc";
    });
  };

  # workaround https://github.com/NixOS/hydra/issues/297
  systemd.services.hydra-queue-runner.serviceConfig.ExecStart = lib.mkForce "@${config.services.hydra.package}/bin/hydra-queue-runner hydra-queue-runner -v";

  # this is most important to us, so prioritize cpu right after the kernel
  systemd.services.hydra-evaluator.serviceConfig.Nice = -19;

  services.postgresql = {
    package = pkgs.postgresql94;
    dataDir = "/var/db/postgresql-${config.services.postgresql.package.psqlSchema}";
  };

  systemd.services.hydra-manual-setup = {
    description = "Create Keys for Hydra";
    serviceConfig.Type = "oneshot";
    serviceConfig.RemainAfterExit = true;
    wantedBy = [ "multi-user.target" ];
    requires = [ "hydra-init.service" ];
    after = [ "hydra-init.service" ];
    environment = config.systemd.services.hydra-init.environment;
    script = ''
      if [ ! -e ~hydra/.setup-is-complete ]; then
        # create signing keys
        /run/current-system/sw/bin/install -d -m 551 /etc/nix/hydra.snabb.co-1
        /run/current-system/sw/bin/nix-store --generate-binary-cache-key hydra.snabb.co-1 /etc/nix/hydra.snabb.co-1/secret /etc/nix/hydra.snabb.co-1/public
        /run/current-system/sw/bin/chown -R hydra:hydra /etc/nix/hydra.snabb.co-1
        /run/current-system/sw/bin/chmod 440 /etc/nix/hydra.snabb.co-1/secret
        /run/current-system/sw/bin/chmod 444 /etc/nix/hydra.snabb.co-1/public
        # done
        touch ~hydra/.setup-is-complete
      fi
    '';
  };

  users.users.hydra.uid = config.ids.uids.hydra;
  users.users.hydra-www.uid = config.ids.uids.hydra-www;
  users.users.hydra-queue-runner.uid = config.ids.uids.hydra-queue-runner;
  users.groups.hydra.gid = config.ids.gids.hydra;

  networking.firewall.allowedTCPPorts = [ 80 443 ];

  security.acme.certs = {
    "hydra.snabb.co" = {
      email = "hydra@snabb.co";
      user = "nginx";
      group = "nginx";
      webroot = "/var/www/challenges";
      postRun = "systemctl reload nginx.service";
    };
  };

  services.nginx = {
    enable = true;
    httpConfig = ''
      server_names_hash_bucket_size 64;

      keepalive_timeout   70;
      gzip            on;
      gzip_min_length 1000;
      gzip_proxied    expired no-cache no-store private auth;
      gzip_types      text/plain application/xml application/javascript application/x-javascript text/javascript text/xml text/css;

      server {
        server_name _;
        listen 80;
        listen [::]:80;
        location /.well-known/acme-challenge {
          root /var/www/challenges;
        }
        location / {
          return 301 https://$host$request_uri;
        }
      }

      # TODO: SSL hardening

      server {
        listen 443 ssl spdy;
        server_name hydra.snabb.co;

        ssl_certificate /var/lib/acme/hydra.snabb.co/fullchain.pem;
        ssl_certificate_key /var/lib/acme/hydra.snabb.co/key.pem;

        location / {
          proxy_pass http://127.0.0.1:8080;
          proxy_set_header Host $http_host;
          proxy_set_header REMOTE_ADDR $remote_addr;
          proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
          proxy_set_header X-Forwarded-Proto https;
        }
      }
    '';
  };
}
