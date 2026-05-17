# Add CodexBar to Windows startup
$startupDir = [System.IO.Path]::Combine($env:APPDATA, "Microsoft\Windows\Start Menu\Programs\Startup")
$shortcutPath = Join-Path $startupDir "CodexBar.lnk"
$scriptPath = Join-Path $PSScriptRoot "CodexBar.ps1"

$shell = New-Object -ComObject WScript.Shell
$shortcut = $shell.CreateShortcut($shortcutPath)
$shortcut.TargetPath = "powershell.exe"
$shortcut.Arguments = "-ExecutionPolicy Bypass -WindowStyle Hidden -File `"$scriptPath`""
$shortcut.WorkingDirectory = $PSScriptRoot
$shortcut.Description = "CodexBar - AI Usage Monitor"
$shortcut.Save()

Write-Host "CodexBar added to Windows startup: $shortcutPath"
Write-Host "It will start automatically on next login."
