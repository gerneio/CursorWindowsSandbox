param([string]$Commit)

# Copied from %temp% on host during ssh remote connect

"Configuring Cursor Server on Remote"
$TMP_DIR = "$env:TEMP\$([System.IO.Path]::GetRandomFileName())"
$ProgressPreference = "SilentlyContinue"

# $DISTRO_COMMIT = "23b9fb205fe595ea2be29da7214e19762d037fc0"
$DISTRO_COMMIT = "3f21b08f0b436a07be29fbfe00b304fa15553350"
if ($Commit) { $DISTRO_COMMIT = $Commit }

$PORT_RANGE = ""
$SERVER_APP_NAME = "cursor-server"
$SERVER_INITIAL_EXTENSIONS = ""
$SERVER_DATA_DIR = "$(Resolve-Path ~)\.cursor-server"
"Server data directory: $SERVER_DATA_DIR"

$env:VSCODE_AGENT_FOLDER = "$SERVER_DATA_DIR"
$env:VSCODE_SERVER_SHUTDOWN_TIMEOUT = "300"

$SERVER_DIR =
$SERVER_NODE_EXECUTABLE =
$SERVER_SCRIPT =
$S_LOG = "$SERVER_DATA_DIR\.$DISTRO_COMMIT.log"
$S_PID = "$SERVER_DATA_DIR\.$DISTRO_COMMIT.pid"
$S_TOKEN = "$SERVER_DATA_DIR\.$DISTRO_COMMIT.token"
$SERVER_ARCH =
$SERVER_CONNECTION_TOKEN =
$SERVER_DOWNLOAD_URL =
$SERVER_PID =
$LISTENING_ON =
$OS_RELEASE_ID =
$OS_VERSION =
$KERNEL_VERSION =
$ARCH =
$PLATFORM = "win32"
$SCRIPT_ID = "3a7a54eea581d59fe4addf9c"
function printResults($code, $error, $fatal) {
    "${SCRIPT_ID}: start"
    "exitCode==$code=="
    "errorMessage==$error=="
    "isFatalError==$fatal=="
    "codeListeningOn==$LISTENING_ON=="
    "codeConnectionToken==$SERVER_CONNECTION_TOKEN=="
    "nodeExecutable==$SERVER_NODE_EXECUTABLE=="
    "detectedPlatform==$PLATFORM=="
    "arch==$SERVER_ARCH=="
    "osVersion==$OS_VERSION=="
    "kernelVersion==$KERNEL_VERSION=="
    "SSH_AUTH_SOCK==$SSH_AUTH_SOCK=="
    "DISPLAY==$DISPLAY=="
    "${SCRIPT_ID}: end"
    if ($code -eq 0) {
        "!!! Closing this terminal will terminate the connection and disconnect Cursor from the remote server."
    }

}

function exitClean($code, $error, $fatal) {
    printResults $code $error $fatal
    exit $code
}

if ($false -or $false) {
    "Killing Cursor servers"
    Get-Process node -ErrorAction SilentlyContinue | Where-Object Path -Like "$SERVER_DATA_DIR\bin\*" | Stop-Process -Force
}

if ($false) {
    "Removing all existing Cursor installations"
    "__CURSOR_LOCK_PREEMPT__ component=remote-ssh reason=forceReinstall lock_file=$SERVER_DATA_DIR/.installation_lock"
    Remove-Item -Path "$SERVER_DATA_DIR/bin", "$SERVER_DATA_DIR/*.log", "$SERVER_DATA_DIR/*.token", "$SERVER_DATA_DIR/.installation_lock" -Recurse -Force -ErrorAction SilentlyContinue
}

function acquireLock() {
    $lockFilePath = (Join-Path "$SERVER_DIR" "cursor-remote.lock")
    try {
        $null = ni $lockFilePath -it f -ea si
    }
    catch {
        exitClean 1 "Error creating lock file: $($_.ToString())" "false"
    }

    for ($I = 1; $I -le 120; $I++) {
        try {
            "Acquiring lock $lockFilePath"
            $global:lockFile = [System.io.File]::Open($lockFilePath, 'Open', 'Read', 'None')
            break
        }
        catch {
            "Install in progress - $($_.ToString())"
            sleep -Milliseconds 1000
        }

    }

    if ($I -le 120) {
        "Lock acquired"
    }
    else {
        exitClean 1 "Error could not acquire lock after 120 attempts" "false"
    }

}


$downloadUrl =
$ARCH = $env:PROCESSOR_ARCHITECTURE
if ($ARCH -eq "AMD64") {
    $SERVER_ARCH = "x64"
    $downloadUrl = "https://cursor.blob.core.windows.net/remote-releases/$DISTRO_COMMIT/vscode-reh-win32-x64.tar.gz"
}
elseif ($ARCH -eq "ARM64") {
    $SERVER_ARCH = "arm64"
    $downloadUrl = "https://cursor.blob.core.windows.net/remote-releases/$DISTRO_COMMIT/vscode-reh-win32-arm64.tar.gz"
}
else {
    exitClean 1 "Error architecture not supported: $ARCH" "true"
}

