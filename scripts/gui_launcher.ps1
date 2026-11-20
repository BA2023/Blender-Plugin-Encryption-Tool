param(
    [string]$InitialFile = ""
)

# 隐藏当前控制台窗口，避免黑框常驻
$code = @'
using System;
using System.Runtime.InteropServices;
public class ConsoleHelper {
    [DllImport("kernel32.dll")]
    public static extern IntPtr GetConsoleWindow();
    [DllImport("user32.dll")]
    public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

    [DllImport("shell32.dll", CharSet = CharSet.Unicode, ExactSpelling = true)]
    public static extern int SetCurrentProcessExplicitAppUserModelID(string appId);
}
'@
Add-Type -TypeDefinition $code

# Give the tool its own taskbar group so Windows uses the form icon.
[void][ConsoleHelper]::SetCurrentProcessExplicitAppUserModelID("GWX.BlenderPluginEncryptionTool")
[ConsoleHelper]::ShowWindow([ConsoleHelper]::GetConsoleWindow(), 0) | Out-Null

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

[System.Windows.Forms.Application]::EnableVisualStyles()

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RootDir = Split-Path -Parent $ScriptDir
$ConfigPath = Join-Path $RootDir "config\versions.json"
$BuilderPython = Join-Path $RootDir "python_envs\py314\python.exe"
$BackendScript = Join-Path $RootDir "scripts\builder_backend.py"
$OutputDir = Join-Path $RootDir "output"
$FormIconPath = Join-Path $RootDir "assets\blender.ico"
$CompilerRoot = Join-Path $RootDir "compiler"
$ToolVersion = "v26.6.25"

if (-not (Test-Path $BuilderPython)) {
    [System.Windows.Forms.MessageBox]::Show("未找到内部运行环境：$BuilderPython", "启动失败")
    exit 1
}

if (-not (Test-Path $BackendScript)) {
    [System.Windows.Forms.MessageBox]::Show("未找到后台构建脚本：$BackendScript", "启动失败")
    exit 1
}

$Config = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
$VersionMap = @{}

function Get-PortableCompilerStatus {
    $gccPath = Join-Path $CompilerRoot "bin\gcc.exe"
    if (-not (Test-Path $gccPath)) {
        return [PSCustomObject]@{
            Ready = $false
            Message = "需要文件：$gccPath"
            GccPath = $gccPath
            Cc1Path = ""
        }
    }

    $cc1File = Get-ChildItem -Path (Join-Path $CompilerRoot "libexec") -Filter "cc1.exe" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $cc1File) {
        return [PSCustomObject]@{
            Ready = $false
            Message = "内置 GCC 不完整，缺少 cc1.exe"
            GccPath = $gccPath
            Cc1Path = ""
        }
    }

    return [PSCustomObject]@{
        Ready = $true
        Message = ""
        GccPath = $gccPath
        Cc1Path = $cc1File.FullName
    }
}

$CompilerStatus = Get-PortableCompilerStatus

$Form = New-Object System.Windows.Forms.Form
$Form.Text = "Blender 插件加密工具 $ToolVersion"
$Form.Size = New-Object System.Drawing.Size(920, 780)
$Form.StartPosition = "CenterScreen"
$Form.BackColor = [System.Drawing.Color]::FromArgb(255, 243, 235)  # 浅橙色背景
$Form.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 9.5)
$Form.AllowDrop = $true
if (Test-Path $FormIconPath) {
    $Form.Icon = New-Object System.Drawing.Icon($FormIconPath)
}

# Header
$TitleLabel = New-Object System.Windows.Forms.Label
$TitleLabel.Text = "Blender 插件加密工具"
$TitleLabel.Location = New-Object System.Drawing.Point(30, 25)
$TitleLabel.AutoSize = $true
$TitleLabel.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 20, [System.Drawing.FontStyle]::Bold)
$TitleLabel.ForeColor = [System.Drawing.Color]::FromArgb(211, 84, 0)  # 深橙色标题
$Form.Controls.Add($TitleLabel)

$SubTitleLabel = New-Object System.Windows.Forms.Label
$SubTitleLabel.Text = "自动将 Python 脚本编译为 .pyd 核心，并打包为可安装的 zip 插件。"
$SubTitleLabel.Location = New-Object System.Drawing.Point(35, 65)
$SubTitleLabel.AutoSize = $true
$SubTitleLabel.ForeColor = [System.Drawing.Color]::FromArgb(100, 100, 100)
$Form.Controls.Add($SubTitleLabel)

