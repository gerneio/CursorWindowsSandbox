<#
.SYNOPSIS
    Temporary PATH shims for Cursor sandbox startup installs.

.DESCRIPTION
    Package installers (e.g. winget) write new directories to the persisted Machine/User
    PATH, but the current process environment does not pick those up until it is
    restarted. During sandbox setup we need newly installed commands (dotnet, etc.)
    to resolve immediately in this session and in child processes.

    This module places a shim directory on PATH and, as persisted PATH entries appear,
    writes small .cmd wrappers there that forward to the real binaries. After startup
    installs finish, Unregister-PathShims removes the shim directory from PATH and
    rebuilds the process PATH from Machine+User so later sessions use the real paths.
#>

function Initialize-PathShims {
    $shimDirectory = "$env:LOCALAPPDATA\CursorSandbox\Links"
    New-Item -ItemType Directory -Path $shimDirectory -Force | Out-Null
    Get-ChildItem -LiteralPath $shimDirectory -File | ? { $_.LinkType -eq "SymbolicLink" } | Remove-Item -Force
    foreach ($target in @("User", "Process")) {
        $path = [Environment]::GetEnvironmentVariable("Path", $target)
        if (@($path -split ';') -notcontains $shimDirectory) {
            [Environment]::SetEnvironmentVariable("Path", (@($path, $shimDirectory) | ? { $_ }) -join ';', $target)
        }
    }
    $shimDirectory
}

function Unregister-PathShims {
    $shimDirectory = $script:PathShimDirectory
    foreach ($target in @("User", "Process")) {
        $path = [Environment]::GetEnvironmentVariable("Path", $target)
        $entries = @($path -split ';' | ? { $_ -and [string]::Compare($_, $shimDirectory, $true) -ne 0 })
        [Environment]::SetEnvironmentVariable("Path", ($entries -join ';'), $target)
    }

    # Rebuild this process PATH from the persisted Machine+User values (installers' real dirs).
    $persisted = @(
        [Environment]::GetEnvironmentVariable("Path", "Machine")
        [Environment]::GetEnvironmentVariable("Path", "User")
    ) | ? { $_ }
    [Environment]::SetEnvironmentVariable("Path", ($persisted -join ';'), "Process")
}

function Get-PersistedPathEntries {
    @("Machine", "User") |
        % { [Environment]::GetEnvironmentVariable("Path", $_) -split ';' } |
        % { $_.Trim().Trim('"') } |
        ? { $_ }
}

function New-PathCommandShims($PathEntries) {
    $commandExtensions = @($env:PATHEXT -split ';')
    foreach ($pathEntry in $PathEntries) {
        $pathEntry = [Environment]::ExpandEnvironmentVariables($pathEntry)
        if (-not (Test-Path -LiteralPath $pathEntry -PathType Container)) {
            continue
        }

        $commands = Get-ChildItem -LiteralPath $pathEntry -File |
            ? { $_.Extension -in $commandExtensions } |
            Sort-Object @{ Expression = { $commandExtensions.IndexOf($_.Extension.ToUpperInvariant()) } }, Name

        foreach ($command in $commands) {
            # Already processed this command on a previous refresh.
            if ($script:PathShimProcessedCommands.Contains($command.FullName)) {
                continue
            }

            $shimPath = Join-Path $script:PathShimDirectory "$($command.BaseName).cmd"
            if (Test-Path -LiteralPath $shimPath) {
                Write-Warning "Command shim '$($command.BaseName)' already exists; ignoring '$($command.FullName)'."
                [void]$script:PathShimProcessedCommands.Add($command.FullName)
                continue
            }

            try {
                $invoke = if ($command.Extension -in @(".cmd", ".bat")) { "call " } else { "" }
                "@$invoke`"$($command.FullName)`" %*" | Set-Content -LiteralPath $shimPath -Encoding Ascii
                [void]$script:PathShimProcessedCommands.Add($command.FullName)
            } catch {
                Write-Warning "Could not create command shim '$shimPath' for '$($command.FullName)': $($_.Exception.Message)"
            }
        }
    }
}

function Invoke-PathShimRefresh($sc, $ArgumentList = @()) {
    # PATH entries present before $sc runs; refresh only considers additions beyond these.
    $script:PathShimPathBefore = [Collections.Generic.HashSet[string]]::new(
        [string[]]@(Get-PersistedPathEntries),
        [StringComparer]::OrdinalIgnoreCase
    )
    $script:PathShimProcessedCommands = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $sourceIdentifier = "PathShimRefresh.$([Guid]::NewGuid())"
    $refresh = {
        $newPathEntries = @(Get-PersistedPathEntries | ? { -not $script:PathShimPathBefore.Contains($_) } | Select-Object -Unique)
        New-PathCommandShims $newPathEntries
    }

    $timer = [Timers.Timer]::new(1000)
    # -Action runs in the event job's session state; invoke the module-bound
    # scriptblock via MessageData so private helpers remain visible.
    $timerJob = Register-ObjectEvent $timer Elapsed -SourceIdentifier $sourceIdentifier -MessageData $refresh -Action {
        & $Event.MessageData
    }
    $job = $null
    try {
        $timer.Start()

        # Job keeps this runspace free so timer actions can run during native commands.
        $job = Start-Job -ScriptBlock $sc -ArgumentList $ArgumentList
        while ($job.State -eq 'Running') {
            Receive-Job $job | Out-Default
            Wait-Job $job -Timeout 1 | Out-Null
        }
        Receive-Job $job | Out-Default

        if ($job.State -eq 'Failed') {
            throw $job.ChildJobs[0].JobStateInfo.Reason
        }
    } finally {
        if ($job) { Remove-Job $job -Force -ErrorAction SilentlyContinue }
        $timer.Stop()
        Unregister-Event -SourceIdentifier $sourceIdentifier -ErrorAction SilentlyContinue
        Receive-Job $timerJob -ErrorAction SilentlyContinue | Out-Null
        Remove-Job $timerJob -Force -ErrorAction SilentlyContinue
        $timer.Dispose()
        & $refresh
        if ($script:PathShimProcessedCommands.Count) {
            Write-Host "Created path shims for $($script:PathShimProcessedCommands.Count) command(s):"
            $script:PathShimProcessedCommands | Sort-Object | % { Write-Host "  $_" }
        }
        Remove-Variable PathShimPathBefore, PathShimProcessedCommands -Scope Script -ErrorAction SilentlyContinue
        Unregister-PathShims
    }
}

$script:PathShimDirectory = Initialize-PathShims
Export-ModuleMember -Function Invoke-PathShimRefresh
