param (
    [string]$MappedFolder = (Get-Location),
    [switch]$Verbose
)

$ErrorActionPreference = "Stop"
$PSDefaultParameterValues['Write-Verbose:Verbose'] = $Verbose

function Stop-Script {
    param([int]$ExitCode = 0)
    Write-Warning "Exiting..."
    Start-Sleep -Seconds 5 # give user chance to review output
    exit $ExitCode
}

function Stop-WithWarning {
    param([string]$Message)
    Write-Warning $Message
    Stop-Script -ExitCode 1
}

function Wait-Until {
    param(
        [scriptblock]$Condition,
        [int]$TimeoutSeconds = $StartupTimeoutSeconds,
        [int]$PollMs = 500
    )

    $timer = [System.Diagnostics.Stopwatch]::StartNew()
    while (-not (& $Condition)) {
        if ($timer.Elapsed.TotalSeconds -ge $TimeoutSeconds) {
            return $false
        }
        if ($PollMs -gt 0) {
            Start-Sleep -Milliseconds $PollMs
        }
    }
    return $true
}

function Test-SshPortOpen {
    param(
        [string]$IpAddress,
        [int]$TimeoutMs = 1000
    )

    $client = [System.Net.Sockets.TcpClient]::new()
    try {
        $task = $client.ConnectAsync($IpAddress, 22)
        return $task.Wait($TimeoutMs) -and $client.Connected
    } catch {
        return $false
    } finally {
        $client.Dispose()
    }
}

function Get-HostCursorCommit {
    $lines = @(
        cursor --version 2>&1 |
            ForEach-Object { "$_".Trim() } |
            Where-Object { $_ }
    )

    # cursor --version: version, commit, arch
    $commit = if ($lines.Count -ge 2) { $lines[1] } else { $null }
    if ($commit -notmatch '^[a-f0-9]{7,40}$') {
        Stop-WithWarning "Could not parse Cursor commit hash from --version output."
    }

    return $commit
}

function Assert-MappedFolder {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "MappedFolder is not valid: $Path"
    }
}

function Ensure-SshKeys {
    if (-not (Test-Path -LiteralPath $SshIdentityFile)) {
        $createKeysScript = Join-Path $PSScriptRoot "Create-SSHKeys.ps1"
        if (-not (Test-Path -LiteralPath $createKeysScript)) {
            Stop-WithWarning "SSH identity file not found and key script missing: $createKeysScript"
        }

        Write-Host "SSH identity file not found; generating keys..."
        & $createKeysScript
    }

    if (-not (Test-Path -LiteralPath $SshIdentityFile)) {
        Stop-WithWarning "SSH identity file not found: $SshIdentityFile"
    }

    $pubKey = Join-Path $ShareFolder ".ssh-host\id_ed25519_winsandbox.pub"
    if (-not (Test-Path -LiteralPath $pubKey)) {
        Stop-WithWarning "SSH public key not found: $pubKey"
    }
}

function Assert-Prerequisites {
    $problems = @()

    if (-not (Get-Command wsb -ErrorAction SilentlyContinue)) {
        $problems += "wsb CLI not found on PATH."
    }

    if (-not (Get-Command cursor -ErrorAction SilentlyContinue)) {
        $problems += "cursor CLI not found on PATH."
    }

    $requiredShareItems = @(
        (Join-Path $ShareFolder "SandboxOnStart.bat"),
        (Join-Path $ShareFolder "Install-Cursor.ps1")
    )
    foreach ($item in $requiredShareItems) {
        if (-not (Test-Path -LiteralPath $item)) {
            $problems += "Share item not found: $item"
        }
    }

    if ($problems.Count -gt 0) {
        $bullets = ($problems | ForEach-Object { "- $_" }) -join [Environment]::NewLine
        Stop-WithWarning "Prerequisites not met:`n$bullets"
    }
}

function Resolve-WsbConfigPath {
    $path = Join-Path $PSScriptRoot "..\wsb\Windows Sandbox Cursor.wsb"
    if (Test-Path -LiteralPath $path) {
        return $path
    }

    Stop-WithWarning "Windows Sandbox config (.wsb) not found: $path"
}

