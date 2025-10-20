# nix-pacman

Personal Nix module to manage Arch Linux packages (pacman/AUR) via home-manager.

## What it does

Allows you to declare Arch/AUR packages in your Nix configuration and have them automatically installed when activating home-manager.

## Structure

```
nix-pacman/
├── flake.nix            # Defines the module and bash script
├── modules/
│   └── nix-pacman.nix   # Home-manager module
└── README.md
```

## Usage

In your main flake (`~/.config/nix/flake.nix`):

```nix
inputs.nix-pacman.url = "path:/Users/palmachris7/.config/nix-pacman";

# Then in your configuration:
nix-pacman = {
  enable = true;
  aurHelper = "yay";                 # or "paru"
  packages = [ "firefox" "htop" ];   # Official packages
  aurPackages = [ "google-chrome" ]; # AUR packages
  safeMode = true;                   # false to actually install
  updatePackages = false;            # true to update system first
};
```

## Options

- `enable` - Activate the module
- `aurHelper` - "yay" or "paru" (default: "yay")
- `packages` - List of official Arch packages
- `aurPackages` - List of AUR packages
- `safeMode` - If `true`, only shows what would be done (dry-run). Default: `true`
- `updatePackages` - If `true`, updates system before installing. Default: `false`

## How it works

1. home-manager creates a bash script at `~/.local/bin/nix-pacman-apply`
2. Validates AUR helper is installed (if needed)
3. Checks which packages are already installed
4. Installs missing packages via pacman/yay
5. Logs everything to `~/.cache/nix-pacman/last.log`
6. Shows summary with success/error/skipped counts

## Notes

- `safeMode = true` by default - packages won't be installed, only shown
- Set `safeMode = false` to actually install packages
- Requires `sudo` access for pacman operations
- AUR helper (yay/paru) must be installed separately if using AUR packages

## Features

- **Safe Mode** - Dry-run to preview changes without installing
- **AUR Helper Validation** - Checks if yay/paru is installed before use
- **Error Tracking** - Reports success/error/skipped package counts
- **Smart Search** - Uses `pacman -Si` for exact package matching
- **Lock Handling** - Waits for pacman database lock (up to 30s)
- **System Updates** - Optional full system update before installing packages
- **Logging** - All operations logged to `~/.cache/nix-pacman/last.log`