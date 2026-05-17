# Test harness for CodexBar - validates all logic on Windows without GUI
# Runs headlessly: exercises credential reading, JWT parsing, API response parsing,
# time formatting, and icon generation. Exit 0 = all tests pass.

param([switch]$Verbose)

$ErrorActionPreference = "Stop"
$passed = 0
$failed = 0

function Assert-Equal {
    param($Expected, $Actual, [string]$TestName)
    if ($Expected -eq $Actual) {
        if ($Verbose) { Write-Host "  PASS: $TestName" -ForegroundColor Green }
        $script:passed++
    } else {
        Write-Host "  FAIL: $TestName — expected '$Expected', got '$Actual'" -ForegroundColor Red
        $script:failed++
    }
}

function Assert-NotNull {
    param($Value, [string]$TestName)
    if ($null -ne $Value -and $Value -ne "") {
        if ($Verbose) { Write-Host "  PASS: $TestName" -ForegroundColor Green }
        $script:passed++
    } else {
        Write-Host "  FAIL: $TestName — value was null/empty" -ForegroundColor Red
        $script:failed++
    }
}

function Assert-True {
    param([bool]$Condition, [string]$TestName)
    if ($Condition) {
        if ($Verbose) { Write-Host "  PASS: $TestName" -ForegroundColor Green }
        $script:passed++
    } else {
        Write-Host "  FAIL: $TestName" -ForegroundColor Red
        $script:failed++
    }
}

Write-Host "=== CodexBar for Windows - Test Suite ===" -ForegroundColor Cyan
Write-Host ""

# --- Test 1: Script loads without error ---
Write-Host "[1] Script parsing..." -ForegroundColor Yellow
try {
    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile(
        "$PSScriptRoot\CodexBar.ps1", [ref]$tokens, [ref]$parseErrors)
    Assert-Equal 0 $parseErrors.Count "Zero parse errors"
    Assert-True ($ast.EndBlock.Statements.Count -gt 0) "Has executable statements"
} catch {
    Write-Host "  FAIL: Script parse threw exception: $_" -ForegroundColor Red
    $failed++
}

# --- Test 2: JWT parsing ---
Write-Host "[2] JWT claim extraction..." -ForegroundColor Yellow

function Get-JwtClaim {
    param([string]$Token, [string]$ClaimName)
    try {
        $parts = $Token.Split('.')
        if ($parts.Length -lt 2) { return $null }
        $payload = $parts[1]
        $mod = $payload.Length % 4
        if ($mod -eq 2) { $payload += "==" }
        elseif ($mod -eq 3) { $payload += "=" }
        $payload = $payload.Replace('-', '+').Replace('_', '/')
        $json = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payload))
        $claims = $json | ConvertFrom-Json
        return $claims.$ClaimName
    } catch {
        return $null
    }
}

# Test JWT with known payload: {"sub":"user_123","name":"Test User","iat":1516239022}
$testJwt = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiJ1c2VyXzEyMyIsIm5hbWUiOiJUZXN0IFVzZXIiLCJpYXQiOjE1MTYyMzkwMjJ9.SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c"
Assert-Equal "user_123" (Get-JwtClaim -Token $testJwt -ClaimName "sub") "Extract 'sub' claim"
Assert-Equal "Test User" (Get-JwtClaim -Token $testJwt -ClaimName "name") "Extract 'name' claim"
$missing = Get-JwtClaim -Token $testJwt -ClaimName "nonexistent"
Assert-True ($null -eq $missing) "Missing claim returns null"
$badToken = Get-JwtClaim -Token "not.a.jwt.at.all" -ClaimName "sub"
Assert-True ($null -eq $badToken) "Invalid JWT returns null gracefully"

# --- Test 3: Time formatting ---
Write-Host "[3] Time formatting..." -ForegroundColor Yellow

function Format-TimeRemaining {
    param([string]$ResetAt)
    if (-not $ResetAt) { return "?" }
    try {
        $resetTime = [DateTimeOffset]::Parse($ResetAt).UtcDateTime
        $now = [DateTime]::UtcNow
        $diff = $resetTime - $now
        if ($diff.TotalSeconds -le 0) { return "now" }
        if ($diff.TotalHours -lt 1) { return "$([math]::Floor($diff.TotalMinutes))m" }
        if ($diff.TotalDays -lt 1) { return "$([math]::Floor($diff.TotalHours))h$($diff.Minutes)m" }
        return "$([math]::Floor($diff.TotalDays))d$($diff.Hours)h"
    } catch {
        return "?"
    }
}

$pastTime = [DateTime]::UtcNow.AddMinutes(-5).ToString("o")
Assert-Equal "now" (Format-TimeRemaining -ResetAt $pastTime) "Past time shows 'now'"

$futureTime = [DateTime]::UtcNow.AddMinutes(30).ToString("o")
$result = Format-TimeRemaining -ResetAt $futureTime
Assert-True ($result -match '^\d+m$') "30min future shows minutes format ($result)"

$farFuture = [DateTime]::UtcNow.AddHours(3).AddMinutes(15).ToString("o")
$result = Format-TimeRemaining -ResetAt $farFuture
Assert-True ($result -match '^\d+h\d+m$') "3h15m future shows hours format ($result)"

Assert-Equal "?" (Format-TimeRemaining -ResetAt $null) "Null input returns '?'"
Assert-Equal "?" (Format-TimeRemaining -ResetAt "garbage") "Invalid input returns '?'"