function Get-SandboxId {
    try {
        $ids = @(wsb list 2>$null | ? { $_.Trim() } | % { [guid]$_ })
    } catch {
        Stop-WithWarning "Failed to read Windows Sandbox sessions: $($_.Exception.Message)"
    }

    if (-not $ids -or $ids.Count -eq 0) {
        return $null
    }
    if ($ids.Count -eq 1) {
        return $ids[0]
    }

    Stop-WithWarning "Multiple Windows Sandbox sessions are running. Close extras and retry."
}

function Start-SandboxIfNeeded {
    if (Get-SandboxId) {
        # TODO: validate that this is the right type of sandbox for remote cursor connection
        return $null
    }

    Write-Host "Launching sandbox..."

    $commit = Get-HostCursorCommit

    Write-Verbose "Current Cursor commit: $commit"

    # Used to speed up subsequent sandbox load times
    New-Item -ItemType Directory -Path (Join-Path $env:TEMP "SandboxPackageCache") -Force | Out-Null

    $tempWsbFile = Join-Path $env:TEMP "CursorSandbox_$([guid]::NewGuid().Guid).wsb"
    $wsbContent = Get-Content -LiteralPath $WsbConfigPath -Raw
    $wsbContent = $wsbContent -replace '</Command>', " $commit</Command>"
    $wsbContent = $wsbContent -replace '\$PWD', (Split-Path $WsbConfigPath -Resolve -Parent)

    Set-Content -LiteralPath $tempWsbFile -Value $wsbContent -NoNewline

    # Prefer launching the .wsb file: wsb start does not trigger LogonCommand and needs manual connect/stop.
    Start-Process $tempWsbFile

    return $tempWsbFile
}

function Wait-SandboxProcess {
    Write-Host "Waiting for sandbox to start..."

    $started = Wait-Until `
        -Condition { Get-Process -Name $SandboxProcessName -ErrorAction SilentlyContinue }

    if (-not $started) {
        Stop-WithWarning "Sandbox process NOT detected within time limit."
    }

    Write-Host "Waiting for sandbox to become available..."
    $ready = Wait-Until `
        -Condition {
            try {
                $null -ne (Get-SandboxId)
            } catch {
                $false
            }
        }

    if (-not $ready) {
        Stop-WithWarning "Sandbox ID NOT available within time limit."
    }
}

function Get-SandboxConnectionInfo {
    $sandboxId = Get-SandboxId
    if (-not $sandboxId) {
        Stop-WithWarning "No running Windows Sandbox session found."
    }

    $sandboxIp = (wsb ip --id $sandboxId | Out-String).Trim()
    if (-not $sandboxIp) {
        Stop-WithWarning "Could not resolve sandbox IP for $sandboxId."
    }

    Write-Host $sandboxId, $sandboxIp

    return [pscustomobject]@{
        Id = $sandboxId
        Ip = $sandboxIp
    }
}

function Mount-SandboxFolder {
    param(
        [guid]$Id,
        [string]$HostPath
    )

    $sandboxFolder = Join-Path $SandboxRootFolder (Split-Path $HostPath -Leaf)

    # TODO: prompt to confirm that this will allow the sandbox to write to this folder
    Write-Warning "Mapping folder as writable:`n`t$HostPath <> $sandboxFolder"
    $null = wsb share --id $Id --host-path $HostPath --sandbox-path $sandboxFolder --allow-write

    # Open root folder on sandbox for visibility
    $null = wsb exec --id $Id -r ExistingLogin -c "cmd.exe /c start $SandboxRootFolder"

    return $sandboxFolder
}

