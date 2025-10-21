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
      INTERACTION_LEVEL=''${INTERACTION_LEVEL:-automatic}
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
        local install_output
        local install_status
        
        if [ "$is_aur" = "true" ]; then
          if [ -x "$AURHELPER" ]; then
            if [ "$INTERACTION_LEVEL" = "full" ]; then
              # Full interactive: user answers ALL questions
              echo "⚠️  Full interactive mode: You answer ALL questions for $pkg"
              install_output=$(export PATH="/usr/bin:/usr/local/bin:/bin:$PATH"; \
                             "$AURHELPER" -S --needed "$pkg" 2>&1)
              install_status=$?
            elif [ "$INTERACTION_LEVEL" = "medium" ]; then
              # Medium interactive: flags handle common questions, user answers special ones
              echo "⚠️  Medium interactive mode: Flags handle common questions, you answer special ones for $pkg"
              install_output=$(export PATH="/usr/bin:/usr/local/bin:/bin:$PATH"; \
                             "$AURHELPER" -S --noconfirm --needed \
                             --answerdiff=None --answerclean=None --answeredit=None \
                             --answerupgrade=None --removemake "$pkg" 2>&1)
              install_status=$?
            else
              # Automatic: use flags to skip prompts + echo "n" for remaining prompts
              install_output=$(export PATH="/usr/bin:/usr/local/bin:/bin:$PATH"; \
                             echo "n" | "$AURHELPER" -S --noconfirm --needed \
                             --answerdiff=None --answerclean=None --answeredit=None \
                             --answerupgrade=None --removemake "$pkg" 2>&1)
              install_status=$?
            fi
          else
            echo "ERROR: AUR helper not found"
            return 1
          fi
        else
          # Pacman packages - also respect interaction level
          if [ "$INTERACTION_LEVEL" = "full" ]; then
            # Full interactive: no automatic flags
            install_output=$($SUDO $PACMAN -S --needed "$pkg" 2>&1)
            install_status=$?
          else
            # Automatic/Medium: use --noconfirm to skip confirmations
            install_output=$(yes 2>/dev/null | $SUDO $PACMAN -S --noconfirm --needed "$pkg" 2>&1)
            install_status=$?
          fi
        fi
        
        # Verify installation
        if $PACMAN -Qi "$pkg" >/dev/null 2>&1; then
          echo "✓ $pkg installed successfully"
          return 0
        else
          # Check for specific errors in output
          if echo "$install_output" | grep -q "not compatible with your architecture"; then
            echo "✗ $pkg - incompatible architecture (skipping)"
          elif echo "$install_output" | grep -q "not available for the.*architecture"; then
            echo "✗ $pkg - not available for this architecture (skipping)"
          else
            echo "✗ $pkg failed to install"
          fi
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
      
      # Summary
      echo ""
      echo "=== Summary ==="
      echo "Mode: $([ "$SAFE_MODE" -eq 1 ] && echo "DRY RUN" || echo "INSTALL")"
      echo "Interaction: $INTERACTION_LEVEL"
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
