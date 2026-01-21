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
# CONFIGURATION & SETUP
# ==========================================================
$baseDir = $PSScriptRoot
$configFile = Join-Path $baseDir "config.json"

if (!(Test-Path $configFile)) {
    Log-Err "Config file not found at: $configFile"
    Write-Host ""
    exit 1
}

$config = Get-Content $configFile | ConvertFrom-Json
$backupDir      = $config.backupDir
$distroName     = $config.distroName
$remote         = $config.rcloneRemote
$retentionLocal = $config.retentionLocal
$retentionCloud = $config.retentionCloud
$logFile        = Join-Path $backupDir "backup.log"

if ([string]::IsNullOrWhiteSpace($distroName)) {
    $distroName = (wsl -l -q).Split("`n")[0].Trim()
}

$zstdExe = Join-Path $baseDir "zstd.exe"
if (!(Test-Path $zstdExe)) {
    Log-Err "zstd.exe not found at $zstdExe"
    Write-Host ""
    exit 1
}

if (!(Test-Path $backupDir)) { New-Item -ItemType Directory -Path $backupDir | Out-Null }

function Write-Log($msg) {
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Add-Content $logFile "$ts  $msg"
}

# ==========================================================
# CORE FUNCTIONS
# ==========================================================

function Get-FastMD5($file) {
    $hash = certutil -hashfile "$file" MD5 | Select-Object -Skip 1 -First 1
    return $hash -replace " ",""
}