try {
    $OS_VERSION = [System.Environment]::OSVersion.VersionString
    $KERNEL_VERSION = [System.Environment]::OSVersion.Version.ToString()
}
catch {
}


$SERVER_DIR = "$SERVER_DATA_DIR\bin\$PLATFORM-$SERVER_ARCH\$DISTRO_COMMIT"
$SERVER_NODE_EXECUTABLE = "$SERVER_DIR\node.exe"
$SERVER_SCRIPT = "$SERVER_DIR\bin\$SERVER_APP_NAME.cmd"
$env:PATH = "$SERVER_DIR\bin\remote-cli;$env:PATH"

$serverDataDirExists = Test-Path $SERVER_DATA_DIR
$serverDataDirIsDirectory = Test-Path $SERVER_DATA_DIR -PathType Container
if ($serverDataDirExists -and (-not $serverDataDirIsDirectory)) {
    $backupPath = "$SERVER_DATA_DIR.backup.$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds()).$([System.Guid]::NewGuid().ToString('N'))"
    "Server data directory path conflict: $SERVER_DATA_DIR exists and is not a directory. Moving to $backupPath"
    try {
        Move-Item -Path $SERVER_DATA_DIR -Destination $backupPath -Force -ErrorAction Stop
    }
    catch {
        exitClean 1 "Server data directory path conflict: $SERVER_DATA_DIR exists and is not a directory. Failed to move it to backup path $backupPath. Please move or remove the conflicting path and retry." "false"
    }

}


if (Test-Path "$SERVER_DATA_DIR\bin") {
    Get-ChildItem "$SERVER_DATA_DIR\bin" -Directory | ForEach-Object {
        $dirName = $_.Name
        $dirPath = $_.FullName

        if ($dirName -match "^(linux|darwin|win32|alpine)-(x64|arm64)$") {
            $commits = Get-ChildItem $dirPath -Directory | Sort-Object LastWriteTime -Descending | Select-Object -Skip 5
            foreach ($commit in $commits) {
                $isRunning = Get-Process node -ErrorAction SilentlyContinue | Where-Object Path -Like "$($commit.FullName)\*"
                if (-not $isRunning -and $commit.Name -ne $DISTRO_COMMIT) {
                    "Cleaning up stale build $($commit.Name) in $dirPath"
                    Remove-Item -Path $commit.FullName -Recurse -Force -ErrorAction SilentlyContinue
                    Remove-Item -Path "$SERVER_DATA_DIR.$($commit.Name).*" -Force -ErrorAction SilentlyContinue
                }

            }

        }
        else {
            $isRunning = Get-Process node -ErrorAction SilentlyContinue | Where-Object Path -Like "$dirPath\*"
            if (-not $isRunning -and $dirName -ne $DISTRO_COMMIT) {
                "Cleaning up old-style stale build $dirName"
                Remove-Item -Path $dirPath -Recurse -Force -ErrorAction SilentlyContinue
                Remove-Item -Path "$SERVER_DATA_DIR.$dirName.*" -Force -ErrorAction SilentlyContinue
            }

        }

    }

}

if (!(Test-Path $SERVER_DIR)) {
    try {
        ni -it d $SERVER_DIR -f -ea si
    }
    catch {
        exitClean 1 "Error creating server install directory: $($_.ToString())" "false"
    }

    if (!(Test-Path $SERVER_DIR)) {
        exitClean 1 "Error creating server install directory $SERVER_DIR" "false"
    }

}

