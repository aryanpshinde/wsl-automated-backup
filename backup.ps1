param([string]$Mode="help")

# ==========================================================
# Helper Functions
# ==========================================================
function C($t,$c){ Write-Host $t -ForegroundColor $c }
function Green($t){ C $t "Green" }
function Red($t){ C $t "Red" }
function Yellow($t){ C $t "Yellow" }
function Blue($t){ C $t "Cyan" }

$ErrorActionPreference="Stop"

# ==========================================================
# Load Config
# ==========================================================
$config = Get-Content "C:\Tools\WSLBackup\config.json" | ConvertFrom-Json
$backupDir  = $config.backupDir
$distroName = $config.distroName
$remote     = $config.rcloneRemote
$logFile    = "$backupDir\backup.log"

$retentionLocal  = $config.retentionLocal
$retentionCloud  = $config.retentionCloud

# ==========================================================
# Auto-detect distro name if empty
# ==========================================================
if(!$distroName -or $distroName -eq ""){
    $line = (wsl -l).Split("`n")[1].Trim()
    $distroName = $line.Split(" ")[0]
}

# ==========================================================
# Ensure backup directory exists
# ==========================================================
if(!(Test-Path $backupDir)){
    New-Item -ItemType Directory -Path $backupDir | Out-Null
}

function Log($msg){
    Add-Content $logFile "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  $msg"
}

# ==========================================================
# Ensure zstd exists
# ==========================================================
$zstd="C:\Tools\WSLBackup\zstd.exe"
if(!(Test-Path $zstd)){
    Red "ERROR: Missing zstd.exe at:"
    Yellow "C:\Tools\WSLBackup\zstd.exe"
    exit 1
}

# ==========================================================
# MD5 Helper
# ==========================================================
function MD5($file){
    $md5 = New-Object System.Security.Cryptography.MD5CryptoServiceProvider
    $fs = [IO.File]::OpenRead($file)
    $hash = $md5.ComputeHash($fs)
    $fs.Close()
    ($hash | ForEach-Object ToString X2) -join ""
}

# ==========================================================
# Export Progress Bar
# ==========================================================
function ProgressBar($cur,$max){
    if($max -lt 1){ $max = 1 }
    $p = [math]::Floor(($cur/$max)*100)
    if($p -gt 100){ $p = 100 }

    $bars = [math]::Floor($p/5)
    if($bars -gt 20){ $bars = 20 }

    $bar = "[" + ("#"*$bars) + ("-"*(20-$bars)) + "]"

    $mbCur = [math]::Round($cur/1MB,1)
    $mbMax = [math]::Round($max/1MB,1)

    Write-Host ("Export:  $bar $p%  $mbCur MB / $mbMax MB") -ForegroundColor Yellow
}

