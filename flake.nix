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
        echo "DEBUG: Validating AUR helper: $AURHELPER"
        echo "DEBUG: PATH during validation: $PATH"
        
        # First try to find it in PATH
        if command -v "$AURHELPER" >/dev/null 2>&1; then
          echo "DEBUG: Found $AURHELPER in PATH"
          return 0
        fi
        
        # If not in PATH, try common system locations
        for path in "/usr/bin/$AURHELPER" "/usr/local/bin/$AURHELPER" "/bin/$AURHELPER"; do
          echo "DEBUG: Checking $path"
          if [ -x "$path" ]; then
            echo "DEBUG: Found AUR helper at $path"
            AURHELPER="$path"
            export AURHELPER
            return 0
          fi
        done
        
        echo "ERROR: AUR helper '$AURHELPER' is not installed"
        echo "Please install it first: /usr/bin/sudo /usr/bin/pacman -S --needed git base-devel && git clone https://aur.archlinux.org/$AURHELPER.git && cd $AURHELPER && makepkg -si"
        return 1
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
        echo "DEBUG: Checking package: $pkg"
        
        # Check if already installed
        echo "DEBUG: Checking if installed with: /usr/bin/pacman -Qi $pkg"
        if /usr/bin/pacman -Qi "$pkg" >/dev/null 2>&1; then
          echo "skip: $pkg (already installed)"
          return 0
        fi
        
        echo "DEBUG: Package not installed, trying direct install"
        # Skip -Si check and try direct install with pacman -S
        # This is more reliable as -Si may fail in restricted environments
        echo "DEBUG: Attempting: /usr/bin/sudo /usr/bin/pacman -S --noconfirm --needed $pkg"
        if yes 2>/dev/null | /usr/bin/sudo /usr/bin/pacman -S --noconfirm --needed "$pkg" 2>&1 | tee /tmp/pacman-install.log; then
          echo "DEBUG: Install command succeeded"
          echo "Successfully installed: $pkg"
          return 0
        else
          local exit_code=$?
          # Exit code 141 is SIGPIPE from yes command, which is OK if package installed
          if [ $exit_code -eq 141 ] && /usr/bin/pacman -Qi "$pkg" >/dev/null 2>&1; then
            echo "DEBUG: Package installed successfully (ignoring SIGPIPE)"
            echo "Successfully installed: $pkg"
            return 0
          fi
          echo "DEBUG: Install failed with exit code: $exit_code"
          echo "DEBUG: Last log lines:"
          tail -3 /tmp/pacman-install.log
        fi
        
        echo "DEBUG: Not in repos, trying AUR..."
        # Try AUR helper
        if command -v "$AURHELPER" >/dev/null 2>&1 || [ -x "$AURHELPER" ]; then
          echo "DEBUG: AUR helper available at: $AURHELPER"
          echo "installing AUR package via $AURHELPER: $pkg"
          if "$AURHELPER" -S --noconfirm --needed "$pkg"; then
            echo "Successfully installed from AUR: $pkg"
            return 0
          else
            echo "Failed to install from AUR: $pkg"
            return 1
          fi
        else
          echo "DEBUG: AUR helper not found at $AURHELPER"
        fi
        
        echo "ERROR: $pkg not found in repos and $AURHELPER not available" d d
        return 2
      }
      
      # Update system packages if requested
      if [ "$UPDATE_PACKAGES" -eq 1 ]; then
        echo "=== Updating system packages ==="
        if [ "$SAFE_MODE" -eq 1 ]; then
          echo "DRY RUN (safe mode). Would run: sudo /usr/bin/pacman -Syu --noconfirm" | tee -a "$LOGDIR/last.log"
        else
          if ! wait_for_pacman; then
            echo "ERROR: Cannot update, pacman is locked"
          else
            /usr/bin/sudo /usr/bin/pacman -Syu --noconfirm 2>&1 | tee -a "$LOGDIR/last.log"
          fi
        fi
      fi
      
      # Error counters
      ERRORS=0
      SUCCESS=0
      SKIPPED=0
      
      # Get currently installed packages that we manage
      get_managed_packages() {
        local managed_file="$LOGDIR/managed_packages"
        if [ -f "$managed_file" ]; then
          cat "$managed_file"
        fi
      }
      
      # Save list of packages we manage
      save_managed_packages() {
        local managed_file="$LOGDIR/managed_packages"
        printf "%s\n" "''${PACKAGES[@]}" "''${AUR_PACKAGES[@]}" > "$managed_file" 2>/dev/null || true
      }
      
      # Remove packages that are no longer in our lists
      remove_orphaned_packages() {
        local managed_file="$LOGDIR/managed_packages"
        if [ ! -f "$managed_file" ]; then
          return 0
        fi
        
        echo "=== Checking for packages to remove ==="
        local current_packages=($(cat "$managed_file" 2>/dev/null || true))
        local all_desired=("''${PACKAGES[@]}" "''${AUR_PACKAGES[@]}")
        
        for old_pkg in "''${current_packages[@]}"; do
          [ -z "$old_pkg" ] && continue
          local found=false
          for new_pkg in "''${all_desired[@]}"; do
            if [ "$old_pkg" = "$new_pkg" ]; then
              found=true
              break
            fi
          done
          
          if [ "$found" = false ] && /usr/bin/pacman -Qi "$old_pkg" >/dev/null 2>&1; then
            echo "-- removing orphaned package: $old_pkg --"
            if [ "$SAFE_MODE" -eq 1 ]; then
              echo "DRY RUN (safe mode). Would remove: $old_pkg" | tee -a "$LOGDIR/last.log"
            else
              if /usr/bin/sudo /usr/bin/pacman -Rns --noconfirm "$old_pkg" 2>&1 | tee -a "$LOGDIR/last.log"; then
                echo "Successfully removed: $old_pkg"
              else
                echo "Failed to remove: $old_pkg" | tee -a "$LOGDIR/last.log"
                ((ERRORS++))
              fi
            fi
          fi
        done
      }
      
      # Remove orphaned packages before installing new ones
      remove_orphaned_packages
      
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
      
      # Save current package list for next run
      save_managed_packages
      
      echo ""
      echo "=== nix-pacman Summary ==="
      echo "Mode: $([ "$SAFE_MODE" -eq 1 ] && echo "DRY RUN (safe mode)" || echo "INSTALLATION MODE")"
      echo "Success: $SUCCESS"
      echo "Errors: $ERRORS"
      echo "Skipped: $SKIPPED"
      echo "Logs: $LOGDIR/last.log"
      echo "Managed packages: $LOGDIR/managed_packages"
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