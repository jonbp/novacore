<#
    Novacore's icon in the Windows notification area, for when Novacore runs
    in WSL. It's the Windows counterpart of the Plasma widget in tray/plasmoid/:
    it shows whether the stack is running, lists the sites, and starts, stops
    and switches PHP versions by running the novacore CLI through wsl.exe.

    A left click opens a panel in the style of Windows 11's own flyouts, and a
    right click the same items as a menu.

    It draws what the CLI describes: `novacore tray menu` gives the menu as
    JSON, with each item's action and the dialogs to show, as it does for the
    macOS menu bar icon in tray/macos/. So new features belong in the CLI, not
    here. See tray/PROTOCOL.md.

    `novacore tray install`, run inside WSL, copies this script to
    %LOCALAPPDATA%\Novacore and starts it from a shortcut in the Startup folder.
    From then on it keeps that copy up to date with the repo (Update-Self).
    The file is kept ASCII-only, as Windows PowerShell 5.1 reads scripts
    without a BOM as ANSI.
#>
param(
    # The WSL distro Novacore lives in, e.g. Ubuntu.
    [Parameter(Mandatory = $true)] [string] $Distro,
    # The absolute path of the novacore CLI inside the distro.
    [Parameter(Mandatory = $true)] [string] $Command,
    [int] $RefreshInterval = 30,
    # Set when an older version restarts into this one.
    [switch] $Updated
)

$ErrorActionPreference = 'Stop'

# One tray icon at a time.
$created = $false
$script:mutex = New-Object System.Threading.Mutex($true, 'Local\NovacoreTray', [ref] $created)
if (-not $created) { exit }

Add-Type -AssemblyName System.Windows.Forms, System.Drawing
Add-Type -Namespace Novacore -Name Native -MemberDefinition '
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("shell32.dll")] public static extern int SetCurrentProcessExplicitAppUserModelID([MarshalAs(UnmanagedType.LPWStr)] string id);
'
# Otherwise Windows scales a 16px icon up, and it's blurry on high-DPI screens.
[void] [Novacore.Native]::SetProcessDPIAware()
[System.Windows.Forms.Application]::EnableVisualStyles()
# Report errors that escape an event handler, rather than showing .NET's
# dialog, which quits the tray icon if you pick Quit. Show-Problem is defined
# later; this only runs once the message loop has started.
[System.Windows.Forms.Application]::SetUnhandledExceptionMode([System.Windows.Forms.UnhandledExceptionMode]::CatchException)
[System.Windows.Forms.Application]::add_ThreadException({ param($sender, $e) Show-Problem $e.Exception })

$g = [System.Drawing.Graphics]::FromHwnd([IntPtr]::Zero)
$script:scale = $g.DpiX / 96
$g.Dispose()

# N pixels at 96 DPI, scaled for this screen.
function S([double] $n) { [int] [Math]::Round($n * $script:scale) }

$Ellipsis = [string] [char] 0x2026  # ellipsis
$MiddleDot = [string] [char] 0xB7  # middle dot

$script:model = $null       # novacore tray menu, parsed
$script:modelJson = ''
$script:form = $null        # the open form dialog's fields
$script:problem = ''        # why novacore status failed
$script:asleep = $false     # the distro isn't running, so we haven't asked
$script:refreshing = $false
$script:polling = $false    # asking how the running command is doing
$script:checkedAction = $false
$script:busy = $false       # an action such as novacore up is running
$script:busyLabel = ''
$script:output = New-Object System.Collections.Generic.List[string]
$script:jobs = New-Object System.Collections.ArrayList
$script:menuSignature = $null
$script:balloonShowsOutput = $false
$script:balloonUrl = ''
$script:lastUpdateCheck = $null
$script:skippedUpdate = ''  # the version of the repo's script that had errors
$script:actionUrl = ''
$script:infoForms = @{}     # open Info windows, by site name
$script:outputForm = $null
$script:outputBox = $null
$script:outputShown = -1
$script:checkedAt = $null   # when novacore last said how it is
$script:unseen = ''         # output you haven't looked at: done or failed
$script:flyout = $null      # the panel a left click opens
$script:flyoutSignature = $null
$script:expanded = ''       # the label of the panel's expanded row

# --- Icon ---------------------------------------------------------------------

# The status icons, like the other tray icons', come from status-icons.png,
# next to this script, copied from tray/ in the repo. tray/build-icons.sh
# renders it from tray/status.svg: the globe from Novacore's link on
# jonbp.co.uk, with a pill whose colour shows the status. The sheet has a 64px
# cell for each theme and status, dark then light, each running, stopped, busy
# then error, with a column per size and the icon in each cell's top left
# corner: 16px for 100% scaling up to 48px for 300%, and 64px.
$script:statusSheet = Join-Path $PSScriptRoot 'status-icons.png'
$StatusSizes = 16, 20, 24, 28, 32, 36, 40, 48, 64
$StatusStates = 'Running', 'Stopped', 'Busy', 'Error'

# The size of the notification area's icons: 16px at 100% scaling, 24px at
# 150% and so on.
$script:iconSize = [System.Windows.Forms.SystemInformation]::SmallIconSize.Width

# Whether the taskbar is light, so the globe should be black. Windows 10 before
# 1903 has no setting, and a dark taskbar.
function Test-LightTaskbar {
    try {
        (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -Name SystemUsesLightTheme -ErrorAction Stop).SystemUsesLightTheme -eq 1
    } catch { $false }
}

# The sheet, read into memory so the file isn't locked and Update-Self can
# replace it. $null without it.
function Read-StatusSheet {
    if (-not (Test-Path -LiteralPath $script:statusSheet)) { return $null }
    $stream = New-Object System.IO.MemoryStream (, [System.IO.File]::ReadAllBytes($script:statusSheet))
    $image = [System.Drawing.Image]::FromStream($stream)
    $sheet = New-Object System.Drawing.Bitmap $image
    $image.Dispose()
    $stream.Dispose()
    $sheet
}

# The icon in ROW of SHEET, at the notification area's size: the image that
# size, or else the next size up, scaled down.
function New-StatusIcon([System.Drawing.Bitmap] $sheet, [int] $row) {
    $size = $script:iconSize
    $col = $StatusSizes.Count - 1
    for ($i = $StatusSizes.Count - 1; $i -ge 0; $i--) {
        if ($StatusSizes[$i] -ge $size) { $col = $i }
    }
    $n = $StatusSizes[$col]
    $from = New-Object System.Drawing.Rectangle ($col * 64), ($row * 64), $n, $n
    $format = [System.Drawing.Imaging.PixelFormat]::Format32bppArgb
    if ($n -eq $size) {
        $bmp = $sheet.Clone($from, $format)
    } else {
        $bmp = New-Object System.Drawing.Bitmap $size, $size, $format
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
        $g.DrawImage($sheet, (New-Object System.Drawing.Rectangle 0, 0, $size, $size), $from, [System.Drawing.GraphicsUnit]::Pixel)
        $g.Dispose()
    }
    $icon = [System.Drawing.Icon]::FromHandle($bmp.GetHicon())
    $bmp.Dispose()
    $icon
}

# Novacore's project icon, for the app itself: its program, notifications
# and windows. It's novacore.ico, next to this script, rendered from
# tray/novacore.svg by tray/build-icons.sh. Each of its images is a PNG.
$script:appIcon = Join-Path $PSScriptRoot 'novacore.ico'

# The PNG bytes of the .ico's image closest to SIZE, at least as big if there
# is one, or $null without the file.
function Get-AppIconPng([int] $size) {
    if (-not (Test-Path -LiteralPath $script:appIcon)) { return $null }
    $bytes = [System.IO.File]::ReadAllBytes($script:appIcon)
    $best = $null
    for ($i = 0; $i -lt [BitConverter]::ToUInt16($bytes, 4); $i++) {
        $entry = 6 + 16 * $i
        $side = if ($bytes[$entry] -eq 0) { 256 } else { [int] $bytes[$entry] }
        $better = (-not $best) -or
            ($best.Side -lt $size -and $side -gt $best.Side) -or
            ($side -ge $size -and $side -lt $best.Side)
        if ($better) {
            $best = @{
                Side   = $side
                Length = [BitConverter]::ToUInt32($bytes, $entry + 8)
                Offset = [BitConverter]::ToUInt32($bytes, $entry + 12)
            }
        }
    }
    , $bytes[$best.Offset..($best.Offset + $best.Length - 1)]
}

# The status icons, redrawn when the taskbar changes between light and dark.
$script:lightTaskbar = $null
function Update-Icons {
    $light = Test-LightTaskbar
    if ($light -eq $script:lightTaskbar) { return $false }
    $script:lightTaskbar = $light
    $old = $script:icons
    $script:icons = @{}
    $sheet = Read-StatusSheet
    for ($i = 0; $i -lt $StatusStates.Count; $i++) {
        $script:icons[$StatusStates[$i]] = if ($sheet) {
            New-StatusIcon $sheet ($(if ($light) { $StatusStates.Count } else { 0 }) + $i)
        } else {
            [System.Drawing.SystemIcons]::Application
        }
    }
    if ($sheet) { $sheet.Dispose() }
    if ($script:notify) { Update-View }
    if ($old) { $old.Values | Where-Object { $_ -ne [System.Drawing.SystemIcons]::Application } | ForEach-Object { $_.Dispose() } }
    $true
}
[void] (Update-Icons)

