#Requires -Version 7.2

[CmdletBinding(SupportsShouldProcess=$true)]
param(
    [Parameter(Position=0)]
    [ValidateSet("daily", "restore-latest", "status", "help")]
    [string]$Mode = "help",

    [Parameter()]
    [ValidateScript({
        if (Test-Path $_ -PathType Leaf) { return $true }
        throw "Config file not found: $_"
    })]
    [string]$ConfigPath = (Join-Path $PSScriptRoot "config.json"),

    [Parameter()]
    [switch]$Force
)


# ==============================================================================
# CONFIGURATION SCHEMA
# ==============================================================================

$ConfigSchema = @{
    Required   = @('backupDir', 'rcloneRemote')
    Defaults   = @{
        distroName       = ''
        retentionLocal   = 7
        retentionCloud   = 30
        compressionLevel = 10
        hashAlgorithm    = 'SHA256'
    }
    Validation = @{
        retentionLocal   = { param($v) $v -is [ValueType] -or ($v -is [string] -and $v -match '^\d+$') }
        retentionCloud   = { param($v) $v -is [ValueType] -or ($v -is [string] -and $v -match '^\d+$') }
        compressionLevel = { param($v) ($v -is [ValueType] -or ($v -is [string] -and $v -match '^\d+$')) -and [int]$v -ge 1 -and [int]$v -le 19 }
        hashAlgorithm    = { param($v) $v -in @('SHA256','SHA1','MD5') }
    }
}


# ==============================================================================
# LOGGING & UI
# ==============================================================================

$LogPrefix = @{
    Info    = "[{0}] {1}" -f ($PSStyle.Foreground.Green + "INFO" + $PSStyle.Reset), "{0}"
    Warn    = "[{0}] {1}" -f ($PSStyle.Foreground.Yellow + "WARN" + $PSStyle.Reset), "{0}"
    Error   = "[{0}] {1}" -f ($PSStyle.Foreground.Red + "FAIL" + $PSStyle.Reset), "{0}"
    Step    = "[{0}] {1}" -f ($PSStyle.Bold + "STEP" + $PSStyle.Reset), "{0}"
    Success = "[{0}] {1}" -f ($PSStyle.Foreground.BrightGreen + "OK" + $PSStyle.Reset), "{0}"
    Debug   = "[{0}] {1}" -f ($PSStyle.Foreground.BrightBlack + "DBG" + $PSStyle.Reset), "{0}"
}

function Write-Log {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position=0)]
        [ValidateSet('Info','Warn','Error','Step','Success','Debug')]
        [string]$Level,

        [Parameter(Mandatory, Position=1)]
        [string]$Message,

        [switch]$NoNewline
    )

    $formatted = $LogPrefix[$Level] -f $Message
    $params = @{
        Object    = $formatted
        NoNewline = $NoNewline
    }
    Microsoft.PowerShell.Utility\Write-Host @params
}

function Write-Header {
    param([string]$Title)
    $width = 60
    $line = [string]::new([char]0x2550, $width)
    Microsoft.PowerShell.Utility\Write-Host ""
    Microsoft.PowerShell.Utility\Write-Host "$($PSStyle.Foreground.Cyan + $PSStyle.Bold)$line$($PSStyle.Reset)"
    Microsoft.PowerShell.Utility\Write-Host "$($PSStyle.Foreground.Cyan + $PSStyle.Bold)  $Title$($PSStyle.Reset)"
    Microsoft.PowerShell.Utility\Write-Host "$($PSStyle.Foreground.Cyan + $PSStyle.Bold)$line$($PSStyle.Reset)"
    Microsoft.PowerShell.Utility\Write-Host ""
}


# ==============================================================================
# UTILITY FUNCTIONS
# ==============================================================================

