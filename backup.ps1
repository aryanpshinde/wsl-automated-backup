param(
    [ValidateSet("daily","restore-latest","status","help")]
    [string]$Mode = "help"
)

# ==================================================
# UI & VISUAL CONSTANTS
# ==================================================
$esc    = [char]27
$RESET  = "$esc[0m"
$BOLD   = "$esc[1m"
$CYAN   = "$esc[36m"
$GREEN  = "$esc[32m"
$YELLOW = "$esc[33m"
$RED    = "$esc[31m"
$GRAY   = "$esc[90m"

function Print-Header($t){
    Write-Host ""
    Write-Host "$CYAN$BOLD$t$RESET"
    Write-Host "$GRAY$('='*40)$RESET"
}
function Log-Step($m){ Write-Host "$BOLD[STEP] $m...$RESET" }
function Log-Info($m){ Write-Host "$GREEN[INFO] $RESET$m" }
function Log-Warn($m){ Write-Host "$YELLOW[WARN] $RESET$m" }
function Log-Err ($m){ Write-Host "$RED[FAIL] $RESET$m" }

$ErrorActionPreference = "Stop"

# ==================================================
# CONFIGURATION
# ==================================================
$configFile = Join-Path $PSScriptRoot "config.json"
if (!(Test-Path $configFile)) {
    Log-Err "Config file not found"
    exit 1
}

$config = Get-Content $configFile | ConvertFrom-Json
$backupDir      = $config.backupDir
$distroName     = $config.distroName
$remote         = $config.rcloneRemote
$retentionLocal = [int]$config.retentionLocal
$retentionCloud = [int]$config.retentionCloud

if ([string]::IsNullOrWhiteSpace($distroName)) {
    $list = wsl -l -q
    if (!$list -or $list.Count -eq 0) {
        Log-Err "No WSL distributions found"
        exit 1
    }
    $distroName = [string]$list[0].Trim()
}

if ([string]::IsNullOrWhiteSpace($backupDir)) {
    Log-Err "backupDir is invalid"
    exit 1
}

$zstdExe = Join-Path $PSScriptRoot "zstd.exe"
if (!(Test-Path $zstdExe)) {
    Log-Err "zstd.exe not found"
    exit 1
}

if (!(Test-Path $backupDir)) {
    New-Item -ItemType Directory -Path $backupDir | Out-Null
}

# ==================================================
# UTILITIES
# ==================================================
function Get-FastMD5($file){
    (certutil -hashfile "$file" MD5 2>$null |
        Select-Object -Skip 1 -First 1).Replace(" ","").ToLower()
}