# For windows' title bars and Alt+Tab: the project icon, at the size of a
# normal icon, which Windows scales down for the title bar.
$script:windowIcon = $null
$png = Get-AppIconPng ([System.Windows.Forms.SystemInformation]::IconSize.Width)
if ($png) {
    $bmp = New-Object System.Drawing.Bitmap (New-Object System.IO.MemoryStream (, $png))
    $script:windowIcon = [System.Drawing.Icon]::FromHandle($bmp.GetHicon())
}

# --- Launcher -----------------------------------------------------------------

# Without these, Windows calls the tray icon "Windows PowerShell": its
# notifications are signed as that, and Task Manager lists it under that name.
#
# Notifications are named after the process's app ID, so the script gives
# itself one and registers it with a name and icon.
#
# Task Manager shows the description inside the program that's running, so
# the installed copy runs in NovacoreTray.exe, a small program that hosts
# PowerShell and runs this script. Windows PowerShell can compile C#, so the
# script builds it the first time it runs, and again when its source below
# changes, then hands over to it. If that fails, it carries on in PowerShell.

$AppName = 'Novacore Tray'
$AppId = 'Novacore.Tray'
$script:appDir = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Novacore'
# Where `novacore tray install` puts this script. Only that copy hands over to
# NovacoreTray.exe and keeps itself up to date, not one run from elsewhere,
# e.g. the repo itself.
$script:installed = $PSCommandPath -eq (Join-Path $script:appDir 'novacore-tray.ps1')

function Get-Hash([string] $path) {
    (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
}

function Register-AppId {
    $key = "HKCU:\Software\Classes\AppUserModelId\$AppId"
    New-Item -Force $key | Out-Null
    Set-ItemProperty $key DisplayName $AppName
    # Notifications want an image file, so save the icon's 64px image. Written
    # every time, so it follows changes to the icon.
    $png = Get-AppIconPng 64
    if ($png) {
        $file = Join-Path $script:appDir 'novacore.png'
        New-Item -ItemType Directory -Force $script:appDir | Out-Null
        [System.IO.File]::WriteAllBytes($file, $png)
        Set-ItemProperty $key IconUri $file
    }
    [void] [Novacore.Native]::SetCurrentProcessExplicitAppUserModelID($AppId)
}

$LauncherSource = @"
using System;
using System.IO;
using System.Management.Automation;
using System.Management.Automation.Runspaces;
using System.Reflection;

[assembly: AssemblyTitle("$AppName")]
[assembly: AssemblyProduct("$AppName")]

// Runs novacore-tray.ps1 from this program's folder, passing on its arguments:
// -Name value, or -Name alone for a switch.
static class NovacoreTray {
    [STAThread]
    static void Main(string[] args) {
        string dir = AppDomain.CurrentDomain.BaseDirectory;
        try {
            InitialSessionState state = InitialSessionState.CreateDefault();
            state.ExecutionPolicy = Microsoft.PowerShell.ExecutionPolicy.Bypass;
            using (Runspace runspace = RunspaceFactory.CreateRunspace(state)) {
                // This thread, as WinForms needs it to be STA.
                runspace.ThreadOptions = PSThreadOptions.UseCurrentThread;
                runspace.Open();
                using (PowerShell ps = PowerShell.Create()) {
                    ps.Runspace = runspace;
                    ps.AddCommand(Path.Combine(dir, "novacore-tray.ps1"));
                    for (int i = 0; i < args.Length; i++) {
                        string name = args[i].TrimStart('-');
                        if (i + 1 < args.Length && !args[i + 1].StartsWith("-")) ps.AddParameter(name, args[++i]);
                        else ps.AddParameter(name);
                    }
                    ps.Invoke();
                    foreach (ErrorRecord error in ps.Streams.Error) Log(dir, error.ToString());
                }
            }
        } catch (Exception e) {
            Log(dir, e.ToString());
        }
    }

    static void Log(string dir, string message) {
        File.AppendAllText(Path.Combine(dir, "tray.log"), DateTime.Now.ToString("s") + " " + message + Environment.NewLine);
    }
}
"@

# Hand over to NovacoreTray.exe, building it first if needed, and point the
# Startup shortcut at it. Returns whether it did, in which case this copy
# should quit.
function Start-Launcher {
    if (-not $script:installed) { return $false }
    if ([System.Diagnostics.Process]::GetCurrentProcess().ProcessName -eq 'NovacoreTray') { return $false }
    $exe = Join-Path $script:appDir 'NovacoreTray.exe'
    $cs = Join-Path $script:appDir 'NovacoreTray.cs'
    # The source, noting the icon's hash, so a new icon rebuilds it too.
    $source = $LauncherSource
    $hasIcon = Test-Path -LiteralPath $script:appIcon
    if ($hasIcon) { $source += "`n// Icon: $(Get-Hash $script:appIcon)`n" }
    $built = (Test-Path -LiteralPath $exe) -and (Test-Path -LiteralPath $cs) -and
        ([System.IO.File]::ReadAllText($cs) -eq $source)
    if (-not $built) {
        # The copy this one is updating from may still be shutting down.
        Get-Process NovacoreTray -ErrorAction SilentlyContinue | Wait-Process -Timeout 10 -ErrorAction SilentlyContinue
        $options = New-Object System.CodeDom.Compiler.CompilerParameters
        $options.GenerateExecutable = $true
        $options.OutputAssembly = $exe
        $options.CompilerOptions = '/target:winexe /optimize'
        if ($hasIcon) { $options.CompilerOptions += " /win32icon:`"$($script:appIcon)`"" }
        foreach ($assembly in 'System.dll', 'System.Core.dll', [PSObject].Assembly.Location) {
            [void] $options.ReferencedAssemblies.Add($assembly)
        }
        $result = (New-Object Microsoft.CSharp.CSharpCodeProvider).CompileAssemblyFromSource($options, $source)
        if ($result.Errors.HasErrors) {
            throw "Couldn't build NovacoreTray.exe: $(@($result.Errors | Where-Object { -not $_.IsWarning })[0])"
        }
        [System.IO.File]::WriteAllText($cs, $source)
    }

    $arguments = "-Distro $(ConvertTo-Arg $Distro) -Command $(ConvertTo-Arg $Command) -RefreshInterval $RefreshInterval"
    $lnk = Join-Path ([Environment]::GetFolderPath('Startup')) 'Novacore.lnk'
    if (Test-Path -LiteralPath $lnk) {
        $shortcut = (New-Object -ComObject WScript.Shell).CreateShortcut($lnk)
        if ($shortcut.TargetPath -ne $exe -or $shortcut.Arguments -ne $arguments) {
            $shortcut.TargetPath = $exe
            $shortcut.Arguments = $arguments
            $shortcut.IconLocation = "$exe,0"
            $shortcut.Save()
        }
    }
    if ($Updated) { $arguments += ' -Updated' }
    $script:mutex.ReleaseMutex()
    $script:mutex.Dispose()
    Start-Process -FilePath $exe -ArgumentList $arguments -WorkingDirectory $script:appDir
    $true
}

# --- Running novacore -------------------------------------------------------

# Quote an argument for a Windows command line.
function ConvertTo-Arg([string] $s) {
    if ($s -and $s -notmatch '[\s"]') { return $s }
    '"' + ($s -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + '"'
}

# ARGUMENTS as one Windows command line.
function Join-Args([string[]] $Arguments) {
    ($Arguments | ForEach-Object { ConvertTo-Arg $_ }) -join ' '
}

# wsl.exe's arguments to run novacore with ARGUMENTS. -e runs it directly,
# not through the user's shell, which might not be a POSIX one.
function Get-NovacoreArgs([string[]] $Arguments) {
    , (@('-d', $Distro, '-e', $Command) + $Arguments)
}

# Start wsl.exe with ARGUMENTS without blocking the UI. Update-Jobs collects
# its output, and calls ONDONE with the job once it exits.
function Start-WslJob([string[]] $Arguments, [scriptblock] $OnDone) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = Join-Path $env:WINDIR 'System32\wsl.exe'
    $psi.Arguments = Join-Args $Arguments
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8
    # wsl.exe's own messages are UTF-16 unless this is set.
    $psi.EnvironmentVariables['WSL_UTF8'] = '1'

    $p = [System.Diagnostics.Process]::Start($psi)
    $job = @{
        Process   = $p
        OnDone    = $OnDone
        Out       = New-Object System.Collections.Generic.List[string]
        Err       = New-Object System.Collections.Generic.List[string]
        All       = New-Object System.Collections.Generic.List[string]
        OutReader = $p.StandardOutput
        ErrReader = $p.StandardError
    }
    $job.OutTask = $job.OutReader.ReadLineAsync()
    $job.ErrTask = $job.ErrReader.ReadLineAsync()
    [void] $script:jobs.Add($job)
    $script:pump.Enabled = $true
    $job
}

# Collect the jobs' output, and finish the jobs that have exited.
function Update-Jobs {
    foreach ($job in @($script:jobs)) {
        $open = $false
        foreach ($stream in 'Out', 'Err') {
            $task = $job["${stream}Task"]
            while ($task -and $task.IsCompleted) {
                $line = $null
                if (-not $task.IsFaulted) { $line = $task.Result }
                if ($null -eq $line) { $task = $null; break }
                $line = $line -replace '\x1b\[[0-9;?]*[A-Za-z]', '' -replace '\r', ''
                $job[$stream].Add($line)
                $job.All.Add($line)
                $task = $job["${stream}Reader"].ReadLineAsync()
            }
            $job["${stream}Task"] = $task
            if ($task) { $open = $true }
        }
        if ($open) { continue }

        $job.Process.WaitForExit()
        $job.ExitCode = $job.Process.ExitCode
        $job.Process.Dispose()
        $script:jobs.Remove($job)
        & $job.OnDone $job
    }
    if ($script:jobs.Count -eq 0) { $script:pump.Enabled = $false }
    Update-OutputWindow
}

# The line that best explains why JOB failed: the first line novacore wrote
# to stderr, where its error messages go, else the first line it wrote at
# all. wsl.exe's own errors, such as a missing distro, come first on stdout,
# followed by a link to WSL's issue tracker.
function Get-JobError($job) {
    $line = @($job.Err | Where-Object { $_.Trim() }) | Select-Object -First 1
    if (-not $line) { $line = @($job.All | Where-Object { $_.Trim() }) | Select-Object -First 1 }
    if (-not $line) { return "novacore exited with code $($job.ExitCode)" }
    ($line -replace '^\W+', '').Trim()
}

# Ask novacore for its status. Unless WAKE is set, this first checks the
# distro is running, as running a command in it would start it again and
# stop WSL from ever shutting down while idle.
function Update-Status([switch] $Wake) {
    if ($script:refreshing -or $script:busy) { return }
    $script:refreshing = $true
    if ($Wake) {
        Request-Status
        return
    }
    [void] (Start-WslJob @('--list', '--running', '--quiet') {
        param($job)
        if (@($job.Out | ForEach-Object { $_.Trim() }) -contains $Distro) {
            Request-Status
        } else {
            $script:refreshing = $false
            $script:asleep = $true
            Update-View
        }
    })
}

function Request-Status {
    [void] (Start-WslJob (Get-NovacoreArgs @('tray', 'menu')) {
        param($job)
        $script:refreshing = $false
        $script:asleep = $false
        if ($job.ExitCode -ne 0) {
            $script:problem = Get-JobError $job
        } else {
            try {
                $json = $job.Out -join "`n"
                $script:model = $json | ConvertFrom-Json
                $script:modelJson = $json
                $script:problem = ''
                $script:checkedAt = Get-Date
                # Once WSL is up, see if a command from before we started is
                # still running, e.g. after a reinstall.
                if (-not $script:checkedAction) {
                    $script:checkedAction = $true
                    Update-Action
                }
            } catch {
                $script:problem = "Couldn't read novacore's output. Is the CLI up to date?"
            }
        }
        Update-View
        Update-Self
    })
}

