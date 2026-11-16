# Matrix screensaver after 5 idle minutes ($IdleMinutes below) on Windows 10/11, for the user who runs this. No admin needed.
#
#   powershell -ExecutionPolicy Bypass -File install.ps1            install or update
#   powershell -ExecutionPolicy Bypass -File install.ps1 -Remove    undo
#
# Sets Matrix.scr as the screen saver. Matrix.scr is the 3D rain built from
# matrix-rain.c (./build.sh), taken from next to this script.
# Without that file a simpler 2D rain is built on the spot instead: the C# below, compiled with the compiler
# that is part of Windows (.NET Framework 4).
# On mains power, screen-off and sleep that would come within 10 minutes of the screensaver starting are moved
# to 30 minutes after it, or the screen would go dark before the screensaver has had its turn. Whether a password is asked afterwards is left as it was.

$ErrorActionPreference = 'Stop'
$IdleMinutes = 5
$dir = Join-Path $env:LOCALAPPDATA 'MatrixScreensaver'
$scr = Join-Path $dir 'Matrix.scr'
$desktop = 'HKCU:\Control Panel\Desktop'

$source = @'
using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Drawing.Text;
using System.Runtime.InteropServices;
using System.Windows.Forms;

static class Program
{
    [DllImport("user32.dll")]
    static extern bool SetProcessDPIAware();

    [STAThread]
    static void Main(string[] args)
    {
        // Windows starts a screen saver with /s to run, /p <window> for the small preview, /c to configure
        string mode = args.Length > 0 ? args[0].ToLowerInvariant().TrimStart('/', '-') : "s";
        if (mode.StartsWith("p")) return;
        if (mode.StartsWith("c"))
        {
            MessageBox.Show("Matrix has no settings.", "Matrix");
            return;
        }
        SetProcessDPIAware();
        foreach (Screen screen in Screen.AllScreens) new Rain(screen.Bounds).Show();
        Cursor.Hide();
        Application.Run();
    }
}

class Rain : Form
{
    static readonly Random random = new Random();
    readonly Bitmap canvas;
    readonly Graphics pen;
    readonly Font font;
    readonly string glyphs;
    readonly int cell;
    readonly int[] row;     // per column: the row its falling head is on; negative while waiting to start
    readonly char[] head;   // per column: the glyph drawn at the head, redrawn in green once the head moves on
    readonly Brush fade = new SolidBrush(Color.FromArgb(26, 0, 0, 0));
    readonly Brush green = new SolidBrush(Color.FromArgb(0, 200, 70));
    readonly Brush white = new SolidBrush(Color.FromArgb(200, 255, 215));
    readonly Timer timer = new Timer();
    Point start;
    bool moved;

    public Rain(Rectangle bounds)
    {
        FormBorderStyle = FormBorderStyle.None;
        StartPosition = FormStartPosition.Manual;
        Bounds = bounds;
        TopMost = true;
        ShowInTaskbar = false;
        BackColor = Color.Black;
        DoubleBuffered = true;

        cell = Math.Max(12, bounds.Height / 90);
        font = new Font("MS Gothic", cell * 0.9f, FontStyle.Bold, GraphicsUnit.Pixel);
        glyphs = "0123456789";
        if (font.Name == "MS Gothic")  // has the half-width katakana of the film; without it, digits and letters
            for (char c = '\uFF66'; c <= '\uFF9D'; c++) glyphs += c;
        else
            glyphs += "ABCDEFGHIJKLMNOPQRSTUVWXYZ<>*+=:";

        canvas = new Bitmap(Math.Max(1, bounds.Width), Math.Max(1, bounds.Height), PixelFormat.Format32bppPArgb);
        pen = Graphics.FromImage(canvas);
        pen.Clear(Color.Black);
        pen.TextRenderingHint = TextRenderingHint.AntiAlias;

        int columns = bounds.Width / cell + 1, rows = bounds.Height / cell + 1;
        row = new int[columns];
        head = new char[columns];
        for (int i = 0; i < columns; i++) row[i] = -random.Next(rows);

        timer.Interval = 55;
        timer.Tick += delegate { Step(); };
        timer.Start();
    }

    void Step()
    {
        pen.FillRectangle(fade, 0, 0, canvas.Width, canvas.Height);
        for (int i = 0; i < row.Length; i++)
        {
            int x = i * cell, y = row[i] * cell;
            if (row[i] > 0)
            {
                pen.FillRectangle(Brushes.Black, x, y - cell, cell, cell);
                pen.DrawString(head[i].ToString(), font, green, x, y - cell);
            }
            if (row[i] >= 0)
            {
                head[i] = glyphs[random.Next(glyphs.Length)];
                pen.DrawString(head[i].ToString(), font, white, x, y);
            }
            if (y > canvas.Height && random.Next(100) < 3) row[i] = 0;
            else row[i]++;
        }
        Invalidate();
    }

    protected override void OnPaintBackground(PaintEventArgs e) { }

    protected override void OnPaint(PaintEventArgs e)
    {
        e.Graphics.CompositingMode = CompositingMode.SourceCopy;
        e.Graphics.DrawImageUnscaled(canvas, 0, 0);
    }

    protected override void OnKeyDown(KeyEventArgs e) { Application.Exit(); }

    protected override void OnMouseDown(MouseEventArgs e) { Application.Exit(); }

