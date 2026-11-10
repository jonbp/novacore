<#
    Novacore's icon in the Windows notification area, for when Novacore runs
    in WSL. It's the Windows counterpart of the Plasma widget in plasmoid/:
    it shows whether the stack is running, lists the sites, and starts, stops
    and switches PHP versions by running the novacore CLI through wsl.exe.

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

$Ellipsis = [string] [char] 0x2026  # ellipsis
$MiddleDot = [string] [char] 0xB7  # middle dot

$script:status = $null      # novacore status --json, parsed
$script:statusJson = ''
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

# --- Icon ---------------------------------------------------------------------

# The globe from Novacore's link in the Open Source nav on jonbp.co.uk, a
# 24x24 icon: a circle, and the equator and two meridians tilted like the
# Earth's axis. The full logo, with its square, is too detailed for 16px. The
# globe is white or black to suit the taskbar, and a badge in its bottom right
# corner shows the status by its colour.
#
# Shapes are drawn in the icon's 24x24 space by DRAW, given the Graphics, and
# this returns how much of each pixel of a SIZE x SIZE icon they cover, from 0
# to 1. GDI+ antialiases thin lines poorly, so they're drawn 8x larger and
# averaged down, or less for big sizes, where it matters less. Raising coverage
# to a power below 1 strengthens faint edge pixels, so thin lines read as solid
# rather than dotted.
function Get-Coverage([int] $size, [scriptblock] $draw, [double] $power = 1.0) {
    $k = if ($size -le 32) { 8 } else { [Math]::Max(1, [Math]::Floor(256 / $size)) }
    $n = $size * $k
    $bmp = New-Object System.Drawing.Bitmap $n, $n, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    # Pixel edges at whole coordinates, not pixel centres, so nothing shifts
    # by half a pixel.
    $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::Half
    $g.ScaleTransform($n / 24, $n / 24)
    & $draw $g
    $g.Dispose()

    $data = $bmp.LockBits((New-Object System.Drawing.Rectangle 0, 0, $n, $n), 'ReadOnly', $bmp.PixelFormat)
    $bytes = New-Object byte[] ($data.Stride * $n)
    [System.Runtime.InteropServices.Marshal]::Copy($data.Scan0, $bytes, 0, $bytes.Length)
    $bmp.UnlockBits($data)
    $bmp.Dispose()

    $coverage = New-Object double[] ($size * $size)
    for ($y = 0; $y -lt $n; $y++) {
        $row = $y * $data.Stride
        $out = [Math]::Floor($y / $k) * $size
        for ($x = 0; $x -lt $n; $x++) {
            $coverage[$out + [Math]::Floor($x / $k)] += $bytes[$row + $x * 4 + 3]
        }
    }
    for ($i = 0; $i -lt $coverage.Length; $i++) {
        # 1.0, not 1: PowerShell would pick Math.Min(int, int) and round.
        $coverage[$i] = [Math]::Pow([Math]::Min(1.0, $coverage[$i] / (255 * $k * $k)), $power)
    }
    , $coverage
}

# A round-capped pen for the shapes. The coordinates passed to Graphics must be
# floats: given doubles, PowerShell picks the Int32 overloads and rounds them,
# which knocks shapes off centre.
function New-Pen([float] $width) {
    $pen = New-Object System.Drawing.Pen ([System.Drawing.Color]::White), $width
    $pen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
    $pen.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
    $pen.LineJoin = [System.Drawing.Drawing2D.LineJoin]::Round
    $pen
}

# How far the globe's equator, and the badge, tilt from level, like the Earth's
# axis.
$Tilt = 23.5

function Get-GlobeCoverage([int] $size) {
    Get-Coverage $size {
        param($g)
        # Lines 1.25px wide at 100% scaling (16px), 1.875px at 150% and so on:
        # a touch bolder than the 1px of Windows' own notification area icons,
        # which are hand-fitted to the pixel grid where this isn't. The circle
        # shrinks to keep its outer edge at the icon's edge.
        [float] $stroke = 1.875
        [float] $r = 12 - $stroke / 2
        [float] $m = 5.5  # the meridians' half-width
        $pen = New-Pen $stroke
        $g.DrawEllipse($pen, [float] (12 - $r), [float] (12 - $r), [float] (2 * $r), [float] (2 * $r))
        $g.TranslateTransform(12, 12)
        $g.RotateTransform(-$Tilt)
        $g.DrawLine($pen, [float] -$r, [float] 0, $r, [float] 0)
        $g.DrawEllipse($pen, [float] -$m, [float] -$r, [float] (2 * $m), [float] (2 * $r))
    } 0.7
}

