param([string]$Mode="help")

# ==========================================================
# UI & FORMATTING CONSTANTS
# ==========================================================
$esc = [char]27
$RESET = "$esc[0m"
$BOLD  = "$esc[1m"
$CYAN  = "$esc[36m"
$GREEN = "$esc[32m"
$RED   = "$esc[31m"
$YELLOW= "$esc[33m"
$GRAY  = "$esc[90m"

function Print-Header($title) {
    Write-Host ""
    Write-Host "$CYAN$BOLD$title$RESET"
    Write-Host "$GRAY$('='*40)$RESET"
}

function Log-Info($msg) { Write-Host "$GREEN[INFO] $RESET$msg" }
function Log-Warn($msg) { Write-Host "$YELLOW[WARN] $RESET$msg" }
function Log-Err($msg)  { Write-Host "$RED[FAIL] $RESET$msg" }
function Log-Step($msg) { Write-Host "$BOLD[STEP] $msg...$RESET" }

$ErrorActionPreference = "Stop"

# ==========================================================
# CONFIGURATION
# ==========================================================
$baseDir    = $PSScriptRoot
$configFile = Join-Path $baseDir "config.json"

if (!(Test-Path $configFile)) {
    Log-Err "Config file not found: $configFile"
    exit 1
}

$config = Get-Content $configFile | ConvertFrom-Json

$backupDir      = $config.backupDir
$distroName     = $config.distroName
$remote         = $config.rcloneRemote
$retentionLocal = [int]$config.retentionLocal
$retentionCloud = [int]$config.retentionCloud
$logMaxSizeMB   = [int]$config.logMaxSizeMB

if ($retentionLocal -lt 1 -or $retentionCloud -lt 1) {
    Log-Err "Retention values must be greater than zero"
    exit 1
}

if ([string]::IsNullOrWhiteSpace($distroName)) {
    $distroName = (wsl -l -q)[0].Trim()
}

$zstdExe = Join-Path $baseDir "zstd.exe"
if (!(Test-Path $zstdExe)) {
    Log-Err "zstd.exe not found"
    exit 1
}

if (!(Test-Path $backupDir)) {
    New-Item -ItemType Directory -Path $backupDir | Out-Null
}

$logFile = Join-Path $backupDir "backup.log"

# ==========================================================
# LOG ROTATION
# ==========================================================
if (Test-Path $logFile) {
    $sizeMB = (Get-Item $logFile).Length / 1MB
    if ($sizeMB -gt $logMaxSizeMB) {
        Move-Item $logFile "$logFile.old" -Force
    }
}

function Write-Log($msg) {
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Add-Content $logFile "$ts  $msg"
}

# ==========================================================
# HASHING
# ==========================================================
function Get-LocalSHA256($file) {
    (Get-FileHash $file -Algorithm SHA256).Hash.ToLower()
}

function Get-RemoteSHA256($remotePath) {
    $out = rclone sha256sum $remotePath 2>$null
    if ($out) { return $out.Split(" ")[0].ToLower() }
    return $null
}

