#Requires -Version 5.1
<#
.SYNOPSIS
    Startup Guard desktop window: one switch that blocks the programs Windows
    launches at sign-in.

.DESCRIPTION
    The switch is the only control that changes configuration.  Turning it on
    blocks every enabled startup entry; turning it off restores exactly what
    was blocked.  The list below the switch shows the entries Windows knows
    about and how the guard currently treats them.

    -SandboxRoot / -StatePath are test-only options.  -CapturePrefix is used
    by the screenshot test: it requires -SandboxRoot, renders the window in
    both switch positions and saves two PNG files.  It never touches real
    startup entries.
#>

[CmdletBinding()]
param(
    [string]$SandboxRoot = '',
    [string]$StatePath = '',
    [string]$CapturePrefix = ''
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Import-Module (Join-Path $PSScriptRoot 'StartupGuard.psm1') -Force

if (-not ('StartupGuard.UI.ToggleSwitch' -as [type])) {
    Add-Type -ReferencedAssemblies 'System.Windows.Forms', 'System.Drawing' -TypeDefinition @'
using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Runtime.InteropServices;
using System.Windows.Forms;

namespace StartupGuard.UI
{
    public class ToggleSwitch : Control
    {
        private bool _checked;
        private bool _hover;

        public event EventHandler CheckedChanged;

        public Color OnColor { get; set; }
        public Color OffColor { get; set; }

        public ToggleSwitch()
        {
            SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint |
                     ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
            Size = new Size(78, 40);
            Cursor = Cursors.Hand;
            TabStop = true;
            OnColor = Color.FromArgb(0, 120, 212);
            OffColor = Color.FromArgb(196, 201, 208);
        }

        public bool Checked
        {
            get { return _checked; }
            set
            {
                if (_checked != value)
                {
                    _checked = value;
                    Invalidate();
                    EventHandler handler = CheckedChanged;
                    if (handler != null) { handler(this, EventArgs.Empty); }
                }
            }
        }

        protected override void OnClick(EventArgs e)
        {
            Checked = !Checked;
            base.OnClick(e);
        }

        protected override void OnMouseEnter(EventArgs e)
        {
            _hover = true;
            Invalidate();
            base.OnMouseEnter(e);
        }

        protected override void OnMouseLeave(EventArgs e)
        {
            _hover = false;
            Invalidate();
            base.OnMouseLeave(e);
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            Graphics g = e.Graphics;
            g.SmoothingMode = SmoothingMode.AntiAlias;
            g.Clear(BackColor);

            int inset = 2;
            int width = Width - inset * 2;
            int height = Height - inset * 2;
            int radius = height;

            using (GraphicsPath path = new GraphicsPath())
            {
                path.AddArc(inset, inset, radius, radius, 90, 180);
                path.AddArc(inset + width - radius, inset, radius, radius, 270, 180);
                path.CloseFigure();
                using (SolidBrush brush = new SolidBrush(_checked ? OnColor : OffColor))
                {
                    g.FillPath(brush, path);
                }
            }

            int pad = 5;
            int knob = height - pad * 2;
            int knobX = _checked ? inset + width - knob - pad : inset + pad;

            using (SolidBrush shadow = new SolidBrush(Color.FromArgb(36, 0, 0, 0)))
            {
                g.FillEllipse(shadow, knobX + 1, inset + pad + 2, knob, knob);
            }
            g.FillEllipse(Brushes.White, knobX, inset + pad, knob, knob);

            if (_hover)
            {
                using (Pen ring = new Pen(Color.FromArgb(110, 255, 255, 255), 1))
                {
                    g.DrawEllipse(ring, knobX, inset + pad, knob, knob);
                }
            }
        }

        protected override bool IsInputKey(Keys keyData)
        {
            if (keyData == Keys.Space || keyData == Keys.Enter) { return true; }
            return base.IsInputKey(keyData);
        }

        protected override void OnKeyDown(KeyEventArgs e)
        {
            if (e.KeyCode == Keys.Space || e.KeyCode == Keys.Enter)
            {
                Checked = !Checked;
                e.Handled = true;
            }
            base.OnKeyDown(e);
        }
    }

    public static class WindowCapture
    {
        [DllImport("user32.dll")]
        private static extern bool PrintWindow(IntPtr hwnd, IntPtr hdcBlt, uint nFlags);

        public static void Save(Form form, string path)
        {
            using (Bitmap bitmap = new Bitmap(form.Width, form.Height))
            using (Graphics graphics = Graphics.FromImage(bitmap))
            {
                IntPtr hdc = graphics.GetHdc();
                PrintWindow(form.Handle, hdc, 2);
                graphics.ReleaseHdc(hdc);
                bitmap.Save(path, System.Drawing.Imaging.ImageFormat.Png);
            }
        }
    }
}
'@
}

[System.Windows.Forms.Application]::EnableVisualStyles()
[System.Windows.Forms.Application]::SetCompatibleTextRenderingDefault($false)

$script:CaptureMode = -not [string]::IsNullOrWhiteSpace($CapturePrefix)
$script:CaptureError = $false
$script:SuppressToggle = $false
$script:Busy = $false
$script:Status = $null

$script:UiText = [pscustomobject]@{
    Title         = '开机启动拦截'
    Subtitle      = '只阻止开机自动启动，程序仍可正常打开'
    On            = '已开启'
    Off           = '已关闭'
    OnDetail      = '已阻止 {0} 个程序自动启动 · 不影响手动打开'
    OnDetailDrift = '已阻止 {0} 项自启 · 另有 {1} 项又自动启动了，可点「重新应用」'
    OffDetail     = '开机时会正常自动启动，手动打开不受影响'
    Blocked       = '已阻止自启'
    Enabled       = '已启用'
    Disabled      = '已禁用'
    Excluded      = '已排除'
    Protected     = '系统项'
    Unknown       = '状态未知'
    ListTitle     = '开机启动项'
    CountOn       = '共 {0} 项 · 已阻止自启 {1} 项'
    CountOff      = '共 {0} 项 · 当前启用 {1} 项'
    Refresh       = '刷新'
    Reapply       = '重新应用'
    Footer        = '只影响当前 Windows 用户的自动启动；关闭开关会恢复，程序始终可手动打开。'
    DemoFooter    = '演示模式：仅使用测试数据；开关只影响当前 Windows 用户。'
    ErrorTitle    = '操作失败'
    PartialTitle  = '部分启动项未能修改'
}

function Get-GuardSourceLabel {
    param([string]$SourceId)
    switch ($SourceId) {
        'UserRun'             { '当前用户 Run' }
        'MachineRun'          { '系统 Run' }
        'MachineRun32'        { '系统 Run（32 位）' }
        'UserStartupFolder'   { '当前用户启动文件夹' }
        'CommonStartupFolder' { '公共启动文件夹' }
        default               { $SourceId }
    }
}

function Get-GuardDisplayState {
    param([string]$DisplayState)
    switch ($DisplayState) {
        'Blocked'  { $script:UiText.Blocked }
        'Enabled'  { $script:UiText.Enabled }
        'Disabled'  { $script:UiText.Disabled }
        'Excluded'  { $script:UiText.Excluded }
        'Protected' { $script:UiText.Protected }
        default     { $script:UiText.Unknown }
    }
}

function Show-GuardMessage {
    param([string]$Title, [string]$Text)
    if ($script:CaptureMode) {
        [Console]::Error.WriteLine(('{0}: {1}' -f $Title, $Text))
        $script:CaptureError = $true
        return
    }
    [System.Windows.Forms.MessageBox]::Show($Text, $Title, [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
}

function Update-GuardUi {
    $script:Status = Get-StartupGuardStatus -SandboxRoot $SandboxRoot -StatePath $StatePath
    $status = $script:Status

    $script:SuppressToggle = $true
    $script:Toggle.Checked = ($status.Switch -eq 'On')
    $script:SuppressToggle = $false

    if ($status.Switch -eq 'On') {
        $script:StatusTitle.Text = $script:UiText.On
        $script:StatusTitle.ForeColor = [System.Drawing.Color]::FromArgb(0, 95, 184)
        if ($status.Drift.Count -gt 0) {
            $script:StatusDetail.Text = ($script:UiText.OnDetailDrift -f $status.Counts.Blocked, $status.Drift.Count)
            $script:StatusDetail.ForeColor = [System.Drawing.Color]::FromArgb(181, 71, 8)
        }
        else {
            $script:StatusDetail.Text = ($script:UiText.OnDetail -f $status.Counts.Blocked)
            $script:StatusDetail.ForeColor = [System.Drawing.Color]::FromArgb(107, 114, 128)
        }
        $script:ReapplyButton.Enabled = ($status.Drift.Count -gt 0)
        $protectedSuffix = if ($status.Counts.Protected -gt 0) { " · 系统项 $($status.Counts.Protected) 项" } else { '' }
        $script:ListCount.Text = ($script:UiText.CountOn -f $status.Counts.Total, $status.Counts.Blocked) + $protectedSuffix
    }
    else {
        $script:StatusTitle.Text = $script:UiText.Off
        $script:StatusTitle.ForeColor = [System.Drawing.Color]::FromArgb(31, 35, 40)
        $script:StatusDetail.Text = $script:UiText.OffDetail
        $script:StatusDetail.ForeColor = [System.Drawing.Color]::FromArgb(107, 114, 128)
        $script:ReapplyButton.Enabled = $false
        $protectedSuffix = if ($status.Counts.Protected -gt 0) { " · 系统项 $($status.Counts.Protected) 项" } else { '' }
        $script:ListCount.Text = ($script:UiText.CountOff -f $status.Counts.Total, $status.Counts.Enabled) + $protectedSuffix
    }

    $order = @{ 'Blocked' = 0; 'Enabled' = 1; 'Disabled' = 2; 'Protected' = 3; 'Excluded' = 4; 'Unknown' = 5 }
    $sorted = @($status.Entries | Sort-Object @{ Expression = { $order[$_.DisplayState] } }, @{ Expression = { $_.Name } })

    $script:EntryList.BeginUpdate()
    try {
        $script:EntryList.Items.Clear()
        foreach ($entry in $sorted) {
            $item = New-Object System.Windows.Forms.ListViewItem((Get-GuardDisplayState $entry.DisplayState))
            [void]$item.SubItems.Add($entry.Name)
            [void]$item.SubItems.Add((Get-GuardSourceLabel $entry.SourceId))
            [void]$item.SubItems.Add($entry.Command)
            switch ($entry.DisplayState) {
                'Blocked'   { $item.ForeColor = [System.Drawing.Color]::FromArgb(16, 124, 16) }
                'Enabled'   { $item.ForeColor = [System.Drawing.Color]::FromArgb(31, 35, 40) }
                'Protected' { $item.ForeColor = [System.Drawing.Color]::FromArgb(70, 90, 120) }
                'Unknown'   { $item.ForeColor = [System.Drawing.Color]::FromArgb(181, 71, 8) }
                default     { $item.ForeColor = [System.Drawing.Color]::FromArgb(107, 114, 128) }
            }
            $item.ToolTipText = if ($entry.Protected) {
                "Windows 系统组件，默认不屏蔽" + [Environment]::NewLine + $entry.Command
            }
            else {
                $entry.Command
            }
            [void]$script:EntryList.Items.Add($item)
        }
    }
    finally {
        $script:EntryList.EndUpdate()
    }

    if ($script:Status.IsSandbox) {
        $script:FooterLabel.Text = $script:UiText.DemoFooter
        $script:FooterLabel.ForeColor = [System.Drawing.Color]::FromArgb(181, 71, 8)
    }
}

function Invoke-GuardSwitchChange {
    param([bool]$Enable)

    $script:Busy = $true
    $script:Toggle.Enabled = $false
    $script:Form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    try {
        $state = if ($Enable) { 'On' } else { 'Off' }
        $result = Set-StartupGuardSwitch -State $state -SandboxRoot $SandboxRoot -StatePath $StatePath
        if (@($result.Failed).Count -gt 0) {
            Show-GuardMessage -Title $script:UiText.PartialTitle -Text (@($result.Failed) -join [Environment]::NewLine)
        }
    }
    catch {
        Show-GuardMessage -Title $script:UiText.ErrorTitle -Text $_.Exception.Message
    }
    finally {
        $script:Busy = $false
        $script:Toggle.Enabled = $true
        $script:Form.Cursor = [System.Windows.Forms.Cursors]::Default
        try { Update-GuardUi } catch { Show-GuardMessage -Title $script:UiText.ErrorTitle -Text $_.Exception.Message }
    }
}

$script:Form = New-Object System.Windows.Forms.Form
$script:Form.Text = $script:UiText.Title
$script:Form.ClientSize = New-Object System.Drawing.Size(860, 638)
$script:Form.MinimumSize = New-Object System.Drawing.Size(780, 590)
$script:Form.StartPosition = 'CenterScreen'
$script:Form.BackColor = [System.Drawing.Color]::FromArgb(243, 244, 246)
$script:Form.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
$script:Form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::Dpi

function New-GuardCard {
    param([int]$X, [int]$Y, [int]$Width, [int]$Height, [string]$Anchor)
    $panel = New-Object System.Windows.Forms.Panel
    $panel.Location = New-Object System.Drawing.Point($X, $Y)
    $panel.Size = New-Object System.Drawing.Size($Width, $Height)
    $panel.BackColor = [System.Drawing.Color]::White
    $panel.Anchor = $Anchor
    return $panel
}

$headerCard = New-GuardCard -X 24 -Y 20 -Width 812 -Height 108 -Anchor 'Top,Left,Right'
$script:Form.Controls.Add($headerCard)

$titleLabel = New-Object System.Windows.Forms.Label
$titleLabel.Text = $script:UiText.Title
$titleLabel.AutoSize = $true
$titleLabel.Location = New-Object System.Drawing.Point(24, 16)
$titleLabel.ForeColor = [System.Drawing.Color]::FromArgb(31, 35, 40)
$titleLabel.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 20, [System.Drawing.FontStyle]::Bold)
$headerCard.Controls.Add($titleLabel)

$subtitleLabel = New-Object System.Windows.Forms.Label
$subtitleLabel.Text = $script:UiText.Subtitle
$subtitleLabel.AutoSize = $true
$subtitleLabel.Location = New-Object System.Drawing.Point(27, 66)
$subtitleLabel.ForeColor = [System.Drawing.Color]::FromArgb(107, 114, 128)
$subtitleLabel.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9.5)
$headerCard.Controls.Add($subtitleLabel)

$toggleCard = New-GuardCard -X 24 -Y 140 -Width 812 -Height 100 -Anchor 'Top,Left,Right'
$script:Form.Controls.Add($toggleCard)

$script:Toggle = New-Object StartupGuard.UI.ToggleSwitch
$script:Toggle.Location = New-Object System.Drawing.Point(28, 30)
$script:Toggle.BackColor = [System.Drawing.Color]::White
$script:Toggle.OnColor = [System.Drawing.Color]::FromArgb(0, 120, 212)
$script:Toggle.OffColor = [System.Drawing.Color]::FromArgb(196, 201, 208)
$toggleCard.Controls.Add($script:Toggle)

$script:StatusTitle = New-Object System.Windows.Forms.Label
$script:StatusTitle.AutoSize = $true
$script:StatusTitle.Location = New-Object System.Drawing.Point(128, 20)
$script:StatusTitle.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 13, [System.Drawing.FontStyle]::Bold)
$toggleCard.Controls.Add($script:StatusTitle)