# The badge: a pill tilted like the equator, touching the icon's bottom and
# right edges, and a 1px gap around it cut out of the globe so the two don't
# run together. The gap falls outside the icon on the bottom and right, so it
# takes up no room there.
$BadgeW = 9; $BadgeH = 4.5  # 6x3px at 16px
# The pill grown by GROW on every side: a line with round caps, as thick as
# the pill is tall, between ends that are HALF apart from its centre on each
# axis. The centre is placed so the pill's lowest and rightmost points just
# reach the icon's edges.
function Get-BadgeCoverage([int] $size, [double] $grow = 0) {
    $draw = {
        param($g)
        $r = $BadgeH / 2
        $a = $Tilt * [Math]::PI / 180
        $half = ($BadgeW - $BadgeH) / 2
        $dx = $half * [Math]::Cos($a)
        $dy = $half * [Math]::Sin($a)
        $cx = 24 - $dx - $r
        $cy = 24 - $dy - $r
        # Rising to the right, like the equator.
        $g.DrawLine((New-Pen ($BadgeH + 2 * $grow)), [float] ($cx - $dx), [float] ($cy + $dy), [float] ($cx + $dx), [float] ($cy - $dy))
    }
    # Get-Coverage runs DRAW from inside itself, so DRAW sees $grow through
    # PowerShell's dynamic scoping. A closure would hide the script's variables
    # (such as $BadgeH) when NovacoreTray.exe runs the script.
    Get-Coverage $size $draw
}

# The globe's colour, and each status's badge colour, on dark and light
# taskbars: jonbp.co.uk's palette in its dark and light themes. The globe is
# the site's text colour; running is Novacore's own accent, neon teal; stopped
# is the secondary text colour; busy and error are neon yellow and neon red.
$script:themes = @{
    Dark = @{
        Foreground = '#FFFFFF'  # --c-copy
        Running    = '#17D4A4'  # --c-neon-teal
        Stopped    = '#768087'  # --c-copy-secondary
        Busy       = '#FEC82C'  # --c-neon-yellow
        Error      = '#FE2C62'  # --c-neon-red
    }
    Light = @{
        Foreground = '#0B0B13'
        Running    = '#009672'
        Stopped    = '#58626A'
        Busy       = '#C48C00'
        Error      = '#DE184C'
    }
}

# Whether the taskbar is light, so the globe should be black. Windows 10 before
# 1903 has no setting, and a dark taskbar.
function Test-LightTaskbar {
    try {
        (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -Name SystemUsesLightTheme -ErrorAction Stop).SystemUsesLightTheme -eq 1
    } catch { $false }
}

# Paint the TOP colour over BOTTOM, both [a, r, g, b] from 0 to 1.
function Join-Colors([double[]] $bottom, [double[]] $top) {
    $a = $top[0] + $bottom[0] * (1 - $top[0])
    if ($a -le 0) { return , [double[]] @(0, 0, 0, 0) }
    $out = [double[]] @($a, 0, 0, 0)
    for ($c = 1; $c -le 3; $c++) {
        $out[$c] = ($top[$c] * $top[0] + $bottom[$c] * $bottom[0] * (1 - $top[0])) / $a
    }
    , $out
}

function Get-Rgb([string] $hex) {
    $color = [System.Drawing.ColorTranslator]::FromHtml($hex)
    , [double[]] @(($color.R / 255), ($color.G / 255), ($color.B / 255))
}

# The globe's and badge's coverage at SIZE, worked out once per size.
$script:shapes = @{}
function Get-Shapes([int] $size) {
    if (-not $script:shapes[$size]) {
        $script:shapes[$size] = @{
            Globe = Get-GlobeCoverage $size
            Badge = Get-BadgeCoverage $size
            # 24 / size: one pixel, in the icon's 24x24 space.
            Cut   = Get-BadgeCoverage $size (24 / $size)
        }
    }
    $script:shapes[$size]
}

