param(
    [ValidateSet("daily","restore-latest","status","help")]
    [string]$Mode = "help"
)

# ==========================================================
# UI CONSTANTS
# ==========================================================
$esc = [char]27
$RESET  = "$esc[0m"
$BOLD   = "$esc[1m"
$CYAN   = "$esc[36m"
$GREEN  = "$esc[32m"
$RED    = "$esc[31m"
$YELLOW = "$esc[33m"
$GRAY   = "$esc[90m"

function Print-Header($t){
    Write-Host ""
    Write-Host "$CYAN$BOLD$t$RESET"
    Write-Host "$GRAY$('='*45)$RESET"
}
function Log-Step($m){ Write-Host "$BOLD[STEP] $m...$RESET" }
function Log-Info($m){ Write-Host "$GREEN[INFO] $RESET$m" }
function Log-Warn($m){ Write-Host "$YELLOW[WARN] $RESET$m" }
function Log-Err ($m){ Write-Host "$RED[FAIL] $RESET$m" }

$ErrorActionPreference = "Stop"

# ==========================================================
# LOAD CONFIG
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

if ([string]::IsNullOrWhiteSpace($distroName)) {
    $distroName = (wsl -l -q)[0].Trim()
}

$zstdExe = Join-Path $baseDir "zstd.exe"
if (!(Test-Path $zstdExe)) {
    Log-Err "zstd.exe not found at $zstdExe"
    exit 1
}

if (!(Test-Path $backupDir)) {
    New-Item -ItemType Directory -Path $backupDir | Out-Null
}

$logFile = Join-Path $backupDir "backup.log"

# ==========================================================
# LOGGING
# ==========================================================
function Write-Log($msg){
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Add-Content $logFile "$ts  $msg"
}

# ==========================================================
# HASHING
# ==========================================================
function Get-LocalSHA256($file){
    (Get-FileHash $file -Algorithm SHA256).Hash.ToLower()
}

function Get-RemoteSHA256($path){
    $out = rclone sha256sum $path 2>$null
    if ($out) { return $out.Split(" ")[0].ToLower() }
    return $null
}

# ==========================================================
# EXPORT PROGRESS
# ==========================================================
function Show-Progress($bytes,$start){
    $mb = [math]::Round($bytes/1MB,1)
    $elapsed = (Get-Date) - $start
    $speed = if ($elapsed.TotalSeconds -gt 0) {
        [math]::Round($mb/$elapsed.TotalSeconds,1)
    } else { 0 }

    $spin = @('|','/','-','\')
    $idx = [math]::Floor($elapsed.TotalSeconds*4) % 4

    Write-Host -NoNewline "`r$GRAY$($spin[$idx])$RESET Exporting: $CYAN$mb MB$RESET @ $speed MB/s "
}

# ==========================================================
# MAIN
# ==========================================================
switch ($Mode) {

# ==========================================================
# DAILY BACKUP
# ==========================================================
"daily" {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    Print-Header "STARTING DAILY BACKUP: $distroName"
    Write-Log "Backup started for $distroName"

    $ts   = Get-Date -Format "yyyy-MM-dd_HH-mm"
    $guid = [guid]::NewGuid()
    $tempTar = Join-Path $backupDir "$distroName-$ts-$guid.raw.tar"
    $outZst  = Join-Path $backupDir "$distroName-$ts.zst"

    # ---------------- EXPORT ----------------
    Log-Step "Exporting WSL distribution"
    $proc = Start-Process wsl `
        -ArgumentList "--export",$distroName,$tempTar `
        -NoNewWindow -PassThru

    $start = Get-Date
    while (!$proc.HasExited) {
        if (Test-Path $tempTar) {
            Show-Progress (Get-Item $tempTar).Length $start
        }
        Start-Sleep -Milliseconds 500
    }
    Write-Host ""

    if (!(Test-Path $tempTar) -or (Get-Item $tempTar).Length -eq 0) {
        Log-Err "Export failed"
        exit 1
    }

    $rawSize = (Get-Item $tempTar).Length
    Log-Info "Export successful. Raw size: $([math]::Round($rawSize/1GB,2)) GB"

    # ---------------- COMPRESSION (FIXED) ----------------
    Log-Step "Compressing with zstd (-10)"

    Start-Process `
        -FilePath $zstdExe `
        -ArgumentList @(
            "-10",
            $tempTar,
            "-o",
            $outZst,
            "--rm"
        ) `
        -NoNewWindow `
        -Wait

    if (!(Test-Path $outZst)) {
        Log-Err "Compression failed"
        exit 1
    }

    $compSize = (Get-Item $outZst).Length
    Log-Info "Compression successful. Size: $([math]::Round($compSize/1GB,2)) GB"

    # ---------------- UPLOAD ----------------
    Log-Step "Uploading to cloud ($remote)"
    rclone copyto $outZst "$remote/$(Split-Path $outZst -Leaf)" --progress --transfers=2
    if ($LASTEXITCODE -ne 0) {
        Log-Err "Upload failed"
        exit 1
    }

    # ---------------- VERIFY ----------------
    Log-Step "Verifying integrity"
    $localHash  = Get-LocalSHA256 $outZst
    $remoteHash = Get-RemoteSHA256 "$remote/$(Split-Path $outZst -Leaf)"

    if (!$remoteHash -or $localHash -ne $remoteHash) {
        Log-Err "Hash mismatch detected"
        exit 1
    }

    Log-Info "Integrity verified"

    # ---------------- RETENTION ----------------
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

# ==========================================================
# RESTORE LATEST (SAFE)
# ==========================================================
"restore-latest" {
    Print-Header "SAFE RESTORE MODE"

    $file = rclone lsl $remote |
            Sort-Object { ($_ -split '\s+')[1] } |
            Select-Object -Last 1

    if (!$file) {
        Log-Err "No backups found in cloud"
        exit 1
    }

    $fname = ($file -split '\s+')[-1]
    $localZst = Join-Path $backupDir $fname

    if (!(Test-Path $localZst)) {
        Log-Step "Downloading latest backup"
        rclone copyto "$remote/$fname" $localZst --progress
    }

    $restoreName = "$distroName-Restored"
    if (wsl -l -q | Select-String -Quiet "^$restoreName$") {
        Log-Err "Restore distro already exists"
        exit 1
    }

    $tempTar = Join-Path $backupDir "restore-$([guid]::NewGuid()).tar"

    Log-Step "Decompressing"
    Start-Process `
        -FilePath $zstdExe `
        -ArgumentList @("-d",$localZst,"-o",$tempTar) `
        -Wait `
        -NoNewWindow

    Log-Step "Importing as $restoreName"
    $restoreDir = Join-Path $backupDir $restoreName
    New-Item -ItemType Directory -Path $restoreDir | Out-Null
    wsl --import $restoreName $restoreDir $tempTar

    Remove-Item $tempTar -Force

    Print-Header "RESTORE COMPLETED"
    Write-Host "Run:  wsl -d $restoreName"
}

# ==========================================================
default {
    Print-Header "WSL BACKUP TOOL"
    Write-Host "  wsl-backup daily"
    Write-Host "  wsl-backup restore-latest"
}
}