function Show-Progress($currentBytes, $startTime) {
    $mb = [math]::Round($currentBytes / 1MB, 1)
    $elapsed = (Get-Date) - $startTime
    $speed = if ($elapsed.TotalSeconds -gt 0) { [math]::Round($mb / $elapsed.TotalSeconds, 1) } else { 0 }
    
    $spin = @('|', '/', '-', '\')
    $idx = [math]::Floor($elapsed.TotalSeconds * 4) % 4
    
    Write-Host -NoNewline "`r$GRAY$($spin[$idx])$RESET Exporting: $CYAN$mb MB$RESET written @ $speed MB/s  "
}

# ==========================================================
# MAIN LOGIC
# ==========================================================
switch ($Mode) {

    # ============================
    # DAILY BACKUP ROUTINE
    # ============================
    "daily" {
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        Print-Header "🚀 STARTING DAILY BACKUP: $distroName"
        Write-Log "Backup started for $distroName"

        $ts = Get-Date -Format "yyyy-MM-dd_HH-mm"
        $tempTar = Join-Path $backupDir "$distroName-$ts.raw.tar"
        $outZst  = Join-Path $backupDir "$distroName-$ts.zst"

        Log-Step "Exporting WSL Distribution"
        
        if (Test-Path $tempTar) { Remove-Item $tempTar -Force }

        $proc = Start-Process wsl -ArgumentList "--export", $distroName, $tempTar -NoNewWindow -PassThru
        $startExport = Get-Date

        while (!$proc.HasExited) {
            if (Test-Path $tempTar) {
                Show-Progress (Get-Item $tempTar).Length $startExport
            }
            Start-Sleep -Milliseconds 500
        }
        Write-Host ""

        if ($proc.ExitCode -ne 0) {
            Log-Err "WSL Export failed with exit code $($proc.ExitCode)"
            Write-Log "Export failed"
            Write-Host ""
            exit 1
        }
        
        $rawSize = (Get-Item $tempTar).Length
        Log-Info "Export success. Raw size: $([math]::Round($rawSize/1GB, 2)) GB"

        Log-Step "Compressing (zstd -10)"
        $cmdArgs = "/c `"$zstdExe`" -10 `"$tempTar`" -o `"$outZst`" --rm"
        Start-Process cmd.exe -ArgumentList $cmdArgs -NoNewWindow -Wait
        
        if (!(Test-Path $outZst)) {
            Log-Err "Compression failed. Output file missing."
            Write-Host ""
            exit 1
        }
        $compSize = (Get-Item $outZst).Length
        Log-Info "Compression success. Size: $([math]::Round($compSize/1GB, 2)) GB"

        Log-Step "Syncing to Cloud ($remote)"
        $rcloneArgs = @("copyto", "$outZst", "$remote/$($outZst | Split-Path -Leaf)", "--progress", "--transfers=2")
        $upload = Start-Process rclone -ArgumentList $rcloneArgs -NoNewWindow -Wait -PassThru

        if ($upload.ExitCode -ne 0) {
            Log-Err "Cloud upload failed."
            Write-Log "Cloud upload failed"
            Write-Host ""
            exit 1
        }

        Log-Step "Verifying Integrity"
        Write-Host -NoNewline "$GRAY   Computing Local Hash... $RESET"
        $localHash = Get-FastMD5 $outZst
        Write-Host "$GREEN OK $RESET"

        Write-Host -NoNewline "$GRAY   Fetching Remote Hash... $RESET"
        $remoteHashObj = rclone md5sum "$remote/$($outZst | Split-Path -Leaf)"
        if ($remoteHashObj) {
            $remoteHash = $remoteHashObj.ToString().Split(" ")[0]
        } else {
            Log-Err "Could not fetch remote hash."
            Write-Host ""
            exit 1
        }
        Write-Host "$GREEN OK $RESET"

        if ($localHash -ne $remoteHash) {
            Log-Err "HASH MISMATCH! Backup corrupted."
            Log-Err "Local:  $localHash"
            Log-Err "Remote: $remoteHash"
            Write-Host ""
            exit 1
        }
        Log-Info "Integrity Verified."

        Print-Header "🧹 RETENTION POLICY"
        
        $files = Get-ChildItem $backupDir -Filter "*.zst" | Sort-Object LastWriteTime
        $cutoff = (Get-Date).AddDays(-$retentionLocal)
        
        foreach ($f in $files) {
            if ($f.LastWriteTime -lt $cutoff) {
                Log-Warn "Deleting old local backup: $($f.Name)"
                Remove-Item $f.FullName -Force
            }
        }

        rclone delete $remote --min-age "${retentionCloud}d" | Out-Null
        Log-Info "Cloud retention applied ($retentionCloud days)."

        $sw.Stop()
        Print-Header "✅ BACKUP SUCCESSFUL"
        Write-Host "   📂 Distro:    $distroName"
        Write-Host "   💾 Size:      $([math]::Round($compSize/1GB, 2)) GB (Raw: $([math]::Round($rawSize/1GB, 2)) GB)"
        Write-Host "   ⏱️ Time:       $([math]::Round($sw.Elapsed.TotalMinutes, 1)) min"
        Write-Host "   ☁️ Location:  $remote"
        Write-Log "Backup completed successfully"
        Write-Host ""
    }

    # ============================
    # STATUS CHECK
    # ============================
    "status" {
        Print-Header "📊 BACKUP STATUS"
        $latest = Get-ChildItem $backupDir -Filter "*.zst" | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        
        if ($latest) {
            $age = New-TimeSpan -Start $latest.LastWriteTime -End (Get-Date)
            Write-Host "Last Local Backup:"
            Write-Host "   📄 Name:  $($latest.Name)"
            Write-Host "   📅 Date:  $($latest.LastWriteTime)"
            if ($age.TotalHours -gt 25) {
                Write-Host "   ⚠️ Status: OVERDUE ($([math]::Round($age.TotalHours, 0)) hours old)" -ForegroundColor Red
            } else {
                Write-Host "   ✅ Status: FRESH ($([math]::Round($age.TotalHours, 1)) hours old)" -ForegroundColor Green
            }
        } else {
            Log-Warn "No local backups found."
        }
        Write-Host ""
    }

    # ============================
    # RESTORE (SAFE MODE)
    # ============================
    "restore-latest" {
        Print-Header "🚑 SAFE RESTORE PROTOCOL"
        
        Log-Step "Locating latest cloud backup"
        $file = rclone lsl $remote | Sort-Object Size -Descending | Select-Object -First 1
        
        if (!$file) { 
            Log-Err "No remote backups found."
            Write-Host ""
            exit 
        }
        
        $fname = $file.ToString().Split(" ")[-1]
        $localPath = Join-Path $backupDir $fname
        Log-Info "Found: $fname"

        if (!(Test-Path $localPath)) {
            Log-Step "Downloading (This may take time)"
            rclone copyto "$remote/$fname" $localPath --progress
        } else {
            Log-Info "File already exists locally, skipping download."
        }

        $restoreName = "$distroName-Restored"
        $restoreDir = Join-Path $backupDir $restoreName
        $tempTar = Join-Path $backupDir "restore-temp.tar"
        
        if (wsl -l -q | Select-String -Quiet $restoreName) {
            Log-Err "Distro '$restoreName' already exists!"
            Log-Warn "Please run: wsl --unregister $restoreName"
            Write-Host ""
            exit 1
        }

        Log-Step "Decompressing archive"
        $cmdArgs = "/c `"$zstdExe`" -d `"$localPath`" -o `"$tempTar`" --rm"
        Start-Process cmd.exe -ArgumentList $cmdArgs -NoNewWindow -Wait

        Log-Step "Importing to NEW distro: $restoreName"
        New-Item -ItemType Directory -Path $restoreDir -Force | Out-Null
        wsl --import $restoreName $restoreDir $tempTar

        Remove-Item $tempTar -Force

        Print-Header "🎉 RESTORE COMPLETE"
        Write-Host "Your backup has been restored as a SEPARATE distro: " -NoNewline; Write-Host "$restoreName" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "To switch to this version, run:"
        Write-Host "   wsl -d $restoreName"
        Write-Host ""
        Write-Host "If satisfied, you can unregister the old one and rename this one."
        Write-Host ""
    }

    default {
        Print-Header "🛠️ WSL BACKUP TOOL v2.0"
        Write-Host "   wsl-backup daily           Run full backup"
        Write-Host "   wsl-backup status          Check last backup age"
        Write-Host "   wsl-backup restore-latest  Safe restore to new distro"
        Write-Host ""
    }
}