# A SIZE x SIZE bitmap of the globe in FOREGROUND, with a badge in BADGECOLOR
# if given.
function New-NovacoreBitmap([int] $size, [string] $foreground, [string] $badgeColor = '') {
    $shapes = Get-Shapes $size
    $fg = Get-Rgb $foreground
    $status = [bool] $badgeColor
    if ($status) { $fill = Get-Rgb $badgeColor }
    # BGRA, as a 32bpp ARGB bitmap keeps it in memory.
    $bytes = New-Object byte[] ($size * $size * 4)
    for ($i = 0; $i -lt $size * $size; $i++) {
        $globe = $shapes.Globe[$i]
        if ($status) { $globe *= 1 - $shapes.Cut[$i] }
        $px = [double[]] @($globe, $fg[0], $fg[1], $fg[2])
        if ($status) {
            $px = Join-Colors $px @($shapes.Badge[$i], $fill[0], $fill[1], $fill[2])
        }
        $bytes[$i * 4] = [Math]::Round(255 * $px[3])
        $bytes[$i * 4 + 1] = [Math]::Round(255 * $px[2])
        $bytes[$i * 4 + 2] = [Math]::Round(255 * $px[1])
        $bytes[$i * 4 + 3] = [Math]::Round(255 * $px[0])
    }
    $bmp = New-Object System.Drawing.Bitmap $size, $size, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $data = $bmp.LockBits((New-Object System.Drawing.Rectangle 0, 0, $size, $size), 'WriteOnly', $bmp.PixelFormat)
    for ($y = 0; $y -lt $size; $y++) {
        [System.Runtime.InteropServices.Marshal]::Copy($bytes, $y * $size * 4, [IntPtr] ($data.Scan0.ToInt64() + $y * $data.Stride), $size * 4)
    }
    $bmp.UnlockBits($data)
    $bmp
}

# The same as an icon, at the size of the notification area's icons: 16px at
# 100% scaling, 24px at 150% and so on.
$script:iconSize = [System.Windows.Forms.SystemInformation]::SmallIconSize.Width
function New-NovacoreIcon([string] $foreground, [string] $badgeColor = '') {
    $bmp = New-NovacoreBitmap $script:iconSize $foreground $badgeColor
    [System.Drawing.Icon]::FromHandle($bmp.GetHicon())
}