# ==========================================================
# Main Switch
# ==========================================================
switch($Mode){

# ==========================================================
# DAILY BACKUP
# ==========================================================
"daily" {
    Blue "== Backup Start =="
    Log "Backup Started"

    $ts = Get-Date -Format "yyyy-MM-dd_HH-mm"
    $tempTar = "$backupDir\$distroName-$ts.raw.tar"
    $outZst  = "$backupDir\$distroName-$ts.zst"

    # ==============================
    # EXPORT
    # ==============================
    Yellow "Exporting WSL distro..."
    Log "Export started"

    if(Test-Path $tempTar){ Remove-Item $tempTar -Force }

    Start-Process wsl -ArgumentList "--export",$distroName,$tempTar -NoNewWindow -PassThru | Out-Null

    $prev = 0
    while($true){
        Start-Sleep -Seconds 1

        $size = 0
        if(Test-Path $tempTar){
            $size = (Get-Item $tempTar).Length
        }

        ProgressBar $size ($size + 200MB)

        if($size -eq $prev -and $size -gt 0){
            Start-Sleep -Seconds 1
            if((Get-Item $tempTar).Length -eq $size){
                break
            }
        }

        $prev = $size
    }

    Green "Export complete."
    $rawSize = (Get-Item $tempTar).Length

    # ==============================
    # COMPRESSION
    # ==============================
    Blue "Compressing with zstd..."
    cmd.exe /c "`"$zstd`" -10 `"$tempTar`" -o `"$outZst`" --rm" | Out-Null

    $compSize = (Get-Item $outZst).Length

    # ==============================
    # CLOUD UPLOAD
    # ==============================
    Blue "Uploading to cloud..."

    try { rclone mkdir $remote | Out-Null } catch {}

    $upload = Start-Process rclone -ArgumentList @(
        "copy", "$outZst", $remote,
        "--progress",
        "--transfers=1",
        "--checkers=1",
        "--drive-chunk-size","64M",
        "--retries","5",
        "--low-level-retries","10"
    ) -NoNewWindow -Wait -PassThru

    if($upload.ExitCode -ne 0){
        Red "Cloud upload failed."
        Log "Cloud upload failed"
        exit 1
    }

    # ==============================
    # VERIFICATION
    # ==============================
    Blue "Verifying integrity..."

    $localMD5 = MD5 $outZst

    $remoteMD5 = (
        rclone md5sum $remote |
        Select-String ([IO.Path]::GetFileName($outZst))
    ).ToString().Split(" ")[0]

    if($localMD5 -ne $remoteMD5){
        Red "Verification FAILED"
        exit 1
    }

    Green "Verification OK."

    # ==============================
    # RETENTION (LOCAL 3 DAYS)
    # ==============================
    Blue "Applying local retention ($retentionLocal days)..."

    Get-ChildItem $backupDir -File |
        Where-Object {
            $_.Extension -eq ".zst" -and
            $_.LastWriteTime -lt (Get-Date).AddDays(-$retentionLocal)
        } |
        ForEach-Object {
            Yellow "Deleting old local backup: $($_.Name)"
            Remove-Item $_.FullName -Force
        }

    # ==============================
    # RETENTION (CLOUD 7 DAYS)
    # ==============================
    Blue "Applying cloud retention ($retentionCloud days)..."
    rclone delete $remote --min-age "${retentionCloud}d"

    # ==============================
    # SUMMARY
    # ==============================
    $ratio = [math]::Round(($rawSize/1MB)/($compSize/1MB),2)

    Green "== Backup Summary =="
    Green "Raw Size:      $([math]::Round($rawSize/1MB,1)) MB"
    Green "Compressed:    $([math]::Round($compSize/1MB,1)) MB"
    Green "Ratio:         $ratio x"
    Green "Verified:      Yes"
    Green "Saved Local:   $outZst"
    Green "Saved Cloud:   $remote"

    Log "Backup completed"
}

# ==========================================================
# STATUS
# ==========================================================
"status" {
    Blue "Local backups:"
    Get-ChildItem $backupDir -File |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 10
}

# ==========================================================
# CLOUD LISTING
# ==========================================================
"list-cloud" {
    Blue "Cloud backups:"
    rclone ls $remote
}

# ==========================================================
# RESTORE LATEST
# ==========================================================
"restore-latest" {

    Blue "Searching for latest cloud backup..."

    $file = rclone lsl $remote |
        Sort-Object Size -Descending |
        Select-Object -First 1

    if(!$file){
        Red "No cloud backups found."
        exit
    }

    $name = $file.ToString().Split(" ")[-1]
    $localZst = "$backupDir\$name"

    Blue "Downloading $name..."
    rclone copy "$remote/$name" $backupDir

    Blue "Stopping WSL..."
    wsl --shutdown

    Blue "Removing old distro..."
    wsl --unregister $distroName

    $localTar = "$backupDir\restore.tar"

    Blue "Decompressing..."
    cmd.exe /c "`"$zstd`" -d `"$localZst`" -o `"$localTar`" --rm" | Out-Null

    Blue "Importing..."
    wsl --import $distroName "$backupDir" $localTar

    Remove-Item $localTar -Force

    Green "Restore completed successfully."
}

# ==========================================================
default {
    Yellow "Commands:"
    Green "  wsl-backup daily"
    Green "  wsl-backup status"
    Green "  wsl-backup list-cloud"
    Green "  wsl-backup restore-latest"
}
}