function Test-AdminRights {
    $principal = New-Object Security.Principal.WindowsPrincipal(
        [Security.Principal.WindowsIdentity]::GetCurrent()
    )
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-WSLDistros {
    [CmdletBinding()]
    param()

    $env:WSL_UTF8 = 1
    $output = wsl.exe -l -v 2>&1

    if ($LASTEXITCODE -ne 0) {
        Write-Verbose "wsl.exe -l -v failed with exit code $LASTEXITCODE"
        return @()
    }

    $distros = @()

    foreach ($line in $output) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        if ($line -match '^\s*NAME\s+STATE\s+VERSION') { continue }

        $isDefault = $line.Trim().StartsWith('*')
        $cleanLine = $line.Trim().TrimStart('*').Trim()

        if ($cleanLine.StartsWith('NAME ')) { continue }

        $parts = @($cleanLine -split '\s+' | Where-Object { $_ })

        if ($parts.Count -ge 3) {
            $version = $parts[-1]
            $state   = $parts[-2]
            $name    = ($parts[0..($parts.Count - 3)] -join ' ').Trim()

            if ($name -eq 'NAME') { continue }

            $distros += [PSCustomObject]@{
                Name      = $name
                State     = $state
                Version   = $version
                IsDefault = $isDefault
            }
            Write-Verbose "Parsed distro: Name='$name', State='$state', Version='$version', Default=$isDefault"
        }
        else {
            Write-Verbose "Could not parse line ($($parts.Count) parts): $line"
        }
    }

    Write-Verbose "Found $($distros.Count) distro(s)"
    return $distros
}

function Get-Config {
    [CmdletBinding()]
    param()

    Write-Verbose "Loading configuration from: $ConfigPath"

    try {
        $config = Get-Content -Path $ConfigPath -Raw |
                  ConvertFrom-Json -AsHashtable -ErrorAction Stop
    }
    catch {
        throw "Failed to parse config JSON: $_"
    }

    # --- Required fields ---
    foreach ($req in $ConfigSchema.Required) {
        if (-not $config.ContainsKey($req) -or [string]::IsNullOrWhiteSpace($config[$req])) {
            throw "Missing required config field: $req"
        }
    }

    # --- Defaults ---
    foreach ($key in $ConfigSchema.Defaults.Keys) {
        if (-not $config.ContainsKey($key)) {
            $config[$key] = $ConfigSchema.Defaults[$key]
            Write-Verbose "Applied default for ${key}: $($ConfigSchema.Defaults[$key])"
        }
    }

    # --- Type / range validation ---
    foreach ($key in $ConfigSchema.Validation.Keys) {
        if ($config.ContainsKey($key)) {
            $validator = $ConfigSchema.Validation[$key]
            if (-not (& $validator $config[$key])) {
                throw "Invalid value for config field '$key': $($config[$key])"
            }
            if ($key -in @('retentionLocal', 'retentionCloud', 'compressionLevel')) {
                $config[$key] = [int]$config[$key]
            }
        }
    }

    # --- Backup directory ---
    $resolvedPath = Resolve-Path $config.backupDir -ErrorAction SilentlyContinue
    if ($resolvedPath) {
        $config.backupDir = $resolvedPath.Path
    }
    else {
        $config.backupDir = (New-Item -ItemType Directory -Path $config.backupDir -Force).FullName
        Write-Verbose "Created backup directory: $($config.backupDir)"
    }

    # --- zstd ---
    $zstdPath = Join-Path $PSScriptRoot "zstd.exe"
    if (-not (Test-Path $zstdPath -PathType Leaf)) {
        throw "zstd.exe not found in script directory: $zstdPath"
    }
    $config.zstdExe = $zstdPath

    # --- Distro auto-detection ---
    if ([string]::IsNullOrWhiteSpace($config.distroName)) {
        Write-Verbose "Auto-detecting WSL distribution..."
        $distros = Get-WSLDistros
        if (-not $distros) {
            throw "No WSL distributions found. Install WSL first."
        }
        $config.distroName = $distros[0].Name
        Write-Verbose "Auto-selected distro: $($config.distroName)"
    }

    return $config
}

function Get-FileHashFast {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [ValidateSet('SHA256','SHA1','MD5')]
        [string]$Algorithm = 'SHA256'
    )

    if (-not (Test-Path $Path -PathType Leaf)) {
        throw "File not found: $Path"
    }

    $fileSize = (Get-Item $Path).Length
    Write-Verbose "Computing $Algorithm hash for $([math]::Round($fileSize/1MB, 1)) MB file"

    try {
        $hash = Get-FileHash -Path $Path -Algorithm $Algorithm -ErrorAction Stop
        return $hash.Hash.ToLower()
    }
    catch {
        throw "Hash calculation failed: $_"
    }
}

