<#
.SYNOPSIS
    Temporary PATH shims for Cursor sandbox startup installs.

.DESCRIPTION
    Package installers (e.g. winget) write new directories to the persisted Machine/User
    PATH, but the current process environment does not pick those up until it is
    restarted. During sandbox setup we need newly installed commands (dotnet, etc.)
    to resolve immediately in this session and in already-running processes such as
    cursor-server (which keep their original environment block).

    On import, this module reserves %LOCALAPPDATA%\CursorSandbox\VirtLink1..VirtLinkN on
    User/Process PATH before those processes start (dirs need not exist yet). As new
    persisted PATH entries appear, it creates VirtLinkN as a directory junction to the
    real install directory.

    After startup installs finish, Unregister-PathShims removes VirtLink entries from
    PATH and rebuilds the process PATH from Machine+User. Junctions are left on disk
    so an already-running cursor-server that inherited VirtLinks keeps resolving tools
    until it is restarted.
#>

function Get-PathVirtLinkDirectories {
    1..$script:PathVirtLinkSlotCount | % { Join-Path $script:PathVirtLinkRoot "VirtLink$_" }
}

function Test-IsPathVirtLinkDirectory([string]$Path) {
    if (-not $Path) { return $false }
    $name = Split-Path -Leaf $Path
    if ($name -notmatch '^VirtLink\d+$') { return $false }
    [string]::Compare((Split-Path -Parent $Path), $script:PathVirtLinkRoot, $true) -eq 0
}

function Initialize-PathShims {
    # Reserve PATH slots early so cursor-server inherits them. Junctions are created
    # later only for PATH dirs that actually appear (fresh sandbox; dirs may be missing).
    $virtLinkDirs = @(Get-PathVirtLinkDirectories)

    foreach ($target in @("User", "Process")) {
        $path = [Environment]::GetEnvironmentVariable("Path", $target)
        $entries = [System.Collections.Generic.List[string]]::new(
            [string[]]@($path -split ';' | ? { $_ })
        )
        foreach ($dir in $virtLinkDirs) {
            if (-not ($entries | ? { [string]::Compare($_, $dir, $true) -eq 0 })) {
                [void]$entries.Add($dir)
            }
        }
        [Environment]::SetEnvironmentVariable("Path", ($entries -join ';'), $target)
    }

    $virtLinkDirs
}

function Unregister-PathShims {
    foreach ($target in @("User", "Process")) {
        $path = [Environment]::GetEnvironmentVariable("Path", $target)
        $entries = @(
            $path -split ';' |
                ? { $_ -and -not (Test-IsPathVirtLinkDirectory $_) }
        )
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
    foreach ($pathEntry in $PathEntries) {
        $pathEntry = [Environment]::ExpandEnvironmentVariables($pathEntry)
        if (
            -not (Test-Path -LiteralPath $pathEntry -PathType Container)
            -or (Test-IsPathVirtLinkDirectory $pathEntry)
            -or $script:PathVirtLinkAssignedTargets.Contains($pathEntry)
        ) {
            continue
        }

        if ($script:PathVirtLinkNextSlot -gt $script:PathVirtLinkSlotCount) {
            Write-Warning "No free VirtLink slots left; cannot junction to '$pathEntry'."
            continue
        }

        $slotPath = Join-Path $script:PathVirtLinkRoot "VirtLink$($script:PathVirtLinkNextSlot)"
        try {
            New-Item -ItemType Directory -Path $script:PathVirtLinkRoot -Force | Out-Null
            $null = New-Item -ItemType Junction -Path $slotPath -Target $pathEntry
            [void]$script:PathVirtLinkAssignedTargets.Add($pathEntry)
            $script:PathVirtLinkAssignments[$slotPath] = $pathEntry
            $script:PathVirtLinkNextSlot++
        } catch {
            Write-Warning "Could not create VirtLink junction '$slotPath' -> '$pathEntry': $($_.Exception.Message)"
        }
    }
}

function Invoke-PathShimRefresh($sc, $ArgumentList = @()) {
    # PATH entries present before $sc runs; refresh only considers additions beyond these.
    $script:PathShimPathBefore = [Collections.Generic.HashSet[string]]::new(
        [string[]]@(Get-PersistedPathEntries),
        [StringComparer]::OrdinalIgnoreCase
    )
    $script:PathVirtLinkAssignedTargets = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $script:PathVirtLinkAssignments = [ordered]@{}
    $script:PathVirtLinkNextSlot = 1
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
        if ($script:PathVirtLinkAssignments.Count) {
            Write-Host "Created temporary VirtLink junctions for $($script:PathVirtLinkAssignments.Count) PATH dir(s):" -ForegroundColor DarkCyan
            $script:PathVirtLinkAssignments.GetEnumerator() | % {
                Write-Host "  $($_.Key) -> $($_.Value)" -ForegroundColor DarkCyan
            }
        }
        Remove-Variable PathShimPathBefore, PathVirtLinkAssignedTargets, PathVirtLinkAssignments, PathVirtLinkNextSlot -Scope Script -ErrorAction SilentlyContinue
        Unregister-PathShims
    }
}

# TODO: make configurable (or calculate per winget-apps.json list size)
$script:PathVirtLinkSlotCount = 15
$script:PathVirtLinkRoot = "$env:LOCALAPPDATA\CursorSandbox"
$script:PathVirtLinkDirectories = Initialize-PathShims

Export-ModuleMember -Function Invoke-PathShimRefresh