# Replace this script and its icons with the repo's copies when they have
# changed, e.g. after a git pull, and restart into it. It runs after a
# successful status check, while WSL is up anyway, so reading the repo doesn't
# start WSL. The repo is where the CLI is: <repo>/bin/novacore.
function Update-Self {
    if (-not $script:installed) { return }
    if ($script:lastUpdateCheck -and ((Get-Date) - $script:lastUpdateCheck).TotalSeconds -lt 60) { return }
    # Restarting would close the menu or a dialog in use, so wait for a quiet
    # moment. A running command is fine to leave: it runs on its own in WSL.
    # (The panel stays among the open forms while hidden.)
    if ($script:menu.Visible -or @([System.Windows.Forms.Application]::OpenForms | Where-Object { $_.Visible }).Count) { return }
    $script:lastUpdateCheck = Get-Date

    $source = Get-WindowsPath (($Command -replace '/bin/[^/]+$', '') + '/tray/windows/novacore-tray.ps1')
    if (-not (Test-Path -LiteralPath $source)) { return }
    $new = Get-Hash $source
    $scriptChanged = $new -ne (Get-Hash $PSCommandPath)
    # And the files that come with it: the panel's controls, novacore.ico,
    # which NovacoreTray.exe is built with, and the status icons.
    $files = @(
        @{ From = Join-Path (Split-Path $source) 'novacore-ui.cs'; To = $script:uiSource },
        @{ From = Join-Path (Split-Path $source) 'novacore.ico'; To = $script:appIcon },
        @{ From = Join-Path (Split-Path (Split-Path $source)) 'status-icons.png'; To = $script:statusSheet })
    $changedFiles = @($files | Where-Object {
        (Test-Path -LiteralPath $_.From) -and (
            -not (Test-Path -LiteralPath $_.To) -or (Get-Hash $_.From) -ne (Get-Hash $_.To)) })
    if (-not $scriptChanged -and -not $changedFiles) { return }

    $ui = $files[0].From
    $uiChanged = $changedFiles -contains $files[0]
    $version = "$new|$(if ($uiChanged) { Get-Hash $ui })"
    if ($version -eq $script:skippedUpdate) { return }
    if ($uiChanged) {
        # Don't swap in controls that won't compile either.
        $problem = Test-UiSource $ui
        if ($problem) {
            $script:skippedUpdate = $version
            Show-Problem "Not updating the tray icon: tray/windows/novacore-ui.cs has errors. $problem"
            return
        }
    }
    if ($scriptChanged) {
        # Don't swap in a script that won't run, e.g. one saved mid-edit.
        $errors = $null
        [void] [System.Management.Automation.Language.Parser]::ParseFile($source, [ref] $null, [ref] $errors)
        if ($errors) {
            $script:skippedUpdate = $version
            Show-Problem "Not updating the tray icon: tray/windows/novacore-tray.ps1 has errors. $($errors[0])"
            return
        }
        Copy-Item -LiteralPath $source -Destination $PSCommandPath -Force
    }
    foreach ($file in $changedFiles) { Copy-Item -LiteralPath $file.From -Destination $file.To -Force }
    # Let the new one take the single-instance lock, then hand over to it.
    $script:mutex.ReleaseMutex()
    $script:mutex.Dispose()
    $arguments = "--headless powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden " +
        "-File `"$PSCommandPath`" -Distro `"$Distro`" -Command `"$Command`" -RefreshInterval $RefreshInterval -Updated"
    Start-Process (Join-Path $env:WINDIR 'System32\conhost.exe') -ArgumentList $arguments
    Exit-Tray
}

# The first error in compiling the C# in PATH, or nothing if it compiles. It
# builds to a temporary file, so nothing is loaded into this process.
function Test-UiSource([string] $path) {
    $options = New-Object System.CodeDom.Compiler.CompilerParameters
    $options.GenerateInMemory = $false
    $options.OutputAssembly = [System.IO.Path]::GetTempFileName() + '.dll'
    foreach ($assembly in @('System', 'System.Core') + $UiAssemblies) { [void] $options.ReferencedAssemblies.Add("$assembly.dll") }
    try {
        $result = (New-Object Microsoft.CSharp.CSharpCodeProvider).CompileAssemblyFromFile($options, $path)
        $errors = @($result.Errors | Where-Object { -not $_.IsWarning })
        if ($errors) { "$($errors[0])" }
    } finally {
        Remove-Item -LiteralPath $options.OutputAssembly -ErrorAction SilentlyContinue
    }
}

# Take the icon out of the notification area and stop.
function Exit-Tray {
    $script:notify.Visible = $false
    $script:notify.Dispose()
    $script:context.ExitThread()
}

# Run a novacore command that changes something, such as up or php. It runs
# detached in WSL (see `novacore tray run`), so it finishes even if this
# script stops meanwhile, and Update-Action follows it from there.
function Start-Action([string[]] $Arguments, [string] $Label, [string] $DoneText, [string] $Url = '') {
    if ($script:busy) { return }
    $script:busy = $true
    $script:busyLabel = $Label
    $script:actionUrl = $Url
    $script:output = @()
    $script:unseen = ''
    $script:outputShown = -1
    Update-View
    try {
        [void] (Start-WslJob (Get-NovacoreArgs (@('tray', 'run', $Label, $DoneText) + $Arguments)) {
            param($job)
            if ($job.ExitCode -eq 0) { return }
            # It didn't start, e.g. as another command is still running.
            $script:busy = $false
            Show-Balloon "Couldn't start: $(Get-ActionName $script:busyLabel)" (Get-JobError $job) 'Error'
            Update-View
        })
    } catch {
        $script:busy = $false
        Update-View
        throw
    }
}

# A label without its trailing ellipsis, e.g. "Starting Novacore".
function Get-ActionName([string] $label) {
    $label.TrimEnd($Ellipsis.ToCharArray())
}