function Test-WSLHealth {
    [CmdletBinding()]
    param([string]$TargetDistro)

    Write-Verbose "Checking WSL status for target: $TargetDistro"
    $distros  = Get-WSLDistros
    $exitCode = $LASTEXITCODE

    if ($exitCode -ne 0 -or $distros.Count -eq 0) {
        return @{
            Healthy     = $false
            Error       = if ($exitCode -ne 0) { "WSL not responding (exit $exitCode)" } else { "No distributions found" }
            Distros     = @()
            TargetFound = $false
        }
    }

    $target = $distros | Where-Object { $_.Name -eq $TargetDistro }

    return @{
        Healthy     = $true
        Error       = $null
        Distros     = $distros
        TargetFound = $null -ne $target
        TargetState = if ($target) { $target.State } else { $null }
    }
}

function Get-DistroSize {
    [CmdletBinding()]
    param([string]$DistroName)

    $env:WSL_UTF8 = 1

    try {
        $dfOutput = wsl.exe -d $DistroName -e df -B1 / 2>$null
        if ($LASTEXITCODE -eq 0 -and $dfOutput.Count -ge 2) {
            $parts = $dfOutput[1].Trim() -split '\s+'
            if ($parts.Count -ge 3 -and $parts[2] -match '^\d+$') {
                return [long]$parts[2]
            }
        }
    }
    catch {
        Write-Verbose "Could not get distro size: $_"
    }
    return 0
}

function Get-AvailableDiskSpace {
    [CmdletBinding()]
    param([string]$Path)

    try {
        $root = [System.IO.Path]::GetPathRoot((Resolve-Path $Path).Path)
        $drive = Get-PSDrive -Name $root.TrimEnd(':\') -ErrorAction SilentlyContinue
        if ($drive -and $null -ne $drive.Free) {
            return [long]$drive.Free
        }

        # Fallback: CIM
        $driveLetter = $root.Substring(0, 2)
        $wmiDisk = Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DeviceID='$driveLetter'" -ErrorAction SilentlyContinue
        if ($wmiDisk) {
            return [long]$wmiDisk.FreeSpace
        }
    }
    catch {
        Write-Verbose "Could not determine free disk space for: $Path"
    }
    return -1
}

function Get-RemoteHash {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Algorithm,
        [Parameter(Mandatory)][string]$RemotePath
    )

    $expectedLength = switch ($Algorithm) {
        'SHA256' { 64 }
        'SHA1'   { 40 }
        'MD5'    { 32 }
    }

    $pattern = "^[0-9a-fA-F]{$expectedLength}\s"
    $rawOutput = rclone hashsum $Algorithm "$RemotePath" 2>$null

    if ([string]::IsNullOrWhiteSpace($rawOutput)) {
        throw "Could not fetch remote hash - rclone returned empty output."
    }

    $hashLine = @($rawOutput -split "`n") |
                Where-Object { $_ -match $pattern } |
                Select-Object -First 1

    if (-not $hashLine) {
        throw "Could not parse remote hash from rclone output:`n$rawOutput"
    }

    return ($hashLine -split '\s+')[0].ToLower()
}


# ==============================================================================
# LOCK FILE MANAGEMENT
# ==============================================================================

function Enter-BackupLock {
    [CmdletBinding()]
    param([string]$LockDir)

    $lockFile   = Join-Path $LockDir ".backup.lock"
    $staleHours = 12

    if (Test-Path $lockFile) {
        $lockAge = (Get-Date) - (Get-Item $lockFile).LastWriteTime

        if ($lockAge.TotalHours -lt $staleHours -and -not $Force) {
            throw "Another backup is running (lock age: $([math]::Round($lockAge.TotalMinutes)) min). Use -Force to override."
        }

        Write-Log Warn "Stale lock detected ($([math]::Round($lockAge.TotalHours, 1)) hours). Overriding."
    }

    Set-Content -Path $lockFile -Value "$PID $(Get-Date -Format o)" -Force
    Write-Verbose "Lock acquired: $lockFile (PID $PID)"
    return $lockFile
}

function Exit-BackupLock {
    [CmdletBinding()]
    param([string]$LockFile)

    if ($LockFile -and (Test-Path $LockFile)) {
        Remove-Item $LockFile -Force -ErrorAction SilentlyContinue
        Write-Verbose "Lock released: $LockFile"
    }
}


# ==============================================================================
# BACKUP OPERATIONS
# ==============================================================================