$AuthorLabel = New-Object System.Windows.Forms.Label
$AuthorLabel.Text = "By: GWX"
$AuthorLabel.Location = New-Object System.Drawing.Point((30 + $TitleLabel.PreferredWidth + 20), 39)
$AuthorLabel.AutoSize = $true
$AuthorLabel.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 11, [System.Drawing.FontStyle]::Italic)
$AuthorLabel.ForeColor = [System.Drawing.Color]::FromArgb(160, 110, 80)
$Form.Controls.Add($AuthorLabel)

$RepositoryName = "BA2023/Blender-Plugin-Encryption-Tool"
$RepositoryUrl = "https://github.com/$RepositoryName"

$RepositoryLink = New-Object System.Windows.Forms.LinkLabel
$RepositoryLink.Text = "GitHub 仓库"
$RepositoryLink.AutoSize = $true
$RepositoryLink.Font = $Form.Font
$RepositoryLink.LinkColor = $AuthorLabel.ForeColor
$RepositoryLink.ActiveLinkColor = $AuthorLabel.ForeColor
$RepositoryLink.LinkBehavior = [System.Windows.Forms.LinkBehavior]::AlwaysUnderline
$RepositoryLink.TabStop = $true
$RepositoryLink.AccessibleDescription = "$RepositoryName，$RepositoryUrl"
$RepositoryLink.Location = New-Object System.Drawing.Point((870 - $RepositoryLink.PreferredWidth), 39)
$RepositoryLink.Links.Clear()
[void]$RepositoryLink.Links.Add(0, $RepositoryLink.Text.Length, $RepositoryUrl)
$RepositoryLink.Add_LinkClicked({
    param($Sender, $EventArgs)
    if ($EventArgs.Button -ne [System.Windows.Forms.MouseButtons]::Right) {
        Start-Process -FilePath ([string]$EventArgs.Link.LinkData)
    }
})
$Form.Controls.Add($RepositoryLink)

$RepositoryToolTip = New-Object System.Windows.Forms.ToolTip
$RepositoryToolTip.SetToolTip($RepositoryLink, "$RepositoryUrl`r`n右键可复制仓库地址")

$RepositoryMenu = New-Object System.Windows.Forms.ContextMenuStrip
$CopyRepositoryUrl = $RepositoryMenu.Items.Add("复制仓库地址")
$CopyRepositoryUrl.Add_Click({ Set-Clipboard -Value $RepositoryUrl })
$RepositoryLink.ContextMenuStrip = $RepositoryMenu

# Card 1: File Input (White Panel)
$Card1Title = New-Object System.Windows.Forms.Label
$Card1Title.Text = "选择文件"
$Card1Title.Location = New-Object System.Drawing.Point(30, 105)
$Card1Title.AutoSize = $true
$Card1Title.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 10.5, [System.Drawing.FontStyle]::Bold)
$Card1Title.ForeColor = [System.Drawing.Color]::FromArgb(211, 84, 0)  # 深橙色
$Form.Controls.Add($Card1Title)

$Card1 = New-Object System.Windows.Forms.Panel
$Card1.Location = New-Object System.Drawing.Point(30, 130)
$Card1.Size = New-Object System.Drawing.Size(840, 200)
$Card1.BackColor = [System.Drawing.Color]::White
$Card1.BorderStyle = [System.Windows.Forms.BorderStyle]::None
$Form.Controls.Add($Card1)

$DropPanel = New-Object System.Windows.Forms.Panel
$DropPanel.Location = New-Object System.Drawing.Point(20, 20)
$DropPanel.Size = New-Object System.Drawing.Size(800, 120)
$DropPanel.BackColor = [System.Drawing.Color]::FromArgb(255, 248, 240)  # 更浅的橙色拖拽区
$DropPanel.Cursor = [System.Windows.Forms.Cursors]::Hand

$Card1.Controls.Add($DropPanel)

$DropLabel = New-Object System.Windows.Forms.Label
$DropLabel.Text = "📁 点击选择或将 .py 文件拖拽到此处"
$DropLabel.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 12)
$DropLabel.ForeColor = [System.Drawing.Color]::FromArgb(230, 115, 0)  # 橙色拖拽文字
$DropLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
$DropLabel.Dock = [System.Windows.Forms.DockStyle]::Fill
$DropLabel.Cursor = [System.Windows.Forms.Cursors]::Hand

