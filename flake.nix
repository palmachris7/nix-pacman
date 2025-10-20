{
  description = "nix-pacman - Manage Arch Linux packages (pacman/AUR) with Home Manager";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, home-manager }: 
  let
    # Support systems
    supportedSystems = [ "x86_64-linux" "aarch64-linux" ];
    forAllSystems = nixpkgs.lib.genAttrs supportedSystems;
    
    # The nix-pacman script as a text string for inclusion in the module
    nix-pacman-script = ''
      #!/usr/bin/env bash
      set -euo pipefail
      
      # Configuration via environment variables
      AURHELPER=''${AURHELPER:-yay}
      SAFE_MODE=''${SAFE_MODE:-1}
      UPDATE_PACKAGES=''${UPDATE_PACKAGES:-0}
      LOGDIR="''${HOME}/.cache/nix-pacman"
      mkdir -p "$LOGDIR"
      
      # Validate AUR helper is installed if we have AUR packages
      validate_aur_helper() {
        if ! command -v "$AURHELPER" >/dev/null 2>&1; then
          echo "ERROR: AUR helper '$AURHELPER' is not installed"
          echo "Please install it first: sudo pacman -S --needed git base-devel && git clone https://aur.archlinux.org/$AURHELPER.git && cd $AURHELPER && makepkg -si"
          return 1
        fi
        return 0
      }
      
      # Parse command line arguments
      PACKAGES=()
      AUR_PACKAGES=()
      
      # First argument after -- is PACKAGES list
      # Second argument after -- is AUR_PACKAGES list
      if [[ "$#" -ge 2 ]]; then
          IFS=',' read -ra PACKAGES <<< "$1"
          IFS=',' read -ra AUR_PACKAGES <<< "$2"
      else
          echo "Usage: $0 'pkg1,pkg2' 'aurpkg1,aurpkg2'"
          echo "Note: Package lists must be comma-separated with no spaces"
          echo "Or set environment variables: PACKAGES and AUR_PACKAGES"
          exit 1
      fi
      
      # helper to wait for pacman lock
      wait_for_pacman() {
        local tries=0
        while [ -f /var/lib/pacman/db.lck ] && [ $tries -lt 30 ]; do
          echo "pacman db locked, waiting... ($tries)"
          sleep 1
          tries=$((tries+1))
        done
        if [ -f /var/lib/pacman/db.lck ]; then
          echo "pacman DB lock still present, aborting"
          return 1
        fi
        return 0
      }
      
      apply_pkg() {
        local pkg="$1"
        if pacman -Qi "$pkg" >/dev/null 2>&1; then
          echo "skip: $pkg (already installed)"
          return 0
        fi
        # Use -Si for exact package search in repos
        if pacman -Si "$pkg" >/dev/null 2>&1; then
          echo "installing repo package: $pkg"
          sudo pacman -S --noconfirm --needed "$pkg"
          return $?
        fi
        # fallback to AUR helper
        if command -v "$AURHELPER" >/dev/null 2>&1; then
          echo "installing AUR package via $AURHELPER: $pkg"
          $AURHELPER -S --noconfirm --needed "$pkg"
          return $?
        fi
        echo "WARN: $pkg not found in repos and $AURHELPER not installed"
        return 2
      }
      
      # Update system packages if requested
      if [ "$UPDATE_PACKAGES" -eq 1 ]; then
        echo "=== Updating system packages ==="
        if [ "$SAFE_MODE" -eq 1 ]; then
          echo "DRY RUN (safe mode). Would run: sudo pacman -Syu --noconfirm" | tee -a "$LOGDIR/last.log"
        else
          if ! wait_for_pacman; then
            echo "ERROR: Cannot update, pacman is locked"
          else
            sudo pacman -Syu --noconfirm 2>&1 | tee -a "$LOGDIR/last.log"
          fi
        fi
      fi
      
      # Error counters
      ERRORS=0
      SUCCESS=0
      SKIPPED=0
      
      # Process regular packages
      echo "=== Processing repo packages ==="
      for pkg in "''${PACKAGES[@]}"; do
        [ -z "$pkg" ] && continue
        echo "-- processing $pkg --"
        if ! wait_for_pacman; then
          echo "Skipping $pkg due to pacman lock"
          ((SKIPPED++))
          continue
        fi
        if [ "$SAFE_MODE" -eq 1 ]; then
          echo "DRY RUN (safe mode). Would install: $pkg" | tee -a "$LOGDIR/last.log"
          ((SUCCESS++))
        else
          if apply_pkg "$pkg" 2>&1 | tee -a "$LOGDIR/last.log"; then
            ((SUCCESS++))
          else
            ((ERRORS++))
          fi
        fi
      done
      
      # Validate AUR helper before processing AUR packages
      if [ ''${#AUR_PACKAGES[@]} -gt 0 ] && [ -n "''${AUR_PACKAGES[0]}" ]; then
        if ! validate_aur_helper; then
          echo "ERROR: Skipping all AUR packages due to missing AUR helper" | tee -a "$LOGDIR/last.log"
          ERRORS=$((ERRORS + ''${#AUR_PACKAGES[@]}))
        else
          # Process AUR packages
          echo "=== Processing AUR packages ==="
          for pkg in "''${AUR_PACKAGES[@]}"; do
            [ -z "$pkg" ] && continue
            echo "-- processing AUR: $pkg --"
            if ! wait_for_pacman; then
              echo "Skipping $pkg due to pacman lock"
              ((SKIPPED++))
              continue
            fi
            if [ "$SAFE_MODE" -eq 1 ]; then
              echo "DRY RUN (safe mode). Would install AUR: $pkg" | tee -a "$LOGDIR/last.log"
              ((SUCCESS++))
            else
              if apply_pkg "$pkg" 2>&1 | tee -a "$LOGDIR/last.log"; then
                ((SUCCESS++))
              else
                ((ERRORS++))
              fi
            fi
          done
        fi
      fi
      
      echo ""
      echo "=== nix-pacman Summary ==="
      echo "Mode: $([ "$SAFE_MODE" -eq 1 ] && echo "DRY RUN (safe mode)" || echo "INSTALLATION MODE")"
      echo "Success: $SUCCESS"
      echo "Errors: $ERRORS"
      echo "Skipped: $SKIPPED"
      echo "Logs: $LOGDIR/last.log"
      echo ""
      
      # Exit with error if there were failures
      if [ "$ERRORS" -gt 0 ]; then
        exit 1
      fi
    '';
  in
  {
    # Export home-manager module for all systems
    homeManagerModules = {
      default = import ./modules/nix-pacman.nix { inherit nix-pacman-script; };
      nix-pacman = import ./modules/nix-pacman.nix { inherit nix-pacman-script; };
    };
  };
}