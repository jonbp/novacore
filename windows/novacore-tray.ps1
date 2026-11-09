<#
    Novacore's icon in the Windows notification area, for when Novacore runs
    in WSL. It's the Windows counterpart of the Plasma widget in plasmoid/:
    it shows whether the stack is running, lists the sites, and starts, stops
    and switches PHP versions by running the novacore CLI through wsl.exe.

    `novacore tray install`, run inside WSL, copies this script to
    %LOCALAPPDATA%\Novacore and starts it from a shortcut in the Startup folder.
    The file is kept ASCII-only, as Windows PowerShell 5.1 reads scripts
    without a BOM as ANSI.
#>
param(
    # The WSL distro Novacore lives in, e.g. Ubuntu.
    [Parameter(Mandatory = $true)] [string] $Distro,
    # The absolute path of the novacore CLI inside the distro.
    [Parameter(Mandatory = $true)] [string] $Command,
    [int] $RefreshInterval = 30
)

$ErrorActionPreference = 'Stop'

# One tray icon at a time.
$created = $false
$script:mutex = New-Object System.Threading.Mutex($true, 'Local\NovacoreTray', [ref] $created)
if (-not $created) { exit }

Add-Type -AssemblyName System.Windows.Forms, System.Drawing
Add-Type -Namespace Novacore -Name Native -MemberDefinition '
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
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
$script:outputForm = $null
$script:outputBox = $null
$script:outputShown = -1

# --- Icon ---------------------------------------------------------------------

# The globe from Novacore's link in the Open Source nav on jonbp.co.uk, a
# 24x24 icon: a circle, and the equator and two meridians tilted like the
# Earth's axis. The full logo, with its square, is too detailed for 16px.
#
# How much of each pixel of a SIZE x SIZE icon the globe covers, from 0 to 1.
# GDI+ antialiases thin lines poorly, so the globe is drawn 8x larger and
# averaged down, and faint edge pixels are then strengthened a little so the
# lines read as solid rather than dotted.
function Get-GlobeCoverage([int] $size) {
    $k = 8
    $n = $size * $k
    $bmp = New-Object System.Drawing.Bitmap $n, $n, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    # Pixel edges at whole coordinates, not pixel centres, so nothing shifts
    # by half a pixel.
    $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::Half
    $g.ScaleTransform($n / 24, $n / 24)
    # A little bolder than the site's 2, to hold up at 16px. The circle shrinks
    # to keep its outer edge at the icon's edge.
    [float] $stroke = 2.5
    [float] $r = 12 - $stroke / 2
    [float] $m = 5.5  # the meridians' half-width
    $pen = New-Object System.Drawing.Pen ([System.Drawing.Color]::White), $stroke
    # The coordinates must be floats: given doubles, PowerShell picks the Int32
    # overloads and rounds them, which knocks the globe off centre.
    $g.DrawEllipse($pen, [float] (12 - $r), [float] (12 - $r), [float] (2 * $r), [float] (2 * $r))
    $g.TranslateTransform(12, 12)
    $g.RotateTransform(-23.5)
    $g.DrawLine($pen, [float] -$r, [float] 0, $r, [float] 0)
    $g.DrawEllipse($pen, [float] -$m, [float] -$r, [float] (2 * $m), [float] (2 * $r))
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
        $coverage[$i] = [Math]::Pow([Math]::Min(1.0, $coverage[$i] / (255 * $k * $k)), 0.7)
    }
    , $coverage
}

# The globe in COLOR, at the size of the notification area's icons: 16px at
# 100% scaling, 24px at 150% and so on.
function New-NovacoreIcon([double[]] $coverage, [string] $hex) {
    $color = [System.Drawing.ColorTranslator]::FromHtml($hex)
    $size = [int] [Math]::Sqrt($coverage.Length)
    $bmp = New-Object System.Drawing.Bitmap $size, $size
    for ($i = 0; $i -lt $coverage.Length; $i++) {
        $alpha = [int] [Math]::Round(255 * $coverage[$i])
        $bmp.SetPixel($i % $size, [Math]::Floor($i / $size), [System.Drawing.Color]::FromArgb($alpha, $color))
    }
    [System.Drawing.Icon]::FromHandle($bmp.GetHicon())
}

$globe = Get-GlobeCoverage ([System.Windows.Forms.SystemInformation]::SmallIconSize.Width)
$script:icons = @{
    Running = New-NovacoreIcon $globe '#17D4A4'  # the dashboard's teal
    Stopped = New-NovacoreIcon $globe '#9AA0A6'
    Busy    = New-NovacoreIcon $globe '#F0B429'
    Error   = New-NovacoreIcon $globe '#E5534B'
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
    })
}

# Run a novacore command that changes something, such as up or php. It runs
# detached in WSL (see `novacore tray run`), so it finishes even if this
# script stops meanwhile, and Update-Action follows it from there.
function Start-Action([string[]] $Arguments, [string] $Label, [string] $DoneText) {
    if ($script:busy) { return }
    $script:busy = $true
    $script:busyLabel = $Label
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
            Show-Balloon 'Novacore' $(if ($done) { $done } else { "Done: $(Get-ActionName $label)" }) 'Info'
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

# A notification. Clicking one with SHOWSOUTPUT opens the output window.
function Show-Balloon([string] $title, [string] $text, [string] $icon, [switch] $ShowsOutput) {
    if (-not $text) { $text = ' ' }  # NotifyIcon refuses empty text.
    $script:balloonShowsOutput = [bool] $ShowsOutput
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
            [void] (Add-MenuItem $sub 'Open Folder' @{ Action = 'folder'; Path = $site.path })
            Add-Separator $sub
            foreach ($version in $script:status.phpVersions) {
                $php = Add-MenuItem $sub "PHP $version" @{ Action = 'php'; Site = $site.name; Version = $version } -Enabled $idle
                $php.Checked = $version -eq $site.php
            }
        }
    } elseif ($script:status -and -not $script:problem) {
        Add-Separator $items
        [void] (Add-MenuItem $items 'No sites yet' -Enabled $false)
    }

    Add-Separator $items
    if ($running) {
        [void] (Add-MenuItem $items 'Stop Novacore' @{ Action = 'down' } -Enabled $idle)
        [void] (Add-MenuItem $items 'Restart Novacore' @{ Action = 'restart' } -Enabled $idle)
    } else {
        [void] (Add-MenuItem $items 'Start Novacore' @{ Action = 'up' } -Enabled $idle)
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
        'folder' {
            $path = "\\wsl.localhost\$Distro" + ($tag.Path -replace '/', '\')
            Start-Process explorer.exe "`"$path`""
        }
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
        $form.Icon = $script:icons.Running
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

# --- Main ---------------------------------------------------------------------

# Event handlers that throw would otherwise stop the whole tray icon.
function Invoke-Safely([scriptblock] $block) {
    try { & $block } catch { Show-Problem $_ }
}

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
$script:notify.add_BalloonTipClicked({ if ($script:balloonShowsOutput) { Invoke-Safely { Show-Output } } })

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

Update-View
$script:notify.Visible = $true
Update-Status

$script:context = New-Object System.Windows.Forms.ApplicationContext
[System.Windows.Forms.Application]::Run($script:context)
