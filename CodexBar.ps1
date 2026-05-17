# CodexBar for Windows - AI Usage Monitor
# System tray application that monitors Claude, Codex, and Gemini usage
# Zero dependencies: runs on PowerShell 5.1+ with .NET (built into Windows 10/11)
#
# Usage: powershell -ExecutionPolicy Bypass -WindowStyle Hidden -File CodexBar.ps1
# Or just right-click > Run with PowerShell

param(
    [switch]$Debug,
    [int]$PollIntervalSeconds = 60
)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# --- Configuration ---
$script:AppName = "CodexBar"
$script:ConfigDir = Join-Path $env:USERPROFILE ".codexbar-win"
$script:LogFile = Join-Path $script:ConfigDir "codexbar.log"

if (-not (Test-Path $script:ConfigDir)) {
    New-Item -ItemType Directory -Path $script:ConfigDir -Force | Out-Null
}

# --- Logging ---
function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$ts] [$Level] $Message"
    if ($Debug) { Write-Host $line }
    Add-Content -Path $script:LogFile -Value $line -ErrorAction SilentlyContinue
}

# --- Credential Readers ---
function Refresh-ClaudeToken {
    param([string]$RefreshToken, [string]$CredFile)
    try {
        $body = @{
            grant_type    = "refresh_token"
            refresh_token = $RefreshToken
            client_id     = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
        }
        $response = Invoke-RestMethod -Uri "https://platform.claude.com/v1/oauth/token" `
            -Method Post -Body ($body | ConvertTo-Json) -ContentType "application/json" -TimeoutSec 15

        if ($response.access_token) {
            $creds = Get-Content $CredFile -Raw | ConvertFrom-Json
            $creds.claudeAiOauth.accessToken = $response.access_token
            if ($response.refresh_token) {
                $creds.claudeAiOauth.refreshToken = $response.refresh_token
            }
            if ($response.expires_in) {
                $creds.claudeAiOauth.expiresAt = [DateTimeOffset]::UtcNow.AddSeconds($response.expires_in).ToString("o")
            }
            $creds | ConvertTo-Json -Depth 10 | Set-Content $CredFile -Encoding UTF8
            Write-Log "Claude: token refreshed successfully"
            return $response.access_token
        }
    } catch {
        Write-Log "Claude: token refresh failed: $_" "WARN"
    }
    return $null
}

function Get-ClaudeOAuthToken {
    # Strategy 1: Read from ~/.claude/.credentials.json
    $credFile = Join-Path $env:USERPROFILE ".claude\.credentials.json"
    if (Test-Path $credFile) {
        try {
            $creds = Get-Content $credFile -Raw | ConvertFrom-Json
            if ($creds.claudeAiOauth.accessToken) {
                $expired = $false
                if ($creds.claudeAiOauth.expiresAt) {
                    try {
                        $expiresAt = [DateTimeOffset]::Parse($creds.claudeAiOauth.expiresAt).UtcDateTime
                        $expired = $expiresAt -lt [DateTime]::UtcNow
                    } catch {}
                }

                if ($expired -and $creds.claudeAiOauth.refreshToken) {
                    Write-Log "Claude: token expired, refreshing..."
                    $newToken = Refresh-ClaudeToken -RefreshToken $creds.claudeAiOauth.refreshToken -CredFile $credFile
                    if ($newToken) {
                        return @{ Token = $newToken; Source = "credentials-file-refreshed" }
                    }
                }

                Write-Log "Claude: loaded token from .credentials.json"
                return @{
                    Token = $creds.claudeAiOauth.accessToken
                    Source = "credentials-file"
                }
            }
        } catch {
            Write-Log "Claude: failed to parse .credentials.json: $_" "WARN"
        }
    }

    # Strategy 2: Environment variable override
    $envToken = $env:CODEXBAR_CLAUDE_OAUTH_TOKEN
    if ($envToken) {
        Write-Log "Claude: using env var CODEXBAR_CLAUDE_OAUTH_TOKEN"
        return @{
            Token = $envToken
            Source = "environment"
        }
    }

    Write-Log "Claude: no credentials found" "WARN"
    return $null
}

function Get-CodexAuthToken {
    $authFile = Join-Path $env:USERPROFILE ".codex\auth.json"
    if (-not (Test-Path $authFile)) {
        Write-Log "Codex: auth.json not found" "WARN"
        return $null
    }

    try {
        $auth = Get-Content $authFile -Raw | ConvertFrom-Json

        # Stock format: { tokens: { access_token, ... } }
        if ($auth.tokens.access_token) {
            Write-Log "Codex: loaded token from auth.json (stock format)"
            return @{
                Token = $auth.tokens.access_token
                Source = "auth-json-stock"
                AccountId = $null
            }
        }

        # Hermes/OpenClaw format: { access_token, ... }
        if ($auth.access_token) {
            Write-Log "Codex: loaded token from auth.json (hermes format)"
            return @{
                Token = $auth.access_token
                Source = "auth-json-hermes"
                AccountId = $null
            }
        }
    } catch {
        Write-Log "Codex: failed to parse auth.json: $_" "WARN"
    }

    return $null
}

function Get-JwtClaim {
    param([string]$Token, [string]$ClaimName)
    try {
        $parts = $Token.Split('.')
        if ($parts.Length -lt 2) { return $null }
        $payload = $parts[1]
        # Fix base64url padding
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

# --- API Fetchers ---
function Fetch-ClaudeUsage {
    param([hashtable]$Creds)
    if (-not $Creds) { return $null }

    try {
        $headers = @{
            "Authorization"  = "Bearer $($Creds.Token)"
            "Accept"         = "application/json"
            "Content-Type"   = "application/json"
            "anthropic-beta" = "oauth-2025-04-20"
            "User-Agent"     = "CodexBar-Win/1.0"
        }

        $response = Invoke-RestMethod -Uri "https://api.anthropic.com/api/oauth/usage" `
            -Method Get -Headers $headers -TimeoutSec 15 -ErrorAction Stop

        $result = @{
            Provider = "Claude"
            FiveHour = @{
                Utilization = [math]::Round($response.five_hour.utilization, 1)
                ResetsAt    = $response.five_hour.resets_at
            }
            SevenDay = @{
                Utilization = [math]::Round($response.seven_day.utilization, 1)
                ResetsAt    = $response.seven_day.resets_at
            }
        }

        Write-Log "Claude: 5h=$($result.FiveHour.Utilization)% 7d=$($result.SevenDay.Utilization)%"
        return $result
    } catch {
        Write-Log "Claude: API error: $_" "ERROR"
        return $null
    }
}