# 使用 Paint 事件在顶层的 Label 上绘制虚线边框
$DropLabel.add_Paint({
    param($sender, $e)
    $pen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(230, 115, 0), 2)
    $pen.DashStyle = [System.Drawing.Drawing2D.DashStyle]::Dash
    $rect = New-Object System.Drawing.Rectangle(1, 1, ($sender.Width - 3), ($sender.Height - 3))
    $e.Graphics.DrawRectangle($pen, $rect)
    $pen.Dispose()
})

$DropPanel.Controls.Add($DropLabel)

$ScriptPathLabel = New-Object System.Windows.Forms.Label
$ScriptPathLabel.Text = "文件路径："
$ScriptPathLabel.Location = New-Object System.Drawing.Point(20, 158)
$ScriptPathLabel.AutoSize = $true
$ScriptPathLabel.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 9.5)
$Card1.Controls.Add($ScriptPathLabel)

$ScriptTextBox = New-Object System.Windows.Forms.TextBox
$ScriptTextBox.Location = New-Object System.Drawing.Point(100, 155)
$ScriptTextBox.Size = New-Object System.Drawing.Size(720, 25)
$ScriptTextBox.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 10)
$ScriptTextBox.BackColor = [System.Drawing.Color]::FromArgb(250, 250, 250)
$Card1.Controls.Add($ScriptTextBox)

# Card 2: Settings & Action
$Card2Title = New-Object System.Windows.Forms.Label
$Card2Title.Text = "构建选项"
$Card2Title.Location = New-Object System.Drawing.Point(30, 350)
$Card2Title.AutoSize = $true
$Card2Title.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 10.5, [System.Drawing.FontStyle]::Bold)
$Card2Title.ForeColor = [System.Drawing.Color]::FromArgb(211, 84, 0)
$Form.Controls.Add($Card2Title)

$Card2 = New-Object System.Windows.Forms.Panel
$Card2.Location = New-Object System.Drawing.Point(30, 375)
$Card2.Size = New-Object System.Drawing.Size(840, 120)
$Card2.BackColor = [System.Drawing.Color]::White
$Form.Controls.Add($Card2)

$VersionLabel = New-Object System.Windows.Forms.Label
$VersionLabel.Text = "Python 版本："
$VersionLabel.Location = New-Object System.Drawing.Point(20, 25)
$VersionLabel.AutoSize = $true
$Card2.Controls.Add($VersionLabel)

$VersionComboBox = New-Object System.Windows.Forms.ComboBox
$VersionComboBox.Location = New-Object System.Drawing.Point(120, 22)
$VersionComboBox.Size = New-Object System.Drawing.Size(160, 25)
$VersionComboBox.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
$Card2.Controls.Add($VersionComboBox)

$VersionHintLabel = New-Object System.Windows.Forms.Label
$VersionHintLabel.Text = "（版本选择需与Blender内置Python版本一致）"
$VersionHintLabel.Location = New-Object System.Drawing.Point(290, 25)
$VersionHintLabel.AutoSize = $true
$VersionHintLabel.ForeColor = [System.Drawing.Color]::FromArgb(120, 120, 120)
$Card2.Controls.Add($VersionHintLabel)

$VersionStatusLabel = New-Object System.Windows.Forms.Label
$VersionStatusLabel.Text = "状态："
$VersionStatusLabel.Location = New-Object System.Drawing.Point(290, 45)
$VersionStatusLabel.Size = New-Object System.Drawing.Size(350, 20)
$VersionStatusLabel.ForeColor = [System.Drawing.Color]::FromArgb(100, 100, 100)
$Card2.Controls.Add($VersionStatusLabel)

$OutputLabel = New-Object System.Windows.Forms.Label
$OutputLabel.Text = "输出目录："
$OutputLabel.Location = New-Object System.Drawing.Point(20, 70)
$OutputLabel.AutoSize = $true
$Card2.Controls.Add($OutputLabel)

$OutputTextBox = New-Object System.Windows.Forms.TextBox
$OutputTextBox.Location = New-Object System.Drawing.Point(100, 67)
$OutputTextBox.Size = New-Object System.Drawing.Size(420, 25)
$OutputTextBox.ReadOnly = $false
$OutputTextBox.Text = $OutputDir
$OutputTextBox.BackColor = [System.Drawing.Color]::FromArgb(250, 250, 250)
$Card2.Controls.Add($OutputTextBox)