    protected override void OnMouseMove(MouseEventArgs e)
    {
        // a window gets one mouse-move just for appearing under the pointer, so only real movement counts
        if (!moved) { start = e.Location; moved = true; return; }
        if (Math.Abs(e.X - start.X) > 8 || Math.Abs(e.Y - start.Y) > 8) Application.Exit();
    }
}
'@

Add-Type -Namespace MatrixScreensaver -Name Win32 -MemberDefinition @'
[DllImport("user32.dll", SetLastError = true)]
public static extern bool SystemParametersInfo(uint action, uint param, IntPtr value, uint flags);
'@
function Set-ScreenSaver([bool]$active, [int]$seconds) {
    # tells the running session, so it applies now rather than at the next sign-in; 3 = save and broadcast
    [void][MatrixScreensaver.Win32]::SystemParametersInfo(15, $seconds, [IntPtr]::Zero, 3)  # SPI_SETSCREENSAVETIMEOUT
    [void][MatrixScreensaver.Win32]::SystemParametersInfo(17, [int]$active, [IntPtr]::Zero, 3)  # SPI_SETSCREENSAVEACTIVE
}

# The mains (AC) idle timeout of the current power plan, in seconds: 0 is never, $null if it cannot be read.
function Get-AcTimeout($subgroup, $setting) {
    $values = @(powercfg /query SCHEME_CURRENT $subgroup $setting 2>$null | Select-String '0x[0-9a-fA-F]{8}\s*$')
    if ($values.Count -lt 2) { return $null }  # the last two lines are the AC and then the battery value
    [Convert]::ToInt32(($values[-2].Line -replace '.*(0x[0-9a-fA-F]{8})\s*$', '$1'), 16)
}

$timeouts = @(
    @{ Name = 'monitor-timeout-ac'; Subgroup = 'SUB_VIDEO'; Setting = 'VIDEOIDLE' },
    @{ Name = 'standby-timeout-ac'; Subgroup = 'SUB_SLEEP'; Setting = 'STANDBYIDLE' }
)

if ($args -contains '-Remove') {
    Stop-Process -Name Matrix, MatrixTest -Force -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName MatrixTest -Confirm:$false -ErrorAction SilentlyContinue  # left by test.sh
    Remove-ItemProperty $desktop -Name 'SCRNSAVE.EXE' -ErrorAction SilentlyContinue
    Set-ItemProperty $desktop -Name ScreenSaveActive -Value '0'
    Set-ScreenSaver $false ($IdleMinutes * 60)
    foreach ($t in $timeouts) {
        $saved = Join-Path $dir $t.Name
        if (Test-Path $saved) { powercfg /change $t.Name ([int](Get-Content $saved) / 60) }
    }
    Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host 'Removed: the screen saver is off.'
    return
}

New-Item $dir -ItemType Directory -Force | Out-Null
# matrix-rain.scr is what deploy puts next to this script on the machine, and is used up; Matrix.scr is the
# one in the project folder, for when this script is run from there, and stays.
$upload = if ($PSScriptRoot) { Join-Path $PSScriptRoot 'matrix-rain.scr' }
$project = if ($PSScriptRoot) { Join-Path $PSScriptRoot 'Matrix.scr' }
Stop-Process -Name Matrix -Force -ErrorAction SilentlyContinue
if ($upload -and (Test-Path $upload)) {
    Move-Item $upload $scr -Force
    Write-Host 'Installed the 3D rain.'
} elseif ($project -and (Test-Path $project)) {
    Copy-Item $project $scr -Force
    Write-Host 'Installed the 3D rain.'
} else {
    Write-Host 'No Matrix.scr next to this script: building the simpler 2D rain.'
    $csc = @("$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe", "$env:WINDIR\Microsoft.NET\Framework\v4.0.30319\csc.exe") |
        Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $csc) { throw 'The .NET Framework 4 compiler (csc.exe) was not found under C:\Windows\Microsoft.NET.' }
    $cs = Join-Path $dir 'Matrix.cs'
    Set-Content $cs $source -Encoding UTF8
    $output = & $csc /nologo /target:winexe /optimize+ "/out:$scr" /r:System.Windows.Forms.dll /r:System.Drawing.dll $cs
    if ($LASTEXITCODE -ne 0) { throw "Compiling the screensaver failed:`n$($output -join "`n")" }
    Remove-Item $cs
}

Set-ItemProperty $desktop -Name 'SCRNSAVE.EXE' -Value $scr
Set-ItemProperty $desktop -Name ScreenSaveActive -Value '1'
Set-ItemProperty $desktop -Name ScreenSaveTimeOut -Value ([string]($IdleMinutes * 60))
Set-ScreenSaver $true ($IdleMinutes * 60)

foreach ($t in $timeouts) {
    $now = Get-AcTimeout $t.Subgroup $t.Setting
    if ($now -and $now -lt ($IdleMinutes + 10) * 60) {
        $saved = Join-Path $dir $t.Name
        if (-not (Test-Path $saved)) { Set-Content $saved $now }
        powercfg /change $t.Name ($IdleMinutes + 30)
        Write-Host "$($t.Name): moved from $([int]($now / 60)) to $($IdleMinutes + 30) minutes."
    }
}

Write-Host "Done: Matrix screen saver after $IdleMinutes idle minutes on $env:COMPUTERNAME."
Write-Host "To see it now: & '$scr' /s"