# Check on the running command: its output so far, or how it ended.
function Update-Action {
    if ($script:polling) { return }
    $script:polling = $true
    [void] (Start-WslJob (Get-NovacoreArgs @('tray', 'poll')) {
        param($job)
        $script:polling = $false
        if ($job.ExitCode -ne 0) { return }  # Try again on the next tick.

        $lines = @($job.Out)
        $exit = "$($lines[0])".Trim()
        $alive = $lines.Count -gt 1 -and $lines[1] -eq 'alive'
        $label = if ($lines.Count -gt 2) { $lines[2] } else { '' }
        $done = if ($lines.Count -gt 3) { $lines[3] } else { '' }
        $log = @(if ($lines.Count -gt 4) { $lines[4..($lines.Count - 1)] })
        while ($log.Count -and -not $log[-1].Trim()) { $log = @(if ($log.Count -gt 1) { $log[0..($log.Count - 2)] }) }

        if ($exit -eq '' -and $alive) {
            # Running, perhaps started before this script was.
            $script:busy = $true
            if ($label) { $script:busyLabel = $label }
            $script:output = $log
            Update-View
            return
        }
        # Finished. Only report it if we saw it running; otherwise it's an old one.
        if (-not $script:busy) { return }
        $script:busy = $false
        $script:output = $log
        if ($exit -eq '0') {
            if (-not $script:outputForm) { $script:unseen = 'done' }
            Show-Balloon 'Novacore' $(if ($done) { $done } else { "Done: $(Get-ActionName $label)" }) 'Info' -Url $script:actionUrl
        } else {
            # novacore's own error message starts with a heavy cross.
            $message = @($log | Where-Object { $_ -match '^\s*\u2716' }) | Select-Object -Last 1
            if (-not $message) { $message = @($log | Where-Object { $_.Trim() }) | Select-Object -Last 1 }
            if ($exit -eq '') { $message = 'novacore stopped before it finished.' }
            elseif (-not $message) { $message = "novacore exited with code $exit" }
            if (-not $script:outputForm) { $script:unseen = 'failed' }
            Show-Balloon "Couldn't finish: $(Get-ActionName $label)" (($message -replace '^\W+', '').Trim()) 'Error' -ShowsOutput
        }
        Update-View
        Update-Status -Wake
    })
}

# A notification. Clicking one with SHOWSOUTPUT opens the output window, and
# one with a URL opens that.
function Show-Balloon([string] $title, [string] $text, [string] $icon, [switch] $ShowsOutput, [string] $Url = '') {
    if (-not $text) { $text = ' ' }  # NotifyIcon refuses empty text.
    $script:balloonShowsOutput = [bool] $ShowsOutput
    $script:balloonUrl = $Url
    $script:notify.ShowBalloonTip(10000, $title, $text, $icon)
}

# --- Menu -------------------------------------------------------------------
#
# The menu is what `novacore tray menu` describes, so new items belong in the
# CLI. See tray/PROTOCOL.md.

function Get-StatusText {
    if ($script:busy) { return $script:busyLabel }
    if ($script:problem) { return "Can't run novacore" }
    if ($script:asleep) { return "WSL isn't running" }
    if (-not $script:model) { return "Checking$Ellipsis" }
    $script:model.status
}

function Get-IconState {
    if ($script:busy) { return 'Busy' }
    if ($script:problem -or ($script:model -and $script:model.state -eq 'error')) { return 'Error' }
    if ($script:model -and $script:model.state -eq 'running' -and -not $script:asleep) { return 'Running' }
    'Stopped'
}

function Add-MenuItem($items, [string] $Text, $Tag = $null, [bool] $Enabled = $true, [switch] $Bold) {
    $item = New-Object System.Windows.Forms.ToolStripMenuItem $Text
    $item.Enabled = $Enabled
    if ($Tag) {
        $item.Tag = $Tag
        $item.add_Click($script:onClick)
    }
    if ($Bold) { $item.Font = New-Object System.Drawing.Font($item.Font, [System.Drawing.FontStyle]::Bold) }
    [void] $items.Add($item)
    $item
}

function Add-Separator($items) {
    [void] $items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
}

# Whether to show an item: not one for an editor that isn't installed.
function Test-ItemShown($spec) {
    $a = $spec.action
    -not ($a -and $a.editor -and -not (Get-Editor $a))
}

# Whether an item can be used now.
function Test-ItemEnabled($spec) {
    if ($spec.enabled -eq $false) { return $false }
    if ($script:busy -and $spec.idle) { return $false }
    $a = $spec.action
    -not ($a -and $a.tray -eq 'output' -and $script:output.Count -eq 0)
}

# Add the items novacore described to ITEMS, a menu's or a submenu's.
function Add-MenuItems($items, $specs) {
    foreach ($spec in $specs) {
        if ($spec.separator) { Add-Separator $items; continue }
        if (-not (Test-ItemShown $spec)) { continue }
        $item = Add-MenuItem $items $spec.label $spec.action -Enabled (Test-ItemEnabled $spec) -Bold:([bool] $spec.bold)
        if ($spec.checked) { $item.Checked = $true }
        if ($spec.items) { Add-MenuItems $item.DropDownItems $spec.items }
    }
}

function Update-Menu {
    $items = $script:menu.Items
    $old = @($items)
    $items.Clear()
    $old | ForEach-Object { $_.Dispose() }

    [void] (Add-MenuItem $items "Novacore $MiddleDot $(Get-StatusText)" -Enabled $false)
    $text = Get-ProblemText
    if ($text) {
        if ($text.Length -gt 80) { $text = $text.Substring(0, 79) + $Ellipsis }
        [void] (Add-MenuItem $items $text -Enabled $false)
    }
    Add-Separator $items
    # The last menu we had, even while WSL sleeps: Docker Desktop may still be
    # serving the sites.
    if ($script:model) {
        Add-MenuItems $items $script:model.items
    } else {
        # novacore couldn't say, so just what this can do on its own.
        [void] (Add-MenuItem $items 'Refresh' ([pscustomobject] @{ tray = 'refresh' }))
        Add-Separator $items
        [void] (Add-MenuItem $items 'Quit' ([pscustomobject] @{ tray = 'quit' }))
    }
    [Novacore.Ui.Theme]::StyleMenu($script:menu)
}

# Why novacore can't run, or what's wrong with it, if anything.
function Get-ProblemText {
    if ($script:problem) { return $script:problem }
    if ($script:model) { return [string] $script:model.problem }
    ''
}

# Bring the icon, tooltip and menu up to date.
function Update-View {
    $script:notify.Icon = $script:icons[(Get-IconState)]

    # The tooltip can't be longer than 63 characters.
    $tip = "Novacore`n$(Get-StatusText)"
    if ($tip.Length -gt 63) { $tip = $tip.Substring(0, 62) + $Ellipsis }
    $script:notify.Text = $tip

    # Rebuilding the menu closes its open submenus, so only do it on a change.
    $signature = "$($script:busy)|$($script:busyLabel)|$($script:problem)|$($script:asleep)|$($script:output.Count -gt 0)|$($script:unseen)|$($script:modelJson)"
    if ($signature -ne $script:menuSignature) {
        $script:menuSignature = $signature
        Update-Menu
        if ($script:flyout.Visible) { Update-Flyout }
    }
    if ($script:flyout.Visible) {
        $note = Get-FooterNote
        if ($script:flyout.Foot.Note -ne $note) { $script:flyout.Foot.Note = $note; $script:flyout.Foot.Invalidate() }
    }
}

# Carry out an action from novacore's menu or a dialog's button.
function Invoke-MenuAction($a) {
    if ($a.open) { Start-Process $a.open }
    elseif ($a.folder) { Start-Process explorer.exe "`"$(Get-WindowsPath $a.folder)`"" }
    elseif ($a.editor) {
        $editor = Get-Editor $a
        if ($editor) { Start-Process $editor.Path -ArgumentList ($editor.Args -f (ConvertTo-Arg $Distro), (ConvertTo-Arg $a.editor)) -WindowStyle Hidden }
    }
    elseif ($a.terminal) { Start-Terminal $a.title @('--cd', $a.terminal) }
    elseif ($a.console) { Start-Terminal $a.title (@('-e', $Command) + @($a.console)) }
    elseif ($a.run) { Start-Action @($a.run) $a.label $a.done -Url ([string] $a.url) }
    elseif ($a.dialog -eq 'form') { Show-Form $a }
    elseif ($a.dialog -eq 'info') { Show-Info $a }
    elseif ($a.tray -eq 'output') { Show-Output }
    elseif ($a.tray -eq 'refresh') { Update-Status -Wake }
    elseif ($a.tray -eq 'quit') {
        if ($script:outputForm) { $script:outputForm.Close() }
        Exit-Tray
    }
}

# Report an error in this script, and log it to tray.log next to it.
function Show-Problem($err) {
    try {
        $where = if ($err.ScriptStackTrace) { "`n$($err.ScriptStackTrace)" } else { '' }
        Add-Content -LiteralPath (Join-Path $PSScriptRoot 'tray.log') -Value "$(Get-Date -Format s) $err$where"
    } catch { }
    try { Show-Balloon 'Novacore tray icon error' "$err" 'Error' } catch { }
}

