{
  description = "jjSync development shell: Flutter, the Android SDK and emulator, and Rust with the Android targets";

  # Every consumer of this flake gets the official cache first, so a fresh
  # checkout does not rebuild the Rust dist tarballs or the Android SDK pieces
  # from source on a machine whose client nix.conf omits cache.nixos.org.
  nixConfig = {
    substituters = [
      "https://cache.nixos.org"
      "https://nix-community.cachix.org"
    ];
    trusted-public-keys = [
      "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
      "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
    ];
  };

  inputs = {
    # nixpkgs 26.11pre-git. Pinned to the revision the workstation channel
    # resolves to, so the shell and the workstation agree exactly.
    nixpkgs.url = "github:NixOS/nixpkgs/eaad089433ca2bb662274377d33df3d0e51ef28b";

    # jj 0.45.1 has an MSRV of 1.97.1, which nixpkgs no longer carries (its
    # rustc is 1.98.1). rust-overlay supplies the exact release plus the Android
    # standard libraries.
    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    { nixpkgs, rust-overlay, ... }:
    let
      # The Android emulator runs on x86_64 hosts only; an aarch64 host would
      # need its own composition and cannot run the emulator.
      system = "x86_64-linux";

      pkgs = import nixpkgs {
        inherit system;
        config = {
          # androidenv is unfree, and its packages need the SDK licence accepted
          # for the androidsdk derivation to link anything.
          allowUnfree = true;
          android_sdk.accept_license = true;
        };
        overlays = [ rust-overlay.overlays.default ];
      };

      # --- pins that can drift -------------------------------------------------
      # Rust: 1.97.1 is jj 0.45.1's MSRV floor, not the newest release. The two
      # targets are the APK ABIs from design decision 19.
      rust = pkgs.rust-bin.stable."1.97.1".default.override {
        targets = [
          "aarch64-linux-android"
          "x86_64-linux-android"
        ];
      };

      # Android SDK: one composition feeds both Flutter/Gradle and the emulator.
      # android-36 and android-37.0 ship together because the ticket "Which
      # Android versions does the first APK support?" is still open; trim the
      # list once it lands.
      androidArgs = {
        platformVersions = [
          "36"
          "37.0"
        ];
        buildToolsVersions = [ "37.0.0" ];
        cmdLineToolsVersion = "22.0";
        platformToolsVersion = "37.0.1";
        includeEmulator = true;
        includeCmake = false;
        includeSystemImages = true;
        # AOSP images only: nothing here needs Play services.
        systemImageTypes = [ "default" ];
        abiVersions = [ "x86_64" ];
        includeNDK = true;
        ndkVersions = [ "29.0.14206865" ];
        # android-sdk-license is always accepted; sdkmanager reports the other
        # seven as unaccepted without these, and `flutter doctor` fails its
        # Android toolchain check on it.
        extraLicenses = [
          "android-sdk-preview-license"
          "android-googletv-license"
          "android-googlexr-license"
          "android-sdk-arm-dbt-license"
          "google-gdk-license"
          "intel-android-extra-license"
          "intel-android-sysimage-license"
          "mips-android-sysimage-license"
        ];
      };

      android = pkgs.androidenv.composeAndroidPackages androidArgs;
      androidSdk = android.androidsdk;
      androidHome = "${androidSdk}/libexec/android-sdk";

      # The emulator route: run-test-emulator creates the AVD on first use,
      # boots it, and waits for the package manager. Override the flags for a
      # headless run with NIX_ANDROID_EMULATOR_FLAGS.
      emulator = pkgs.androidenv.emulateApp {
        name = "jjsync-emulator";
        platformVersion = "36";
        abiVersion = "x86_64";
        systemImageType = "default";
        deviceName = "jjsync";
        configOptions = { "hw.keyboard" = "yes"; };
        sdkExtraArgs = androidArgs;
      };

      jdk = pkgs.jdk;

      pins = {
        nixpkgs = nixpkgs.lib.version;
        rust = rust.version;
        flutter = pkgs.flutter.version;
        androidSdk = androidSdk.version;
        androidPlatforms = androidArgs.platformVersions;
        androidBuildTools = androidArgs.buildToolsVersions;
        androidNdk = androidArgs.ndkVersions;
        cargoNdk = pkgs.cargo-ndk.version;
        flutterRustBridge = pkgs.flutter_rust_bridge_codegen.version;
        jujutsu = pkgs.jujutsu.version;
        git = pkgs.git.version;
        jdk = jdk.version;
      };
    in
    {
      devShells.${system}.default = pkgs.mkShell {
        name = "jjsync";

        packages = [
          # Flutter and the Dart it carries.
          pkgs.flutter
          # Bindings generator; its version must match the flutter_rust_bridge
          # Dart package the app depends on.
          pkgs.flutter_rust_bridge_codegen

          # Android SDK, adb, sdkmanager, avdmanager and the emulator wrapper.
          androidSdk
          android.platform-tools
          emulator
          jdk

          # Rust core: the pinned toolchain, plus the NDK-driven cross builds.
          rust
          pkgs.cargo-ndk

          # Native build tools for the Rust core's C dependencies (libgit2,
          # OpenSSL) and for Flutter's Linux toolchain check.
          pkgs.pkg-config
          pkgs.cmake
          pkgs.ninja
          pkgs.clang
          pkgs.openssl
          pkgs.perl

          # jj drives the real git for fetch, push and clone (git >= 2.42).
          pkgs.jujutsu
          pkgs.git

          pkgs.curl
          pkgs.which
          pkgs.unzip
        ];

        JAVA_HOME = jdk.home;

        # Flutter and Gradle read ANDROID_HOME; the SDK tools read
        # ANDROID_SDK_ROOT; cargo-ndk reads ANDROID_NDK_HOME first.
        ANDROID_HOME = androidHome;
        ANDROID_SDK_ROOT = androidHome;
        ANDROID_NDK_HOME = "${androidHome}/ndk-bundle";
        ANDROID_NDK_ROOT = "${androidHome}/ndk-bundle";

        shellHook = ''
          printf 'jjsync shell: flutter %s | rust %s | jj %s | cargo-ndk %s | ndk %s\n' \
            "${pins.flutter}" "${pins.rust}" "${pins.jujutsu}" "${pins.cargoNdk}" \
            "$(basename "$(readlink -f "$ANDROID_NDK_HOME")")"
        '';
      };

      legacyPackages.${system} = {
        # Cross-compiled C libraries with the Android ABI, for Rust crates that
        # link C code for the APK ABIs:
        #   nix build .#legacyPackages.x86_64-linux.androidAarch64.openssl
        # Ticket "Can jj 0.45.1 cross-compile for Android arm64-v8a and x86_64?"
        # runs inside this dev shell and adds inputs here if it needs them.
        androidAarch64 = pkgs.pkgsCross.aarch64-android;

        # The pinned versions, readable without entering the shell:
        #   nix eval .#legacyPackages.x86_64-linux.pins --json
        pins = pins;
      };
    };
}
