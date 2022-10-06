{ pkgs, nixpkgs }:

# Functions for executing benchmarks on different hardware groups,
# collecting results by parsing logs and converting them to CSV and
# generating reports using Rmarkdown.

let
  testing = import ./testing.nix { inherit pkgs nixpkgs; };
  software = import ./software.nix { inherit pkgs nixpkgs; };
in rec {
  /* Execute a benchmark named as specified using `name` parameter,
     repeated as many times as the integer `times`.

     `toCSV` function is mandatory. It's called using the resulting
     benchmark derivation and returns a bash snippet. The function
     should parse the log in ${drv}/log.txt and set `score` variable
     providing the benchmark value. It should then call `writeCSV`
     function to generate the CSV line.

     `meta` attribute includes information needed at CSV generation time.

     The rest of the attributes are specified in testing.nix:`mkSnabbTest`
  */
  mkSnabbBenchTest = { name, times, keepShm ? false, sudo, toCSV, ... }@attrs:
    let
      # patch needed for Snabb v2016.05 and lower
      testEnvPatch = pkgs.fetchurl {
        url = "https://github.com/snabbco/snabb/commit/e78b8b2d567dc54cad5f2eb2bbb9aadc0e34b4c3.patch";
        sha256 = "12k4217y6d30l6cn9gq53s1wz3m31gacj9ppsgdq2wk72v4s7j06";
      };
      snabbBenchmark = num:
        let
          name' = "${name}_num=${toString num}";
        in {
          ${name'} = pkgs.lib.hydraJob (testing.mkSnabbTest ({
            name = name';
            alwaysSucceed = true;
            patchPhase = ''
              patch -p1 < ${testEnvPatch} || true
            '';
            preInstall = ''
              cp qemu*.log $out/ || true
              cp snabb*.log $out/ || true
            '';
            SNABB_SHM_KEEP=keepShm;
            postInstall = ''
              echo "POST INSTALL"
              echo "keepShm = $keepShm"
              ${sudo} chmod a+rX /var/run/snabb
              if [ -n "$keepShm" ]; then
                cd /var/run/snabb
                ${sudo} tar cvf $out/snabb.tar [0-9]*
                ${sudo} rm -rf [0-9]*
                ${sudo} chown $(whoami):$(id -g -n) $out/snabb.tar
                xz -0 -T0 $out/snabb.tar
                mkdir -p $out/nix-support
                echo "file tarball $out/snabb.tar.xz" >> $out/nix-support/hydra-build-products
              fi
            '';
            meta = {
              snabbVersion = attrs.snabb.version or "";
              qemuVersion = attrs.qemu.version or "";
              kernelVersion = attrs.kPackages.kernel.version or "";
              repeatNum = num;
              inherit sudo toCSV;
            } // (attrs.meta or {});
          } // removeAttrs attrs [ "times" "toCSV" "kPackages" "meta" "name"]));
        };
    in testing.mergeAttrsMap snabbBenchmark (pkgs.lib.range 1 times);

  /* Execute `basic1` benchmark.

     `basic1` has no dependencies except Snabb,
     being a minimal configuration for a benchmark.    
  */
  mkMatrixBenchBasic = { snabb, times, hardware ? "murren", keepShm, sudo, ... }:
    mkSnabbBenchTest {
      name = "basic1_snabb=${testing.versionToAttribute snabb.version or ""}_packets=100e6";
      inherit snabb times hardware keepShm sudo;
      checkPhase = ''
        [ -z "$SNABB_CPUS" ] && (echo "SNABB_CPUS not set"; exit 1)
        ${sudo} -E taskset -c $(cut -d '-' -f 1 <<<$SNABB_CPUS) ${snabb}/bin/snabb snabbmark basic1 100e6 |& tee $out/log.txt
      '';
      toCSV = drv: ''
        score=$(awk '/Mpps/ {print $(NF-1)}' < ${drv}/log.txt)
        ${writeCSV drv "basic" "Mpps"}
      '';
    };

  /* Execute `packetblaster` benchmark.

    `packetblaster` sets "lugano" as default hardware group,
    as the benchmark depends on having a NIC installed.
  */
  mkMatrixBenchPacketblaster = { snabb, times, hardware ? "lugano", keepShm, sudo, ... }:
    mkSnabbBenchTest {
      name = "${testing.versionToAttribute snabb.version or ""}-packetblaster-64";
      inherit snabb times hardware keepShm sudo;
      toCSV = drv: ''
        pps=$(cat ${drv}/log.txt | grep TXDGPC | cut -f 3 | sed s/,//g)
        score=$(echo "scale=2; $pps / 1000000" | bc)
        ${writeCSV drv "blast" "Mpps"}
      '';
      checkPhase = ''
        cd src
        ${sudo} -E ${snabb}/bin/snabb packetblaster replay --duration 1 \
          program/snabbnfv/test_fixtures/pcap/64.pcap "$SNABB_PCI_INTEL0" |& tee $out/log.txt
      '';
    };

  /* Execute `packetblaster-synth` benchmark.

    Similar to `packetblaster` benchmark, but use "synth"
    command with size 64.
  */
  mkMatrixBenchPacketblasterSynth = { snabb, times, hardware ? "lugano", keepShm, sudo, ... }:
    mkSnabbBenchTest {
      name = "${testing.versionToAttribute snabb.version or ""}-packetblaster-synth-64";
      inherit snabb times hardware keepShm sudo;
      toCSV = drv: ''
        pps=$(cat ${drv}/log.txt | grep TXDGPC | cut -f 3 | sed s/,//g)
        score=$(echo "scale=2; $pps / 1000000" | bc)
        ${writeCSV drv "blastsynth" "Mpps"}
      '';
      checkPhase = ''
        ${sudo} -E ${snabb}/bin/snabb packetblaster synth \
          --src 11:11:11:11:11:11 --dst 22:22:22:22:22:22 --sizes 64 \
          --duration 1 "$SNABB_PCI_INTEL0" |& tee $out/log.txt
      '';
    };


  /* Execute `iperf` benchmark.

     Requires `testNixEnv` built fixtures providing qemu images.

     If hardware group doesn't use have a NIC, ports can be specified.
  */
  mkMatrixBenchNFVIperf = { snabb, times, qemu, kPackages, conf ? "NA", hardware ? "lugano", testNixEnv, keepShm, sudo, ... }:
    let
      iperfports = {
        base         = "program/snabbnfv/test_fixtures/nfvconfig/test_functions/same_vlan.ports";
        filter       = "program/snabbnfv/test_fixtures/nfvconfig/test_functions/filter.ports";
        ipsec        = "program/snabbnfv/test_fixtures/nfvconfig/test_functions/crypto.ports";
        l2tpv3       = "program/snabbnfv/test_fixtures/nfvconfig/test_functions/tunnel.ports";
        l2tpv3_ipsec = "program/snabbnfv/test_fixtures/nfvconfig/test_functions/crypto-tunnel.ports";
      };
    in mkSnabbBenchTest {
      name = "iperf_conf=${conf}_snabb=${testing.versionToAttribute snabb.version or ""}_kernel=${testing.versionToAttribute kPackages.kernel.version}_qemu=${testing.versionToAttribute qemu.version}";
      inherit hardware kPackages snabb times qemu testNixEnv keepShm sudo;
      toCSV = drv: ''
        score=$(awk '/^IPERF-/ { print $2 }' < ${drv}/log.txt)
        ${writeCSV drv "iperf" "Gbps"}
      '';
      meta = { inherit conf; };
      needsNixTestEnv = true;
      SNABB_IPERF_BENCH_CONF = iperfports.${conf} or "";
      checkPhase = ''
        cd src
        ${sudo} -E program/snabbnfv/selftest.sh bench |& tee $out/log.txt
      '';
    };

  /* Execute `vita-loopback` benchmark.

     `vita-loopback` has no dependencies except Snabb. Packet size can be
     specified via pktsize.
  */
  mkMatrixBenchVitaLoopback = { snabb, times, pktsize ? "IMIX", hardware ? "murren", keepShm, sudo, ... }:
    mkSnabbBenchTest {
      name = "vita-loopback_pktsize=${pktsize}_packets=100e6_snabb=${testing.versionToAttribute snabb.version or ""}";
      inherit snabb times hardware keepShm sudo;
      meta = { inherit pktsize; };
      toCSV = drv: ''
        score=$(awk '/Gbps/ {print $(NF-1)}' < ${drv}/log.txt)
        ${writeCSV drv "vita-loopback" "Gbps"}
      '';
      checkPhase = ''
        cd src
        ${sudo} -E ${snabb}/bin/snabb snsh program/vita/test.snabb ${pktsize} 100e6 |& tee $out/log.txt
      '';

    };

  /* Execute `interlink-wait` benchmark.

     `interlink-wait` has no dependencies except Snabb.
         - duration specifies benchmark duration
         - nreceivers specifies number of receiver links (1-to-n core topology)

      Requires SNABB_CPUS to be set.
  */
  mkMatrixBenchInterlinkWait = { snabb, times, duration ? "3", nreceivers ? "1", hardware ? "murren", keepShm, sudo, ... }:
    mkSnabbBenchTest {
      name = "interlink-wait_duration=${duration}_nreceivers=${nreceivers}_snabb=${testing.versionToAttribute snabb.version or ""}";
      inherit snabb times hardware keepShm sudo;
      meta = { inherit duration nreceivers; conf = "nreceivers=${nreceivers}"; };
      toCSV = drv: ''
        score=$(awk '/Mpps/ {print $(NF-1)}' < ${drv}/log.txt)
        ${writeCSV drv "interlink-wait" "Mpps"}
      '';
      checkPhase = ''
        cd src
        [ -z "$SNABB_CPUS" ] && (echo "SNABB_CPUS not set"; exit 1)
        ${sudo} -E ${snabb}/bin/snabb snsh apps/interlink/wait_test.snabb ${duration} ${nreceivers} $SNABB_CPUS \
          2>&1 >interlink_latency.csv | tee $out/log.txt
      '';

    };

  /* Execute `mellanox-source-sink` benchmark.

     `mellanox-source-sink` depends on SNABB_PCI_CONNECTX_0 and SNABB_PCI_CONNECTX_1
     (wired to each other), as well as SNABB_CPUS0 and SNABB_CPUS1.
       - pktsize specifies packet size
       - conf specifies extra benchmark options
  */
  mkMatrixBenchMellanoxSourceSink = { snabb, times, pktsize ? "IMIX", conf ? "", hardware ? "murren", keepShm, sudo, ... }:
    mkSnabbBenchTest {
      name = "mellanox-source-sink_pktsize=${pktsize}_packets=100e6_snabb=${testing.versionToAttribute snabb.version or ""}";
      inherit snabb times hardware keepShm sudo;
      meta = { inherit pktsize; conf = builtins.replaceStrings [","] [" "] conf; };
      toCSV = drv: ''
        score=$(awk '/Rx Rate/ {print $(NF-1)}' < ${drv}/log.txt)
        ${writeCSV drv "mellanox-source-sink" "Mpps"}
      '';
      checkPhase = ''
        cd src
        [ -z "$SNABB_CPUS0" ] && (echo "SNABB_CPUS0 not set"; exit 1)
        [ -z "$SNABB_CPUS1" ] && (echo "SNABB_CPUS0 not set"; exit 1)
        [ -z "$SNABB_PCI_CONNECTX_0" ] && (echo "SNABB_PCI_CONNECTX_0 not set"; exit 1)
        [ -z "$SNABB_PCI_CONNECTX_1" ] && (echo "SNABB_PCI_CONNECTX_1 not set"; exit 1)
        ${sudo} -E ${snabb}/bin/snabb snsh apps/mellanox/benchmark.snabb \
          -a "$SNABB_PCI_CONNECTX_0" -b "$SNABB_PCI_CONNECTX_1" -A "$SNABB_CPUS0" -B "$SNABB_CPUS1" \
          -m source-sink -w 6 -q 4 -n 100e6 \
          -s ${pktsize} ${conf} |& tee $out/log.txt
      '';

    };

    /* Execute `mellanox-source` benchmark.

     `mellanox-source` depends on SNABB_PCI_CONNECTX_0 as well as SNABB_CPUS0.
       - pktsize specifies packet size
       - conf specifies extra benchmark options
  */
  mkMatrixBenchMellanoxSource = { snabb, times, pktsize ? "IMIX", conf ? "", hardware ? "murren", keepShm, sudo, ... }:
    mkSnabbBenchTest {
      name = "mellanox-source_pktsize=${pktsize}_packets=100e6_snabb=${testing.versionToAttribute snabb.version or ""}";
      inherit snabb times hardware keepShm sudo;
      meta = { inherit pktsize; conf = builtins.replaceStrings [","] [" "] conf; };
      toCSV = drv: ''
        score=$(awk '/Tx Rate/ {print $(NF-1)}' < ${drv}/log.txt)
        ${writeCSV drv "mellanox-source" "Mpps"}
      '';
      checkPhase = ''
        cd src
        [ -z "$SNABB_CPUS0" ] && (echo "SNABB_CPUS0 not set"; exit 1)
        [ -z "$SNABB_PCI_CONNECTX_0" ] && (echo "SNABB_PCI_CONNECTX_0 not set"; exit 1)
        ${sudo} -E ${snabb}/bin/snabb snsh apps/mellanox/benchmark.snabb \
          -a "$SNABB_PCI_CONNECTX_0" -A "$SNABB_CPUS0" \
          -m source -w 1 -q 8 -n 100e6 \
          -s ${pktsize} ${conf} |& tee $out/log.txt
      '';

    };

  /* Execute `lwaftr-soft` benchmark.

     `lwaftr-soft` depends on SNABB_CPUS0.
       - pktsize specifies packet size
       - conf specifies extra benchmark options
  */
  mkMatrixBenchLwaftrSoft = { snabb, times, pktsize ? "60", conf ? "", hardware ? "murren", keepShm, sudo, ... }:
    mkSnabbBenchTest {
      name = "lwaftr-soft_pktsize=${pktsize}_snabb=${testing.versionToAttribute snabb.version or ""}";
      inherit snabb times hardware keepShm sudo;
      meta = { inherit pktsize; conf = builtins.replaceStrings [","] [" "] conf; };
      toCSV = drv: ''
        score=$(awk '/Decap. avg. Mpps:/ {print $(NF-0)}' < ${drv}/log.txt)
        ${writeCSV drv "lwaftr-soft" "Mpps"}
      '';
      checkPhase = ''
        cd src
        [ -z "$SNABB_CPUS0" ] && (echo "SNABB_CPUS0 not set"; exit 1)
        ${sudo} -E ${snabb}/bin/snabb lwaftr generate-configuration \
          --output lwaftr.conf --pcap-v6 v6.pcap --pcap-v4 v4.pcap \
          --packet-size ${pktsize} --npackets 10000 \
          178.79.150.233 65000 8:9:a:b:c:d:e:f 127:2:3:4:5:6:7:128 0
        ${sudo} -E ${snabb}/bin/snabb lwaftr bench \
          -D 5 --cpu "$SNABB_CPUS0" \
          lwaftr.conf v4.pcap v6.pcap |& tee $out/log.txt
      '';

    };

  /* Given a benchmark derivation, benchmark name and a unit,
     write a line of the CSV file using all provided benchmark information.
  */
  writeCSV = drv: benchName: unit: ''
    if test -z "$score"; then score="NA"; fi
    echo ${drv},${benchName},${drv.meta.pktsize or "NA"},${drv.meta.conf or "NA"},${drv.meta.snabbVersion or "NA"},${drv.meta.kernelVersion or "NA"},${drv.meta.qemuVersion or "NA"},${toString drv.meta.repeatNum},$score,${unit} >> $out/bench.csv
  '';

  # Generate CSV out of collection of benchmarking logs
  mkBenchmarkCSV = benchmarkList:
    pkgs.stdenv.mkDerivation {
      name = "snabb-report-csv";
      buildInputs = [ pkgs.gawk pkgs.bc ];
      # Build CSV on Hydra localhost to spare time on copying
      #requiredSystemFeatures = [ "local" ];
      # TODO: uses writeText until following is merged https://github.com/NixOS/nixpkgs/pull/15803
      builder = pkgs.writeText "csv-builder.sh" ''
        source $stdenv/setup
        mkdir -p $out/nix-support

        echo "drv,benchmark,pktsize,config,snabb,kernel,qemu,id,score,unit" > $out/bench.csv
        ${pkgs.lib.concatMapStringsSep "\n" (drv: drv.meta.toCSV drv) benchmarkList}

        # Make CSV file available via Hydra
        echo "file CSV $out/bench.csv" >> $out/nix-support/hydra-build-products
      '';
    };

    /* Using a generated CSV file, list of benchmarks and a report name,
      generate a report using Rmarkdown.
    */
    mkBenchmarkReport = csv: benchmarksList: reportName:
    pkgs.stdenv.mkDerivation {
      name = "snabb-report";
      buildInputs = with pkgs.rPackages; [ fpc rmarkdown ggplot2 dplyr pkgs.R pkgs.pandoc pkgs.which ];
      # Build reports on Hydra localhost to spare time on copying
      #requiredSystemFeatures = [ "local" ];
      # TODO: use writeText until runCommand uses passAsFile (16.09)
      builder = pkgs.writeText "csv-builder.sh" ''
        source $stdenv/setup

        # Store all logs
        mkdir -p $out/nix-support
        ${pkgs.lib.concatMapStringsSep "\n" (drv: "cat ${drv}/log.txt > $out/${drv.name}-${toString drv.meta.repeatNum}.log") benchmarksList}
        tar cfJ logs.tar.xz -C $out .
        mv logs.tar.xz $out/
        echo "file tarball $out/logs.tar.xz" >> $out/nix-support/hydra-build-products

        # Create markdown report
        cp ${../lib/reports + "/${reportName}.Rmd"} ./report.Rmd
        cp ${csv} .
        cat bench.csv
        cat report.Rmd
        echo "library(rmarkdown); render('report.Rmd')" | R --no-save
        cp report.html $out
        echo "file HTML $out/report.html"  >> $out/nix-support/hydra-build-products
        echo "nix-build out $out" >> $out/nix-support/hydra-build-products
      '';
    };

    # Generate a list of names of available reports in `./lib/reports`
    listReports =
      map (name: pkgs.lib.removeSuffix ".Rmd" name)
        (builtins.attrNames (builtins.readDir ../lib/reports));

    # Returns true if version is a prefix of drv.version
    matchesVersionPrefix = version: drv:
      pkgs.lib.hasPrefix version (pkgs.lib.getVersion drv);

    # Select software collections based on version strings
    selectQemus = versions:
      if versions == []
      then software.qemus
      else pkgs.lib.concatMap (version: pkgs.lib.filter (matchesVersionPrefix version) software.qemus) versions;
    selectKernelPackages = versions:
      if versions == []
      then software.kernelPackages
      else pkgs.lib.concatMap (version: pkgs.lib.filter (kPackages: pkgs.lib.hasPrefix version (pkgs.lib.getVersion kPackages.kernel)) software.kernelPackages) versions;

    # Given a list of names and benchmark inputs/parameters, get benchmarks by their alias and pass them the parameters
    selectBenchmarks = names: params:
      testing.mergeAttrsMap (name: (pkgs.lib.getAttr name benchmarks) params) names;

    # Benchmarks aliases that can be referenced using just a name, i.e. "iperf-filter"
    benchmarks = {
      basic = params: mkMatrixBenchBasic (params);

      packetblaster = mkMatrixBenchPacketblaster;
      packetblaster-synth = mkMatrixBenchPacketblasterSynth;

      iperf = mkMatrixBenchNFVIperf;
      iperf-base = params: mkMatrixBenchNFVIperf (params // {conf = "base"; hardware = "murren";});
      iperf-filter = params: mkMatrixBenchNFVIperf (params // {conf = "filter"; hardware = "murren";});
      iperf-ipsec = params: mkMatrixBenchNFVIperf (params // {conf = "ipsec"; hardware = "murren";});
      iperf-l2tpv3 = params: mkMatrixBenchNFVIperf (params // {conf = "l2tpv3"; hardware = "murren";});
      iperf-l2tpv3-ipsec = params: mkMatrixBenchNFVIperf (params // {conf = "l2tpv3_ipsec"; hardware = "murren";});

      vita-loopback = mkMatrixBenchVitaLoopback;
      vita-loopback-imix = params: mkMatrixBenchVitaLoopback (params // {pktsize = "IMIX"; hardware = "murren";});
      vita-loopback-60 = params: mkMatrixBenchVitaLoopback (params // {pktsize = "60"; hardware = "murren";});
      vita-loopback-600 = params: mkMatrixBenchVitaLoopback (params // {pktsize = "600"; hardware = "murren";});
      vita-loopback-1000 = params: mkMatrixBenchVitaLoopback (params // {pktsize = "1000"; hardware = "murren";});

      interlink-single = params: mkMatrixBenchInterlinkWait (params // {nreceivers = "1";});
      interlink-multi = params: mkMatrixBenchInterlinkWait (params // {nreceivers = "3";});

      mellanox-source-sink-imix = params: mkMatrixBenchMellanoxSourceSink (params // {pktsize = "IMIX";});
      mellanox-source-sink-64 = params: mkMatrixBenchMellanoxSourceSink (params // {pktsize = "64";});

      mellanox-source-imix = params: mkMatrixBenchMellanoxSource (params // {pktsize = "IMIX";});
      mellanox-source-64 = params: mkMatrixBenchMellanoxSource (params // {pktsize = "64";});

      lwaftr-soft = mkMatrixBenchLwaftrSoft;
    };
}