# --- Output window ------------------------------------------------------------

# The output of the last action, like the Plasma widget's log.
function Show-Output {
    if ($script:unseen) {
        $script:unseen = ''
        Update-View
    }
    if (-not $script:outputForm) {
        $form = New-Object System.Windows.Forms.Form
        $form.Text = 'Novacore'
        $form.Icon = $script:windowIcon
        $form.StartPosition = 'CenterScreen'
        $form.Size = New-Object System.Drawing.Size (S 760), (S 440)

        $box = New-Object System.Windows.Forms.TextBox
        $box.Multiline = $true
        $box.ReadOnly = $true
        $box.WordWrap = $false
        $box.ScrollBars = 'Both'
        $box.Dock = 'Fill'
        $box.Font = New-Object System.Drawing.Font('Consolas', 10)
        $box.BackColor = [System.Drawing.ColorTranslator]::FromHtml('#1B1E20')
        $box.ForeColor = [System.Drawing.ColorTranslator]::FromHtml('#D0D4D7')
        $form.Controls.Add($box)
        $form.add_FormClosed({ $script:outputForm = $null; $script:outputBox = $null })

        $script:outputForm = $form
        $script:outputBox = $box
        $script:outputShown = -1
        $form.Show()
    }
    Update-OutputWindow
    $script:outputForm.Activate()
}

function Update-OutputWindow {
    if (-not $script:outputForm) { return }
    $script:outputForm.Text = if ($script:busy) { "Novacore $MiddleDot $($script:busyLabel)" } else { "Novacore $MiddleDot Output" }
    if ($script:output.Count -eq $script:outputShown) { return }
    $script:outputShown = $script:output.Count
    $box = $script:outputBox
    $box.Text = if ($script:output.Count) { $script:output -join "`r`n" } else { "Waiting for output$Ellipsis" }
    $box.SelectionStart = $box.TextLength
    $box.ScrollToCaret()
}

# --- Terminals and paths ------------------------------------------------------

# A path in the distro as Windows sees it, e.g. \\wsl.localhost\Ubuntu\home\you.
function Get-WindowsPath([string] $path) {
    "\\wsl.localhost\$Distro" + ($path -replace '/', '\')
}

# Open a terminal running wsl.exe with ARGUMENTS: in Windows Terminal when
# it's installed, else in a console window.
function Start-Terminal([string] $Title, [string[]] $Arguments) {
    $wsl = @('-d', $Distro) + $Arguments
    if ($script:wt) {
        # Windows Terminal reads ; as a separator between its own commands.
        $line = Join-Args (@('--title', $Title, 'wsl.exe') + $wsl)
        Start-Process $script:wt -ArgumentList ($line -replace ';', '\;')
    } else {
        Start-Process (Join-Path $env:WINDIR 'System32\wsl.exe') -ArgumentList (Join-Args $wsl)
    }
}

$script:wt = (Get-Command wt.exe -ErrorAction SilentlyContinue | Select-Object -First 1).Source

# NAME on the PATH, else the first of PATHS that exists, else $null.
function Find-Program([string] $name, [string[]] $paths) {
    $found = (Get-Command $name -ErrorAction SilentlyContinue | Select-Object -First 1).Source
    if (-not $found) { $found = $paths | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1 }
    $found
}

# The editors an editor action's app can name: each one's CLI, if it's
# installed, and its arguments to open a folder in the distro, with {0} for
# the distro and {1} for the folder.
$script:editors = @{
    vscode = @{
        Path = Find-Program code.cmd @(
            "$env:LOCALAPPDATA\Programs\Microsoft VS Code\bin\code.cmd",
            "$env:ProgramFiles\Microsoft VS Code\bin\code.cmd")
        Args = '--remote wsl+{0} {1}'
    }
    zed = @{
        Path = Find-Program zed.exe @("$env:LOCALAPPDATA\Programs\Zed\bin\zed.exe")
        Args = '--wsl {0} {1}'
    }
}

# The editor action A names, or $null if it isn't installed.
function Get-Editor($a) {
    $app = if ($a.app) { [string] $a.app } else { 'vscode' }
    $editor = $script:editors[$app]
    if ($editor -and $editor.Path) { $editor }
}

# --- Dialogs ------------------------------------------------------------------

function New-Dialog([string] $title) {
    $form = New-Object System.Windows.Forms.Form
    $form.Text = $title
    $form.Font = [System.Drawing.SystemFonts]::MessageBoxFont
    $form.Icon = $script:windowIcon
    $form.FormBorderStyle = 'FixedDialog'
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.StartPosition = 'CenterScreen'
    $form.AutoSize = $true
    $form.AutoSizeMode = 'GrowAndShrink'
    $form.Padding = New-Object System.Windows.Forms.Padding (S 12)
    # Started from the tray, a window can open behind others; bring it forward.
    $form.add_Shown({ $this.TopMost = $true; $this.Activate(); $this.TopMost = $false })
    $form
}

# A grid of COLUMNS, each as wide as its widest control.
function New-Grid([int] $columns) {
    $grid = New-Object System.Windows.Forms.TableLayoutPanel
    $grid.ColumnCount = $columns
    $grid.AutoSize = $true
    $grid.AutoSizeMode = 'GrowAndShrink'
    $grid.GrowStyle = 'AddRows'
    for ($i = 0; $i -lt $columns; $i++) {
        [void] $grid.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle ([System.Windows.Forms.SizeType]::AutoSize)))
    }
    $grid
}

function New-Label([string] $text, [switch] $Bold, [switch] $Hint) {
    $label = New-Object System.Windows.Forms.Label
    $label.Text = $text
    $label.AutoSize = $true
    $label.Anchor = 'Left'
    $label.Margin = New-Object System.Windows.Forms.Padding 0, (S 4), (S 8), (S 4)
    if ($Bold) { $label.Font = New-Object System.Drawing.Font($label.Font, [System.Drawing.FontStyle]::Bold) }
    if ($Hint) { $label.ForeColor = [System.Drawing.SystemColors]::GrayText }
    $label
}

# Add a row of CONTROLS to GRID, with an empty cell for each $null.
function Add-Row($grid, [object[]] $controls) {
    $row = $grid.RowCount
    $grid.RowCount = $row + 1
    for ($i = 0; $i -lt $controls.Count; $i++) {
        if ($controls[$i]) { $grid.Controls.Add($controls[$i], $i, $row) }
    }
}

# A control across all of GRID's columns.
function Add-Wide($grid, $control) {
    $row = $grid.RowCount
    $grid.RowCount = $row + 1
    $grid.Controls.Add($control, 0, $row)
    $grid.SetColumnSpan($control, $grid.ColumnCount)
}

# A heading across GRID's columns.
function Add-Heading($grid, [string] $text) {
    $label = New-Label $text -Bold
    $label.Margin = New-Object System.Windows.Forms.Padding 0, (S 10), 0, (S 2)
    Add-Wide $grid $label
}

# A row of BUTTONS, right-aligned, for the bottom of a dialog.
function New-ButtonRow([object[]] $buttons) {
    $row = New-Object System.Windows.Forms.FlowLayoutPanel
    $row.FlowDirection = 'RightToLeft'
    $row.AutoSize = $true
    $row.AutoSizeMode = 'GrowAndShrink'
    $row.Anchor = 'Right'
    $row.Margin = New-Object System.Windows.Forms.Padding 0, (S 12), 0, 0
    foreach ($button in $buttons) { $row.Controls.Add($button) }
    $row
}

# Put GRID above a row of BUTTONS in FORM. (Docking them instead would stop
# the form sizing itself to fit them.)
function Set-DialogContent($form, $grid, [object[]] $buttons) {
    $stack = New-Object System.Windows.Forms.FlowLayoutPanel
    $stack.FlowDirection = 'TopDown'
    $stack.WrapContents = $false
    $stack.AutoSize = $true
    $stack.AutoSizeMode = 'GrowAndShrink'
    $stack.Controls.Add($grid)
    $stack.Controls.Add((New-ButtonRow $buttons))
    $form.Controls.Add($stack)
}

function New-Button([string] $text, $result = $null) {
    $button = New-Object System.Windows.Forms.Button
    $button.Text = $text
    $button.AutoSize = $true
    $button.MinimumSize = New-Object System.Drawing.Size (S 88), 0
    if ($null -ne $result) { $button.DialogResult = $result }
    $button
}

# Replace {id} in TEXT with each of VALUES' answers.
function Format-Template([string] $text, $values) {
    foreach ($v in $values) { $text = $text.Replace("{$($v.Id)}", $v.Value) }
    $text
}