# Novacore's project icon, for the app itself: its program, notifications
# and windows. It's novacore.ico, next to this script, rendered from
# novacore.svg by build-icon.sh. Each of its images is a PNG.
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
    $theme = $script:themes[$(if ($light) { 'Light' } else { 'Dark' })]
    $old = $script:icons
    $script:icons = @{}
    foreach ($status in 'Running', 'Stopped', 'Busy', 'Error') {
        $script:icons[$status] = New-NovacoreIcon $theme.Foreground $theme[$status]
    }
    if ($script:notify) { Update-View }
    if ($old) { $old.Values | ForEach-Object { $_.Dispose() } }
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
    if ($PSCommandPath -ne (Join-Path $script:appDir 'novacore-tray.ps1')) { return $false }
    if ([System.Diagnostics.Process]::GetCurrentProcess().ProcessName -eq 'NovacoreTray') { return $false }
    $exe = Join-Path $script:appDir 'NovacoreTray.exe'
    $cs = Join-Path $script:appDir 'NovacoreTray.cs'
    # The source, noting the icon's hash, so a new icon rebuilds it too.
    $source = $LauncherSource
    $hasIcon = Test-Path -LiteralPath $script:appIcon
    if ($hasIcon) { $source += "`n// Icon: $((Get-FileHash -LiteralPath $script:appIcon -Algorithm SHA256).Hash)`n" }
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
    $psi.Arguments = ($Arguments | ForEach-Object { ConvertTo-Arg $_ }) -join ' '
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
    [void] (Start-WslJob (Get-NovacoreArgs @('status', '--json')) {
        param($job)
        $script:refreshing = $false
        $script:asleep = $false
        if ($job.ExitCode -ne 0) {
            $script:problem = Get-JobError $job
        } else {
            try {
                $json = $job.Out -join "`n"
                $script:status = $json | ConvertFrom-Json
                $script:statusJson = $json
                $script:problem = ''
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

# Replace this script and its icon with the repo's copies when they have
# changed, e.g. after a git pull, and restart into it. It runs after a
# successful status check, while WSL is up anyway, so reading the repo doesn't
# start WSL. The repo is where the CLI is: <repo>/bin/novacore.
function Update-Self {
    # Only the installed copy, not one run from elsewhere, e.g. the repo itself.
    $installed = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Novacore\novacore-tray.ps1'
    if ($PSCommandPath -ne $installed) { return }
    if ($script:lastUpdateCheck -and ((Get-Date) - $script:lastUpdateCheck).TotalSeconds -lt 60) { return }
    # Restarting would close the menu or a dialog in use, so wait for a quiet
    # moment. A running command is fine to leave: it runs on its own in WSL.
    if ($script:menu.Visible -or [System.Windows.Forms.Application]::OpenForms.Count -gt 0) { return }
    $script:lastUpdateCheck = Get-Date

    $source = Get-WindowsPath (($Command -replace '/bin/[^/]+$', '') + '/windows/novacore-tray.ps1')
    if (-not (Test-Path -LiteralPath $source)) { return }
    $new = (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash
    $scriptChanged = $new -ne (Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash
    # And its icon, which NovacoreTray.exe is built with.
    $sourceIcon = Join-Path (Split-Path $source) 'novacore.ico'
    $iconChanged = (Test-Path -LiteralPath $sourceIcon) -and (
        -not (Test-Path -LiteralPath $script:appIcon) -or
        (Get-FileHash -LiteralPath $sourceIcon -Algorithm SHA256).Hash -ne (Get-FileHash -LiteralPath $script:appIcon -Algorithm SHA256).Hash)
    if (-not $scriptChanged -and -not $iconChanged) { return }

    if ($scriptChanged) {
        if ($new -eq $script:skippedUpdate) { return }
        # Don't swap in a script that won't run, e.g. one saved mid-edit.
        $errors = $null
        [void] [System.Management.Automation.Language.Parser]::ParseFile($source, [ref] $null, [ref] $errors)
        if ($errors) {
            $script:skippedUpdate = $new
            Show-Problem "Not updating the tray icon: windows/novacore-tray.ps1 has errors. $($errors[0])"
            return
        }
        Copy-Item -LiteralPath $source -Destination $PSCommandPath -Force
    }
    if ($iconChanged) { Copy-Item -LiteralPath $sourceIcon -Destination $script:appIcon -Force }
    # Let the new one take the single-instance lock, then hand over to it.
    $script:mutex.ReleaseMutex()
    $script:mutex.Dispose()
    $arguments = "--headless powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden " +
        "-File `"$PSCommandPath`" -Distro `"$Distro`" -Command `"$Command`" -RefreshInterval $RefreshInterval -Updated"
    Start-Process (Join-Path $env:WINDIR 'System32\conhost.exe') -ArgumentList $arguments
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
            Show-Balloon 'Novacore' $(if ($done) { $done } else { "Done: $(Get-ActionName $label)" }) 'Info' -Url $script:actionUrl
        } else {
            # novacore's own error message starts with a heavy cross.
            $message = @($log | Where-Object { $_ -match '^\s*\u2716' }) | Select-Object -Last 1
            if (-not $message) { $message = @($log | Where-Object { $_.Trim() }) | Select-Object -Last 1 }
            if ($exit -eq '') { $message = 'novacore stopped before it finished.' }
            elseif (-not $message) { $message = "novacore exited with code $exit" }
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

function Get-StatusText {
    if ($script:busy) { return $script:busyLabel }
    if ($script:problem) { return "Can't run novacore" }
    if ($script:asleep) { return "WSL isn't running" }
    if (-not $script:status) { return "Checking$Ellipsis" }
    if (-not $script:status.running) { return 'Stopped' }
    $n = @($script:status.sites).Count
    if ($n -eq 1) { 'Running, 1 site' } else { "Running, $n sites" }
}

function Test-Running {
    $script:status -and $script:status.running -and -not $script:asleep
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

function Update-Menu {
    $items = $script:menu.Items
    $old = @($items)
    $items.Clear()
    $old | ForEach-Object { $_.Dispose() }

    $running = Test-Running
    $stopped = $script:status -and -not $script:status.running -and -not $script:asleep
    $idle = -not $script:busy

    [void] (Add-MenuItem $items "Novacore $MiddleDot $(Get-StatusText)" -Enabled $false)
    if ($script:problem) {
        $text = $script:problem
        if ($text.Length -gt 80) { $text = $text.Substring(0, 79) + $Ellipsis }
        [void] (Add-MenuItem $items $text -Enabled $false)
    }
    Add-Separator $items

    $dashboard = 'https://localhost'
    if ($script:status -and $script:status.dashboard) { $dashboard = $script:status.dashboard }
    [void] (Add-MenuItem $items 'Open Dashboard' @{ Action = 'url'; Url = $dashboard } -Enabled (-not $stopped) -Bold)

    # The last sites we heard of, even while WSL sleeps: Docker Desktop may
    # still be serving them.
    $sites = @(if ($script:status) { $script:status.sites })
    if ($sites.Count) {
        Add-Separator $items
        foreach ($site in $sites) {
            $item = Add-MenuItem $items $site.name
            $sub = $item.DropDownItems
            [void] (Add-MenuItem $sub "Open $($site.url -replace '^https?://', '')" @{ Action = 'url'; Url = $site.url } -Bold)
            [void] (Add-MenuItem $sub "Info$Ellipsis" @{ Action = 'info'; Site = $site.name })
            Add-Separator $sub
            [void] (Add-MenuItem $sub 'Open Folder' @{ Action = 'folder'; Path = $site.path })
            if ($script:code) { [void] (Add-MenuItem $sub 'Open in VS Code' @{ Action = 'code'; Path = $site.path }) }
            [void] (Add-MenuItem $sub 'Open Terminal' @{ Action = 'terminal'; Path = $site.path; Title = $site.name })
            [void] (Add-MenuItem $sub 'PHP Shell' @{ Action = 'cli'; Args = @('shell', $site.name); Title = "$($site.name) $MiddleDot PHP shell" } -Enabled $running)
            [void] (Add-MenuItem $sub 'Follow Error Log' @{ Action = 'cli'; Args = @('errors', $site.name); Title = "$($site.name) $MiddleDot error log" })
            Add-Separator $sub
            foreach ($version in $script:status.phpVersions) {
                $php = Add-MenuItem $sub "PHP $version" @{ Action = 'php'; Site = $site.name; Version = $version } -Enabled $idle
                $php.Checked = $version -eq $site.php
            }
            Add-Separator $sub
            [void] (Add-MenuItem $sub "Remove$Ellipsis" @{ Action = 'remove'; Site = $site.name } -Enabled $idle)
        }
    } elseif ($script:status -and -not $script:problem) {
        Add-Separator $items
        [void] (Add-MenuItem $items 'No sites yet' -Enabled $false)
    }
    if ($script:status -and -not $script:problem) {
        if (-not $sites.Count) { Add-Separator $items }
        [void] (Add-MenuItem $items "Add Site$Ellipsis" @{ Action = 'add' } -Enabled $idle)
    }

    Add-Separator $items
    if ($running) {
        [void] (Add-MenuItem $items 'Stop Novacore' @{ Action = 'down' } -Enabled $idle)
        [void] (Add-MenuItem $items 'Restart Novacore' @{ Action = 'restart' } -Enabled $idle)
    } else {
        [void] (Add-MenuItem $items 'Start Novacore' @{ Action = 'up' } -Enabled $idle)
    }

    if ($script:status -and -not $script:problem) {
        # novacore xdebug's modes; "on" is develop,debug.
        $xdebug = Add-MenuItem $items 'Xdebug'
        $sub = $xdebug.DropDownItems
        foreach ($mode in @(
            @('off', 'Off'), @('develop,debug', 'On (develop, debug)'), $null,
            @('debug', 'Debug only'), @('develop', 'Develop only'), @('profile', 'Profile'), @('trace', 'Trace'), @('coverage', 'Coverage'))) {
            if (-not $mode) { Add-Separator $sub; continue }
            $item = Add-MenuItem $sub $mode[1] @{ Action = 'xdebug'; Mode = $mode[0]; Name = $mode[1] } -Enabled $idle
            $item.Checked = $script:status.xdebug -eq $mode[0]
        }
        if (@('off', 'develop,debug', 'debug', 'develop', 'profile', 'trace', 'coverage') -notcontains $script:status.xdebug) {
            Add-Separator $sub
            $item = Add-MenuItem $sub $script:status.xdebug -Enabled $false
            $item.Checked = $true
        }

        $tools = Add-MenuItem $items 'Tools'
        $sub = $tools.DropDownItems
        [void] (Add-MenuItem $sub 'Database Shell' @{ Action = 'cli'; Args = @('db', 'shell'); Title = "Novacore $MiddleDot database" } -Enabled $running)
        [void] (Add-MenuItem $sub 'Container Logs' @{ Action = 'cli'; Args = @('logs'); Title = "Novacore $MiddleDot logs" })
        [void] (Add-MenuItem $sub 'Open Sites Folder' @{ Action = 'folder'; Path = $script:status.sitesPath })
    }
    [void] (Add-MenuItem $items "Show Output$Ellipsis" @{ Action = 'output' } -Enabled ($script:output.Count -gt 0))
    [void] (Add-MenuItem $items 'Refresh' @{ Action = 'refresh' } -Enabled $idle)
    Add-Separator $items
    [void] (Add-MenuItem $items 'Quit' @{ Action = 'quit' })
}

# Bring the icon, tooltip and menu up to date.
function Update-View {
    $icon = if ($script:busy) { 'Busy' }
        elseif ($script:problem) { 'Error' }
        elseif (Test-Running) { 'Running' }
        else { 'Stopped' }
    $script:notify.Icon = $script:icons[$icon]

    # The tooltip can't be longer than 63 characters.
    $tip = "Novacore`n$(Get-StatusText)"
    if ($tip.Length -gt 63) { $tip = $tip.Substring(0, 62) + $Ellipsis }
    $script:notify.Text = $tip

    # Rebuilding the menu closes its open submenus, so only do it on a change.
    $signature = "$($script:busy)|$($script:busyLabel)|$($script:problem)|$($script:asleep)|$($script:output.Count -gt 0)|$($script:statusJson)"
    if ($signature -ne $script:menuSignature) {
        $script:menuSignature = $signature
        Update-Menu
    }
}

function Invoke-MenuAction($tag) {
    switch ($tag.Action) {
        'url' { Start-Process $tag.Url }
        'folder' { Start-Process explorer.exe "`"$(Get-WindowsPath $tag.Path)`"" }
        'up' { Start-Action @('up') "Starting Novacore$Ellipsis" 'Novacore is running' }
        'down' { Start-Action @('down') "Stopping Novacore$Ellipsis" 'Novacore has stopped' }
        'restart' { Start-Action @('restart') "Restarting Novacore$Ellipsis" 'Novacore has restarted' }
        'php' {
            $site = @($script:status.sites | Where-Object { $_.name -eq $tag.Site })[0]
            if ($site -and $site.php -eq $tag.Version) { return }
            $label = if (@($script:status.builtPhp) -contains $tag.Version) {
                "Switching $($tag.Site) to PHP $($tag.Version)$Ellipsis"
            } else {
                "Building PHP $($tag.Version)$Ellipsis"
            }
            Start-Action @('php', $tag.Site, $tag.Version) $label "$($tag.Site) now uses PHP $($tag.Version)"
        }
        'xdebug' { Start-Action @('xdebug', $tag.Mode) "Setting Xdebug to $($tag.Name)$Ellipsis" "Xdebug is now $($tag.Name)" }
        'add' { Show-AddSite }
        'remove' { Show-RemoveSite $tag.Site }
        'info' { Show-SiteInfo $tag.Site }
        'code' { Start-Process $script:code -ArgumentList "--remote wsl+$Distro `"$($tag.Path)`"" -WindowStyle Hidden }
        'terminal' { Start-Terminal $tag.Title @('--cd', $tag.Path) }
        'cli' { Start-Terminal $tag.Title (@('-e', $Command) + $tag.Args) }
        'output' { Show-Output }
        'refresh' { Update-Status -Wake }
        'quit' {
            $script:notify.Visible = $false
            $script:notify.Dispose()
            if ($script:outputForm) { $script:outputForm.Close() }
            $script:context.ExitThread()
        }
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
    if (-not $script:outputForm) {
        $g = [System.Drawing.Graphics]::FromHwnd([IntPtr]::Zero)
        $scale = $g.DpiX / 96
        $g.Dispose()

        $form = New-Object System.Windows.Forms.Form
        $form.Text = 'Novacore'
        $form.Icon = $script:windowIcon
        $form.StartPosition = 'CenterScreen'
        $form.Size = New-Object System.Drawing.Size ([int] (760 * $scale)), ([int] (440 * $scale))

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
        $line = (@('--title', $Title, 'wsl.exe') + $wsl | ForEach-Object { ConvertTo-Arg $_ }) -join ' '
        Start-Process $script:wt -ArgumentList ($line -replace ';', '\;')
    } else {
        Start-Process (Join-Path $env:WINDIR 'System32\wsl.exe') -ArgumentList (($wsl | ForEach-Object { ConvertTo-Arg $_ }) -join ' ')
    }
}

$script:wt = (Get-Command wt.exe -ErrorAction SilentlyContinue | Select-Object -First 1).Source
$script:code = (Get-Command code.cmd -ErrorAction SilentlyContinue | Select-Object -First 1).Source

# --- Dialogs ------------------------------------------------------------------

$g = [System.Drawing.Graphics]::FromHwnd([IntPtr]::Zero)
$script:scale = $g.DpiX / 96
$g.Dispose()

# N pixels at 96 DPI, scaled for this screen.
function S([double] $n) { [int] [Math]::Round($n * $script:scale) }

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

# A heading across GRID's columns.
function Add-Heading($grid, [string] $text) {
    $label = New-Label $text -Bold
    $label.Margin = New-Object System.Windows.Forms.Padding 0, (S 10), 0, (S 2)
    $row = $grid.RowCount
    $grid.RowCount = $row + 1
    $grid.Controls.Add($label, 0, $row)
    $grid.SetColumnSpan($label, $grid.ColumnCount)
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

# Under Add Site's PHP version, say if it needs building first.
function Update-PhpHint {
    $d = $script:dialog
    $v = $d.Php.SelectedItem
    $built = @($script:status.builtPhp) -contains $v
    $d.PhpHint.Text = "PHP $v needs building first, which takes a few minutes."
    $d.PhpHint.Visible = -not $built
}

# Ask for a new site's details, then add it with novacore site add.
function Show-AddSite {
    $s = $script:status
    $form = New-Dialog 'Add Site'
    $grid = New-Grid 2

    $name = New-Object System.Windows.Forms.TextBox
    $name.Width = S 260
    $name.CharacterCasing = 'Lower'
    $nameHint = New-Label ' ' -Hint
    Add-Row $grid @((New-Label 'Name'), $name)
    Add-Row $grid @($null, $nameHint)

    $php = New-Object System.Windows.Forms.ComboBox
    $php.DropDownStyle = 'DropDownList'
    $php.Width = S 100
    foreach ($v in $s.phpVersions) { [void] $php.Items.Add($v) }
    $php.SelectedItem = $s.defaultPhp
    $phpHint = New-Label ' ' -Hint
    Add-Row $grid @((New-Label 'PHP'), $php)
    Add-Row $grid @($null, $phpHint)

    $root = New-Object System.Windows.Forms.ComboBox
    $root.Width = S 160
    foreach ($r in 'Auto-detect', 'public', 'web', 'public_html', 'htdocs') { [void] $root.Items.Add($r) }
    $root.SelectedIndex = 0
    Add-Row $grid @((New-Label 'Document root'), $root)
    Add-Row $grid @($null, (New-Label 'Auto-detect looks for public, web, public_html or htdocs.' -Hint))

    $db = New-Object System.Windows.Forms.CheckBox
    $db.Text = 'Create a database'
    $db.AutoSize = $true
    $db.Checked = $true
    if (-not (Test-Running)) {
        $db.Checked = $false
        $db.Enabled = $false
        $db.Text = "Create a database (start Novacore first)"
    }
    Add-Row $grid @($null, $db)

    $add = New-Button 'Add' ([System.Windows.Forms.DialogResult]::OK)
    $add.Enabled = $false
    $cancel = New-Button 'Cancel' ([System.Windows.Forms.DialogResult]::Cancel)
    Set-DialogContent $form $grid @($cancel, $add)
    $form.AcceptButton = $add
    $form.CancelButton = $cancel

    $script:dialog = @{ Name = $name; NameHint = $nameHint; Php = $php; PhpHint = $phpHint; Add = $add }
    # The same rules as novacore's check_name.
    $name.add_TextChanged({
        $d = $script:dialog
        $n = $d.Name.Text.Trim()
        $problem = if (-not $n) { '' }
            elseif ($n -cnotmatch '^[a-z0-9]([a-z0-9-]*[a-z0-9])?$') { 'Use letters, numbers and hyphens, not at the start or end.' }
            elseif ($n -eq 'default') { "'default' is a reserved name." }
            elseif (@($script:status.sites | Where-Object { $_.name -eq $n }).Count) { "There's already a site called $n." }
            else { '' }
        $d.Add.Enabled = $n -and -not $problem
        $d.NameHint.ForeColor = if ($problem) { [System.Drawing.Color]::Firebrick } else { [System.Drawing.SystemColors]::GrayText }
        $d.NameHint.Text = if ($problem) { $problem } elseif ($n) { "https://$n.$($script:status.tld)" } else { ' ' }
    })
    $php.add_SelectedIndexChanged({ Update-PhpHint })
    Update-PhpHint
    $name.Select()

    $result = $form.ShowDialog()
    $n = $name.Text.Trim()
    $arguments = @('site', 'add', $n, '--php', $php.SelectedItem)
    if ($root.Text.Trim() -and $root.Text -ne 'Auto-detect') { $arguments += @('--root', $root.Text.Trim()) }
    if (-not $db.Checked) { $arguments += '--no-db' }
    $form.Dispose()
    $script:dialog = $null
    if ($result -ne [System.Windows.Forms.DialogResult]::OK) { return }

    $url = "https://$n.$($s.tld)"
    Start-Action $arguments "Adding $n$Ellipsis" "$n is ready at $url" -Url $url
}

# Confirm removing a site, then remove it with novacore site rm.
function Show-RemoveSite([string] $name) {
    $site = @($script:status.sites | Where-Object { $_.name -eq $name })[0]
    if (-not $site) { return }
    $form = New-Dialog "Remove $name"
    $grid = New-Grid 1
    Add-Row $grid @((New-Label "Stop serving $($site.url)?" -Bold))
    $note = New-Label "Its files stay in $($site.path)."
    $note.MaximumSize = New-Object System.Drawing.Size (S 380), 0
    Add-Row $grid @($note)

    $db = New-Object System.Windows.Forms.CheckBox
    $db.Text = "Also delete its database, $($site.database)"
    $db.AutoSize = $true
    $db.Margin = New-Object System.Windows.Forms.Padding 0, (S 8), 0, 0
    if (-not (Test-Running)) {
        $db.Enabled = $false
        $db.Text += ' (start Novacore first)'
    }
    Add-Row $grid @($db)

    $remove = New-Button 'Remove' ([System.Windows.Forms.DialogResult]::OK)
    $cancel = New-Button 'Cancel' ([System.Windows.Forms.DialogResult]::Cancel)
    Set-DialogContent $form $grid @($cancel, $remove)
    $form.AcceptButton = $remove
    $form.CancelButton = $cancel
    $form.add_Shown({ $this.CancelButton.Select() })

    $result = $form.ShowDialog()
    $dropDb = $db.Checked
    $form.Dispose()
    if ($result -ne [System.Windows.Forms.DialogResult]::OK) { return }
    $arguments = @('site', 'rm', $name)
    if ($dropDb) { $arguments += '--drop-db' }
    Start-Action $arguments "Removing $name$Ellipsis" "Removed $name. Its files are still in $($site.path)"
}

# A site's details, like novacore site info, each with a Copy button.
function Show-SiteInfo([string] $name) {
    if ($script:infoForms[$name]) { $script:infoForms[$name].Activate(); return }
    $site = @($script:status.sites | Where-Object { $_.name -eq $name })[0]
    if (-not $site) { return }
    $db = $script:status.db

    $form = New-Dialog $name
    $form.Tag = $name
    $grid = New-Grid 3
    $rows = @(
        'Site',
        @('URL', $site.url),
        @('PHP', $site.php),
        @('Folder', $site.path),
        @('In Windows', (Get-WindowsPath $site.path)),
        @('Document root', $(if ($site.root -eq '.') { $site.path } else { "$($site.path)/$($site.root)" })),
        @('Error log', $site.errorLog),
        'Database',
        @('Name', $site.database),
        @('User', $db.user),
        @('Password', $db.password),
        @('Host', $db.host),
        @('Host in Novacore', $db.containerHost),
        'DB_HOST that works in Novacore and on your machine',
        @('wp-config.php', "define( 'DB_HOST', getenv( 'NOVACORE_DB_HOST' ) ?: '$($db.host)' );"),
        @('Bedrock', "Config::define( 'DB_HOST', env( 'NOVACORE_DB_HOST' ) ?: env( 'DB_HOST' ) ?: '$($db.host)' );"),
        @('Laravel', "'host' => env( 'NOVACORE_DB_HOST', env( 'DB_HOST', '127.0.0.1' ) ),")
    )
    foreach ($row in $rows) {
        if ($row -is [string]) { Add-Heading $grid $row; continue }
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

    $open = New-Button 'Open Site'
    $open.Tag = $site.url
    $open.add_Click({ Start-Process $this.Tag })
    $folder = New-Button 'Open Folder'
    $folder.Tag = Get-WindowsPath $site.path
    $folder.add_Click({ Start-Process explorer.exe "`"$($this.Tag)`"" })
    $close = New-Button 'Close'
    $close.add_Click({ $this.FindForm().Close() })
    Set-DialogContent $form $grid @($close, $folder, $open)
    $form.CancelButton = $close
    $form.ActiveControl = $close
    $form.add_FormClosed({ $script:infoForms.Remove($this.Tag) })

    $script:infoForms[$name] = $form
    $form.Show()
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

$script:notify = New-Object System.Windows.Forms.NotifyIcon
$script:notify.ContextMenuStrip = $script:menu
# Show the menu on a left click too, as it's all there is.
$script:notify.add_MouseUp({
    param($sender, $e)
    if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
        $show = [System.Windows.Forms.NotifyIcon].GetMethod('ShowContextMenu', [System.Reflection.BindingFlags] 'Instance, NonPublic')
        [void] $show.Invoke($script:notify, $null)
    }
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

# Follow the taskbar between light and dark.
$theme = New-Object System.Windows.Forms.Timer
$theme.Interval = 2000
$theme.add_Tick({ Invoke-Safely { [void] (Update-Icons) } })
$theme.Start()

Update-View
$script:notify.Visible = $true
if ($Updated) { Show-Balloon 'Novacore' 'The tray icon has been updated.' 'Info' }
Update-Status

$script:context = New-Object System.Windows.Forms.ApplicationContext
[System.Windows.Forms.Application]::Run($script:context)