$OpenOutputButton = New-Object System.Windows.Forms.Button
$OpenOutputButton.Text = "选择目录"
$OpenOutputButton.Location = New-Object System.Drawing.Point(530, 66)
$OpenOutputButton.Size = New-Object System.Drawing.Size(90, 28)
$OpenOutputButton.BackColor = [System.Drawing.Color]::FromArgb(225, 225, 225)
$OpenOutputButton.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$OpenOutputButton.FlatAppearance.BorderSize = 0
$OpenOutputButton.Cursor = [System.Windows.Forms.Cursors]::Hand
$Card2.Controls.Add($OpenOutputButton)

$BuildButton = New-Object System.Windows.Forms.Button
$BuildButton.Text = "▶ 开始加密"
$BuildButton.Location = New-Object System.Drawing.Point(660, 22)
$BuildButton.Size = New-Object System.Drawing.Size(160, 72)
$BuildButton.BackColor = [System.Drawing.Color]::FromArgb(211, 84, 0)  # 深橙色按钮
$BuildButton.ForeColor = [System.Drawing.Color]::White
$BuildButton.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$BuildButton.FlatAppearance.BorderSize = 0
$BuildButton.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 12, [System.Drawing.FontStyle]::Bold)
$BuildButton.Cursor = [System.Windows.Forms.Cursors]::Hand
$Card2.Controls.Add($BuildButton)

# Card 3: Terminal / Logs
$Card3 = New-Object System.Windows.Forms.Panel
$Card3.Location = New-Object System.Drawing.Point(30, 520)
$Card3.Size = New-Object System.Drawing.Size(840, 190)
$Card3.BackColor = [System.Drawing.Color]::FromArgb(30, 30, 30)
$Form.Controls.Add($Card3)

$LogLabel = New-Object System.Windows.Forms.Label
$LogLabel.Text = "运行日志"
$LogLabel.Location = New-Object System.Drawing.Point(10, 10)
$LogLabel.AutoSize = $true
$LogLabel.ForeColor = [System.Drawing.Color]::FromArgb(230, 115, 0)
$Card3.Controls.Add($LogLabel)

$CopyLogButton = New-Object System.Windows.Forms.Button
$CopyLogButton.Text = "复制日志"
$CopyLogButton.Location = New-Object System.Drawing.Point(750, 7)
$CopyLogButton.Size = New-Object System.Drawing.Size(80, 24)
$CopyLogButton.BackColor = [System.Drawing.Color]::FromArgb(60, 60, 60)
$CopyLogButton.ForeColor = [System.Drawing.Color]::FromArgb(204, 204, 204)
$CopyLogButton.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$CopyLogButton.FlatAppearance.BorderSize = 0
$CopyLogButton.Cursor = [System.Windows.Forms.Cursors]::Hand
$CopyLogButton.Add_Click({
    if (-not [string]::IsNullOrWhiteSpace($LogTextBox.Text)) {
        [System.Windows.Forms.Clipboard]::SetText($LogTextBox.Text)
        $CopyLogButton.Text = "已复制！"
        $CopyLogButton.BackColor = [System.Drawing.Color]::FromArgb(46, 139, 87) # 成功绿色

        # 2秒后恢复原样
        $timer = New-Object System.Windows.Forms.Timer
        $timer.Interval = 2000
        $timer.Add_Tick({
            $CopyLogButton.Text = "复制日志"
            $CopyLogButton.BackColor = [System.Drawing.Color]::FromArgb(60, 60, 60)
            $timer.Stop()
            $timer.Dispose()
        })
        $timer.Start()
    }
})
$Card3.Controls.Add($CopyLogButton)

$LogTextBox = New-Object System.Windows.Forms.TextBox
$LogTextBox.Location = New-Object System.Drawing.Point(10, 35)
$LogTextBox.Size = New-Object System.Drawing.Size(820, 145)
$LogTextBox.Multiline = $true
$LogTextBox.ScrollBars = "Vertical"
$LogTextBox.ReadOnly = $true
$LogTextBox.BackColor = [System.Drawing.Color]::FromArgb(30, 30, 30)
$LogTextBox.ForeColor = [System.Drawing.Color]::FromArgb(204, 204, 204)
$LogTextBox.BorderStyle = [System.Windows.Forms.BorderStyle]::None
$LogTextBox.Font = New-Object System.Drawing.Font("Consolas", 10)
$Card3.Controls.Add($LogTextBox)