# Check the open form's answers as they're typed: show each text field's hint
# or what's wrong with it, and each choice's hint, and allow submitting only
# when all is well.
function Update-FormState {
    $state = $script:form
    if (-not $state) { return }
    $ok = $true
    foreach ($f in $state.Fields) {
        $spec = $f.Spec
        if ($spec.type -eq 'choice') {
            $v = [string] $f.Control.SelectedItem
            $h = if ($spec.hints) { $spec.hints.PSObject.Properties[$v] } else { $null }
            $f.Hint.Text = if ($h) { $h.Value } else { ' ' }
        } elseif ($spec.type -ne 'check' -and $spec.type -ne 'combo') {
            $v = $f.Control.Text.Trim()
            $problem = ''
            if (-not $v) { $ok = $false }
            else {
                foreach ($rule in $spec.rules) {
                    if (($rule.match -and $v -cnotmatch $rule.match) -or ($rule.notIn -and @($rule.notIn) -ccontains $v)) {
                        $problem = ([string] $rule.error).Replace('{value}', $v)
                        break
                    }
                }
            }
            if ($problem) { $ok = $false }
            $f.Hint.ForeColor = if ($problem) { [System.Drawing.Color]::Firebrick } else { [System.Drawing.SystemColors]::GrayText }
            $f.Hint.Text = if ($problem) { $problem } elseif ($v -and $spec.hint) { ([string] $spec.hint).Replace('{value}', $v) } else { ' ' }
        }
    }
    $state.Submit.Enabled = $ok
}

# Each field's answer, as `novacore tray submit` takes them.
function Get-FormValues {
    foreach ($f in $script:form.Fields) {
        $c = $f.Control
        $v = switch ($f.Spec.type) {
            'check' { if ($c.Checked) { '1' } else { '0' } }
            'choice' { [string] $c.SelectedItem }
            default { $c.Text.Trim() }
        }
        [pscustomobject] @{ Id = [string] $f.Spec.id; Value = $v }
    }
}

# A dialog that asks for something, then runs its action with the answers,
# e.g. Add Site. See "Form dialogs" in tray/PROTOCOL.md.
function Show-Form($spec) {
    $form = New-Dialog $spec.title
    $grid = New-Grid 2
    if ($spec.heading) { Add-Wide $grid (New-Label $spec.heading -Bold) }
    if ($spec.message) {
        $message = New-Label $spec.message
        $message.MaximumSize = New-Object System.Drawing.Size (S 380), 0
        Add-Wide $grid $message
    }

    $fields = New-Object System.Collections.ArrayList
    $first = $null
    foreach ($f in $spec.fields) {
        $hint = $null
        switch ($f.type) {
            'choice' {
                $c = New-Object System.Windows.Forms.ComboBox
                $c.DropDownStyle = 'DropDownList'
                $c.Width = S 100
                foreach ($o in $f.options) { [void] $c.Items.Add($o) }
                $c.SelectedItem = $f.value
                $c.add_SelectedIndexChanged({ Invoke-Safely { Update-FormState } })
                Add-Row $grid @((New-Label $f.label), $c)
                $hint = New-Label ' ' -Hint
            }
            'combo' {
                $c = New-Object System.Windows.Forms.ComboBox
                $c.Width = S 160
                foreach ($o in $f.options) { [void] $c.Items.Add($o) }
                $c.Text = $f.value
                Add-Row $grid @((New-Label $f.label), $c)
                if ($f.note) { $hint = New-Label $f.note -Hint }
            }
            'check' {
                $c = New-Object System.Windows.Forms.CheckBox
                $c.Text = $f.label
                $c.AutoSize = $true
                $c.Checked = [bool] $f.value
                $c.Margin = New-Object System.Windows.Forms.Padding 0, (S 8), 0, 0
                Add-Row $grid @($null, $c)
            }
            default {
                $c = New-Object System.Windows.Forms.TextBox
                $c.Width = S 260
                if ($f.lowercase) { $c.CharacterCasing = 'Lower' }
                $c.Text = $f.value
                $c.add_TextChanged({ Invoke-Safely { Update-FormState } })
                Add-Row $grid @((New-Label $f.label), $c)
                $hint = New-Label ' ' -Hint
                if (-not $first) { $first = $c }
            }
        }
        if ($f.enabled -eq $false) { $c.Enabled = $false }
        if ($hint) { Add-Row $grid @($null, $hint) }
        [void] $fields.Add(@{ Spec = $f; Control = $c; Hint = $hint })
    }

    $submit = New-Button $spec.submit ([System.Windows.Forms.DialogResult]::OK)
    $cancel = New-Button 'Cancel' ([System.Windows.Forms.DialogResult]::Cancel)
    Set-DialogContent $form $grid @($cancel, $submit)
    $form.AcceptButton = $submit
    $form.CancelButton = $cancel
    # Enter cancels rather than, say, removing a site.
    if ($spec.destructive) { $form.add_Shown({ $this.CancelButton.Select() }) }

    $script:form = @{ Fields = $fields; Submit = $submit }
    Update-FormState
    if ($first) { $first.Select() }
    $result = $form.ShowDialog()
    $values = @(Get-FormValues)
    $form.Dispose()
    $script:form = $null
    if ($result -ne [System.Windows.Forms.DialogResult]::OK) { return }

    $a = $spec.action
    $arguments = @($a.run) + @($values | ForEach-Object { "$($_.Id)=$($_.Value)" })
    Start-Action $arguments (Format-Template $a.label $values) (Format-Template $a.done $values) -Url (Format-Template $a.url $values)
}

# A dialog of details, each with a Copy button, e.g. a site's Info.
function Show-Info($spec) {
    $title = [string] $spec.title
    if ($script:infoForms[$title]) { $script:infoForms[$title].Activate(); return }

    $form = New-Dialog $title
    $form.Tag = $title
    $grid = New-Grid 3
    foreach ($section in $spec.sections) {
        Add-Heading $grid $section.heading
        foreach ($row in $section.rows) {
            $box = New-Object System.Windows.Forms.TextBox
            $box.Text = $row[1]
            $box.ReadOnly = $true
            $box.Width = S 500
            $copy = New-Button 'Copy'
            $copy.MinimumSize = New-Object System.Drawing.Size (S 60), 0
            $copy.Tag = $row[1]
            $copy.add_Click({ [System.Windows.Forms.Clipboard]::SetText([string] $this.Tag) })
            Add-Row $grid @((New-Label $row[0]), $box, $copy)
        }
    }

    $close = New-Button 'Close'
    $close.add_Click({ $this.FindForm().Close() })
    # The buttons flow right to left, so Close goes first, then the rest
    # backwards.
    $buttons = @($close)
    $extra = @(foreach ($b in $spec.buttons) {
        $button = New-Button $b.label
        $button.Tag = $b.action
        $button.add_Click({ $tag = $this.Tag; Invoke-Safely { Invoke-MenuAction $tag } })
        $button
    })
    [array]::Reverse($extra)
    Set-DialogContent $form $grid ($buttons + $extra)
    $form.CancelButton = $close
    $form.ActiveControl = $close
    $form.add_FormClosed({ $script:infoForms.Remove($this.Tag) })

    $script:infoForms[$title] = $form
    $form.Show()
}

# --- Panel --------------------------------------------------------------------
#
# What a left click opens: a panel in the style of Windows 11's own flyouts,
# laid out from the same items as the menu. The status goes at the top, with
# any problem under it. Each item is a row, and separators with a label start
# sections. A submenu's row expands to show its items as links, two to a
# line, with each group its separators make starting a new line, and
# destructive ones, such as Remove, as buttons. Commands to
# run that sit together, such as Stop and Restart, share a row of buttons,
# and the icon's own commands (Show Output, Refresh, Quit) go at the bottom.
#
# The controls are drawn by novacore-ui.cs, next to this script, which it
# compiles when it starts.

$script:uiSource = Join-Path $PSScriptRoot 'novacore-ui.cs'
if (-not (Test-Path -LiteralPath $script:uiSource)) {
    # Copies of this script from before it came in two files update
    # themselves without it, so fetch it from the repo, as Update-Self would.
    Copy-Item -LiteralPath (Get-WindowsPath (($Command -replace '/bin/[^/]+$', '') + '/tray/windows/novacore-ui.cs')) -Destination $script:uiSource
}
$UiAssemblies = 'System.Windows.Forms', 'System.Drawing'
Add-Type -Path $script:uiSource -ReferencedAssemblies $UiAssemblies
[void] [Novacore.Ui.Theme]::Load($script:scale)

# The project icon, for the panel's header.
$script:appImage = $null
$png = Get-AppIconPng 64
if ($png) { $script:appImage = New-Object System.Drawing.Bitmap (New-Object System.IO.MemoryStream (, $png)) }

function Get-Glyph([string] $name) { [Novacore.Ui.Theme]::Glyph($name) }

# The name of an item's icon: its own (see tray/PROTOCOL.md), else one for
# what it does.
function Get-ItemIcon($spec) {
    if ($spec.icon) { return [string] $spec.icon }
    $a = $spec.action
    if (-not $a) { return '' }
    if ($a.open) { return 'site' }
    if ($a.folder) { return 'folder' }
    if ($a.editor) { return 'code' }
    if ($a.terminal -or $a.console) { return 'terminal' }
    if ($a.dialog -eq 'info') { return 'info' }
    if ($a.dialog -eq 'form') { if ($a.destructive) { return 'remove' } else { return 'add' } }
    if ($a.tray) { return [string] $a.tray }
    ''
}

