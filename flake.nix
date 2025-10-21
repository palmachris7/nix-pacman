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
    supportedSystems = [ "x86_64-linux" "aarch64-linux" ];
    forAllSystems = nixpkgs.lib.genAttrs supportedSystems;
    
    nix-pacman-script = ''
      #!/usr/bin/env bash
      set -eo pipefail
      
      # Configuration
      AURHELPER=''${AURHELPER:-yay}
      SAFE_MODE=''${SAFE_MODE:-1}
      UPDATE_PACKAGES=''${UPDATE_PACKAGES:-0}
      LOGDIR="''${HOME}/.cache/nix-pacman"
      mkdir -p "$LOGDIR"
      
      # Use full paths for all commands
      PACMAN="/usr/bin/pacman"
      SUDO="/usr/bin/sudo"
      
      # Find AUR helper
      if [ ! -x "$AURHELPER" ]; then
        for path in "/usr/bin/$AURHELPER" "/usr/local/bin/$AURHELPER"; do
          if [ -x "$path" ]; then
            AURHELPER="$path"
            break
          fi
        done
      fi
      
      # Parse arguments
      PACKAGES=()
      AUR_PACKAGES=()
      if [[ "$#" -ge 2 ]]; then
        IFS=',' read -ra PACKAGES <<< "$1"
        IFS=',' read -ra AUR_PACKAGES <<< "$2"
      fi
      
      # File to track installed packages
      INSTALLED_FILE="$HOME/.nix-pacman-installed"
      
      # Read previous installed packages
      declare -A previous_packages
      if [ -f "$INSTALLED_FILE" ]; then
        echo "[DEBUG] Reading previous installed packages from $INSTALLED_FILE"
        while IFS= read -r pkg; do
          [ -n "$pkg" ] && previous_packages["$pkg"]=1
        done < "$INSTALLED_FILE"
        echo "[DEBUG] Previous packages: ''${!previous_packages[@]}"
      else
        echo "[DEBUG] No previous installed packages file found at $INSTALLED_FILE"
      fi
      
      # Current desired packages
      current_packages=()
      for pkg in "''${PACKAGES[@]}"; do
        [ -n "$pkg" ] && current_packages+=("$pkg")
      done
      for pkg in "''${AUR_PACKAGES[@]}"; do
        [ -n "$pkg" ] && current_packages+=("$pkg")
      done
      echo "[DEBUG] Current desired packages: ''${current_packages[@]}"
      
      # Uninstall packages not in current list
      echo "[DEBUG] Checking for packages to uninstall..."
      packages_to_remove=()
      for pkg in "''${!previous_packages[@]}"; do
        if [[ ! " ''${current_packages[*]} " =~ " $pkg " ]]; then
          packages_to_remove+=("$pkg")
        fi
      done
      
      if [ ''${#packages_to_remove[@]} -gt 0 ]; then
        echo "[DEBUG] Packages to remove: ''${packages_to_remove[@]}"
        for pkg in "''${packages_to_remove[@]}"; do
          echo "nix-pacman: Removing $pkg (no longer in config)"
          if [ "$SAFE_MODE" -eq 0 ]; then
            echo "[DEBUG] Executing: $AURHELPER -Rns $pkg --noconfirm"
            "$AURHELPER" -Rns "$pkg" --noconfirm 2>/dev/null || echo "Warning: Could not remove $pkg"
          else
            echo "[DEBUG] SAFE MODE: Would remove $pkg"
          fi
        done
      else
        echo "[DEBUG] No packages to remove"
      fi
      
      # Counters
      ERRORS=0
      SUCCESS=0
      SKIPPED=0
      
      # Install package function
      install_package() {
        local pkg="$1"
        local is_aur="$2"
        
        echo "[DEBUG] install_package called for: $pkg (AUR: $is_aur)"
        
        # Check if already installed
        if $PACMAN -Qi "$pkg" >/dev/null 2>&1; then
          echo "✓ $pkg (already installed)"
          echo "[DEBUG] Returning from install_package (already installed)"
          return 0
        fi
        
        # Install
        if [ "$SAFE_MODE" -eq 1 ]; then
          echo "DRY RUN: Would install $pkg"
          return 0
        fi
        
        echo "Installing $pkg..."
        if [ "$is_aur" = "true" ]; then
          if [ -x "$AURHELPER" ]; then
            # Run yay with explicit environment and no privilege elevation
            # yay will call sudo internally when needed
            (export PATH="/usr/bin:/usr/local/bin:/bin:$PATH"; yes 2>/dev/null | "$AURHELPER" -S --noconfirm --needed "$pkg") || true
          else
            echo "ERROR: AUR helper not found"
            return 1
          fi
        else
          yes 2>/dev/null | $SUDO $PACMAN -S --noconfirm --needed "$pkg" || true
        fi
        
        # Verify installation
        if $PACMAN -Qi "$pkg" >/dev/null 2>&1; then
          echo "✓ $pkg installed successfully"
          return 0
        else
          echo "✗ $pkg failed to install"
          return 1
        fi
      }
      
      # Process regular packages
      echo "=== Installing packages ==="
      for pkg in "''${PACKAGES[@]}"; do
        [ -z "$pkg" ] && continue
        echo "[DEBUG] About to install: $pkg"
        if install_package "$pkg" "false"; then
          SUCCESS=$((SUCCESS + 1))
          echo "[DEBUG] Success count: $SUCCESS"
        else
          ERRORS=$((ERRORS + 1))
          echo "[DEBUG] Error count: $ERRORS"
        fi
        echo "[DEBUG] Finished processing: $pkg"
      done
      
      echo "[DEBUG] Finished processing regular packages"
      echo "[DEBUG] About to process AUR packages"
      
      # Process AUR packages
      echo "[DEBUG] AUR packages count: ''${#AUR_PACKAGES[@]}"
      echo "[DEBUG] First AUR package: ''${AUR_PACKAGES[0]}"
      if [ ''${#AUR_PACKAGES[@]} -gt 0 ] && [ -n "''${AUR_PACKAGES[0]}" ]; then
        echo ""
        echo "=== Installing AUR packages ==="
        for pkg in "''${AUR_PACKAGES[@]}"; do
          echo "[DEBUG] Processing AUR package: $pkg"
          [ -z "$pkg" ] && continue
          if install_package "$pkg" "true"; then
            ((SUCCESS++))
          else
            ((ERRORS++))
          fi
        done
      else
        echo "[DEBUG] No AUR packages to process"
      fi
      
      # Save current installed packages list
      echo "[DEBUG] Saving current packages list to $INSTALLED_FILE"
      printf '%s\n' "''${current_packages[@]}" > "$INSTALLED_FILE"
      echo "[DEBUG] Saved ''${#current_packages[@]} packages to tracking file"
      
      # Summary
      echo ""
      echo "=== Summary ==="
      echo "Mode: $([ "$SAFE_MODE" -eq 1 ] && echo "DRY RUN" || echo "INSTALL")"
      echo "Success: $SUCCESS"
      echo "Errors: $ERRORS"
      
      [ "$ERRORS" -gt 0 ] && exit 1
      exit 0
    '';
  in
  {
    homeManagerModules = {
      default = import ./modules/nix-pacman.nix { inherit nix-pacman-script; };
      nix-pacman = import ./modules/nix-pacman.nix { inherit nix-pacman-script; };
    };
  };
}