# === 函数与事件 ===
function Add-Log {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return }
    $LogTextBox.AppendText($Text + [Environment]::NewLine)
    $LogTextBox.SelectionStart = $LogTextBox.Text.Length
    $LogTextBox.ScrollToCaret()
}

function Get-SelectedVersionInfo {
    $selected = [string]$VersionComboBox.SelectedItem
    if ([string]::IsNullOrWhiteSpace($selected)) { return $null }
    return $VersionMap[$selected]
}

function Refresh-VersionStatus {
    $info = Get-SelectedVersionInfo
    if ($null -eq $info) {
        $VersionStatusLabel.Text = ""
        return
    }

    if ($info.Available) {
        $VersionStatusLabel.Text = ""
    } else {
        $VersionStatusLabel.Text = "未就绪    $($info.StatusMessage)"
        $VersionStatusLabel.ForeColor = [System.Drawing.Color]::FromArgb(199, 69, 69)
    }
}

function Set-ScriptPath {
    param([string]$PathText)
    if (-not [string]::IsNullOrWhiteSpace($PathText)) {
        $ScriptTextBox.Text = $PathText.Trim('"')
    }
}

# 拖拽事件
$DragEnterHandler = {
    if ($_.Data.GetDataPresent([System.Windows.Forms.DataFormats]::FileDrop)) {
        $_.Effect = [System.Windows.Forms.DragDropEffects]::Copy
        $DropPanel.BackColor = [System.Drawing.Color]::FromArgb(255, 230, 204)  # 悬停时稍微深一点的橙色
    } else {
        $_.Effect = [System.Windows.Forms.DragDropEffects]::None
    }
}
$DragLeaveHandler = {
    $DropPanel.BackColor = [System.Drawing.Color]::FromArgb(255, 248, 240)
}
$DragDropHandler = {
    $DropPanel.BackColor = [System.Drawing.Color]::FromArgb(255, 248, 240)
    $files = $_.Data.GetData([System.Windows.Forms.DataFormats]::FileDrop)
    if ($files.Length -gt 0) {
        Set-ScriptPath $files[0]
    }
}

$DropPanel.add_DragEnter($DragEnterHandler)
$DropPanel.add_DragLeave($DragLeaveHandler)
$DropPanel.add_DragDrop($DragDropHandler)

$DropLabel.add_DragEnter($DragEnterHandler)
$DropLabel.add_DragLeave($DragLeaveHandler)
$DropLabel.add_DragDrop($DragDropHandler)

# 全局兜底
$Form.add_DragEnter({
    if ($_.Data.GetDataPresent([System.Windows.Forms.DataFormats]::FileDrop)) {
        $_.Effect = [System.Windows.Forms.DragDropEffects]::Copy
    } else {
        $_.Effect = [System.Windows.Forms.DragDropEffects]::None
    }
})
$Form.add_DragDrop({
    $files = $_.Data.GetData([System.Windows.Forms.DataFormats]::FileDrop)
    if ($files.Length -gt 0) {
        Set-ScriptPath $files[0]
    }
})

# 浏览文件
$BrowseClickHandler = {
    $dialog = New-Object System.Windows.Forms.OpenFileDialog
    $dialog.Filter = "Python 脚本 (*.py)|*.py|所有文件 (*.*)|*.*"
    if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        Set-ScriptPath $dialog.FileName
    }
}
$DropPanel.add_Click($BrowseClickHandler)
$DropLabel.add_Click($BrowseClickHandler)

$VersionComboBox.Add_SelectedIndexChanged({
    Refresh-VersionStatus
})

