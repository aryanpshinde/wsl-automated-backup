# WSL Automated Backup

Automated, compressed, and cloud-synced backup system for Windows Subsystem for Linux (WSL) distributions.

## Overview

This system provides a production-grade disaster recovery pipeline for WSL environments. It automates the complete backup lifecycle: export, compression, cloud synchronization, integrity verification, and retention management. The tool treats your WSL distros as critical systems that deserve automated, audited backups.

**Status:** Production Ready (v1.0)

## Features

- **Cold Backup Consistency**: Automatically terminates running distros before export to ensure filesystem consistency
- **High-Ratio Compression**: ZSTD compression typically achieves 60-70% size reduction
  - Example: 4.5GB Ubuntu distro → 1.5GB backup (2.99:1 ratio) in ~3 minutes
- **Cloud Integration**: Native Rclone support for Google Drive, OneDrive, AWS S3, and 40+ backends
- **Cryptographic Verification**: Post-upload hash validation (SHA256, SHA1, or MD5) to detect corruption or tampering
- **Concurrency Locking**: Prevents overlapping backup runs; auto-recovers from stale locks
- **Retention Policies**: Separate rotation schedules for local and cloud storage
- **Pre-flight Validation**: Disk space checks, WSL health verification, and distro availability confirmation
- **Safe Error Handling**: Automatic cleanup of partial files on failure

## Requirements

- Windows 10 (build 19041+) or Windows 11 with WSL2 enabled
- PowerShell 7.2 or newer ([download](https://aka.ms/powershell))
- WSL2 with at least one distribution installed
- [Rclone](https://rclone.org) installed and configured with a remote
- [Zstandard](https://github.com/facebook/zstd) (zstd.exe) placed in the script directory
  - Quick install: `winget install zstandard`

## Installation

1. Clone or download this repository to a location on your system:
   ```powershell
   git clone https://github.com/yourusername/wsl-backup
   cd wsl-backup
   ```

2. Download zstd.exe and place it in the script directory:
   ```powershell
   # On Windows, using curl:
   curl -L https://github.com/facebook/zstd/releases/download/v1.5.5/zstd-v1.5.5-win64.zip -o zstd.zip
   Expand-Archive zstd.zip
   Copy-Item zstd-v1.5.5-win64/zstd.exe .
   Remove-Item zstd.zip, zstd-v1.5.5-win64 -Recurse
   ```

3. Configure Rclone with a remote backend:
   ```powershell
   rclone config
   # Follow prompts to set up your cloud backend (e.g., 'gdrive', 'onedrive', 's3backup')
   ```

4. Create and edit config.json:
   ```json
   {
       "backupDir": "C:\\WSL-Backups",
       "distroName": "Ubuntu",
       "rcloneRemote": "gdrive:WSL-Backups",
       "retentionLocal": 7,
       "retentionCloud": 30,
       "compressionLevel": 10,
       "hashAlgorithm": "SHA256"
   }
   ```

5. (Optional) Add the script directory to your PATH for global access:
   ```powershell
   $scriptDir = "C:\path\to\wsl-backup"
   [Environment]::SetEnvironmentVariable(
       "Path",
       [Environment]::GetEnvironmentVariable("Path") + ";$scriptDir",
       "User"
   )
   ```

## Configuration

The config.json file controls all aspects of the backup behavior:

### Required Fields

| Field        | Type   | Description                                                                             |
| ------------ | ------ | --------------------------------------------------------------------------------------- |
| backupDir    | string | Local directory where backup archives are stored. Will be created if it does not exist. |
| rcloneRemote | string | Rclone remote path in the format remote-name:path. Example: gdrive:WSL-Backups          |

### Optional Fields

| Field            | Type   | Default       | Description                                                               |
| ---------------- | ------ | ------------- | ------------------------------------------------------------------------- |
| distroName       | string | (auto-detect) | WSL distro name to back up. If empty, the first available distro is used. |
| retentionLocal   | int    | 7             | Number of days to retain backups in local storage before deletion.        |
| retentionCloud   | int    | 30            | Number of days to retain backups in cloud storage before deletion.        |
| compressionLevel | int    | 10            | ZSTD compression level (1-19). Higher = smaller file, slower compression. |
| hashAlgorithm    | string | SHA256        | Hash algorithm for integrity verification: SHA256, SHA1, or MD5.          |

## Usage

### Syntax

```
wsl-backup [command] [-ConfigPath <path>] [-WhatIf] [-Verbose] [-Force]
```

### Commands

#### daily

Perform a complete backup cycle: export, compress, upload, verify, and apply retention.

```powershell
wsl-backup daily
```

#### status

Display the current backup health, WSL distro state, and recent backup statistics.

```powershell
wsl-backup status
```

#### restore-latest

Display manual restore instructions for disaster recovery.

```powershell
wsl-backup restore-latest
```

#### help

Display command syntax and available options.

```powershell
wsl-backup help
```

## Exit Codes

| Code | Meaning                                                       |
| ---- | ------------------------------------------------------------- |
| 0    | Success                                                       |
| 1    | Configuration error, validation failure, or operation failure |

## Architecture

Pipeline Flow:

```
WSL Distro
    │
    ├─→ [Pre-flight Checks]
    │   ├─ Admin rights
    │   ├─ WSL health
    │   ├─ Disk space
    │   └─ Distro availability
    │
    ├─→ [Lock Acquisition]
    │
    ├─→ [Export]
    │   └─ wsl --export → TAR
    │
    ├─→ [Compress]
    │   └─ ZSTD compression
    │
    ├─→ [Upload]
    │   └─ Rclone to cloud
    │
    ├─→ [Verify]
    │   └─ Compare hashes
    │
    ├─→ [Retention]
    │
    └─→ [Lock Release]
```

## License

Licensed under the MIT License. See LICENSE file for details.