# ==================================================
# DAILY BACKUP
# ==================================================
if ($Mode -eq "daily") {

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    Print-Header "STARTING DAILY BACKUP: $distroName"

    $ts = Get-Date -Format "yyyy-MM-dd_HH-mm"
    $tempTar = Join-Path $backupDir "$distroName-$ts.raw.tar"
    $outZst  = Join-Path $backupDir "$distroName-$ts.zst"

    if (Test-Path $tempTar) { Remove-Item $tempTar -Force -ErrorAction SilentlyContinue }
    if (Test-Path $outZst)  { Remove-Item $outZst  -Force -ErrorAction SilentlyContinue }

    Log-Step "Exporting WSL Distribution"

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = "wsl.exe"
    $psi.Arguments = "--export `"$distroName`" `"$tempTar`""
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $false
    $psi.RedirectStandardError  = $false
    $psi.CreateNoWindow = $false

    $proc = [System.Diagnostics.Process]::Start($psi)
    $proc.WaitForExit()

    if (!(Test-Path $tempTar)) {
        Log-Err "WSL Export failed - file not created"
        exit 1
    }

    if ($proc.ExitCode -ne 0) {
        Log-Warn "WSL exit code $($proc.ExitCode), but backup file exists. Assuming success."
    }

    $rawSize = (Get-Item $tempTar).Length
    Log-Info "Export success. Raw size: $([math]::Round($rawSize/1GB,2)) GB"

    Log-Step "Compressing (zstd -10)"
    & $zstdExe -10 "$tempTar" -o "$outZst" --rm

    if ($LASTEXITCODE -ne 0 -or !(Test-Path $outZst)) {
        Log-Err "Compression failed"
        exit 1
    }

    $compSize = (Get-Item $outZst).Length
    Log-Info "Compression success. Size: $([math]::Round($compSize/1GB,1)) GB"
    Write-Host ""

    Log-Step "Syncing to Cloud ($remote)"
    rclone copyto "$outZst" "$remote/$(Split-Path $outZst -Leaf)" --progress --transfers=2
    if ($LASTEXITCODE -ne 0) {
        Log-Err "Cloud upload failed"
        exit 1
    }

    Log-Step "Verifying Integrity"

    Write-Host -NoNewline "   Computing Local Hash...  "
    $localHash = Get-FastMD5 $outZst
    Write-Host "$GREEN OK $RESET"

    Write-Host -NoNewline "   Fetching Remote Hash...  "
    $remoteOut = rclone md5sum "$remote/$(Split-Path $outZst -Leaf)" 2>$null
    if ([string]::IsNullOrWhiteSpace($remoteOut)) {
        Log-Err "Could not fetch remote hash"
        exit 1
    }

    $remoteHash = ($remoteOut -split '\s+')[0]
    Write-Host "$GREEN OK $RESET"

    if ($localHash -ne $remoteHash) {
        Log-Err "HASH MISMATCH!"
        Log-Err "Local:  $localHash"
        Log-Err "Remote: $remoteHash"
        exit 1
    }

    Log-Info "Integrity Verified."
    Write-Host ""

    Print-Header "RETENTION POLICY"

    $cutoff = (Get-Date).AddDays(-$retentionLocal)
    $files = Get-ChildItem $backupDir -Filter "*.zst" -ErrorAction SilentlyContinue |
             Sort-Object LastWriteTime -Descending

    $kept = 0
    foreach ($f in $files) {
        if ($f.LastWriteTime -lt $cutoff) {
            Log-Warn "Deleting old local backup: $($f.Name)"
            Remove-Item $f.FullName -Force -ErrorAction SilentlyContinue
        } else {
            $kept++
        }
    }

    Log-Info "Local retention checked ($retentionLocal days). Keeping $kept files."

    rclone delete "$remote" --min-age "${retentionCloud}d" 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Log-Info "Cloud retention applied ($retentionCloud days)."
    } else {
        Log-Warn "Cloud retention cleanup failed"
    }

    $sw.Stop()
    Write-Host ""
    Print-Header "BACKUP SUCCESSFUL"
    Write-Host "   Distro:     $distroName"
    Write-Host "   Size:       $([math]::Round($compSize/1GB,1)) GB (Raw: $([math]::Round($rawSize/1GB,2)) GB)"
    Write-Host "   Time:       $([math]::Round($sw.Elapsed.TotalMinutes,1)) min"
    Write-Host "   Location:   $remote"
}

# ==================================================
# STATUS
# ==================================================
elseif ($Mode -eq "status") {

    Print-Header "BACKUP STATUS"

    if (!(Test-Path $backupDir)) {
        Log-Warn "Backup directory does not exist"
        exit 0
    }

    $latest = Get-ChildItem $backupDir -Filter "*.zst" -ErrorAction SilentlyContinue |
              Sort-Object LastWriteTime -Descending |
              Select-Object -First 1

    if ($latest) {
        $age = New-TimeSpan -Start $latest.LastWriteTime -End (Get-Date)
        Write-Host "Latest backup: $($latest.Name)"
        Write-Host "Date:          $($latest.LastWriteTime)"
        Write-Host "Size:          $([math]::Round($latest.Length/1GB,2)) GB"

        if ($age.TotalHours -gt 25) {
            Log-Warn "Status: OVERDUE ($([math]::Round($age.TotalHours,0)) hours old)"
        } else {
            Log-Info "Status: FRESH ($([math]::Round($age.TotalHours,1)) hours old)"
        }
    } else {
        Log-Warn "No backups found"
    }
}

# ==================================================
# RESTORE (DISABLED)
# ==================================================
elseif ($Mode -eq "restore-latest") {
    Print-Header "SAFE RESTORE PROTOCOL"
    Log-Err "Restore mode intentionally disabled for safety"
    exit 1
}

# ==================================================
# HELP
# ==================================================
else {
    Print-Header "WSL BACKUP TOOL"
    Write-Host "  wsl-backup daily"
    Write-Host "  wsl-backup status"
    Write-Host "  wsl-backup restore-latest"
}