function Fetch-CodexUsage {
    param([hashtable]$Creds)
    if (-not $Creds) { return $null }

    $accountId = Get-JwtClaim -Token $Creds.Token -ClaimName "https://api.openai.com/auth.chatgpt_account_id"

    try {
        $headers = @{
            "Authorization"      = "Bearer $($Creds.Token)"
            "Accept"             = "application/json"
            "User-Agent"         = "CodexBar"
        }
        if ($accountId) {
            $headers["ChatGPT-Account-Id"] = $accountId
        }

        $response = Invoke-RestMethod -Uri "https://chatgpt.com/backend-api/wham/usage" `
            -Method Get -Headers $headers -TimeoutSec 15 -ErrorAction Stop

        $result = @{
            Provider = "Codex"
            PlanType = $response.plan_type
            Windows  = @()
        }

        $rateLimit = $response.rate_limit
        if ($rateLimit.primary_window) {
            $result.Windows += @{
                Name        = "Primary"
                UsedPercent = [math]::Round($rateLimit.primary_window.used_percent, 1)
                ResetAt     = $rateLimit.primary_window.reset_at
                WindowSecs  = $rateLimit.primary_window.limit_window_seconds
            }
        }
        if ($rateLimit.secondary_window) {
            $result.Windows += @{
                Name        = "Weekly"
                UsedPercent = [math]::Round($rateLimit.secondary_window.used_percent, 1)
                ResetAt     = $rateLimit.secondary_window.reset_at
                WindowSecs  = $rateLimit.secondary_window.limit_window_seconds
            }
        }

        $primary = if ($result.Windows.Count -gt 0) { "$($result.Windows[0].UsedPercent)%" } else { "?" }
        Write-Log "Codex: primary=$primary plan=$($result.PlanType)"
        return $result
    } catch {
        Write-Log "Codex: API error: $_" "ERROR"
        return $null
    }
}

function Get-GeminiSessionCount {
    $geminiDir = Join-Path $env:USERPROFILE ".gemini"
    if (-not (Test-Path $geminiDir)) { return $null }

    $model = "Unknown"
    $settingsFile = Join-Path $geminiDir "settings.json"
    if (Test-Path $settingsFile) {
        try {
            $settings = Get-Content $settingsFile -Raw | ConvertFrom-Json
            if ($settings.model.name) { $model = $settings.model.name }
        } catch {}
    }

    $sessions = 0
    $tmpDir = Join-Path $geminiDir "tmp"
    if (Test-Path $tmpDir) {
        $sessions = (Get-ChildItem -Path $tmpDir -Filter "session-*.json" -Recurse -ErrorAction SilentlyContinue).Count
    }

    return @{
        Provider = "Gemini"
        Model    = $model
        Sessions = $sessions
    }
}

# --- UI Helpers ---
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

function Get-UsageColor {
    param([double]$Percent)
    if ($Percent -lt 50) { return "Green" }
    if ($Percent -lt 75) { return "Yellow" }
    if ($Percent -lt 90) { return "Orange" }
    return "Red"
}

function Get-TrayIcon {
    param([double]$MaxUsage)
    # Generate a simple colored circle icon based on usage level
    $size = 16
    $bmp = New-Object System.Drawing.Bitmap($size, $size)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias

    $color = if ($MaxUsage -lt 50) { [System.Drawing.Color]::FromArgb(82, 208, 23) }      # Green
             elseif ($MaxUsage -lt 75) { [System.Drawing.Color]::FromArgb(255, 215, 0) }   # Yellow
             elseif ($MaxUsage -lt 90) { [System.Drawing.Color]::FromArgb(255, 140, 0) }   # Orange
             else { [System.Drawing.Color]::FromArgb(255, 68, 68) }                         # Red

    $brush = New-Object System.Drawing.SolidBrush($color)
    $g.FillEllipse($brush, 1, 1, $size - 2, $size - 2)

    # Draw usage percentage arc (dark overlay for used portion)
    $pen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(60, 0, 0, 0), 2)
    $sweepAngle = [math]::Min(360, $MaxUsage * 3.6)
    if ($sweepAngle -gt 0) {
        $g.DrawArc($pen, 2, 2, $size - 4, $size - 4, -90, $sweepAngle)
    }

    $g.Dispose()
    $brush.Dispose()
    $pen.Dispose()

    $hIcon = $bmp.GetHicon()
    $icon = [System.Drawing.Icon]::FromHandle($hIcon)
    return $icon
}

# --- Main Application ---
function Start-CodexBarTray {
    [System.Windows.Forms.Application]::EnableVisualStyles()

    $script:NotifyIcon = New-Object System.Windows.Forms.NotifyIcon
    $script:NotifyIcon.Text = "CodexBar - Loading..."
    $script:NotifyIcon.Icon = Get-TrayIcon -MaxUsage 0
    $script:NotifyIcon.Visible = $true

    # Context menu
    $contextMenu = New-Object System.Windows.Forms.ContextMenuStrip

    $script:ClaudeMenuItem = New-Object System.Windows.Forms.ToolStripMenuItem("Claude: Loading...")
    $script:ClaudeDetailItem = New-Object System.Windows.Forms.ToolStripMenuItem("  Checking...")
    $script:CodexMenuItem = New-Object System.Windows.Forms.ToolStripMenuItem("Codex: Loading...")
    $script:CodexDetailItem = New-Object System.Windows.Forms.ToolStripMenuItem("  Checking...")
    $script:GeminiMenuItem = New-Object System.Windows.Forms.ToolStripMenuItem("Gemini: Loading...")

    $separator1 = New-Object System.Windows.Forms.ToolStripSeparator
    $separator2 = New-Object System.Windows.Forms.ToolStripSeparator

    $refreshItem = New-Object System.Windows.Forms.ToolStripMenuItem("Refresh Now")
    $refreshItem.Add_Click({ Update-Usage })

    $openLogItem = New-Object System.Windows.Forms.ToolStripMenuItem("Open Log")
    $openLogItem.Add_Click({ Start-Process notepad.exe $script:LogFile })

    $exitItem = New-Object System.Windows.Forms.ToolStripMenuItem("Exit")
    $exitItem.Add_Click({
        $script:NotifyIcon.Visible = $false
        $script:NotifyIcon.Dispose()
        [System.Windows.Forms.Application]::Exit()
    })

    $contextMenu.Items.Add($script:ClaudeMenuItem) | Out-Null
    $contextMenu.Items.Add($script:ClaudeDetailItem) | Out-Null
    $contextMenu.Items.Add($separator1) | Out-Null
    $contextMenu.Items.Add($script:CodexMenuItem) | Out-Null
    $contextMenu.Items.Add($script:CodexDetailItem) | Out-Null
    $contextMenu.Items.Add($separator2) | Out-Null
    $contextMenu.Items.Add($script:GeminiMenuItem) | Out-Null
    $contextMenu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null
    $contextMenu.Items.Add($refreshItem) | Out-Null
    $contextMenu.Items.Add($openLogItem) | Out-Null
    $contextMenu.Items.Add($exitItem) | Out-Null

    $script:NotifyIcon.ContextMenuStrip = $contextMenu

    # Double-click opens menu
    $script:NotifyIcon.Add_DoubleClick({
        $script:NotifyIcon.ContextMenuStrip.Show(
            [System.Windows.Forms.Cursor]::Position)
    })

    # Timer for periodic updates
    $script:Timer = New-Object System.Windows.Forms.Timer
    $script:Timer.Interval = $PollIntervalSeconds * 1000
    $script:Timer.Add_Tick({ Update-Usage })
    $script:Timer.Start()

    # Initial fetch
    Update-Usage

    Write-Log "CodexBar started (poll=${PollIntervalSeconds}s)"
    [System.Windows.Forms.Application]::Run()
}

function Update-Usage {
    $maxUsage = 0

    # --- Claude ---
    $claudeCreds = Get-ClaudeOAuthToken
    $claudeUsage = Fetch-ClaudeUsage -Creds $claudeCreds

    if ($claudeUsage) {
        $fiveHr = $claudeUsage.FiveHour.Utilization
        $sevenDay = $claudeUsage.SevenDay.Utilization
        $resetIn = Format-TimeRemaining -ResetAt $claudeUsage.FiveHour.ResetsAt
        $weeklyReset = Format-TimeRemaining -ResetAt $claudeUsage.SevenDay.ResetsAt

        $script:ClaudeMenuItem.Text = "Claude: ${fiveHr}% (resets in $resetIn)"
        $script:ClaudeDetailItem.Text = "  Weekly: ${sevenDay}% (resets in $weeklyReset)"
        $maxUsage = [math]::Max($maxUsage, $fiveHr)
    } else {
        $script:ClaudeMenuItem.Text = "Claude: Not connected"
        $script:ClaudeDetailItem.Text = "  Click to authenticate..."
        $script:ClaudeDetailItem.Add_Click({
            Start-Process "cmd.exe" "/c claude && pause"
        })
    }

    # --- Codex ---
    $codexCreds = Get-CodexAuthToken
    $codexUsage = Fetch-CodexUsage -Creds $codexCreds

    if ($codexUsage) {
        if ($codexUsage.Windows.Count -gt 0) {
            $primary = $codexUsage.Windows[0]
            $resetIn = ""
            if ($primary.ResetAt) {
                $resetEpoch = [DateTimeOffset]::FromUnixTimeSeconds($primary.ResetAt)
                $diff = $resetEpoch.UtcDateTime - [DateTime]::UtcNow
                if ($diff.TotalMinutes -gt 0) {
                    $resetIn = " (resets in $([math]::Floor($diff.TotalHours))h$($diff.Minutes)m)"
                }
            }
            $script:CodexMenuItem.Text = "Codex: $($primary.UsedPercent)%$resetIn"
            $maxUsage = [math]::Max($maxUsage, $primary.UsedPercent)
        }
        if ($codexUsage.Windows.Count -gt 1) {
            $weekly = $codexUsage.Windows[1]
            $script:CodexDetailItem.Text = "  Weekly: $($weekly.UsedPercent)%"
        } else {
            $script:CodexDetailItem.Text = "  Plan: $($codexUsage.PlanType)"
        }
    } else {
        $script:CodexMenuItem.Text = "Codex: Not connected"
        $script:CodexDetailItem.Text = "  Run 'codex login' to authenticate"
    }

    # --- Gemini ---
    $gemini = Get-GeminiSessionCount
    if ($gemini) {
        $script:GeminiMenuItem.Text = "Gemini: $($gemini.Sessions) sessions ($($gemini.Model))"
    } else {
        $script:GeminiMenuItem.Text = "Gemini: Not installed"
    }

    # Update tray icon and tooltip
    $oldIcon = $script:NotifyIcon.Icon
    $script:NotifyIcon.Icon = Get-TrayIcon -MaxUsage $maxUsage

    $tooltip = "CodexBar"
    if ($claudeUsage) { $tooltip += "`nClaude: $($claudeUsage.FiveHour.Utilization)%" }
    if ($codexUsage -and $codexUsage.Windows.Count -gt 0) { $tooltip += "`nCodex: $($codexUsage.Windows[0].UsedPercent)%" }
    $script:NotifyIcon.Text = $tooltip.Substring(0, [math]::Min(63, $tooltip.Length))

    if ($oldIcon) {
        try { $oldIcon.Dispose() } catch {}
    }
}

# --- Entry Point ---
Write-Log "=== CodexBar for Windows v1.0.0 ==="
Write-Log "Config dir: $script:ConfigDir"
Write-Log "Poll interval: ${PollIntervalSeconds}s"

Start-CodexBarTray
