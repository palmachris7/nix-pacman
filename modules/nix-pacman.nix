# Import the script from the flake
{ nix-pacman-script }: { config, pkgs, lib, ... }:

let
  cfg = config.nix-pacman;
in
{
  options.nix-pacman = {
    enable = lib.mkEnableOption "Enable nix-pacman helper to manage Arch Linux packages";

    aurHelper = lib.mkOption {
      type = lib.types.str;
      default = "yay";
      description = "AUR helper to use (yay/paru).";
    };

    packages = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      example = [ "base-devel" "htop" "firefox" ];
      description = "List of pacman repo packages to manage.";
    };

    aurPackages = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      example = [ "google-chrome" ];
      description = "List of AUR packages to manage via aurHelper.";
    };

    safeMode = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "If true, installation won't run automatically on activation (script is deployed but only dry-runs).";
    };

    updatePackages = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "If true, runs 'pacman -Syu' to update all system packages before installing declared packages.";
    };

    interactiveMode = lib.mkOption {
      type = lib.types.enum [ "automatic" "medium" "full" ];
      default = "automatic";
      description = ''
        Interaction level for AUR packages:
        - "automatic": All questions answered automatically
        - "medium": Common questions auto-answered, user answers special questions (like architecture, licenses)
        - "full": User answers all questions manually
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # Deploy script into the user's home via home-manager
    home.file.".local/bin/nix-pacman-apply" = {
      text = nix-pacman-script;
      executable = true;
    };

    # Provide activation hook that runs script with parameters directly
    home.activation.nix-pacman = lib.hm.dag.entryAfter ["writeBoundary"] ''
      # Format packages as comma-separated list for the script
      PACKAGES_LIST="${lib.strings.concatStringsSep "," cfg.packages}"
      AUR_PACKAGES_LIST="${lib.strings.concatStringsSep "," cfg.aurPackages}"
      
      echo "nix-pacman: helper at $HOME/.local/bin/nix-pacman-apply"
      echo "nix-pacman: packages = $PACKAGES_LIST"
      echo "nix-pacman: aurPackages = $AUR_PACKAGES_LIST"
      
      export AURHELPER="${cfg.aurHelper}"
      
      if [ -x "$HOME/.local/bin/nix-pacman-apply" ]; then
        # Run script with package lists as arguments
        if [ "${toString cfg.safeMode}" = "true" ]; then
          echo "nix-pacman: SAFE MODE enabled (dry run only)"
          export SAFE_MODE=1
        else
          echo "nix-pacman: SAFE MODE disabled (packages will be installed)"
          export SAFE_MODE=0
        fi
        
        if [ "${toString cfg.updatePackages}" = "true" ]; then
          echo "nix-pacman: UPDATE PACKAGES enabled"
          export UPDATE_PACKAGES=1
        else
          export UPDATE_PACKAGES=0
        fi
        
        echo "nix-pacman: INTERACTION LEVEL = ${cfg.interactiveMode}"
        export INTERACTION_LEVEL="${cfg.interactiveMode}"
        
        if [ -n "$PACKAGES_LIST" ] || [ -n "$AUR_PACKAGES_LIST" ]; then
          "$HOME/.local/bin/nix-pacman-apply" "$PACKAGES_LIST" "$AUR_PACKAGES_LIST"
        else
          echo "nix-pacman: No packages specified - nothing to do"
        fi
      else
        echo "nix-pacman: ERROR - script not found or not executable"
      fi
    '';
  };
}