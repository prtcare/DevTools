Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

$ErrorActionPreference = 'Stop'

$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$ConfigPath = Join-Path $Root 'config\projects.json'
$DevToolsPath = 'C:\Personal\DevTools'
$NotifyScript = Join-Path $DevToolsPath 'notify.ps1'
$StartDevScript = Join-Path $DevToolsPath 'start-dev.ps1'

function Get-GitInfo {
    param([string]$RepoPath)

    $result = [ordered]@{
        IsRepo = $false
        Branch = '-'
        StatusText = 'Not a Git repository'
        IsClean = $false
        ChangeCount = 0
    }

    if (-not (Test-Path $RepoPath)) {
        $result.StatusText = 'Folder not found'
        return [pscustomobject]$result
    }

    if (-not (Test-Path (Join-Path $RepoPath '.git'))) {
        return [pscustomobject]$result
    }

    $result.IsRepo = $true
    try {
        $branch = (& git -C $RepoPath branch --show-current 2>$null | Select-Object -First 1)
        if ($branch) { $result.Branch = $branch.Trim() }
        $changes = @(& git -C $RepoPath status --porcelain 2>$null)
        $count = @($changes | Where-Object { $_ -and $_.Trim() }).Count
        $result.ChangeCount = $count
        if ($count -eq 0) {
            $result.StatusText = 'Clean'
            $result.IsClean = $true
        }
        else {
            $result.StatusText = "$count change(s)"
        }
    }
    catch {
        $result.StatusText = 'Git unavailable'
    }

    return [pscustomobject]$result
}

function Start-DeepCode {
    param([string]$RepoPath)
    $escaped = $RepoPath.Replace("'", "''")
    Start-Process powershell.exe -ArgumentList @(
        '-NoExit',
        '-Command',
        "Set-Location '$escaped'; deepcode"
    )
}

function Open-VSCode {
    param([string]$RepoPath)
    try {
        Start-Process code -ArgumentList @('"' + $RepoPath + '"')
    }
    catch {
        [System.Windows.MessageBox]::Show("VS Code command 'code' was not found.\n\nOpen VS Code and enable the shell command, or use Open Folder.", 'Nexus Development') | Out-Null
    }
}

function Open-GitStatus {
    param([string]$RepoPath)
    $escaped = $RepoPath.Replace("'", "''")
    Start-Process powershell.exe -ArgumentList @(
        '-NoExit',
        '-Command',
        "Set-Location '$escaped'; git status"
    )
}

function Test-Notifications {
    if (-not (Test-Path $NotifyScript)) {
        [System.Windows.MessageBox]::Show("notify.ps1 was not found at:\n$NotifyScript", 'Nexus Development') | Out-Null
        return
    }

    Start-Process powershell.exe -WindowStyle Hidden -ArgumentList @(
        '-ExecutionPolicy','Bypass','-File',('"' + $NotifyScript + '"'),
        '-Type','Console Test',
        '-Message','Nexus Development Console notification test'
    ) -Wait

    [System.Windows.MessageBox]::Show('Notification test sent.', 'Nexus Development') | Out-Null
}

if (-not (Test-Path $ConfigPath)) {
    [System.Windows.MessageBox]::Show("Missing config file:\n$ConfigPath", 'Nexus Development') | Out-Null
    exit 1
}

$projects = Get-Content $ConfigPath -Raw | ConvertFrom-Json

[xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Nexus Development" Height="680" Width="1080"
        WindowStartupLocation="CenterScreen" Background="#0D1117">
    <Window.Resources>
        <Style TargetType="Button">
            <Setter Property="Background" Value="#21262D"/>
            <Setter Property="Foreground" Value="#F0F6FC"/>
            <Setter Property="BorderBrush" Value="#30363D"/>
            <Setter Property="Padding" Value="14,9"/>
            <Setter Property="Margin" Value="0,0,8,0"/>
            <Setter Property="FontSize" Value="13"/>
            <Setter Property="Cursor" Value="Hand"/>
        </Style>
        <Style TargetType="TextBlock">
            <Setter Property="Foreground" Value="#F0F6FC"/>
        </Style>
    </Window.Resources>

    <Grid Margin="28">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="20"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="20"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>

        <StackPanel Grid.Row="0">
            <TextBlock Text="NEXUS DEVELOPMENT" FontSize="30" FontWeight="SemiBold"/>
            <TextBlock Text="Local development control console" Foreground="#8B949E" FontSize="14" Margin="0,6,0,0"/>
        </StackPanel>

        <ScrollViewer Grid.Row="2" VerticalScrollBarVisibility="Auto">
            <StackPanel>
                <TextBlock Text="PROJECTS" FontSize="13" FontWeight="Bold" Foreground="#8B949E" Margin="0,0,0,12"/>
                <WrapPanel Name="ProjectPanel"/>

                <TextBlock Text="DEVELOPMENT TOOLS" FontSize="13" FontWeight="Bold" Foreground="#8B949E" Margin="0,26,0,12"/>
                <Border Background="#161B22" BorderBrush="#30363D" BorderThickness="1" CornerRadius="8" Padding="16">
                    <StackPanel Orientation="Horizontal">
                        <Button Name="BtnStartDev" Content="Start Dev Launcher"/>
                        <Button Name="BtnOpenDevTools" Content="Open DevTools"/>
                        <Button Name="BtnTestNotify" Content="Test Notification"/>
                        <Button Name="BtnRefresh" Content="Refresh Status"/>
                    </StackPanel>
                </Border>

                <TextBlock Text="SYSTEM" FontSize="13" FontWeight="Bold" Foreground="#8B949E" Margin="0,26,0,12"/>
                <Border Background="#161B22" BorderBrush="#30363D" BorderThickness="1" CornerRadius="8" Padding="16">
                    <StackPanel>
                        <TextBlock Name="TxtPowerShell"/>
                        <TextBlock Name="TxtGit" Margin="0,6,0,0"/>
                        <TextBlock Name="TxtNotify" Margin="0,6,0,0"/>
                    </StackPanel>
                </Border>
            </StackPanel>
        </ScrollViewer>

        <TextBlock Grid.Row="4" Text="Nexus DevTools • Local only" Foreground="#6E7681" FontSize="12" HorizontalAlignment="Right"/>
    </Grid>
</Window>
"@

$reader = New-Object System.Xml.XmlNodeReader $xaml
$window = [Windows.Markup.XamlReader]::Load($reader)
$projectPanel = $window.FindName('ProjectPanel')
$btnStartDev = $window.FindName('BtnStartDev')
$btnOpenDevTools = $window.FindName('BtnOpenDevTools')
$btnTestNotify = $window.FindName('BtnTestNotify')
$btnRefresh = $window.FindName('BtnRefresh')
$txtPowerShell = $window.FindName('TxtPowerShell')
$txtGit = $window.FindName('TxtGit')
$txtNotify = $window.FindName('TxtNotify')

function Add-ProjectCard {
    param($Project)

    $info = Get-GitInfo -RepoPath $Project.path

    $border = New-Object System.Windows.Controls.Border
    $border.Width = 310
    $border.MinHeight = 190
    $border.Margin = '0,0,14,14'
    $border.Padding = '18'
    $border.Background = '#161B22'
    $border.BorderBrush = '#30363D'
    $border.BorderThickness = '1'
    $border.CornerRadius = '8'

    $stack = New-Object System.Windows.Controls.StackPanel

    $title = New-Object System.Windows.Controls.TextBlock
    $title.Text = $Project.name
    $title.FontSize = 21
    $title.FontWeight = 'SemiBold'
    $stack.Children.Add($title) | Out-Null

    $path = New-Object System.Windows.Controls.TextBlock
    $path.Text = $Project.path
    $path.Foreground = '#8B949E'
    $path.FontSize = 11
    $path.Margin = '0,5,0,12'
    $stack.Children.Add($path) | Out-Null

    $branch = New-Object System.Windows.Controls.TextBlock
    $branch.Text = "Branch: $($info.Branch)"
    $branch.Foreground = '#C9D1D9'
    $stack.Children.Add($branch) | Out-Null

    $status = New-Object System.Windows.Controls.TextBlock
    $status.Text = "Status: $($info.StatusText)"
    $status.Foreground = if ($info.IsClean) { '#3FB950' } elseif ($info.IsRepo) { '#D29922' } else { '#F85149' }
    $status.Margin = '0,4,0,14'
    $stack.Children.Add($status) | Out-Null

    $buttons1 = New-Object System.Windows.Controls.StackPanel
    $buttons1.Orientation = 'Horizontal'
    $buttons1.Margin = '0,0,0,8'

    $start = New-Object System.Windows.Controls.Button
    $start.Content = 'Start DeepSeek'
    $start.Tag = $Project.path
    $start.Add_Click({ Start-DeepCode -RepoPath $this.Tag })
    $buttons1.Children.Add($start) | Out-Null

    $folder = New-Object System.Windows.Controls.Button
    $folder.Content = 'Open Folder'
    $folder.Tag = $Project.path
    $folder.Add_Click({ Start-Process explorer.exe -ArgumentList ('"' + $this.Tag + '"') })
    $buttons1.Children.Add($folder) | Out-Null

    $stack.Children.Add($buttons1) | Out-Null

    $buttons2 = New-Object System.Windows.Controls.StackPanel
    $buttons2.Orientation = 'Horizontal'

    $code = New-Object System.Windows.Controls.Button
    $code.Content = 'VS Code'
    $code.Tag = $Project.path
    $code.Add_Click({ Open-VSCode -RepoPath $this.Tag })
    $buttons2.Children.Add($code) | Out-Null

    $git = New-Object System.Windows.Controls.Button
    $git.Content = 'Git Status'
    $git.Tag = $Project.path
    $git.Add_Click({ Open-GitStatus -RepoPath $this.Tag })
    $buttons2.Children.Add($git) | Out-Null

    if ($Project.github) {
        $gh = New-Object System.Windows.Controls.Button
        $gh.Content = 'GitHub'
        $gh.Tag = $Project.github
        $gh.Add_Click({ Start-Process $this.Tag })
        $buttons2.Children.Add($gh) | Out-Null
    }

    $stack.Children.Add($buttons2) | Out-Null
    $border.Child = $stack
    $projectPanel.Children.Add($border) | Out-Null
}

function Refresh-Console {
    $projectPanel.Children.Clear()
    foreach ($project in $projects) {
        Add-ProjectCard -Project $project
    }

    $txtPowerShell.Text = "PowerShell: $($PSVersionTable.PSVersion)"

    try {
        $gitVersion = (& git --version 2>$null)
        $txtGit.Text = "Git: $gitVersion"
    }
    catch {
        $txtGit.Text = 'Git: Not available'
    }

    $txtNotify.Text = if (Test-Path $NotifyScript) { "Notifications: notify.ps1 found" } else { "Notifications: notify.ps1 missing" }
}

$btnStartDev.Add_Click({
    if (Test-Path $StartDevScript) {
        Start-Process powershell.exe -ArgumentList @('-NoExit','-ExecutionPolicy','Bypass','-File',('"' + $StartDevScript + '"'))
    }
    else {
        [System.Windows.MessageBox]::Show("start-dev.ps1 was not found at:\n$StartDevScript", 'Nexus Development') | Out-Null
    }
})

$btnOpenDevTools.Add_Click({
    if (Test-Path $DevToolsPath) { Start-Process explorer.exe -ArgumentList ('"' + $DevToolsPath + '"') }
})

$btnTestNotify.Add_Click({ Test-Notifications })
$btnRefresh.Add_Click({ Refresh-Console })

Refresh-Console
$window.ShowDialog() | Out-Null
