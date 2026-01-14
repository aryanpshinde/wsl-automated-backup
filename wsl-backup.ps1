param([string]$cmd="help")
& "$Env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -ExecutionPolicy Bypass -File "C:\Tools\WSLBackup\backup.ps1" $cmd