$OpenOutputButton.Add_Click({
    Add-Type -AssemblyName System.Windows.Forms

    # 使用 CommonOpenFileDialog 来实现更现代的文件夹选择
    # 注意：PowerShell 5 原生不支持 CommonOpenFileDialog（需要 WindowsAPICodePack）
    # 但我们可以利用 OpenFileDialog 的一个 trick 来选择文件夹
    $dialog = New-Object System.Windows.Forms.OpenFileDialog
    $dialog.Title = "选择输出目录"
    $dialog.ValidateNames = $false
    $dialog.CheckFileExists = $false
    $dialog.CheckPathExists = $true
    $dialog.FileName = "选择此文件夹."
    $dialog.Filter = "文件夹|*.none"

    if (Test-Path $OutputTextBox.Text) {
        $dialog.InitialDirectory = $OutputTextBox.Text
    }

    if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $selectedPath = [System.IO.Path]::GetDirectoryName($dialog.FileName)
        if (-not [string]::IsNullOrWhiteSpace($selectedPath)) {
            $OutputTextBox.Text = $selectedPath
        }
    }
})

$BuildButton.Add_Click({
    $sourcePath = $ScriptTextBox.Text.Trim()
    $outPath = $OutputTextBox.Text.Trim()
    $versionInfo = Get-SelectedVersionInfo

    if ([string]::IsNullOrWhiteSpace($sourcePath)) {
        [System.Windows.Forms.MessageBox]::Show("请先选择或拖入一个 .py 脚本文件。", "提示")
        return
    }
    if (-not (Test-Path $sourcePath)) {
        [System.Windows.Forms.MessageBox]::Show("脚本文件不存在：$sourcePath", "提示")
        return
    }
    if ([string]::IsNullOrWhiteSpace($outPath)) {
        [System.Windows.Forms.MessageBox]::Show("输出目录不能为空。", "提示")
        return
    }
    if ($null -eq $versionInfo) {
        [System.Windows.Forms.MessageBox]::Show("请先选择一个 Python 版本。", "提示")
        return
    }
    if (-not $versionInfo.Available) {
        [System.Windows.Forms.MessageBox]::Show("当前所选版本环境未就绪，请换一个可用版本。", "提示")
        return
    }

    $BuildButton.Enabled = $false
    $BuildButton.Text = "正在加密..."
    $LogTextBox.Clear()
    Add-Log "[开始] 准备编译打包"
    Add-Log "[脚本] $sourcePath"
    Add-Log "[输出] $outPath"
    Add-Log "[版本] $($versionInfo.Version)"
    Add-Log ""

    $logFile = Join-Path $RootDir "work\build_log.txt"
    if (-not (Test-Path (Join-Path $RootDir "work"))) {
        New-Item -ItemType Directory -Path (Join-Path $RootDir "work") | Out-Null
    }
    if (Test-Path $logFile) { Remove-Item $logFile -Force }

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = "cmd.exe"
    # 使用 cmd /c 运行并将输出重定向到文件，彻底避免管道死锁和跨线程闪退
    $psi.Arguments = "/c `"`"$BuilderPython`" `"$BackendScript`" --source `"$sourcePath`" --version $($versionInfo.Version) --output `"$outPath`" > `"$logFile`" 2>&1`""
    $psi.WorkingDirectory = $RootDir
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true

    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi
    [void]$proc.Start()

    $lastPos = 0
    # 轮询等待进程结束，使用 DoEvents 保持 UI 响应（解决假死），并安全读取文件日志（解决闪退）
    while (-not $proc.HasExited) {
        [System.Windows.Forms.Application]::DoEvents()

        if (Test-Path $logFile) {
            try {
                $fs = New-Object System.IO.FileStream($logFile, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
                if ($fs.Length -gt $lastPos) {
                    $fs.Position = $lastPos
                    $sr = New-Object System.IO.StreamReader($fs, [System.Text.Encoding]::UTF8)
                    $newLogs = $sr.ReadToEnd()
                    if (-not [string]::IsNullOrEmpty($newLogs)) {
                        $newLogs = $newLogs.Replace("`r`n", "`n").Replace("`n", "`r`n")
                        $LogTextBox.AppendText($newLogs)
                        $LogTextBox.SelectionStart = $LogTextBox.Text.Length
                        $LogTextBox.ScrollToCaret()
                    }
                    $lastPos = $fs.Position
                    $sr.Dispose()
                }
                $fs.Dispose()
            } catch {}
        }

        Start-Sleep -Milliseconds 100
    }

    $proc.WaitForExit()

    # 进程结束后再读最后一次，确保没有遗漏
    if (Test-Path $logFile) {
        try {
            $fs = New-Object System.IO.FileStream($logFile, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
            if ($fs.Length -gt $lastPos) {
                $fs.Position = $lastPos
                $sr = New-Object System.IO.StreamReader($fs, [System.Text.Encoding]::UTF8)
                $newLogs = $sr.ReadToEnd()
                if (-not [string]::IsNullOrEmpty($newLogs)) {
                    $newLogs = $newLogs.Replace("`r`n", "`n").Replace("`n", "`r`n")
                    $LogTextBox.AppendText($newLogs)
                    $LogTextBox.SelectionStart = $LogTextBox.Text.Length
                    $LogTextBox.ScrollToCaret()
                }
                $sr.Dispose()
            }
            $fs.Dispose()
            # 不在这里删除日志文件，保留给用户查看
        } catch {}
    }

    # 加密完成后清理 work 目录下的临时编译文件夹，但保留 build_log.txt
    try {
        $workDir = Join-Path $RootDir "work"
        if (Test-Path $workDir) {
            Get-ChildItem -Path $workDir | Where-Object { $_.Name -ne "build_log.txt" } | Remove-Item -Recurse -Force
        }
    } catch {}

    # 从日志文本中匹配 zipPath
    $stdout = $LogTextBox.Text

    if ($proc.ExitCode -eq 0) {
        Add-Log ""
        Add-Log "[完成] 编译打包成功。"
        [System.Windows.Forms.MessageBox]::Show("加密打包成功，安装包已输出到目标目录。", "完成")

        # 尝试从 stdout 中解析出具体的 zip 文件路径
        $zipPath = $null
        if ($stdout -match "\[输出\]\s+(.+\.zip)") {
            $zipPath = $matches[1]
        }

        if ($null -ne $zipPath -and (Test-Path $zipPath)) {
            # 选中具体的 zip 文件
            Start-Process explorer.exe "/select,`"$zipPath`""
        } elseif (Test-Path $outPath) {
            # 如果没找到具体文件，退回到打开目录
            Start-Process explorer.exe "`"$outPath`""
        }
    } else {
        Add-Log ""
        Add-Log "[失败] 编译打包失败。"
        [System.Windows.Forms.MessageBox]::Show("加密打包失败，请查看上方日志。", "失败")
    }

    $BuildButton.Enabled = $true
    $BuildButton.Text = "▶ 开始加密"
})

foreach ($property in $Config.versions.PSObject.Properties) {
    $version = [string]$property.Name
    $info = $property.Value
    $pythonPath = Join-Path $RootDir $info.python
    $pythonReady = Test-Path $pythonPath
    $available = $pythonReady -and $CompilerStatus.Ready
    $statusMessage = if (-not $pythonReady) {
        "需要文件：$pythonPath"
    } elseif (-not $CompilerStatus.Ready) {
        $CompilerStatus.Message
    } else {
        ""
    }
    $itemLabel = if ($available) { "Python $version" } else { "Python $version（未就绪）" }

    $VersionMap[$itemLabel] = [PSCustomObject]@{
        Label = $itemLabel
        Version = $version
        Path = $pythonPath
        Available = $available
        Tag = [string]$info.tag
        StatusMessage = $statusMessage
        CompilerPath = $CompilerStatus.GccPath
    }
    [void]$VersionComboBox.Items.Add($itemLabel)
}

if ($VersionComboBox.Items.Count -gt 0) {
    # 尝试找到 Python 3.14 的索引
    $defaultIndex = -1
    for ($i = 0; $i -lt $VersionComboBox.Items.Count; $i++) {
        $candidate = $VersionMap[[string]$VersionComboBox.Items[$i]]
        if ($candidate.Version -eq "3.14" -and $candidate.Available) {
            $defaultIndex = $i
            break
        }
    }

    if ($defaultIndex -ge 0) {
        $VersionComboBox.SelectedIndex = $defaultIndex
    } else {
        # 退回原逻辑，找第一个可用的
        for ($i = 0; $i -lt $VersionComboBox.Items.Count; $i++) {
            $candidate = $VersionMap[[string]$VersionComboBox.Items[$i]]
            if ($candidate.Available) {
                $VersionComboBox.SelectedIndex = $i
                break
            }
        }
        if ($VersionComboBox.SelectedIndex -lt 0) {
            $VersionComboBox.SelectedIndex = 0
        }
    }
}

if (-not [string]::IsNullOrWhiteSpace($InitialFile)) {
    Set-ScriptPath $InitialFile
}

Refresh-VersionStatus
[void]$Form.ShowDialog()