$script:StatusDetail = New-Object System.Windows.Forms.Label
$script:StatusDetail.AutoSize = $true
$script:StatusDetail.Location = New-Object System.Drawing.Point(130, 54)
$script:StatusDetail.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
$toggleCard.Controls.Add($script:StatusDetail)

$script:RefreshButton = New-Object System.Windows.Forms.Button
$script:RefreshButton.Text = $script:UiText.Refresh
$script:RefreshButton.Size = New-Object System.Drawing.Size(88, 32)
$script:RefreshButton.Location = New-Object System.Drawing.Point(700, 32)
$script:RefreshButton.Anchor = 'Top,Right'
$script:RefreshButton.UseVisualStyleBackColor = $true
$toggleCard.Controls.Add($script:RefreshButton)

$script:ReapplyButton = New-Object System.Windows.Forms.Button
$script:ReapplyButton.Text = $script:UiText.Reapply
$script:ReapplyButton.Size = New-Object System.Drawing.Size(96, 32)
$script:ReapplyButton.Location = New-Object System.Drawing.Point(594, 32)
$script:ReapplyButton.Anchor = 'Top,Right'
$script:ReapplyButton.UseVisualStyleBackColor = $true
$script:ReapplyButton.Enabled = $false
$toggleCard.Controls.Add($script:ReapplyButton)