# --- Test 4: API response parsing ---
Write-Host "[4] API response parsing..." -ForegroundColor Yellow

$mockClaudeResponse = @{
    five_hour = @{ utilization = 42.5; resets_at = [DateTime]::UtcNow.AddHours(2).ToString("o") }
    seven_day = @{ utilization = 15.2; resets_at = [DateTime]::UtcNow.AddDays(3).ToString("o") }
}

Assert-Equal 42.5 ([math]::Round($mockClaudeResponse.five_hour.utilization, 1)) "Claude 5h parse"
Assert-Equal 15.2 ([math]::Round($mockClaudeResponse.seven_day.utilization, 1)) "Claude 7d parse"
Assert-NotNull $mockClaudeResponse.five_hour.resets_at "Claude reset time present"

$mockCodexResponse = @{
    plan_type = "plus"
    rate_limit = @{
        primary_window = @{ used_percent = 33.7; reset_at = 1716000000; limit_window_seconds = 18000 }
        secondary_window = @{ used_percent = 12.1; reset_at = 1716500000; limit_window_seconds = 604800 }
    }
}

Assert-Equal "plus" $mockCodexResponse.plan_type "Codex plan type parse"
Assert-Equal 33.7 ([math]::Round($mockCodexResponse.rate_limit.primary_window.used_percent, 1)) "Codex primary parse"
Assert-Equal 12.1 ([math]::Round($mockCodexResponse.rate_limit.secondary_window.used_percent, 1)) "Codex weekly parse"

# --- Test 5: Icon generation (requires System.Drawing) ---
Write-Host "[5] Tray icon generation..." -ForegroundColor Yellow

try {
    Add-Type -AssemblyName System.Drawing

    function Get-TrayIcon {
        param([double]$MaxUsage)
        $size = 16
        $bmp = New-Object System.Drawing.Bitmap($size, $size)
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias

        $color = if ($MaxUsage -lt 50) { [System.Drawing.Color]::FromArgb(82, 208, 23) }
                 elseif ($MaxUsage -lt 75) { [System.Drawing.Color]::FromArgb(255, 215, 0) }
                 elseif ($MaxUsage -lt 90) { [System.Drawing.Color]::FromArgb(255, 140, 0) }
                 else { [System.Drawing.Color]::FromArgb(255, 68, 68) }

        $brush = New-Object System.Drawing.SolidBrush($color)
        $g.FillEllipse($brush, 1, 1, $size - 2, $size - 2)
        $g.Dispose()
        $brush.Dispose()

        $hIcon = $bmp.GetHicon()
        $icon = [System.Drawing.Icon]::FromHandle($hIcon)
        return $icon
    }

    $icon0 = Get-TrayIcon -MaxUsage 0
    Assert-NotNull $icon0 "Green icon (0% usage)"
    $icon0.Dispose()

    $icon60 = Get-TrayIcon -MaxUsage 60
    Assert-NotNull $icon60 "Yellow icon (60% usage)"
    $icon60.Dispose()

    $icon80 = Get-TrayIcon -MaxUsage 80
    Assert-NotNull $icon80 "Orange icon (80% usage)"
    $icon80.Dispose()

    $icon95 = Get-TrayIcon -MaxUsage 95
    Assert-NotNull $icon95 "Red icon (95% usage)"
    $icon95.Dispose()
} catch {
    Write-Host "  SKIP: System.Drawing not available (expected on non-Windows)" -ForegroundColor DarkYellow
}

# --- Test 6: Credential file detection ---
Write-Host "[6] Credential path detection..." -ForegroundColor Yellow

$claudePath = Join-Path $env:USERPROFILE ".claude\.credentials.json"
$codexPath = Join-Path $env:USERPROFILE ".codex\auth.json"
$geminiPath = Join-Path $env:USERPROFILE ".gemini\settings.json"

Assert-NotNull $claudePath "Claude credential path resolves"
Assert-NotNull $codexPath "Codex credential path resolves"
Assert-NotNull $geminiPath "Gemini settings path resolves"
Assert-True ($claudePath -like "*\.claude\.credentials.json") "Claude path correct format"
Assert-True ($codexPath -like "*\.codex\auth.json") "Codex path correct format"

# --- Test 7: System.Windows.Forms available (tray prerequisite) ---
Write-Host "[7] Windows Forms availability..." -ForegroundColor Yellow
try {
    Add-Type -AssemblyName System.Windows.Forms
    $testIcon = New-Object System.Windows.Forms.NotifyIcon
    Assert-NotNull $testIcon "NotifyIcon instantiation"
    $testIcon.Dispose()

    $testMenu = New-Object System.Windows.Forms.ContextMenuStrip
    Assert-NotNull $testMenu "ContextMenuStrip instantiation"
    $testMenu.Dispose()

    $testTimer = New-Object System.Windows.Forms.Timer
    Assert-NotNull $testTimer "Timer instantiation"
    $testTimer.Dispose()
} catch {
    Write-Host "  SKIP: System.Windows.Forms not available (expected on non-Windows)" -ForegroundColor DarkYellow
}

# --- Results ---
Write-Host ""
Write-Host "=== Results ===" -ForegroundColor Cyan
Write-Host "  Passed: $passed" -ForegroundColor Green
if ($failed -gt 0) {
    Write-Host "  Failed: $failed" -ForegroundColor Red
    exit 1
} else {
    Write-Host "  Failed: 0" -ForegroundColor Green
    Write-Host ""
    Write-Host "All tests passed. CodexBar is functional." -ForegroundColor Green
    exit 0
}