function Start-DailyBackup {
    [CmdletBinding(SupportsShouldProcess=$true)]
    param([hashtable]$Config)

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $lockFile  = $null
    $tempTar   = $null
    $outZst    = $null

    try {
        # ==============================================================
        # LOCK
        # ==============================================================
        $lockFile = Enter-BackupLock -LockDir $Config.backupDir

        Write-Header "WSL BACKUP: $($Config.distroName.ToUpper())"

        # ==============================================================
        # PRE-FLIGHT
        # ==============================================================
        Write-Log Step "Running pre-flight checks"
        Write-Host ""

        if (-not (Test-AdminRights)) {
            Write-Log Warn "Running without administrator rights (may fail for running distros)"
        }

        $wslHealth = Test-WSLHealth -TargetDistro $Config.distroName
        if (-not $wslHealth.Healthy) {
            throw "WSL health check failed: $($wslHealth.Error)"
        }
        if (-not $wslHealth.TargetFound) {
            $available = ($wslHealth.Distros | ForEach-Object { $_.Name }) -join ', '
            throw "Distro '$($Config.distroName)' not found in WSL. Available: $available"
        }

        if ($wslHealth.TargetState -eq 'Running') {
            Write-Log Warn "Distro is currently running. Will terminate before export for consistency."
        }

        # Disk-space sanity check
        $estimatedSize = Get-DistroSize -DistroName $Config.distroName
        if ($estimatedSize -gt 0) {
            Write-Verbose "Estimated distro size: $([math]::Round($estimatedSize/1GB, 2)) GB"

            $freeSpace = Get-AvailableDiskSpace -Path $Config.backupDir
            if ($freeSpace -gt 0) {
                $requiredSpace = [long]($estimatedSize * 1.6)
                if ($freeSpace -lt $requiredSpace) {
                    throw ("Insufficient disk space. Need ~{0:N1} GB, only {1:N1} GB available on backup drive." -f
                        ($requiredSpace / 1GB), ($freeSpace / 1GB))
                }
                Write-Verbose "Disk space OK: $([math]::Round($freeSpace/1GB, 1)) GB free, ~$([math]::Round($requiredSpace/1GB, 1)) GB needed"
            }
        }

        Write-Log Success "Pre-flight checks passed"
        Write-Host ""

        # ==============================================================
        # PATHS
        # ==============================================================
        $timestamp = Get-Date -Format "yyyy-MM-dd_HH-mm"
        $baseName  = "$($Config.distroName)-$timestamp"
        $tempTar   = Join-Path $Config.backupDir "$baseName.raw.tar"
        $outZst    = Join-Path $Config.backupDir "$baseName.zst"

        @($tempTar, $outZst) | ForEach-Object {
            if (Test-Path $_) {
                Write-Verbose "Removing existing file: $_"
                Remove-Item $_ -Force
            }
        }

        # ==============================================================
        # EXPORT
        # ==============================================================
        Write-Log Step "Exporting WSL distribution"
        Write-Host ""

        if ($estimatedSize -gt 0) {
            Write-Host "  Estimated size: $([math]::Round($estimatedSize/1GB, 2)) GB"
        }
        Write-Host "  This may take several minutes depending on size and disk speed."
        Write-Host ""

        if ($PSCmdlet.ShouldProcess($Config.distroName, "Export WSL to $tempTar")) {
            $env:WSL_UTF8 = 1

            Write-Verbose "Terminating distro for cold backup..."
            wsl.exe --terminate $Config.distroName 2>$null

            $exportStart = Get-Date
            $proc = Start-Process -FilePath "wsl.exe" `
                        -ArgumentList "--export `"$($Config.distroName)`" `"$tempTar`"" `
                        -Wait -PassThru -NoNewWindow

            $exportDuration = (Get-Date) - $exportStart

            if (-not (Test-Path $tempTar -PathType Leaf)) {
                throw "Export failed - output file not created. Exit code: $($proc.ExitCode)"
            }

            $rawSize = (Get-Item $tempTar).Length
            if ($rawSize -eq 0) {
                Remove-Item $tempTar -Force -ErrorAction SilentlyContinue
                throw "Export created an empty file (likely interrupted or insufficient permissions)"
            }

            if ($proc.ExitCode -ne 0) {
                Write-Log Warn "WSL exit code $($proc.ExitCode), but valid file created. Continuing."
            }
        }
        else {
            Write-Log Info "[WhatIf] Would terminate distro: $($Config.distroName)"
            Write-Log Info "[WhatIf] Would export to:        $tempTar"
            Write-Log Info "[WhatIf] Would compress to:      $outZst"
            Write-Log Info "[WhatIf] Would upload to:        $($Config.rcloneRemote)/$(Split-Path $outZst -Leaf)"
            Write-Host ""
            Write-Log Info "Dry run complete. No changes made."
            return
        }

        Write-Log Info "Export complete: $([math]::Round($rawSize/1GB, 2)) GB in $([math]::Round($exportDuration.TotalMinutes, 1)) min"
        Write-Host ""

        # ==============================================================
        # COMPRESS
        # ==============================================================
        Write-Log Step "Compressing with zstd (level $($Config.compressionLevel))"
        Write-Host ""

        $compressStart = Get-Date

        if ($PSCmdlet.ShouldProcess($tempTar, "Compress to $outZst")) {
            $zstdProc = Start-Process -FilePath $Config.zstdExe `
                            -ArgumentList "-$($Config.compressionLevel) `"$tempTar`" -o `"$outZst`"" `
                            -Wait -NoNewWindow -PassThru

            if ($zstdProc.ExitCode -ne 0) {
                throw "Compression failed with exit code $($zstdProc.ExitCode)"
            }
            if (-not (Test-Path $outZst -PathType Leaf)) {
                throw "Compression failed - output file not found"
            }

            $compSize = (Get-Item $outZst).Length
            if ($compSize -eq 0) {
                throw "Compression produced an empty file"
            }

            # Safe to remove raw tar now
            Remove-Item $tempTar -Force
            $tempTar = $null
            Write-Verbose "Removed raw tar after successful compression"
        }

        $compressDuration = (Get-Date) - $compressStart
        $ratio = [math]::Round(($rawSize - $compSize) / $rawSize * 100, 1)

        Write-Log Info "Compressed: $([math]::Round($compSize/1GB, 2)) GB (saved ${ratio}%) in $([math]::Round($compressDuration.TotalSeconds, 0)) sec"
        Write-Host ""

        # ==============================================================
        # UPLOAD
        # ==============================================================
        $remotePath = "$($Config.rcloneRemote)/$(Split-Path $outZst -Leaf)"
        Write-Log Step "Uploading to cloud"
        Write-Host "  Remote: $remotePath"
        Write-Host ""

        $uploadStart = Get-Date

        if ($PSCmdlet.ShouldProcess($outZst, "Upload to $remotePath")) {
            $rcloneProc = Start-Process -FilePath "rclone" `
                              -ArgumentList "copyto `"$outZst`" `"$remotePath`" --progress --transfers=2" `
                              -Wait -PassThru

            if ($rcloneProc.ExitCode -ne 0) {
                throw "Cloud upload failed with exit code $($rcloneProc.ExitCode)"
            }
        }

        $uploadDuration = (Get-Date) - $uploadStart
        Write-Log Info "Upload complete in $([math]::Round($uploadDuration.TotalSeconds, 0)) sec"
        Write-Host ""

        # ==============================================================
        # VERIFY
        # ==============================================================
        Write-Log Step "Verifying integrity ($($Config.hashAlgorithm))"
        Write-Host ""

        Write-Host "  > Computing local hash...  " -NoNewline
        $localHash = Get-FileHashFast -Path $outZst -Algorithm $Config.hashAlgorithm
        Write-Log Success "Done"

        Write-Host "  > Fetching remote hash...  " -NoNewline
        $remoteHash = Get-RemoteHash -Algorithm $Config.hashAlgorithm -RemotePath $remotePath
        Write-Log Success "Done"
        Write-Host ""

        if ($localHash -ne $remoteHash) {
            throw @"
INTEGRITY FAILURE - HASH MISMATCH
  Algorithm: $($Config.hashAlgorithm)
  Local:     $localHash
  Remote:    $remoteHash
"@
        }

        Write-Log Info "Integrity verified ($($Config.hashAlgorithm))"
        Write-Host ""

        # ==============================================================
        # RETENTION
        # ==============================================================
        Write-Header "RETENTION POLICY"

        $cutoffLocal = (Get-Date).AddDays(-$Config.retentionLocal)
        $localFiles  = Get-ChildItem $Config.backupDir -Filter "*.zst" -File -ErrorAction SilentlyContinue |
                       Sort-Object LastWriteTime -Descending

        $kept       = 0
        $removed    = 0
        $freedBytes = [long]0

        foreach ($file in $localFiles) {
            if ($file.LastWriteTime -lt $cutoffLocal) {
                if ($PSCmdlet.ShouldProcess($file.Name, "Delete (local retention: $($Config.retentionLocal) days)")) {
                    $freedBytes += $file.Length
                    Remove-Item $file.FullName -Force -ErrorAction SilentlyContinue
                    Write-Log Warn "Deleted: $($file.Name) ($([math]::Round($file.Length/1MB, 1)) MB)"
                    $removed++
                }
            }
            else {
                $kept++
            }
        }

        Write-Log Info "Local: $kept kept, $removed removed ($([math]::Round($freedBytes/1MB, 1)) MB freed)"
        Write-Host ""

        if ($PSCmdlet.ShouldProcess($Config.rcloneRemote, "Cloud retention ($($Config.retentionCloud) days, *.zst only)")) {
            rclone delete "$($Config.rcloneRemote)" `
                --min-age "$($Config.retentionCloud)d" `
                --include "*.zst" 2>&1 | Out-Null

            if ($LASTEXITCODE -eq 0) {
                Write-Log Info "Cloud: Retention applied ($($Config.retentionCloud) days)"
            }
            else {
                Write-Log Warn "Cloud: Retention cleanup may have failed"
            }
        }

        # ==============================================================
        # SUMMARY
        # ==============================================================
        $stopwatch.Stop()

        Write-Header "BACKUP COMPLETE"
        Write-Host "  Distribution:  $($Config.distroName)"
        Write-Host "  Timestamp:     $timestamp"
        Write-Host "  Raw Size:      $([math]::Round($rawSize/1GB, 2)) GB"
        Write-Host "  Compressed:    $([math]::Round($compSize/1GB, 2)) GB (${ratio}% saved)"
        Write-Host "  Export Time:   $([math]::Round($exportDuration.TotalMinutes, 1)) min"
        Write-Host "  Compress Time: $([math]::Round($compressDuration.TotalSeconds, 0)) sec"
        Write-Host "  Upload Time:   $([math]::Round($uploadDuration.TotalSeconds, 0)) sec"
        Write-Host "  Total Time:    $([math]::Round($stopwatch.Elapsed.TotalMinutes, 1)) min"
        Write-Host "  Location:      $remotePath"
        Write-Host "  $($Config.hashAlgorithm):        $localHash"
        Write-Host ""
    }
    catch {
        Write-Host ""
        Write-Log Error "Backup failed: $_"

        foreach ($file in @($tempTar, $outZst)) {
            if ($file -and (Test-Path $file)) {
                $size = (Get-Item $file).Length
                Remove-Item $file -Force -ErrorAction SilentlyContinue
                Write-Log Warn "Cleaned up: $(Split-Path $file -Leaf) ($([math]::Round($size/1MB, 1)) MB)"
            }
        }

        throw
    }
    finally {
        Exit-BackupLock -LockFile $lockFile
    }
}


# ==============================================================================
# STATUS
# ==============================================================================

function Get-BackupStatus {
    [CmdletBinding()]
    param([hashtable]$Config)

    Write-Header "BACKUP STATUS"

    # --- WSL health ---
    $wslHealth = Test-WSLHealth -TargetDistro $Config.distroName

    if ($wslHealth.Healthy) {
        if ($wslHealth.TargetFound) {
            $target = $wslHealth.Distros | Where-Object { $_.Name -eq $Config.distroName }
            Write-Host "  WSL Status:    $($PSStyle.Foreground.Green)Healthy$($PSStyle.Reset)"
            Write-Host "  Distro State:  $($target.State)"
            Write-Host "  WSL Version:   $($target.Version)"
        }
        else {
            Write-Log Warn "Configured distro '$($Config.distroName)' not found in WSL"
            Write-Host ""
            Write-Host "  Available distros:"
            foreach ($d in $wslHealth.Distros) {
                $marker = if ($d.IsDefault) { " (default)" } else { "" }
                Write-Host "    - $($d.Name)$marker [$($d.State)]"
            }
        }
    }
    else {
        Write-Log Error "WSL Status: $($wslHealth.Error)"
    }
    Write-Host ""

    # --- Local backups ---
    if (-not (Test-Path $Config.backupDir -PathType Container)) {
        Write-Log Warn "Backup directory does not exist: $($Config.backupDir)"
        Write-Host ""
        return
    }

    $backups = Get-ChildItem $Config.backupDir -Filter "*.zst" -File -ErrorAction SilentlyContinue |
               Sort-Object LastWriteTime -Descending

    if (-not $backups) {
        Write-Log Warn "No backups found in $($Config.backupDir)"
        Write-Host ""
        return
    }

    $latest    = $backups | Select-Object -First 1
    $age       = New-TimeSpan -Start $latest.LastWriteTime -End (Get-Date)
    $totalSize = ($backups | Measure-Object -Property Length -Sum).Sum

    Write-Host "  Latest Backup:   $($latest.Name)"
    Write-Host "  Timestamp:       $($latest.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss'))"
    Write-Host "  Size:            $([math]::Round($latest.Length/1GB, 2)) GB"
    Write-Host "  Age:             $([math]::Round($age.TotalHours, 1)) hours"
    Write-Host "  Total Backups:   $($backups.Count)"
    Write-Host "  Total Size:      $([math]::Round($totalSize/1GB, 2)) GB"
    Write-Host ""

    if ($age.TotalHours -gt 48) {
        Write-Log Error "Status: CRITICAL (backup is $([math]::Round($age.TotalDays, 1)) days old)"
    }
    elseif ($age.TotalHours -gt 25) {
        Write-Log Warn "Status: OVERDUE (expected within 24 hours)"
    }
    else {
        Write-Log Success "Status: HEALTHY"
    }

    Write-Host ""
    Write-Host "  Retention Policy:"
    Write-Host "    Local:  $($Config.retentionLocal) days"
    Write-Host "    Cloud:  $($Config.retentionCloud) days"
    Write-Host ""
}


# ==============================================================================
# RESTORE
# ==============================================================================

function Start-Restore {
    [CmdletBinding(SupportsShouldProcess=$true)]
    param([hashtable]$Config)

    Write-Header "RESTORE PROTOCOL"
    Write-Log Error "Automatic restore is disabled for safety"
    Write-Host ""
    Write-Host "  Manual restore procedure:"
    Write-Host ""
    Write-Host "    1. List available backups:"
    Write-Host "       rclone ls $($Config.rcloneRemote)"
    Write-Host ""
    Write-Host "    2. Download backup from cloud:"
    Write-Host "       rclone copy $($Config.rcloneRemote)/<backup.zst> C:\Temp\"
    Write-Host ""
    Write-Host "    3. Decompress:"
    Write-Host "       zstd -d C:\Temp\<backup.zst> -o C:\Temp\<backup.tar>"
    Write-Host ""
    Write-Host "    4. Import to WSL:"
    Write-Host "       wsl --import <DistroName> <InstallLocation> C:\Temp\<backup.tar>"
    Write-Host ""

    if ($Force) {
        Write-Log Warn "-Force specified, but restore remains disabled"
        Write-Log Info "Edit the script to enable automatic restore functionality"
    }
    Write-Host ""
}


# ==============================================================================
# MAIN
# ==============================================================================

try {
    $ErrorActionPreference = "Stop"
    $Config = Get-Config

    switch ($Mode) {
        "daily"          { Start-DailyBackup -Config $Config }
        "status"         { Get-BackupStatus  -Config $Config }
        "restore-latest" { Start-Restore     -Config $Config }
        "help" {
            Write-Header "WSL BACKUP TOOL"
            Write-Host "  Usage: wsl-backup <command> [options]"
            Write-Host ""
            Write-Host "  Commands:"
            Write-Host "    daily            Perform backup with compression and cloud sync"
            Write-Host "    status           Show backup health and statistics"
            Write-Host "    restore-latest   Show restore instructions"
            Write-Host "    help             Show this help message"
            Write-Host ""
            Write-Host "  Options:"
            Write-Host "    -ConfigPath <p>  Path to config.json (default: script directory)"
            Write-Host "    -WhatIf          Simulate operations without executing"
            Write-Host "    -Verbose         Show detailed operation logs"
            Write-Host "    -Force           Override safety checks (where applicable)"
            Write-Host ""
        }
    }
}
catch {
    Write-Host ""
    Write-Log Error $_.Exception.Message
    Write-Verbose "Stack Trace: $($_.ScriptStackTrace)"
    Write-Host ""
    exit 1
}
finally {
    Write-Progress -Activity "WSL Backup" -Completed
}