$listCard = New-GuardCard -X 24 -Y 252 -Width 812 -Height 338 -Anchor 'Top,Bottom,Left,Right'
$script:Form.Controls.Add($listCard)

$listTitle = New-Object System.Windows.Forms.Label
$listTitle.Text = $script:UiText.ListTitle
$listTitle.AutoSize = $true
$listTitle.Location = New-Object System.Drawing.Point(24, 16)
$listTitle.ForeColor = [System.Drawing.Color]::FromArgb(31, 35, 40)
$listTitle.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 10.5, [System.Drawing.FontStyle]::Bold)
$listCard.Controls.Add($listTitle)

$script:ListCount = New-Object System.Windows.Forms.Label
$script:ListCount.AutoSize = $false
$script:ListCount.Size = New-Object System.Drawing.Size(300, 24)
$script:ListCount.Location = New-Object System.Drawing.Point(488, 15)
$script:ListCount.Anchor = 'Top,Right'
$script:ListCount.TextAlign = 'MiddleRight'
$script:ListCount.ForeColor = [System.Drawing.Color]::FromArgb(107, 114, 128)
$listCard.Controls.Add($script:ListCount)

$script:EntryList = New-Object System.Windows.Forms.ListView
$script:EntryList.View = 'Details'
$script:EntryList.FullRowSelect = $true
$script:EntryList.MultiSelect = $false
$script:EntryList.HideSelection = $false
$script:EntryList.HeaderStyle = 'Nonclickable'
$script:EntryList.BorderStyle = 'None'
$script:EntryList.BackColor = [System.Drawing.Color]::White
$script:EntryList.ForeColor = [System.Drawing.Color]::FromArgb(31, 35, 40)
$script:EntryList.ShowItemToolTips = $true
$script:EntryList.Location = New-Object System.Drawing.Point(22, 48)
$script:EntryList.Size = New-Object System.Drawing.Size(768, 272)
$script:EntryList.Anchor = 'Top,Bottom,Left,Right'
[void]$script:EntryList.Columns.Add('状态', 82)
[void]$script:EntryList.Columns.Add('名称', 190)
[void]$script:EntryList.Columns.Add('位置', 170)
[void]$script:EntryList.Columns.Add('启动命令', 320)
$listCard.Controls.Add($script:EntryList)