# The line at the bottom of the panel: the distro, and when we last checked.
function Get-FooterNote {
    $note = $Distro
    if ($script:asleep) { $note += " $MiddleDot asleep" }
    elseif ($script:checkedAt) { $note += " $MiddleDot updated $($script:checkedAt.ToString('t'))" }
    $note
}

$script:onFlyoutClick = { Invoke-Safely { Invoke-FlyoutAction $this.Tag } }

# Carry out an action from the panel. Most take you elsewhere, so the panel
# closes, but it stays to show a command's progress.
function Invoke-FlyoutAction($a) {
    if (-not ($a.run -or $a.tray -eq 'refresh')) { $script:flyout.Hide() }
    Invoke-MenuAction $a
}

# A button for an item, for a row of buttons, or a destructive one in an
# expanded row.
function New-FlyoutChip($spec) {
    $chip = New-Object Novacore.Ui.Chip
    $chip.Label = [string] $spec.label
    $icon = Get-ItemIcon $spec
    if ($icon) { $chip.Icon = Get-Glyph $icon }
    $chip.Danger = [bool] (Test-Destructive $spec)
    $chip.Checked = [bool] $spec.checked
    $chip.Strong = [bool] $spec.bold
    $chip.Enabled = Test-ItemEnabled $spec
    if ($spec.items) {
        $chip.Tag = $spec
        $chip.add_Click({ Invoke-Safely { Show-FlyoutMenu $this } })
    } elseif ($spec.action) {
        $chip.Tag = $spec.action
        $chip.add_Click($script:onFlyoutClick)
    }
    $chip
}

# A submenu inside a submenu, which an expanded row can't show, as a menu by
# its button.
function Show-FlyoutMenu($chip) {
    $menu = New-Object System.Windows.Forms.ContextMenuStrip
    Add-MenuItems $menu.Items $chip.Tag.items
    [Novacore.Ui.Theme]::StyleMenu($menu)
    $script:flyout.Hold = $true
    $menu.add_Closed({ $script:flyout.Hold = $false })
    $menu.Show($chip, 0, $chip.Height)
}

# ITEMS split at their separators: each group's items, and the label of the
# separator before it.
function Get-ItemGroups($specs) {
    $groups = New-Object System.Collections.ArrayList
    $group = @{ Label = ''; Items = New-Object System.Collections.ArrayList }
    foreach ($spec in $specs) {
        if ($spec.separator) {
            if ($group.Items.Count) { [void] $groups.Add($group) }
            $group = @{ Label = [string] $spec.label; Items = New-Object System.Collections.ArrayList }
        } elseif (Test-ItemShown $spec) {
            [void] $group.Items.Add($spec)
        }
    }
    if ($group.Items.Count) { [void] $groups.Add($group) }
    , $groups
}

# Whether ITEMS are options to pick one of, such as PHP versions: one is
# checked, and none has a picture.
function Test-Choices($specs) {
    $items = @($specs | Where-Object { -not $_.separator })
    @($items | Where-Object { $_.checked }).Count -gt 0 -and
        @($items | Where-Object { Get-ItemIcon $_ }).Count -eq 0
}

# Options to pick one of, as a menu under CONTROL.
function Show-ChoiceMenu($control, $specs) {
    $menu = New-Object System.Windows.Forms.ContextMenuStrip
    Add-MenuItems $menu.Items $specs
    [Novacore.Ui.Theme]::StyleMenu($menu)
    $script:flyout.Hold = $true
    $menu.add_Closed({ $script:flyout.Hold = $false })
    $menu.Show($control, (New-Object System.Drawing.Point $control.Width, $control.Height), [System.Windows.Forms.ToolStripDropDownDirection]::BelowLeft)
}

# Whether an item is one to think twice about, such as Remove.
function Test-Destructive($spec) {
    (Get-ItemIcon $spec) -eq 'remove' -or ($spec.action -and $spec.action.destructive)
}

# A link for an item, for an expanded row.
function New-FlyoutLink($spec) {
    $link = New-Object Novacore.Ui.Link
    $link.Label = [string] $spec.label
    $icon = Get-ItemIcon $spec
    if ($icon) { $link.Icon = Get-Glyph $icon }
    $link.Enabled = Test-ItemEnabled $spec
    if ($spec.items) {
        $link.Tag = $spec
        $link.add_Click({ Invoke-Safely { Show-FlyoutMenu $this } })
    } elseif ($spec.action) {
        $link.Tag = $spec.action
        $link.add_Click($script:onFlyoutClick)
    }
    $link
}

# What an expanded row shows, in a card: its submenu's items as links, two to
# a line, leaving out SKIP, which is on the row already. Groups of options,
# such as PHP versions, are a box to pick from instead, captioned with their
# separator's label, and destructive items, such as Remove, are buttons at the
# bottom.
function New-FlyoutCard($specs, $skip) {
    $card = New-Object Novacore.Ui.Stack
    $card.Card = $true
    $card.BackColor = [Novacore.Ui.Theme]::Card
    $card.Padding = New-Object System.Windows.Forms.Padding (S 12), (S 8), (S 12), (S 10)
    $card.Margin = New-Object System.Windows.Forms.Padding (S 8), (S 2), (S 8), (S 6)

    $groups = Get-ItemGroups $specs
    $grid = $null
    $buttons = New-Object System.Collections.ArrayList
    foreach ($group in $groups) {
        if (Test-Choices $group.Items) { continue }
        $first = $true
        foreach ($spec in $group.Items) {
            if ($spec -eq $skip) { continue }
            if (Test-Destructive $spec) { [void] $buttons.Add($spec); continue }
            if (-not $grid) {
                $grid = New-Object Novacore.Ui.Grid
                $card.Controls.Add($grid)
            }
            $link = New-FlyoutLink $spec
            $grid.Controls.Add($link)
            if ($first) { [void] $grid.GroupStarts.Add($link) }
            $first = $false
        }
    }
    foreach ($group in $groups) {
        if (-not (Test-Choices $group.Items)) { continue }
        $field = New-Object Novacore.Ui.Field
        $field.Caption = $group.Label
        $field.Value = [string] (@($group.Items | Where-Object { $_.checked })[0].label)
        $field.Enabled = @($group.Items | Where-Object { $_.action -and (Test-ItemEnabled $_) }).Count -gt 0
        $field.Tag = $group.Items.ToArray()
        if ($card.Controls.Count) { $field.Margin = New-Object System.Windows.Forms.Padding 0, (S 8), 0, 0 }
        $field.add_Click({ Invoke-Safely { Show-ChoiceMenu $this $this.Tag } })
        $card.Controls.Add($field)
    }
    if ($buttons.Count) {
        $flow = New-Object Novacore.Ui.Flow
        if ($card.Controls.Count) { $flow.Margin = New-Object System.Windows.Forms.Padding 0, (S 10), 0, 0 }
        foreach ($spec in $buttons) {
            $flow.Controls.Add((New-FlyoutChip $spec))
        }
        $card.Controls.Add($flow)
    }
    $card
}

# Add a row for an item to STACK, and the card it expands into if it's a
# submenu. A submenu's bold item, such as a site's Open, gets a button on the
# row too.
function Add-FlyoutRow($stack, $spec) {
    $row = New-Object Novacore.Ui.Row
    $row.Title = [string] $spec.label
    $row.Detail = [string] $spec.detail
    $row.Strong = [bool] $spec.bold
    $row.Enabled = Test-ItemEnabled $spec
    $icon = Get-ItemIcon $spec
    if ($icon -eq 'site' -and $spec.items) {
        $row.Avatar = [Novacore.Ui.Theme]::Initials($row.Title)
        $row.AvatarColor = [Novacore.Ui.Theme]::AvatarColor($row.Title)
    } elseif ($icon) {
        $row.Icon = Get-Glyph $icon
    }
    $row.add_ButtonClick({ param($sender, $e) Invoke-Safely { Invoke-FlyoutAction $e.Tag } })
    $stack.Controls.Add($row)

    if ($spec.items) {
        $row.Chevron = $true
        if (Test-Choices $spec.items) {
            # Just options, such as Xdebug's modes: pick one from a menu.
            $row.Tag = @($spec.items)
            $row.add_Click({ Invoke-Safely { Show-ChoiceMenu $this $this.Tag } })
            return
        }
        $main = @($spec.items | Where-Object { $_.bold -and $_.action -and (Test-ItemEnabled $_) }) | Select-Object -First 1
        if ($main) {
            $button = New-Object Novacore.Ui.RowButton
            $button.Glyph = Get-Glyph $(if ($main.action.open) { 'open' } else { Get-ItemIcon $main })
            $button.Tip = [string] $main.label
            $button.Tag = $main.action
            $row.Buttons.Add($button)
        }
        $card = New-FlyoutCard $spec.items $main
        $row.Tag = $card
        $stack.Controls.Add($card)
        $row.Expanded = $script:expanded -eq $row.Title
        $stack.Collapse($card, -not $row.Expanded)
        $row.add_Click({ Invoke-Safely { Switch-FlyoutRow $this } })
    } elseif ($spec.action) {
        $row.Tag = $spec.action
        $row.add_Click($script:onFlyoutClick)
    }
}

