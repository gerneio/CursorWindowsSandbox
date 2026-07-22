# Cursor Windows Sandbox

Let agents run with real Windows tooling without handing them your host: Cursor over SSH into an ephemeral [Windows Sandbox](https://learn.microsoft.com/en-us/windows/security/application-security/application-isolation/windows-sandbox/windows-sandbox-overview).

## Intent

Windows Sandbox is disposable by design—each session starts clean and discards state when it closes. That makes it a practical containment boundary for Cursor agents: they get a full Windows environment (installers, shells, package managers) while host impact is limited to what you explicitly share.

This project wires that up for Cursor remote development:

1. Launch a sandbox with a known configuration (`.wsb`).
2. On first logon, install enough inside the sandbox for Cursor to connect (SSH, server bits, package managers, optional apps).
3. Share one or more host folders into the sandbox and open the primary folder in Cursor via SSH remote.

The host-side scripts (`scripts/`) start the sandbox, wait for SSH, map folders, and launch Cursor. The share folder (`share/`) is mounted read-only into the sandbox and holds the logon bootstrap and install scripts that run inside it. The sandbox still has network access and runs elevated inside the VM—so prefer a narrow `-MappedFolder`, and assume anything written there (or fetched over the network into that tree) is in the agent’s reach.

## Prerequisites

On the **host** machine:

- [Windows Sandbox](https://learn.microsoft.com/en-us/windows/security/application-security/application-isolation/windows-sandbox/windows-sandbox-overview) enabled (optional feature)
- [Cursor](https://cursor.com) installed, with the `cursor` CLI on `PATH`
- The Windows Sandbox `wsb` CLI on `PATH` (included with recent Sandbox releases)
- Networking available to the sandbox (bootstrap downloads WinGet, Terminal, Cursor server, etc.)
- OpenSSH client (`ssh-keygen`) — present by default on modern Windows
- [PowerShell 7+](https://learn.microsoft.com/en-us/powershell/scripting/install/installing-powershell-on-windows) (`pwsh`)

## Usage

### Install

Pick a path: **quick install** (`irm | iex`) or **clone** (reviewable, no remote execute).

#### Quick install

> [!WARNING]
> Downloads a script from the internet and runs it in your current PowerShell session (`irm … | iex`). Only do this if you trust the source. Prefer reviewing [`install.ps1`](https://github.com/gerneio/CursorWindowsSandbox/blob/main/install.ps1) first, or use the clone path below.

```powershell
irm https://raw.githubusercontent.com/gerneio/CursorWindowsSandbox/main/install.ps1 | iex; Install-CursorWindowsSandbox -RegisterContextMenu
```

Optional arguments:

- `-RegisterContextMenu` — register “Open with Cursor Sandbox” on folders in Explorer
- `-Force` — overwrite the install folder if it already exists, and skip the install-path confirmation prompt when `-InstallPath` was not passed
- `-InstallPath 'D:\tools\CursorWindowsSandbox'` — destination (default: `%USERPROFILE%\source\repos\CursorWindowsSandbox`; prompted to confirm if omitted and `-Force` is not set)

#### Clone

```powershell
git clone https://github.com/gerneio/CursorWindowsSandbox.git
cd CursorWindowsSandbox
```

Optionally run `.\scripts\Create-CursorSandboxWindowsContextMenu.ps1` for the Explorer entry.

<details>
<summary>Test <code>install.ps1</code> locally</summary>

Same flow as the remote one-liner, without fetching from GitHub:

```powershell
Get-Content .\install.ps1 -Raw | iex; Install-CursorWindowsSandbox -RegisterContextMenu
```

</details>

> [!WARNING]
> If PowerShell blocks scripts, adjust execution policy for your user (for example `RemoteSigned` after a clone), or run a single script with `-ExecutionPolicy Bypass`. Files from the zip/`irm` install may also carry Mark of the Web—unblock them if needed (`Unblock-File`) rather than setting a permanent Bypass policy.

### Launch

> [!WARNING]
> On the first connection, Cursor may ask for the remote operating system. Select **Windows**; Cursor will remember the choice for subsequent runs.

If you registered the Explorer context menu, right-click a folder (or empty space in a folder) and choose **Open with Cursor Sandbox**.

Or run the start script from this repo (or pass an absolute path):

```powershell
.\scripts\Start-CursorSandbox.ps1 -MappedFolder 'C:\path\to\project'
# omit -MappedFolder to use the current directory
# add -SkipIDELaunch to prepare the sandbox without opening Cursor
```

Both methods launch or reuse the sandbox, wait for SSH, map the requested folder, and open it in Cursor remotely (unless you pass `-SkipIDELaunch`).

First boot installs WinGet, SSH, Terminal, the Cursor server, and anything in `winget-apps.json` / `cursor-extensions.json` onto the sandbox—expect several minutes before your local Cursor IDE is opened with the remote target folder. Later runs reuse the package cache when possible.

> [!WARNING]
> Always launch through the script or context menu. The `.wsb` file is a template used by the launch scripts; opening it directly skips required setup, so the sandbox will fail to start.

### Folder mappings


| Host                         | Sandbox                                                                                                              |
| ---------------------------- | -------------------------------------------------------------------------------------------------------------------- |
| Repo `share/`                | `C:\Users\WDAGUtilityAccount\.sandbox` (read-only bootstrap)                                                         |
| `%TEMP%\SandboxPackageCache` | `C:\PackageCache` (download cache)                                                                                   |
| `-MappedFolder`              | `C:\host\<folder-name>` by default (**writable**); customize root via [Hosting config](#hosting-config-sandboxconfigjson) |
| Extra folders from config    | Same sandbox root tree; **read-only** unless `"writable": true`                                                      |


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
cursor --folder-uri vscode-remote://ssh-remote+windows-sandbox/C:/host/${workspaceFolderBasename}
```



## Configuration

### Hosting config (`.sandbox/config.json`)

Optional launch settings for [`Start-CursorSandbox.ps1`](scripts/Start-CursorSandbox.ps1), read from the CursorWindowsSandbox install root:

`<install>/.sandbox/config.json`

<details>
<summary>Example <code>config.json</code>: schema and layout</summary>

```json
{
  "global": {
    "sandboxRootFolder": "C:\\shared"
  },
  "%USERPROFILE%\\source\\repos\\MyApp": {
    "sandboxRootFolder": "C:\\Users\\WDAGUtilityAccount\\source\\repos",
    "folderMappings": [
      { "path": "..\\SharedLib" },
      { "path": "%USERPROFILE%\\source\\tools\\build", "writable": true }
    ]
  }
}
```

| Field | Where | Meaning |
| ----- | ----- | ------- |
| Top-level path keys | Root of the file | Match `-MappedFolder` after `%VAR%` expansion and full-path normalize (case-insensitive). Non-path keys such as `global` are ignored as project entries. |
| `folderMappings` | Per project | Extra host folders to share. `path` may be relative to `-MappedFolder` or absolute; `%VAR%` expansion applies. Omit `writable` → read-only; `"writable": true` → writable. |
| `sandboxRootFolder` | Per project or `global` | Absolute path **inside the sandbox** where shares are rooted (no host env expansion). Per-project overrides `global`; if neither is set, the start script default is `C:\host`. |

Missing file or no matching project key → primary `-MappedFolder` only (previous behavior).

With no extra folders, the primary mapped folder uses a leaf-name path under the sandbox root (`C:\host\<folder-name>` by default). When `folderMappings` are configured, shares are placed under a common-ancestor layout so relative paths between those folders still work inside the sandbox (the ancestor itself is not shared wholesale; calculated on best-effort basis).

Example: `-MappedFolder` `C:\Users\you\source\repos\MyApp` with `folderMappings` path `..\SharedLib` →

| Host | Sandbox (default root `C:\host`) |
| ---- | -------------------------------- |
| `C:\Users\you\source\repos\MyApp` | `C:\host\repos\MyApp` |
| `C:\Users\you\source\repos\SharedLib` | `C:\host\repos\SharedLib` |

Common ancestor is `..\source\repos`; only those two folders are shared, not the whole `repos` tree.

</details>

### `wsb/Windows Sandbox Cursor.wsb`

[Sandbox configuration](https://learn.microsoft.com/en-us/windows/security/application-security/application-isolation/windows-sandbox/windows-sandbox-configure-using-wsb-file) template (adjust as desired).

### `share/winget-apps.json`

Optional WinGet [import](https://learn.microsoft.com/en-us/windows/package-manager/winget/import) list installed after the core bootstrap. Edit `Packages` (or regenerate with `winget export -o winget-apps.json`) to preinstall tooling—for example the default includes `Microsoft.DotNet.SDK.10`. Delete or empty the file if you want no extra packages.

> [!NOTE]
> During bootstrap, newly installed commands are temporarily re-exposed through `%LOCALAPPDATA%\CursorSandbox\VirtLink#` on `PATH` as directory junction links, so the current remote cursor session can resolve these new packages/tools without a full restart. Those entries are removed from persisted `PATH` when the WinGet import finishes, however an already-running Cursor server will still keep its original environment until retarted. After packages install (or if a tool is missing in the remote IDE), manually run `Remote-SSH: Kill Remote Server on Host` from the Command Palette (`F1`) and reconnect so the remote cursor server picks up the updated Machine/User `PATH`. See [Remote Development troubleshooting](https://code.visualstudio.com/docs/remote/troubleshooting).

### `share/cursor-extensions.json`

Optional JSON array of Cursor/VS Code extensions installed into the sandbox Cursor server after it is downloaded. Each entry is either an extension id (`publisher.name`) or an absolute URL to a `.vsix`. Omit or delete the file to skip extension install.

<details>
<summary>Example <code>cursor-extensions.json</code></summary>

```json
[
	"anysphere.csharp",
	"https://marketplace.visualstudio.com/_apis/public/gallery/publishers/ms-dotnettools/vsextensions/csharp/2.140.9/vspackage?targetPlatform=win32-x64"
]
```

</details>

### `share/LayoutModification.xml`

Customizable taskbar layout template used by [`Set-WinTaskbarPin`](share/Helpers.psm1#L10-L25). See [Customize the Windows 11 taskbar](https://learn.microsoft.com/en-us/windows-hardware/customize/desktop/customize-the-windows-11-taskbar) for advanced configuration.

### Always installed (scripted)

`share/Install-Cursor.ps1` always installs `Microsoft.PowerShell` and `Microsoft.OpenSSH.Preview` via WinGet so SSH remoting works. Change that list only if you know you still have a working SSH server path.

### Host launch script (`scripts/Start-CursorSandbox.ps1`)

`-MappedFolder` is the host folder shared into the sandbox and opened in Cursor (defaults to the current directory)—prefer a project directory you intend the agent to touch, not a broad path like your user profile. Additional folders and the in-sandbox root can be configured via [`.sandbox/config.json`](#hosting-config-sandboxconfigjson). `-SkipIDELaunch` starts or reuses the sandbox, mounts folders, and updates SSH config without waiting for SSH or opening Cursor. SSH keys are created under `.ssh/` (private) and `share/.ssh-host/` (public, read by the sandbox) the first time you launch if missing (`Create-SSHKeys.ps1`).

### Explorer context menu (`scripts/Create-CursorSandboxWindowsContextMenu.ps1`)

Optional: register “Open with Cursor Sandbox” on folders in Explorer. Prefer `Install-CursorWindowsSandbox -RegisterContextMenu`, or run this script after a clone.

## Faster workflows

Some scripts that run inside the sandbox exist mainly to cut friction and wait time—not to install “nice to have” software for its own sake. Examples:

- Renaming `catroot2` on startup to avoid a long PowerShell delay
- Disabling Smart App Control so MSI/app installs are not painfully slow ([microsoft/Windows-Sandbox#68](https://github.com/microsoft/Windows-Sandbox/issues/68#issuecomment-2684406010))
- Caching packages under `%TEMP%\SandboxPackageCache` (a [mapped folder](https://learn.microsoft.com/en-us/windows/security/application-security/application-isolation/windows-sandbox/windows-sandbox-configure-using-wsb-file#mapped-folders) into `C:\PackageCache`) so later sandbox runs reuse downloaded assets
- Installing WinGet via the fast GitHub MSIX path instead of `Repair-WinGetPackageManager` ([microsoft/Windows-Sandbox#62](https://github.com/microsoft/Windows-Sandbox/issues/62#issuecomment-2675894311)), then Terminal and the Cursor server in sequence so remote Cursor is ready sooner

Treat those steps as workflow optimization for a short-lived containment environment, not as a general Windows setup guide.