$script:FooterLabel = New-Object System.Windows.Forms.Label
$script:FooterLabel.Text = $script:UiText.Footer
$script:FooterLabel.AutoSize = $true
$script:FooterLabel.Location = New-Object System.Drawing.Point(28, 606)
$script:FooterLabel.Anchor = 'Bottom,Left'
$script:FooterLabel.ForeColor = [System.Drawing.Color]::FromArgb(107, 114, 128)
$script:FooterLabel.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 8.5)
$script:Form.Controls.Add($script:FooterLabel)

$script:Toggle.Add_CheckedChanged({
        if ($script:SuppressToggle -or $script:Busy) { return }
        Invoke-GuardSwitchChange -Enable ([bool]$script:Toggle.Checked)
    })

$script:RefreshButton.Add_Click({ Update-GuardUi })
$script:ReapplyButton.Add_Click({ Invoke-GuardSwitchChange -Enable $true })

try {
    Update-GuardUi
}
catch {
    Show-GuardMessage -Title $script:UiText.ErrorTitle -Text $_.Exception.Message
    $script:Toggle.Enabled = $false
}

if ($script:CaptureMode) {
    if ([string]::IsNullOrWhiteSpace($SandboxRoot)) {
        throw 'Capture mode requires -SandboxRoot so real startup entries are never modified.'
    }
    $script:Form.TopMost = $true
    $script:Form.Show()
    $script:Form.Activate()
    $script:Form.Refresh()
    [void]$script:Toggle.Focus()
    [System.Windows.Forms.Application]::DoEvents()
    Start-Sleep -Milliseconds 700

    [StartupGuard.UI.WindowCapture]::Save($script:Form, "$CapturePrefix-off.png")

    $script:Toggle.Checked = $true
    [void]$script:Toggle.Focus()
    [System.Windows.Forms.Application]::DoEvents()
    Start-Sleep -Milliseconds 800
    $script:Form.Refresh()
    [System.Windows.Forms.Application]::DoEvents()
    [StartupGuard.UI.WindowCapture]::Save($script:Form, "$CapturePrefix-on.png")

    $script:Toggle.Checked = $false
    [System.Windows.Forms.Application]::DoEvents()
    Start-Sleep -Milliseconds 400
    $script:Form.Close()

    if ($script:CaptureError) { exit 1 }
    exit 0
}

[void]$script:Form.ShowDialog()