# Expand ROW, closing any other, or close it.
function Switch-FlyoutRow($row) {
    $open = -not $row.Expanded
    $body = $script:flyout.Body
    foreach ($c in @($body.Controls)) {
        if ($c -is [Novacore.Ui.Row] -and $c.Expanded -and $c.Tag -is [System.Windows.Forms.Control]) {
            $c.Expanded = $false
            $body.Collapse($c.Tag, $true)
            $c.Invalidate()
        }
    }
    if ($open) {
        $row.Expanded = $true
        $body.Collapse($row.Tag, $false)
    }
    $row.Invalidate()
    $script:expanded = if ($open) { $row.Title } else { '' }
    $script:flyout.Reflow()
    if ($open -and $body.AutoScroll) { $body.ScrollControlIntoView($row.Tag); $body.ScrollControlIntoView($row) }
}

# Start a section of STACK, called LABEL if it has one.
function Add-FlyoutSection($stack, [string] $label) {
    $n = $stack.Controls.Count
    if ($n -and ($stack.Controls[$n - 1] -is [Novacore.Ui.Heading] -or $stack.Controls[$n - 1] -is [Novacore.Ui.Divider])) {
        $stack.Controls[$n - 1].Dispose()
        $n--
    }
    if ($label) {
        $heading = New-Object Novacore.Ui.Heading
        $heading.Label = $label
        $stack.Controls.Add($heading)
    } elseif ($n) {
        $stack.Controls.Add((New-Object Novacore.Ui.Divider))
    }
}

# Lay the panel out afresh from novacore's items.
function Update-Flyout {
    $f = $script:flyout
    $script:flyoutSignature = $script:menuSignature
    $f.SuspendLayout()
    $f.Clear()
    $f.ApplyTheme()

    $header = New-Object Novacore.Ui.Header
    $header.Image = $script:appImage
    $header.Title = 'Novacore'
    $header.Status = Get-StatusText
    $header.State = Get-IconState
    $f.Head.Controls.Add($header)
    $problem = Get-ProblemText
    if ($problem) {
        $banner = New-Object Novacore.Ui.Banner
        $banner.Message = $problem
        $f.Head.Controls.Add($banner)
    }
    if ($script:busy) { $f.Head.Controls.Add((New-Object Novacore.Ui.Progress)) }

    $specs = if ($script:model) { $script:model.items } else {
        @([pscustomobject] @{ label = 'Refresh'; action = [pscustomobject] @{ tray = 'refresh' } },
          [pscustomobject] @{ label = 'Quit'; action = [pscustomobject] @{ tray = 'quit' } })
    }
    # The first item, if it's the main one, such as Open Dashboard, is what
    # clicking the header does.
    $first = @($specs)[0]
    if ($first -and $first.bold -and $first.action -and -not $first.items -and -not $first.action.tray) {
        $header.Tip = ([string] $first.label).TrimEnd($Ellipsis.ToCharArray())
        $header.Enabled = Test-ItemEnabled $first
        $header.Tag = $first.action
        $header.add_Click($script:onFlyoutClick)
        $specs = @($specs | Select-Object -Skip 1)
    }
    $own = New-Object System.Collections.ArrayList
    $bar = $null
    foreach ($spec in $specs) {
        if ($spec.separator) { $bar = $null; Add-FlyoutSection $f.Body ([string] $spec.label); continue }
        if (-not (Test-ItemShown $spec)) { continue }
        $a = $spec.action
        if ($a -and $a.tray -and -not $spec.items) { [void] $own.Add($spec); continue }
        if ($a -and $a.run -and -not $spec.items) {
            if (-not $bar) {
                $bar = New-Object Novacore.Ui.Bar
                $f.Body.Controls.Add($bar)
            }
            $bar.Controls.Add((New-FlyoutChip $spec))
            continue
        }
        $bar = $null
        Add-FlyoutRow $f.Body $spec
    }
    # A command that stands alone, such as Start, is the one to press.
    foreach ($c in @($f.Body.Controls)) {
        if ($c -is [Novacore.Ui.Bar] -and $c.Controls.Count -eq 1) { $c.Controls[0].Primary = $true }
    }
    # No section without anything in it.
    $n = $f.Body.Controls.Count
    if ($n -and ($f.Body.Controls[$n - 1] -is [Novacore.Ui.Heading] -or $f.Body.Controls[$n - 1] -is [Novacore.Ui.Divider])) {
        $f.Body.Controls[$n - 1].Dispose()
    }

    $f.Foot.Note = Get-FooterNote
    foreach ($spec in $own) {
        $button = New-Object Novacore.Ui.IconButton
        $button.Icon = Get-Glyph (Get-ItemIcon $spec)
        $button.Tip = ([string] $spec.label).TrimEnd($Ellipsis.ToCharArray())
        $button.Enabled = Test-ItemEnabled $spec
        if ($spec.action.tray -eq 'output' -and $script:unseen) {
            # The last command's output, not yet seen: red if it failed.
            $button.Badge = if ($script:unseen -eq 'failed') { [Novacore.Ui.Theme]::Danger } else { [Novacore.Ui.Theme]::Accent }
            $button.Tip += $(if ($script:unseen -eq 'failed') { ' (the last command failed)' } else { ' (new)' })
        }
        $button.Tag = $spec.action
        $button.add_Click($script:onFlyoutClick)
        $f.Foot.Controls.Add($button)
    }
    $f.ResumeLayout()
    if ($f.Visible) { $f.Reflow() }
}

# Follow the system between light and dark.
function Update-Theme {
    if (-not [Novacore.Ui.Theme]::Load($script:scale)) { return }
    [Novacore.Ui.Theme]::StyleMenu($script:menu)
    $script:flyoutSignature = $null
    if ($script:flyout.Visible) { Update-Flyout }
}

function Show-Flyout {
    Update-Theme
    if ($script:flyoutSignature -ne $script:menuSignature) { Update-Flyout }
    $script:flyout.Foot.Note = Get-FooterNote
    $script:flyout.ShowAt([System.Windows.Forms.Cursor]::Position)
    # Opening it is a good time to check, even if that wakes WSL.
    Update-Status -Wake
}

function Switch-Flyout {
    $f = $script:flyout
    if ($f.Visible) { $f.Hide(); return }
    # Clicking the icon takes the focus from the panel, which hides it, so
    # don't show it again straight away.
    if (((Get-Date) - $f.HiddenAt).TotalMilliseconds -lt 400) { return }
    Show-Flyout
}

# --- Main ---------------------------------------------------------------------

# Event handlers that throw would otherwise stop the whole tray icon.
function Invoke-Safely([scriptblock] $block) {
    try { & $block } catch { Show-Problem $_ }
}

Invoke-Safely { Register-AppId }
Invoke-Safely { if (Start-Launcher) { exit } }

$script:onClick = { param($sender, $e) Invoke-Safely { Invoke-MenuAction $sender.Tag } }

$script:menu = New-Object System.Windows.Forms.ContextMenuStrip
# Opening the menu is a good time to check, even if that wakes WSL.
$script:menu.add_Opening({ Invoke-Safely { Update-Status -Wake } })

[Novacore.Ui.Theme]::StyleMenu($script:menu)
$script:flyout = New-Object Novacore.Ui.Flyout
$script:flyout.Icon = $script:windowIcon

$script:notify = New-Object System.Windows.Forms.NotifyIcon
# A right click opens the menu, and a left click the panel.
$script:notify.ContextMenuStrip = $script:menu
$script:notify.add_MouseUp({
    param($sender, $e)
    if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) { Invoke-Safely { Switch-Flyout } }
})
$script:notify.add_BalloonTipClicked({
    Invoke-Safely {
        if ($script:balloonShowsOutput) { Show-Output }
        elseif ($script:balloonUrl) { Start-Process $script:balloonUrl }
    }
})

$script:pump = New-Object System.Windows.Forms.Timer
$script:pump.Interval = 200
$script:pump.add_Tick({ Invoke-Safely { Update-Jobs } })

# Follow a running command's progress.
$watch = New-Object System.Windows.Forms.Timer
$watch.Interval = 1000
$watch.add_Tick({ if ($script:busy) { Invoke-Safely { Update-Action } } })
$watch.Start()

$refresh = New-Object System.Windows.Forms.Timer
$refresh.Interval = [Math]::Max(5, $RefreshInterval) * 1000
$refresh.add_Tick({ Invoke-Safely { Update-Status } })
$refresh.Start()

# Follow the taskbar, and apps, between light and dark.
$theme = New-Object System.Windows.Forms.Timer
$theme.Interval = 2000
$theme.add_Tick({ Invoke-Safely { [void] (Update-Icons); Update-Theme } })
$theme.Start()

Update-View
$script:notify.Visible = $true
if ($Updated) { Show-Balloon 'Novacore' 'The tray icon has been updated.' 'Info' }
Update-Status

$script:context = New-Object System.Windows.Forms.ApplicationContext
[System.Windows.Forms.Application]::Run($script:context)
