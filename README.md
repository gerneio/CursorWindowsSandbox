# Cursor Windows Sandbox

Let agents run with real Windows tooling without handing them your host: Cursor over SSH into an ephemeral [Windows Sandbox](https://learn.microsoft.com/en-us/windows/security/application-security/application-isolation/windows-sandbox/windows-sandbox-overview).

## Intent

Windows Sandbox is disposable by design—each session starts clean and discards state when it closes. That makes it a practical containment boundary for Cursor agents: they get a full Windows environment (installers, shells, package managers) while host impact is limited to what you explicitly share.

This project wires that up for Cursor remote development:

1. Launch a sandbox with a known configuration (`.wsb`).
2. On first logon, install enough inside the sandbox for Cursor to connect (SSH, server bits, package managers, optional apps).
3. Share a host folder into the sandbox and open it in Cursor via SSH remote.

The host-side scripts (`scripts/`) start the sandbox, wait for SSH, map folders, and launch Cursor. The share folder (`share/`) is mounted read-only into the sandbox and holds the logon bootstrap and install scripts that run inside it. The sandbox still has network access and runs elevated inside the VM—so prefer a narrow `-MappedFolder`, and assume anything written there (or fetched over the network into that tree) is in the agent’s reach.

## Prerequisites

On the **host** machine:

- [Windows Sandbox](https://learn.microsoft.com/en-us/windows/security/application-security/application-isolation/windows-sandbox/windows-sandbox-overview) enabled (optional feature)
- [Cursor](https://cursor.com) installed, with the `cursor` CLI on `PATH`
- The Windows Sandbox `wsb` CLI on `PATH` (included with recent Sandbox releases)
- Networking available to the sandbox (bootstrap downloads WinGet, Terminal, Cursor server, etc.)
- OpenSSH client (`ssh-keygen`) — present by default on modern Windows
- [PowerShell 7+](https://learn.microsoft.com/en-us/powershell/scripting/install/installing-powershell-on-windows) (`pwsh`) — preferred

## Usage

### Install

Recommended (registers the Explorer context menu; UAC prompt):

```powershell
irm https://raw.githubusercontent.com/gerneio/CursorWindowsSandbox/main/install.ps1 | iex; Install-CursorWindowsSandbox -RegisterContextMenu
```

Force re-install:

```powershell
irm https://raw.githubusercontent.com/gerneio/CursorWindowsSandbox/main/install.ps1 | iex; Install-CursorWindowsSandbox -RegisterContextMenu -Force
```

Optional arguments:

- `-RegisterContextMenu` — register “Open with Cursor Sandbox” on folders in Explorer (UAC prompt)
- `-Force` — overwrite the install folder if it already exists (otherwise the installer fails early)
- `-InstallPath 'D:\tools\CursorWindowsSandbox'` — destination (default: `%USERPROFILE%\source\repos\CursorWindowsSandbox`)

Or clone instead:

```powershell
git clone https://github.com/gerneio/CursorWindowsSandbox.git
cd CursorWindowsSandbox
# optional: .\scripts\Create-CursorSandboxWindowsContextMenu.ps1  (elevated)
```



### Launch

If you registered the Explorer context menu, right-click a folder (or empty space in a folder) and choose **Open with Cursor Sandbox**.

Or run the start script from this repo (or pass an absolute path):

```powershell
.\scripts\Start-CursorSandbox.ps1 -MappedFolder 'C:\path\to\project'
# omit -MappedFolder to use the current directory
```

Either path starts the sandbox if needed, waits for SSH, shares the folder, and opens Cursor remotely. Do not open the `.wsb` file directly.

First boot installs WinGet, SSH, Terminal, the Cursor server, and anything in `winget-apps.json`—expect several minutes. Later runs reuse the package cache when possible.

### Folder mappings


| Host                         | Sandbox                                                                                                              |
| ---------------------------- | -------------------------------------------------------------------------------------------------------------------- |
| Repo `share/`                | `C:\Users\WDAGUtilityAccount\.sandbox` (read-only bootstrap)                                                         |
| `%TEMP%\SandboxPackageCache` | `C:\PackageCache` (download cache)                                                                                   |
| `-MappedFolder`              | `C:\Users\WDAGUtilityAccount\source\repos\<folder-name>` (**writable**—treat this as the agent’s host write surface) |




### Sessions

Running the start script again with a different folder opens another Cursor window, but reuses the **same** Windows Sandbox session. Closing Cursor does not close the sandbox; closing Windows Sandbox discards that session’s installs, tools, and other agent side effects.

The start script maintains a `windows-sandbox` host entry in your user `~/.ssh/config` and updates its `HostName` to the sandbox’s current IP on each launch (sandbox addresses change between sessions).

### Cursor / VS Code task

To open the current workspace over the sandbox from inside an editor, add a `tasks.json` (adjust the script path):

<details>
<summary>Example <code>tasks.json</code></summary>

```json
{
  "version": "2.0.0",
  "tasks": [
    {
        "label": "Pivot to Windows Sandbox",
        "dependsOrder": "sequence",
        "dependsOn": [
            "Launch Sandbox",
            "Close Local Window"
        ],
        "problemMatcher": []
    },
    {
        "label": "Launch Sandbox",
        "type": "shell",
        "command": "pwsh.exe",
        "args": [
            "-ExecutionPolicy", "Bypass",
            "-File", "C:\\path\\to\\CursorWindowsSandbox\\scripts\\Start-CursorSandbox.ps1",
            "-MappedFolder", "${workspaceFolder}"
        ],
        "problemMatcher": [],
        "presentation": {
            "reveal": "always",
            "focus": true,
            "panel": "new",
            "close": false
        },
        "hide": true
    },
    {
        "label": "Close Local Window",
        "type": "process",
        "command": "${command:workbench.action.closeWindow}",
        "problemMatcher": [],
        "hide": true
    }
  ]
}
```

</details>

If the sandbox is already up and the folder is mapped, you can instead open with our start/context script, or use:

```text
cursor --folder-uri vscode-remote://ssh-remote+windows-sandbox/C:/Users/WDAGUtilityAccount/source/repos/${workspaceFolderBasename}
```



## Configuration

### `wsb/Windows Sandbox Cursor.wsb`

[Sandbox configuration](https://learn.microsoft.com/en-us/windows/security/application-security/application-isolation/windows-sandbox/windows-sandbox-configure-using-wsb-file) template (adjust as desired).

### `share/winget-apps.json`

Optional WinGet [import](https://learn.microsoft.com/en-us/windows/package-manager/winget/import) list installed after the core bootstrap. Edit `Packages` (or regenerate with `winget export -o winget-apps.json`) to preinstall tooling—for example the default includes `Microsoft.DotNet.SDK.10`. Delete or empty the file if you want no extra packages.

### Always installed (scripted)

`share/Install-Cursor.ps1` always installs `Microsoft.PowerShell` and `Microsoft.OpenSSH.Preview` via WinGet so SSH remoting works. Change that list only if you know you still have a working SSH server path.

### Host launch script (`scripts/Start-CursorSandbox.ps1`)

`-MappedFolder` is the host folder shared into the sandbox and opened in Cursor (defaults to the current directory)—prefer a project directory you intend the agent to touch, not a broad path like your user profile. SSH keys are created under `.ssh/` (private) and `share/.ssh-host/` (public, read by the sandbox) the first time you launch if missing (`Create-SSHKeys.ps1`).

### Explorer context menu (`scripts/Create-CursorSandboxWindowsContextMenu.ps1`)

Optional: register “Open with Cursor Sandbox” on folders in Explorer. Prefer `Install-CursorWindowsSandbox -RegisterContextMenu`, or run this script elevated after a clone.

## Faster workflows

Some scripts that run inside the sandbox exist mainly to cut friction and wait time—not to install “nice to have” software for its own sake. Examples:

- Renaming `catroot2` on startup to avoid a long PowerShell delay
- Disabling Smart App Control so MSI/app installs are not painfully slow ([microsoft/Windows-Sandbox#68](https://github.com/microsoft/Windows-Sandbox/issues/68#issuecomment-2684406010))
- Caching packages under `%TEMP%\SandboxPackageCache` (a [mapped folder](https://learn.microsoft.com/en-us/windows/security/application-security/application-isolation/windows-sandbox/windows-sandbox-configure-using-wsb-file#mapped-folders) into `C:\PackageCache`) so later sandbox runs reuse downloaded assets
- Installing WinGet via the fast GitHub MSIX path instead of `Repair-WinGetPackageManager` ([microsoft/Windows-Sandbox#62](https://github.com/microsoft/Windows-Sandbox/issues/62#issuecomment-2675894311)), then Terminal and the Cursor server in sequence so remote Cursor is ready sooner

Treat those steps as workflow optimization for a short-lived containment environment, not as a general Windows setup guide.