function Ensure-SshHostEntry {
    Ensure-SshKeys

    $sshDir = Split-Path -Parent $SshConfigFile
    if (-not (Test-Path -LiteralPath $sshDir)) {
        New-Item -ItemType Directory -Path $sshDir -Force | Out-Null
        Write-Verbose "Created $sshDir"
    }

    if (-not (Test-Path -LiteralPath $SshConfigFile)) {
        New-Item -ItemType File -Path $SshConfigFile -Force | Out-Null
        Write-Verbose "Created $SshConfigFile"
    }

    $hostLine = "Host $SshHostAlias"
    $sshConfig = Get-Content -LiteralPath $SshConfigFile -Raw -ErrorAction SilentlyContinue
    if ($sshConfig -match "(?m)^$([regex]::Escape($hostLine))\s*$") {
        return
    }

    Write-Verbose "Adding '$SshHostAlias' to .ssh\config..."

    $identityFilePath = $SshIdentityFile
    $homePrefix = $env:USERPROFILE.TrimEnd('\', '/')
    if ($identityFilePath -like "$homePrefix*") {
        $identityFilePath = '~' + $identityFilePath.Substring($homePrefix.Length)
    }
    $identityFilePath = $identityFilePath -replace '\\', '/'

    $block = @"
$hostLine
    HostName 127.0.0.1
    Port 22
    User WDAGUtilityAccount
    IdentityFile $identityFilePath
    StrictHostKeyChecking no
    UserKnownHostsFile `$null
"@

    Add-Content -LiteralPath $SshConfigFile -Value "`n$block"
}

function Update-SshConfig {
    param([string]$IpAddress)

    Write-Host "Updating .ssh\config..."

    $sshConfig = @(Get-Content -LiteralPath $SshConfigFile)
    $hostIndex = $sshConfig.IndexOf("Host $SshHostAlias")

    if ($hostIndex -lt 0) {
        Stop-WithWarning "Unable to update .ssh\config"
    }

    $hostNameIndex = $hostIndex + 1
    if ($sshConfig[$hostNameIndex] -notmatch '^\s*HostName\s+\S+') {
        Stop-WithWarning "Expected HostName line after 'Host $SshHostAlias' in .ssh\config; aborting update"
    }

    $sshConfig[$hostNameIndex] = "    HostName $IpAddress"
    $sshConfig | Set-Content $SshConfigFile
}

function Wait-SshPort {
    param([string]$IpAddress)

    Write-Host "Waiting for sandbox SSH server to start..."

    $opened = Wait-Until `
        -Condition { Test-SshPortOpen -IpAddress $IpAddress }

    if (-not $opened) {
        Stop-WithWarning "Port connection NOT detected within time limit."
    }
}

function Start-RemoteCursor {
    param([string]$SandboxFolder)

    # TODO: consider adding script arg to skip launching cursor (i.e. might already be started?)
    Write-Host "Launching cursor w/ remote ${SshHostAlias}: $SandboxFolder"

    # $cursorArgs = @("--remote", "ssh-remote+$SshHostAlias", $SandboxFolder) # stopped working reliably
    $cursorArgs = @("--folder-uri", "vscode-remote://ssh-remote+$SshHostAlias/$($SandboxFolder.Replace('\', '/'))")

    Start-Process -FilePath "cursor" -ArgumentList $cursorArgs -WindowStyle Hidden
}

# --- Main ---

#region Config
$SandboxProcessName = "vmmemWindowsSandbox"
$SandboxRootFolder = "C:\Users\WDAGUtilityAccount\source\repos"
$ShareFolder = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\share"))
$SshConfigFile = "$env:USERPROFILE\.ssh\config"
$SshHostAlias = "windows-sandbox"
$SshIdentityFile = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\.ssh\id_ed25519_winsandbox"))
$StartupTimeoutSeconds = 120
#endregion

Assert-MappedFolder $MappedFolder
Assert-Prerequisites
$WsbConfigPath = Resolve-WsbConfigPath

Ensure-SshHostEntry

$tempWsbFile = Start-SandboxIfNeeded
Wait-SandboxProcess
if ($tempWsbFile) {
    Remove-Item -LiteralPath $tempWsbFile -ErrorAction SilentlyContinue
}

$sandbox = Get-SandboxConnectionInfo
$sandboxFolder = Mount-SandboxFolder -Id $sandbox.Id -HostPath $MappedFolder

Update-SshConfig -IpAddress $sandbox.Ip
Wait-SshPort -IpAddress $sandbox.Ip

Start-RemoteCursor -SandboxFolder $sandboxFolder

# Read-Host "Press Enter to exit..."
Stop-Script
