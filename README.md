# Brew Lag

**A robust tool to maintain a "safety lag" for Homebrew packages.**

Brew Lag ensures that your installed Homebrew packages are strictly `N` versions behind the latest release (default: 4 versions). This "lag" provides stability by avoiding bleeding-edge bugs while still receiving security patches.

## 🚀 Features

*   **Version Lag Enforcement**: Automatically downgrades packages that are "too new" and upgrades those that are "too old".
*   **New Package Installation**: Install new packages directly at their lagged version.
*   **Safety First**: Defaults to a **Plan & Apply** workflow. Nothing changes without your explicit command.
*   **Blazing Fast**: Uses optimized parallel Git queries and local caching for instant results.
*   **Safe Dependencies**: Implements "Water Level" resolution to ensure that even when lagging packages, their shared dependencies are synchronized to a compatible version (avoiding "Symbol not found" errors).
*   **Exception Management**: Exclude core system libraries from lagging to prevent ABI compatibility issues.
*   **Persistence**: Remembers your exceptions (overrides) and configuration.
*   **Compatibility**: Works with any Bash version (macOS system or Homebrew).

## 📦 Installation

Just download the script and make it executable:

```bash
chmod +x brew-lag.sh
```

## 🛠 Usage

### 1. Analyze & Plan
Run the script to analyze your system and generate a plan. This is a read-only operation.

```bash
./brew-lag.sh plan
```

*   **First Run**: Takes ~10-15 seconds (scans git history).
*   **Subsequent Runs**: Instant (uses cache).
*   **Fresh Check**: Use `--update` to pull the latest Homebrew data and rescan.
    ```bash
    /bin/bash ./brew-lag.sh plan --update
    ```

> **Important**: Always use `/bin/bash` to run the script. This prevents the script from crashing if it decides to reinstall the `bash` package itself.

### 2. Review Notations
The plan will output a table showing proposed actions.
**Note**: Versions now include the specific commit hash (e.g., `1.6 (cba4ed6)`) for precision.

*   `DOWNGRADE`: Package is newer than the target lag version.
*   `UPGRADE`: Package is older than the target lag version.
*   `SYNC-UP`: Package needs upgrade for dependency compatibility (Water Level).
*   `NEW_INSTALL`: Package not installed, will install lagged version.
*   `OK`: Package is exactly at the target version.
*   `OK-Sync`: Package was moved up by Water Level and is now correct.
*   `EXCEPTed`: Package is excluded from lag rules (kept at latest).

### 3. Apply Changes
Once you are happy with the plan, execute it:

```bash
/bin/bash ./brew-lag.sh apply
```

This will unpin, uninstall, reinstall from the lagged commit, and re-pin each item in the plan.

### 4. Install New Packages
Install a new package directly at its lagged version:

```bash
# Check what version would be installed
./brew-lag.sh install bash-completion@2

# Actually install it
./brew-lag.sh install bash-completion@2 --apply
```

This handles pinned dependencies automatically by temporarily unpinning them during installation.

### 5. Single Package Fix
Want to check or fix just one existing package without scanning everything?

```bash
# Check status
./brew-lag.sh install jq

# Fix this package only
./brew-lag.sh install jq --apply
```

## ⚙️ Configuration & Exceptions

### Managing Exceptions
If you need a specific package to stay on the **latest** version, add it to the exclusion list:

```bash
# Keep bash at latest version
./brew-lag.sh exclude bash

# Resume enforcing lag for bash
./brew-lag.sh include bash

# List all exceptions
./brew-lag.sh list
```

> **Important**: Core system libraries like `ncurses`, `readline`, `libunistring`, `gettext`, and `bash` should typically be excluded. These are dependencies for many packages, and downgrading them breaks ABI compatibility with pre-compiled Homebrew bottles.

### Upgrading Excluded Packages
Excluded packages are still pinned to prevent automatic upgrades. When you're ready to upgrade them:

```bash
./brew-lag.sh upgrade-excluded
```

This will unpin, upgrade, and re-pin all excluded packages in one command.

### Config File
Configuration is stored in `~/.brew-lag/`. You can tune settings in `~/.brew-lag/config`:

```bash
# Number of versions behind latest (Default: 4)
OFFSET=4

# Number of parallel jobs (Default: 4)
PARALLEL_JOBS=8
```

### Cleanup
To remove the local tap and all cached data:

```bash
./brew-lag.sh cleanup
```

## 📋 Command Reference

| Command | Description |
|---------|-------------|
| `plan [--update]` | Analyze packages and generate a plan |
| `apply` | Execute the saved plan |
| `install <pkg> [--apply]` | Install or fix a single package |
| `exclude <pkg>` | Add package to exception list (keep at latest) |
| `include <pkg>` | Remove package from exception list |
| `list` | Show all excluded packages |
| `upgrade-excluded` | Upgrade all excluded packages to latest |
| `cleanup` | Remove local tap and cache |

## ❓ FAQ

**Why "4 versions behind"?**
It's a heuristic for stability. If a package is on v1.5, checking v1.1 usually lands you on a stable, battle-tested release from a few months ago.

**Why does it use Git?**
Homebrew is essentially a Git repository. We query the `git log` of `homebrew/core` to find the exact commit hash that corresponded to previous versions.

**Why are some packages excluded?**
Core system libraries (ncurses, readline, etc.) should be kept at latest because Homebrew bottles are pre-compiled against specific library versions. Downgrading these libraries breaks other packages with "Library not loaded" errors.

**Can I run this in cron?**
Yes, but it's recommended to run it manually to review downgrades, as they can sometimes break data compatibility (e.g., PostgreSQL database formats).