cd $SERVER_DIR
acquireLock
try {
    if (!(Test-Path $SERVER_SCRIPT)) {
        if (Test-Path "cursor-server.tar.gz") {
            try {
                Remove-Item "cursor-server.tar.gz" -Force -ErrorAction Stop
            }
            catch {
                exitClean 1 "Failed to remove stale archive cursor-server.tar.gz before install: $($_.Exception.Message)" "false"
            }

        }

        $SCP_SERVER_PATH = "$(Resolve-Path ~)\.cursor-server\cursor-server-1ca24588-395b-46bb-bcd0-26c1d2546326.tar.gz"
        if (Test-Path "$SCP_SERVER_PATH") {
            "Using server from $SCP_SERVER_PATH"
            Move-Item "$SCP_SERVER_PATH" "cursor-server.tar.gz"
        }
        else {
            if ($false -eq $true) {
                exitClean 1 "Download failed: Failed to copy server from local client" "true"
            }

            "Downloading from $downloadUrl"
            $REQUEST_ARGUMENTS = @{
                Uri             = "$downloadUrl"
                TimeoutSec      = 20
                OutFile         = "cursor-server.tar.gz" # TODO: archive in C:\PackageCache
                UseBasicParsing = $True
            }

            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            try {
                Invoke-RestMethod @REQUEST_ARGUMENTS
            }
            catch {
                exitClean 1 "Download failed: $($_.ToString())" "false"
            }

        }

        if (Test-Path "cursor-server.tar.gz") {
            "Extracting server contents from cursor-server.tar.gz"
            $extractJob = Start-Job -ScriptBlock {
                param($archivePath, $workingDirectory)
                Set-Location $workingDirectory
                tar -xf $archivePath --strip-components 1
                if ($LASTEXITCODE -ne 0) {
                    throw "Tar failed to extract server contents from $archivePath"
                }

            } -ArgumentList "cursor-server.tar.gz", "$SERVER_DIR"
            while ($extractJob.State -eq "Running") {
                Start-Sleep -Seconds 10
                if ($extractJob.State -eq "Running") {
                    "Extracting..."
                }

            }

            $extractFailed = $false
            try {
                Receive-Job $extractJob -ErrorAction Stop | Out-Null
            }
            catch {
                $extractFailed = $true
            }
            finally {
                Remove-Job $extractJob -Force -ErrorAction SilentlyContinue
            }

            if ($extractFailed) {
                exitClean 1 "Tar failed to extract server contents from cursor-server.tar.gz" "false"
            }

            if (Test-Path "cursor-server.tar.gz") {
                try {
                    Remove-Item "cursor-server.tar.gz" -Force -ErrorAction Stop
                }
                catch {
                    "Warning: Failed to remove archive cursor-server.tar.gz after extraction: $($_.Exception.Message)"
                }

            }

        }

        if (!(Test-Path $SERVER_SCRIPT)) {
            exitClean 1 "Failed to extract code server script: $SERVER_SCRIPT" "false"
        }

    }

    else {
        "Server already installed: $SERVER_SCRIPT"
    }

    exitClean 0 "Server installed, but not started" "false"

    if (Get-Process node -ErrorAction SilentlyContinue | Where-Object Path -Like "$SERVER_DIR\*") {
        "Server already running $SERVER_SCRIPT"
    }

    else {
        "Starting server $SERVER_SCRIPT"
        if (Test-Path $S_LOG) {
            del $S_LOG
        }

        if (Test-Path $S_PID) {
            del $S_PID
        }

        if (Test-Path $S_TOKEN) {
            del $S_TOKEN
        }

        $SERVER_CONNECTION_TOKEN = "02920437-5ac8-4f44-a19d-d5e32b6eaab2"
        [System.IO.File]::WriteAllLines($S_TOKEN, $SERVER_CONNECTION_TOKEN)

        if ([string]::IsNullOrEmpty($PORT_RANGE)) {
            $SERVER_PORT = 0
        }
        else {
            $SERVER_PORT = $PORT_RANGE
        }

        $ARGS = "--start-server --host=127.0.0.1 --port=$SERVER_PORT $SERVER_INITIAL_EXTENSIONS --connection-token-file `"$S_TOKEN`" --telemetry-level off --enable-remote-auto-shutdown --accept-server-license-terms"
        $S_CMD = "& `"$SERVER_SCRIPT`" $ARGS *> `"$S_LOG`""
        $ENCODED_COMMAND = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($S_CMD))
        $START_ARGUMENTS = @{
            FilePath     = "powershell.exe"
            WindowStyle  = "hidden"
            ArgumentList = @(
                "-ExecutionPolicy", "Unrestricted", "-NoLogo", "-NoProfile", "-NonInteractive", "-EncodedCommand", $ENCODED_COMMAND
            )
            PassThru     = $True
        }

        $SERVER_ID = (start @START_ARGUMENTS).ID
        if ($SERVER_ID) {
            [System.IO.File]::WriteAllLines($S_PID, $SERVER_ID)
        }

    }

    if (Test-Path $S_TOKEN) {
        $SERVER_CONNECTION_TOKEN = "$(cat $S_TOKEN)"
    }

    else {
        exitClean 1 "Server token file not found $S_TOKEN" "false"
    }

    sleep -Milliseconds 500
    $SELECT_ARGUMENTS = @{
        Path    = $S_LOG
        Pattern = "Extension host agent listening on (\d+)"
    }

    for ($I = 1; $I -le 40; $I++) {
        "Checking $S_LOG for port"
        if (Test-Path $S_LOG) {
            $GROUPS = (Select-String @SELECT_ARGUMENTS).Matches.Groups
            if ($GROUPS) {
                $LISTENING_ON = $GROUPS[1].Value
                "Listening on port: $LISTENING_ON"
                break
            }

        }

        sleep -Milliseconds 500
    }

}
finally {
    $lockFile.Close()
}

if (!$LISTENING_ON) {
    exitClean 1 "Error server did not start successfully. Could not extract server port from log file $S_LOG" "false"
}

if (!(Test-Path $S_LOG)) {
    exitClean 1 "Error server log file not found $S_LOG" "false"
}

if (Test-Path $S_PID) {
    $SERVER_PID = "$(cat $S_PID)"
}

if (!$SERVER_PID) {
    exitClean 1 "Error server pid file not found $S_PID" "false"
}

printResults 0 "" "false"
while ($True) {
    if (!(gps -Id $SERVER_PID)) {
        "server died, exit"
        exit 0
    }

    sleep 30
}