# ==========================================================
# PROGRESS
# ==========================================================
function Show-Progress($bytes, $start) {
    $mb = [math]::Round($bytes / 1MB, 1)
    $elapsed = (Get-Date) - $start
    $speed = if ($elapsed.TotalSeconds -gt 0) {
        [math]::Round($mb / $elapsed.TotalSeconds, 1)
    } else { 0 }

    $spin = @('|','/','-','\')
    $idx = [math]::Floor($elapsed.TotalSeconds * 4) % 4
    Write-Host -NoNewline "`r$GRAY$($spin[$idx])$RESET Exporting: $CYAN$mb MB$RESET @ $speed MB/s "
}

# ==========================================================
# MAIN LOGIC
# ==========================================================
switch ($Mode) {

    "daily" {
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        Print-Header "STARTING DAILY BACKUP: $distroName"
        Write-Log "Backup started"

        $ts = Get-Date -Format "yyyy-MM-dd_HH-mm"
        $guid = [guid]::NewGuid()
        $tempTar = Join-Path $backupDir "$distroName-$ts-$guid.raw.tar"
        $outZst  = Join-Path $backupDir "$distroName-$ts.zst"

        Log-Step "Exporting WSL distribution"
        $proc = Start-Process wsl -ArgumentList "--export",$distroName,$tempTar -PassThru -NoNewWindow
        $start = Get-Date

        while (!$proc.HasExited) {
            if (Test-Path $tempTar) {
                Show-Progress (Get-Item $tempTar).Length $start
            }
            Start-Sleep -Milliseconds 500
        }
        Write-Host ""

        if (!(Test-Path $tempTar) -or (Get-Item $tempTar).Length -eq 0) {
            Log-Err "Export failed or produced empty archive"
            exit 1
        }

        $rawSize = (Get-Item $tempTar).Length
        Log-Info "Export successful. Raw size: $([math]::Round($rawSize/1GB,2)) GB"

        Log-Step "Compressing with zstd (-10)"
        Start-Process cmd.exe -ArgumentList "/c `"$zstdExe`" -10 `"$tempTar`" -o `"$outZst`" --rm" -Wait -NoNewWindow

        if (!(Test-Path $outZst)) {
            Log-Err "Compression failed"
            exit 1
        }

        $compSize = (Get-Item $outZst).Length
        Log-Info "Compression successful. Size: $([math]::Round($compSize/1GB,2)) GB"

        Log-Step "Uploading to remote ($remote)"
        rclone copyto $outZst "$remote/$(Split-Path $outZst -Leaf)" --progress --transfers=2
        if ($LASTEXITCODE -ne 0) {
            Log-Err "Cloud upload failed"
            exit 1
        }

        Log-Step "Verifying integrity"
        $localHash  = Get-LocalSHA256 $outZst
        $remoteHash = Get-RemoteSHA256 "$remote/$(Split-Path $outZst -Leaf)"

        if (!$remoteHash -or $localHash -ne $remoteHash) {
            Log-Err "Hash mismatch detected"
            exit 1
        }

        Log-Info "Integrity verified"

        Print-Header "RETENTION POLICY"

        $locals = Get-ChildItem $backupDir -Filter "*.zst" |
                  Sort-Object LastWriteTime -Descending

        if ($locals.Count -gt $retentionLocal) {
            $locals | Select-Object -Skip $retentionLocal | ForEach-Object {
                Log-Warn "Deleting old local backup: $($_.Name)"
                Remove-Item $_.FullName -Force
            }
        }

        rclone delete $remote --min-age "${retentionCloud}d" | Out-Null
        Log-Info "Cloud retention applied ($retentionCloud days)"

        $sw.Stop()
        Print-Header "BACKUP COMPLETED SUCCESSFULLY"
        Write-Host "   Distro:   $distroName"
        Write-Host "   Size:     $([math]::Round($compSize/1GB,2)) GB"
        Write-Host "   Time:     $([math]::Round($sw.Elapsed.TotalMinutes,1)) minutes"
        Write-Host "   Remote:   $remote"
        Write-Log "Backup completed"
    }

    "restore-latest" {
        Print-Header "SAFE RESTORE MODE"

        $file = rclone lsl $remote |
                Sort-Object { ($_ -split '\s+')[1] } |
                Select-Object -Last 1

        if (!$file) {
            Log-Err "No backups found in remote"
            exit 1
        }

        $fname = ($file -split '\s+')[-1]
        $localPath = Join-Path $backupDir $fname

        if (!(Test-Path $localPath)) {
            Log-Step "Downloading latest backup"
            rclone copyto "$remote/$fname" $localPath --progress
        }

        $restoreName = "$distroName-Restored"
        if (wsl -l -q | Select-String -Quiet "^$restoreName$") {
            Log-Err "Restore distro already exists"
            exit 1
        }

        $tempTar = Join-Path $backupDir "restore-$([guid]::NewGuid()).tar"

        Log-Step "Decompressing archive"
        Start-Process cmd.exe -ArgumentList "/c `"$zstdExe`" -d `"$localPath`" -o `"$tempTar`"" -Wait -NoNewWindow

        Log-Step "Importing as new distro: $restoreName"
        $restoreDir = Join-Path $backupDir $restoreName
        New-Item -ItemType Directory -Path $restoreDir -Force | Out-Null
        wsl --import $restoreName $restoreDir $tempTar

        Remove-Item $tempTar -Force

        Print-Header "RESTORE COMPLETED"
        Write-Host "To start the restored distro:"
        Write-Host "   wsl -d $restoreName"
    }

    default {
        Print-Header "WSL BACKUP TOOL"
        Write-Host "   wsl-backup daily"
        Write-Host "   wsl-backup restore-latest"
        Write-Host ""
    }
}
