Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

$ErrorActionPreference = "Stop"

# =====================================================================
# FIND: APP_PATHS
# Purpose: All common paths used by the Nexus Development Console.
# =====================================================================

$Root = Split-Path -Parent $MyInvocation.MyCommand.Path

$DevToolsPath = "C:\Personal\DevTools"

$ConfigPath       = Join-Path $Root "config\layers.json"
$LayerShellScript = Join-Path $DevToolsPath "LayerShell.ps1"

$NotifyScript     = Join-Path $DevToolsPath "notify.ps1"
$CheckpointScript = Join-Path $DevToolsPath "checkpoint.ps1"
$VerifyScript     = Join-Path $DevToolsPath "verify.ps1"


# =====================================================================
# FIND: GIT_HELPERS
# Purpose: Read branch / change status for repositories.
# =====================================================================

function Get-GitInfo {

    param(
        [string]$RepoPath
    )

    $result = [ordered]@{
        Branch      = "-"
        StatusText  = "NO REPOSITORY"
        IsClean     = $false
        IsRepo      = $false
        ChangeCount = 0
    }

    if ([string]::IsNullOrWhiteSpace($RepoPath)) {
        return [pscustomobject]$result
    }

    if (-not (Test-Path $RepoPath)) {
        $result.StatusText = "FOLDER NOT FOUND"
        return [pscustomobject]$result
    }

    if (-not (Test-Path (Join-Path $RepoPath ".git"))) {
        $result.StatusText = "NOT A GIT REPOSITORY"
        return [pscustomobject]$result
    }

    $result.IsRepo = $true

    try {

        $branch = (
            & git -C $RepoPath branch --show-current 2>$null |
            Select-Object -First 1
        )

        if ($branch) {
            $result.Branch = $branch.Trim()
        }

        $changes = @(
            & git -C $RepoPath status --porcelain 2>$null
        )

        $count = @(
            $changes |
            Where-Object {
                $_ -and $_.Trim()
            }
        ).Count

        $result.ChangeCount = $count

        if ($count -eq 0) {

            $result.StatusText = "CLEAN"
            $result.IsClean = $true

        }
        else {

            $result.StatusText = "$count CHANGE(S)"

        }

    }
    catch {

        $result.StatusText = "GIT ERROR"

    }

    return [pscustomobject]$result
}


# =====================================================================
# FIND: AI_SERVICE_STATUS
# Purpose: DeepSeek balance + Claude installation status.
# =====================================================================

function Get-DeepSeekBalance {

    $result = [ordered]@{
        Available    = $false
        Status       = "NOT CONFIGURED"
        Currency     = "-"
        TotalBalance = "-"
        Granted      = "-"
        ToppedUp     = "-"
        ErrorMessage = ""
    }

    $apiKey = [Environment]::GetEnvironmentVariable(
        "DEEPSEEK_API_KEY",
        "User"
    )

    if ([string]::IsNullOrWhiteSpace($apiKey)) {
        $apiKey = $env:DEEPSEEK_API_KEY
    }

    if ([string]::IsNullOrWhiteSpace($apiKey)) {

        $result.Status = "API KEY MISSING"
        return [pscustomobject]$result

    }

    try {

        $headers = @{
            Authorization = "Bearer $apiKey"
        }

        $response = Invoke-RestMethod `
            -Method Get `
            -Uri "https://api.deepseek.com/user/balance" `
            -Headers $headers `
            -TimeoutSec 10

        $result.Available = [bool]$response.is_available

        if ($response.is_available) {
            $result.Status = "AVAILABLE"
        }
        else {
            $result.Status = "UNAVAILABLE"
        }

        $balance = $response.balance_infos |
            Where-Object {
                $_.currency -eq "USD"
            } |
            Select-Object -First 1

        if (-not $balance) {

            $balance = $response.balance_infos |
                Select-Object -First 1

        }

        if ($balance) {

            $result.Currency     = $balance.currency
            $result.TotalBalance = $balance.total_balance
            $result.Granted      = $balance.granted_balance
            $result.ToppedUp     = $balance.topped_up_balance

        }

    }
    catch {

        $result.Status = "CONNECTION ERROR"
        $result.ErrorMessage = $_.Exception.Message

    }

    return [pscustomobject]$result
}


function Test-ClaudeDesktopInstalled {

    try {

        $app = Get-StartApps |
            Where-Object {
                $_.Name -match "^Claude"
            } |
            Select-Object -First 1

        if ($app) {
            return $true
        }

    }
    catch {}

    $possiblePaths = @(
        "$env:LOCALAPPDATA\Programs\Claude\Claude.exe",
        "$env:LOCALAPPDATA\AnthropicClaude\Claude.exe",
        "$env:ProgramFiles\Claude\Claude.exe"
    )

    foreach ($path in $possiblePaths) {

        if (Test-Path $path) {
            return $true
        }

    }

    return $false
}


function Test-ClaudeCodeInstalled {

    try {

        $command = Get-Command claude `
            -ErrorAction SilentlyContinue

        if ($command) {
            return $true
        }

    }
    catch {}

    return $false
}


# =====================================================================
# FIND: LAYER_NAVIGATION
# Purpose: Open a common layer page for ANY of the 12 layers.
# =====================================================================

function Open-LayerPage {

    param(
        $Layer
    )

    if (-not (Test-Path $LayerShellScript)) {

        [System.Windows.MessageBox]::Show(
            "Layer shell not found:`n$LayerShellScript",
            "Nexus Development"
        ) | Out-Null

        return
    }

    try {

        if (Get-Command Show-NexusLayerPage -ErrorAction SilentlyContinue) {
            Remove-Item Function:\Show-NexusLayerPage `
                -ErrorAction SilentlyContinue
        }

        . $LayerShellScript

        if (-not (Get-Command Show-NexusLayerPage -ErrorAction SilentlyContinue)) {

            [System.Windows.MessageBox]::Show(
                "LayerShell.ps1 does not expose Show-NexusLayerPage.",
                "Nexus Development"
            ) | Out-Null

            return
        }

        Show-NexusLayerPage `
            -Layer $Layer `
            -DevToolsPath $DevToolsPath

    }
    catch {

        [System.Windows.MessageBox]::Show(
            "Unable to open layer:`n`n$($_.Exception.Message)",
            "Nexus Development"
        ) | Out-Null

    }
}


# =====================================================================
# FIND: REPOSITORY_ACTIONS
# Purpose: Launch terminals, DeepSeek, VS Code, Claude and utility scripts.
# =====================================================================

function Start-RepoTerminal {

    param(
        [string]$RepoPath,
        [string]$Command = ""
    )

    if ([string]::IsNullOrWhiteSpace($RepoPath)) {
        return
    }

    if (-not (Test-Path $RepoPath)) {

        [System.Windows.MessageBox]::Show(
            "Repository folder not found:`n$RepoPath",
            "Nexus Development"
        ) | Out-Null

        return
    }

    $escaped = $RepoPath.Replace("'", "''")

    $commandText = @"
Set-Location -LiteralPath '$escaped'
$Command
"@

    Start-Process powershell.exe `
        -WorkingDirectory $RepoPath `
        -ArgumentList @(
            "-NoExit",
            "-Command",
            $commandText
        )
}


function Start-DeepCode {

    param(
        [string]$RepoPath
    )

    if ([string]::IsNullOrWhiteSpace($RepoPath)) {

        [System.Windows.MessageBox]::Show(
            "No repository path is assigned to this layer.",
            "Nexus Development"
        ) | Out-Null

        return
    }

    if (-not (Test-Path $RepoPath)) {

        [System.Windows.MessageBox]::Show(
            "Repository folder not found:`n$RepoPath",
            "Nexus Development"
        ) | Out-Null

        return
    }

    $escaped = $RepoPath.Replace("'", "''")

    # deepcode is your PowerShell profile function.
    # powershell.exe loads the user profile by default.
    $commandText = @"
Set-Location -LiteralPath '$escaped'
deepcode
"@

    Start-Process powershell.exe `
        -WorkingDirectory $RepoPath `
        -ArgumentList @(
            "-NoExit",
            "-Command",
            $commandText
        )
}


function Open-VSCode {

    param(
        [string]$RepoPath
    )

    if ([string]::IsNullOrWhiteSpace($RepoPath)) {
        return
    }

    try {

        Start-Process "code" `
            -ArgumentList @(
                "`"$RepoPath`""
            )

    }
    catch {

        [System.Windows.MessageBox]::Show(
            "VS Code could not be started.",
            "Nexus Development"
        ) | Out-Null

    }
}


function Open-ClaudeDesktop {

    try {

        $claudeApp = Get-StartApps |
            Where-Object {
                $_.Name -match "^Claude"
            } |
            Select-Object -First 1

        if ($claudeApp) {

            Start-Process explorer.exe `
                -ArgumentList "shell:AppsFolder\$($claudeApp.AppID)"

            return
        }

        $possiblePaths = @(
            "$env:LOCALAPPDATA\Programs\Claude\Claude.exe",
            "$env:LOCALAPPDATA\AnthropicClaude\Claude.exe",
            "$env:ProgramFiles\Claude\Claude.exe"
        )

        foreach ($path in $possiblePaths) {

            if (Test-Path $path) {

                Start-Process $path
                return

            }

        }

        [System.Windows.MessageBox]::Show(
            "Claude Desktop could not be found automatically.",
            "Nexus Development"
        ) | Out-Null

    }
    catch {

        [System.Windows.MessageBox]::Show(
            "Claude Desktop could not be started.`n`n$($_.Exception.Message)",
            "Nexus Development"
        ) | Out-Null

    }
}


function Run-RepoTool {

    param(
        [string]$ScriptPath,
        [string]$RepoPath
    )

    if (-not (Test-Path $ScriptPath)) {

        [System.Windows.MessageBox]::Show(
            "Tool not found:`n$ScriptPath",
            "Nexus Development"
        ) | Out-Null

        return
    }

    Start-Process powershell.exe `
        -ArgumentList @(
            "-NoExit",
            "-ExecutionPolicy",
            "Bypass",
            "-File",
            "`"$ScriptPath`"",
            "-RepoPath",
            "`"$RepoPath`""
        )
}


function Test-Notifications {

    if (-not (Test-Path $NotifyScript)) {

        [System.Windows.MessageBox]::Show(
            "notify.ps1 was not found.",
            "Nexus Development"
        ) | Out-Null

        return
    }

    Start-Process powershell.exe `
        -WindowStyle Hidden `
        -ArgumentList @(
            "-ExecutionPolicy",
            "Bypass",
            "-File",
            "`"$NotifyScript`"",
            "-Type",
            "Dashboard Test",
            "-Message",
            "Nexus Development Console is connected"
        ) `
        -Wait
}


# =====================================================================
# FIND: LOAD_LAYER_CONFIG
# Purpose: Load the 12-layer metadata.
# =====================================================================

if (-not (Test-Path $ConfigPath)) {

    [System.Windows.MessageBox]::Show(
        "layers.json not found:`n$ConfigPath",
        "Nexus Development"
    ) | Out-Null

    exit 1
}

$layers = Get-Content $ConfigPath -Raw |
    ConvertFrom-Json


# =====================================================================
# FIND: MAIN_WINDOW_XAML
# Purpose: Main 12-layer home screen.
# =====================================================================

[xml]$xaml = @"
<Window
    xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"

    Title="Nexus Development Console"

    Height="900"
    Width="1650"

    MinHeight="820"
    MinWidth="1450"

    WindowStartupLocation="CenterScreen"

    Background="#0D1117">


    <Window.Resources>

        <Style TargetType="Button">

            <Setter
                Property="Background"
                Value="#21262D"/>

            <Setter
                Property="Foreground"
                Value="#F0F6FC"/>

            <Setter
                Property="BorderBrush"
                Value="#30363D"/>

            <Setter
                Property="Padding"
                Value="10,6"/>

            <Setter
                Property="Margin"
                Value="0,0,6,6"/>

            <Setter
                Property="FontSize"
                Value="11"/>

            <Setter
                Property="Cursor"
                Value="Hand"/>

        </Style>


        <Style TargetType="TextBlock">

            <Setter
                Property="Foreground"
                Value="#F0F6FC"/>

        </Style>

    </Window.Resources>


    <Grid Margin="24">

        <Grid.RowDefinitions>

            <RowDefinition Height="Auto"/>
            <RowDefinition Height="10"/>

            <RowDefinition Height="Auto"/>
            <RowDefinition Height="10"/>

            <RowDefinition Height="Auto"/>
            <RowDefinition Height="10"/>

            <RowDefinition Height="Auto"/>
            <RowDefinition Height="10"/>

            <RowDefinition Height="*"/>

            <RowDefinition Height="Auto"/>

        </Grid.RowDefinitions>


        <!-- FIND: HOME_HEADER -->

        <DockPanel Grid.Row="0">

            <StackPanel>

                <TextBlock
                    Text="NEXUS DEVELOPMENT"
                    FontSize="28"
                    FontWeight="SemiBold"/>

                <TextBlock
                    Text="12-Layer Development Control Center"
                    Foreground="#8B949E"
                    FontSize="13"
                    Margin="0,3,0,0"/>

            </StackPanel>

        </DockPanel>


        <!-- FIND: HOME_OVERVIEW -->

        <Border
            Grid.Row="2"
            Background="#161B22"
            BorderBrush="#30363D"
            BorderThickness="1"
            CornerRadius="7"
            Padding="12">

            <Grid>

                <Grid.ColumnDefinitions>

                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="*"/>

                </Grid.ColumnDefinitions>


                <StackPanel Grid.Column="0">

                    <TextBlock
                        Text="TOTAL LAYERS"
                        Foreground="#8B949E"
                        FontSize="10"/>

                    <TextBlock
                        Name="TxtTotalLayers"
                        FontSize="21"
                        FontWeight="SemiBold"/>

                </StackPanel>


                <StackPanel Grid.Column="1">

                    <TextBlock
                        Text="STARTED"
                        Foreground="#8B949E"
                        FontSize="10"/>

                    <TextBlock
                        Name="TxtStartedLayers"
                        FontSize="21"
                        FontWeight="SemiBold"/>

                </StackPanel>


                <StackPanel Grid.Column="2">

                    <TextBlock
                        Text="NOT STARTED"
                        Foreground="#8B949E"
                        FontSize="10"/>

                    <TextBlock
                        Name="TxtNotStartedLayers"
                        FontSize="21"
                        FontWeight="SemiBold"/>

                </StackPanel>


                <StackPanel Grid.Column="3">

                    <TextBlock
                        Text="ACTIVE REPOSITORIES"
                        Foreground="#8B949E"
                        FontSize="10"/>

                    <TextBlock
                        Name="TxtRepositories"
                        FontSize="21"
                        FontWeight="SemiBold"/>

                </StackPanel>

            </Grid>

        </Border>


        <!-- FIND: HOME_AI_SERVICES -->

        <Border
            Grid.Row="4"
            Background="#161B22"
            BorderBrush="#30363D"
            BorderThickness="1"
            CornerRadius="7"
            Padding="10">

            <Grid>

                <Grid.ColumnDefinitions>

                    <ColumnDefinition Width="Auto"/>
                    <ColumnDefinition Width="25"/>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="20"/>
                    <ColumnDefinition Width="*"/>

                </Grid.ColumnDefinitions>


                <TextBlock
                    Grid.Column="0"
                    Text="AI SERVICES"
                    FontSize="11"
                    FontWeight="Bold"
                    Foreground="#8B949E"
                    VerticalAlignment="Center"/>


                <StackPanel
                    Grid.Column="2"
                    Orientation="Horizontal"
                    VerticalAlignment="Center">

                    <TextBlock
                        Text="DEEPSEEK"
                        FontWeight="Bold"
                        FontSize="11"
                        Margin="0,0,12,0"/>

                    <TextBlock
                        Name="TxtDeepSeekStatus"
                        Text="Checking..."
                        Foreground="#8B949E"
                        FontSize="11"
                        Margin="0,0,14,0"/>

                    <TextBlock
                        Text="Balance:"
                        Foreground="#8B949E"
                        FontSize="11"
                        Margin="0,0,5,0"/>

                    <TextBlock
                        Name="TxtDeepSeekBalance"
                        Text="-"
                        FontWeight="SemiBold"
                        FontSize="12"
                        Margin="0,0,14,0"/>

                    <Button
                        Name="BtnRefreshDeepSeek"
                        Content="Refresh"/>

                </StackPanel>


                <StackPanel
                    Grid.Column="4"
                    Orientation="Horizontal"
                    VerticalAlignment="Center">

                    <TextBlock
                        Text="CLAUDE"
                        FontWeight="Bold"
                        FontSize="11"
                        Margin="0,0,12,0"/>

                    <TextBlock
                        Name="TxtClaudeStatus"
                        Text="Checking..."
                        Foreground="#8B949E"
                        FontSize="11"
                        Margin="0,0,14,0"/>

                    <Button
                        Name="BtnClaudeUsage"
                        Content="Open Claude"/>

                </StackPanel>

            </Grid>

        </Border>


        <!-- FIND: HOME_GLOBAL_TOOLS -->

        <Border
            Grid.Row="6"
            Background="#161B22"
            BorderBrush="#30363D"
            BorderThickness="1"
            CornerRadius="7"
            Padding="10">

            <DockPanel>

                <TextBlock
                    Text="GLOBAL TOOLS"
                    FontSize="11"
                    FontWeight="Bold"
                    Foreground="#8B949E"
                    VerticalAlignment="Center"
                    Margin="0,0,16,0"/>


                <WrapPanel>

                    <Button
                        Name="BtnClaude"
                        Content="Claude Desktop"/>

                    <Button
                        Name="BtnDevTools"
                        Content="Open DevTools"/>

                    <Button
                        Name="BtnNotifications"
                        Content="Test Notification"/>

                    <Button
                        Name="BtnGitHub"
                        Content="GitHub"/>

                    <Button
                        Name="BtnRefresh"
                        Content="Refresh Dashboard"/>

                </WrapPanel>

            </DockPanel>

        </Border>


        <!-- FIND: HOME_LAYER_GRID -->

        <Grid
            Grid.Row="8"
            Name="LayerGrid">

            <Grid.RowDefinitions>

                <RowDefinition Height="*"/>
                <RowDefinition Height="*"/>

            </Grid.RowDefinitions>


            <Grid.ColumnDefinitions>

                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="*"/>

            </Grid.ColumnDefinitions>

        </Grid>


        <!-- FIND: HOME_FOOTER -->

        <TextBlock
            Grid.Row="9"
            Text="Nexus DevTools | Common shell | Modular 12-layer framework"
            Foreground="#6E7681"
            FontSize="10"
            HorizontalAlignment="Right"
            Margin="0,8,0,0"/>

    </Grid>

</Window>
"@


# =====================================================================
# FIND: MAIN_WINDOW_LOAD
# Purpose: Create the WPF home window and capture controls.
# =====================================================================

$reader = New-Object System.Xml.XmlNodeReader $xaml

$window = [Windows.Markup.XamlReader]::Load(
    $reader
)


$layerGrid =
    $window.FindName("LayerGrid")


$btnClaude =
    $window.FindName("BtnClaude")


$btnDevTools =
    $window.FindName("BtnDevTools")


$btnNotifications =
    $window.FindName("BtnNotifications")


$btnGitHub =
    $window.FindName("BtnGitHub")


$btnRefresh =
    $window.FindName("BtnRefresh")


$txtTotalLayers =
    $window.FindName("TxtTotalLayers")


$txtStartedLayers =
    $window.FindName("TxtStartedLayers")


$txtNotStartedLayers =
    $window.FindName("TxtNotStartedLayers")


$txtRepositories =
    $window.FindName("TxtRepositories")


$txtDeepSeekStatus =
    $window.FindName("TxtDeepSeekStatus")


$txtDeepSeekBalance =
    $window.FindName("TxtDeepSeekBalance")


$btnRefreshDeepSeek =
    $window.FindName("BtnRefreshDeepSeek")


$txtClaudeStatus =
    $window.FindName("TxtClaudeStatus")


$btnClaudeUsage =
    $window.FindName("BtnClaudeUsage")


# =====================================================================
# FIND: LAYER_CARD_FACTORY
# Purpose: Build each of the 12 layer cards.
# =====================================================================

function Add-LayerCard {

    param(
        $Layer,
        [int]$Index
    )

    $row =
        [math]::Floor(
            $Index / 6
        )

    $column =
        $Index % 6


    $hasRepo =
        -not [string]::IsNullOrWhiteSpace(
            [string]$Layer.path
        )


    $isStarted =
        ([string]$Layer.status -eq "Started")


    $gitInfo = if ($hasRepo) {

        Get-GitInfo `
            -RepoPath ([string]$Layer.path)

    }
    else {

        [pscustomobject]@{
            Branch      = "-"
            StatusText  = "NO REPOSITORY"
            IsClean     = $false
            IsRepo      = $false
            ChangeCount = 0
        }

    }


    $card =
        New-Object System.Windows.Controls.Border


    $card.Margin =
        "0,0,10,10"


    $card.Padding =
        "13"


    $card.Background =
        "#161B22"


    $card.BorderBrush =
        "#30363D"


    $card.BorderThickness =
        "1"


    $card.CornerRadius =
        "7"


    [System.Windows.Controls.Grid]::SetRow(
        $card,
        $row
    )


    [System.Windows.Controls.Grid]::SetColumn(
        $card,
        $column
    )


    $stack =
        New-Object System.Windows.Controls.StackPanel


    # -----------------------------------------------------------------
    # FIND: LAYER_CARD_HEADER
    # Purpose: Layer number + name + solution + top-right Open button.
    # -----------------------------------------------------------------

    $header =
        New-Object System.Windows.Controls.Grid


    $leftColumn =
        New-Object System.Windows.Controls.ColumnDefinition


    $leftColumn.Width =
        "*"


    $rightColumn =
        New-Object System.Windows.Controls.ColumnDefinition


    $rightColumn.Width =
        "Auto"


    $header.ColumnDefinitions.Add(
        $leftColumn
    ) | Out-Null


    $header.ColumnDefinitions.Add(
        $rightColumn
    ) | Out-Null


    $headerLeft =
        New-Object System.Windows.Controls.StackPanel


    [System.Windows.Controls.Grid]::SetColumn(
        $headerLeft,
        0
    )


    $number =
        New-Object System.Windows.Controls.TextBlock


    $number.Text =
        "LAYER $($Layer.number)"


    $number.Foreground =
        "#58A6FF"


    $number.FontSize =
        9


    $number.FontWeight =
        "Bold"


    $headerLeft.Children.Add(
        $number
    ) | Out-Null


    $title =
        New-Object System.Windows.Controls.TextBlock


    $title.Text =
        [string]$Layer.name


    $title.FontSize =
        17


    $title.FontWeight =
        "SemiBold"


    $title.Margin =
        "0,2,0,0"


    $headerLeft.Children.Add(
        $title
    ) | Out-Null


    $solution =
        New-Object System.Windows.Controls.TextBlock


    if (
        -not [string]::IsNullOrWhiteSpace(
            [string]$Layer.solution
        )
    ) {

        $solution.Text =
            "Solution: $($Layer.solution)"


        $solution.Foreground =
            "#C9D1D9"

    }
    else {

        $solution.Text =
            "Solution: Not assigned"


        $solution.Foreground =
            "#6E7681"

    }


    $solution.FontSize =
        9


    $solution.Margin =
        "0,2,0,0"


    $headerLeft.Children.Add(
        $solution
    ) | Out-Null


    $header.Children.Add(
        $headerLeft
    ) | Out-Null


    $openButton =
        New-Object System.Windows.Controls.Button


    $openButton.Content =
        "Open"


    $openButton.Tag =
        $Layer


    $openButton.Padding =
        "8,4"


    $openButton.Margin =
        "6,0,0,0"


    [System.Windows.Controls.Grid]::SetColumn(
        $openButton,
        1
    )


    $openButton.Add_Click({

        param(
            $sender,
            $eventArgs
        )

        Open-LayerPage `
            -Layer $sender.Tag

    })


    $header.Children.Add(
        $openButton
    ) | Out-Null


    $stack.Children.Add(
        $header
    ) | Out-Null


    # -----------------------------------------------------------------
    # FIND: LAYER_CARD_DESCRIPTION
    # -----------------------------------------------------------------

    $description =
        New-Object System.Windows.Controls.TextBlock


    $description.Text =
        [string]$Layer.description


    $description.Foreground =
        "#8B949E"


    $description.FontSize =
        10


    $description.TextWrapping =
        "Wrap"


    $description.Margin =
        "0,5,0,8"


    $stack.Children.Add(
        $description
    ) | Out-Null


    # -----------------------------------------------------------------
    # FIND: LAYER_CARD_STATUS
    # -----------------------------------------------------------------

    $status =
        New-Object System.Windows.Controls.TextBlock


    if ($isStarted) {

        $status.Text =
            "STARTED"


        $status.Foreground =
            "#3FB950"

    }
    else {

        $status.Text =
            "NOT STARTED"


        $status.Foreground =
            "#6E7681"

    }


    $status.FontWeight =
        "Bold"


    $status.FontSize =
        10


    $stack.Children.Add(
        $status
    ) | Out-Null


    # -----------------------------------------------------------------
    # FIND: LAYER_CARD_REPOSITORY_TOOLS
    # Purpose: Only visible for layers that already have a repository.
    # -----------------------------------------------------------------

    if ($hasRepo) {

        $repo =
            New-Object System.Windows.Controls.TextBlock


        $repo.Text =
            "$($Layer.repository) | $($gitInfo.Branch)"


        $repo.Foreground =
            "#C9D1D9"


        $repo.FontSize =
            10


        $repo.Margin =
            "0,3,0,0"


        $stack.Children.Add(
            $repo
        ) | Out-Null


        $git =
            New-Object System.Windows.Controls.TextBlock


        $git.Text =
            "Git: $($gitInfo.StatusText)"


        if ($gitInfo.IsClean) {

            $git.Foreground =
                "#3FB950"

        }
        elseif ($gitInfo.IsRepo) {

            $git.Foreground =
                "#D29922"

        }
        else {

            $git.Foreground =
                "#F85149"

        }


        $git.FontSize =
            10


        $git.Margin =
            "0,2,0,6"


        $stack.Children.Add(
            $git
        ) | Out-Null


        $repoPath =
            [string]$Layer.path


        $actions1 =
            New-Object System.Windows.Controls.WrapPanel


        # DeepSeek

        $deepSeekButton =
            New-Object System.Windows.Controls.Button


        $deepSeekButton.Content =
            "DeepSeek"


        $deepSeekButton.Tag =
            $repoPath


        $deepSeekButton.Add_Click({

            param(
                $sender,
                $eventArgs
            )

            Start-DeepCode `
                -RepoPath ([string]$sender.Tag)

        })


        $actions1.Children.Add(
            $deepSeekButton
        ) | Out-Null


        # Terminal

        $terminalButton =
            New-Object System.Windows.Controls.Button


        $terminalButton.Content =
            "Terminal"


        $terminalButton.Tag =
            $repoPath


        $terminalButton.Add_Click({

            param(
                $sender,
                $eventArgs
            )

            Start-RepoTerminal `
                -RepoPath ([string]$sender.Tag)

        })


        $actions1.Children.Add(
            $terminalButton
        ) | Out-Null


        # VS Code

        $vsCodeButton =
            New-Object System.Windows.Controls.Button


        $vsCodeButton.Content =
            "VS Code"


        $vsCodeButton.Tag =
            $repoPath


        $vsCodeButton.Add_Click({

            param(
                $sender,
                $eventArgs
            )

            Open-VSCode `
                -RepoPath ([string]$sender.Tag)

        })


        $actions1.Children.Add(
            $vsCodeButton
        ) | Out-Null


        $stack.Children.Add(
            $actions1
        ) | Out-Null


        $actions2 =
            New-Object System.Windows.Controls.WrapPanel


        # Verify

        $verifyButton =
            New-Object System.Windows.Controls.Button


        $verifyButton.Content =
            "Verify"


        $verifyButton.Tag =
            $repoPath


        $verifyButton.Add_Click({

            param(
                $sender,
                $eventArgs
            )

            Run-RepoTool `
                -ScriptPath $VerifyScript `
                -RepoPath ([string]$sender.Tag)

        })


        $actions2.Children.Add(
            $verifyButton
        ) | Out-Null


        # Checkpoint

        $checkpointButton =
            New-Object System.Windows.Controls.Button


        $checkpointButton.Content =
            "Checkpoint"


        $checkpointButton.Tag =
            $repoPath


        $checkpointButton.Add_Click({

            param(
                $sender,
                $eventArgs
            )

            Run-RepoTool `
                -ScriptPath $CheckpointScript `
                -RepoPath ([string]$sender.Tag)

        })


        $actions2.Children.Add(
            $checkpointButton
        ) | Out-Null


        $stack.Children.Add(
            $actions2
        ) | Out-Null


        $actions3 =
            New-Object System.Windows.Controls.WrapPanel


        # Git status

        $gitStatusButton =
            New-Object System.Windows.Controls.Button


        $gitStatusButton.Content =
            "Git Status"


        $gitStatusButton.Tag =
            $repoPath


        $gitStatusButton.Add_Click({

            param(
                $sender,
                $eventArgs
            )

            Start-RepoTerminal `
                -RepoPath ([string]$sender.Tag) `
                -Command "git status"

        })


        $actions3.Children.Add(
            $gitStatusButton
        ) | Out-Null


        # Folder

        $folderButton =
            New-Object System.Windows.Controls.Button


        $folderButton.Content =
            "Folder"


        $folderButton.Tag =
            $repoPath


        $folderButton.Add_Click({

            param(
                $sender,
                $eventArgs
            )

            Start-Process `
                explorer.exe `
                ([string]$sender.Tag)

        })


        $actions3.Children.Add(
            $folderButton
        ) | Out-Null


        # GitHub

        if (
            -not [string]::IsNullOrWhiteSpace(
                [string]$Layer.github
            )
        ) {

            $githubButton =
                New-Object System.Windows.Controls.Button


            $githubButton.Content =
                "GitHub"


            $githubButton.Tag =
                [string]$Layer.github


            $githubButton.Add_Click({

                param(
                    $sender,
                    $eventArgs
                )

                Start-Process `
                    ([string]$sender.Tag)

            })


            $actions3.Children.Add(
                $githubButton
            ) | Out-Null

        }


        $stack.Children.Add(
            $actions3
        ) | Out-Null

    }
    else {

        $message =
            New-Object System.Windows.Controls.TextBlock


        if ($isStarted) {

            $message.Text =
                "Layer work has started; implementation repository is not assigned yet."

        }
        else {

            $message.Text =
                "Repository will be assigned when this layer becomes actionable."

        }


        $message.Foreground =
            "#6E7681"


        $message.FontSize =
            10


        $message.TextWrapping =
            "Wrap"


        $message.Margin =
            "0,5,0,0"


        $stack.Children.Add(
            $message
        ) | Out-Null

    }


    $card.Child =
        $stack


    $layerGrid.Children.Add(
        $card
    ) | Out-Null
}


# =====================================================================
# FIND: REFRESH_AI_SERVICES
# Purpose: Refresh DeepSeek and Claude status in the home screen.
# =====================================================================

function Refresh-AIServices {

    $txtDeepSeekStatus.Text =
        "Checking..."


    $txtDeepSeekStatus.Foreground =
        "#8B949E"


    $txtDeepSeekBalance.Text =
        "-"


    try {

        $deepSeek =
            Get-DeepSeekBalance


        $txtDeepSeekStatus.Text =
            $deepSeek.Status


        if ($deepSeek.Available) {

            $txtDeepSeekStatus.Foreground =
                "#3FB950"

        }
        elseif ($deepSeek.Status -eq "API KEY MISSING") {

            $txtDeepSeekStatus.Foreground =
                "#D29922"

        }
        else {

            $txtDeepSeekStatus.Foreground =
                "#F85149"

        }


        if ($deepSeek.TotalBalance -ne "-") {

            $symbol = ""


            if ($deepSeek.Currency -eq "USD") {
                $symbol = '$'
            }
            elseif ($deepSeek.Currency -eq "CNY") {
                $symbol = "CNY "
            }


            $txtDeepSeekBalance.Text =
                "$symbol$($deepSeek.TotalBalance)"


            $txtDeepSeekBalance.ToolTip =
                "Topped up: $($deepSeek.ToppedUp) | Granted: $($deepSeek.Granted)"

        }

    }
    catch {

        $txtDeepSeekStatus.Text =
            "ERROR"


        $txtDeepSeekStatus.Foreground =
            "#F85149"

    }


    $desktop =
        Test-ClaudeDesktopInstalled


    $code =
        Test-ClaudeCodeInstalled


    if ($desktop -and $code) {

        $txtClaudeStatus.Text =
            "Desktop + Code Available"


        $txtClaudeStatus.Foreground =
            "#3FB950"

    }
    elseif ($desktop) {

        $txtClaudeStatus.Text =
            "Desktop Available"


        $txtClaudeStatus.Foreground =
            "#3FB950"

    }
    elseif ($code) {

        $txtClaudeStatus.Text =
            "Claude Code Available"


        $txtClaudeStatus.Foreground =
            "#3FB950"

    }
    else {

        $txtClaudeStatus.Text =
            "NOT FOUND"


        $txtClaudeStatus.Foreground =
            "#D29922"

    }
}


# =====================================================================
# FIND: REFRESH_HOME_DASHBOARD
# Purpose: Rebuild layer cards and summary counts.
# =====================================================================

function Refresh-Dashboard {

    $layerGrid.Children.Clear()


    $index = 0


    foreach ($layer in $layers) {

        Add-LayerCard `
            -Layer $layer `
            -Index $index


        $index++

    }


    $total =
        @($layers).Count


    $started = @(
        $layers |
        Where-Object {
            [string]$_.status -eq "Started"
        }
    ).Count


    $notStarted =
        $total - $started


    $repos = @(
        $layers |
        Where-Object {
            -not [string]::IsNullOrWhiteSpace(
                [string]$_.repository
            )
        }
    ).Count


    $txtTotalLayers.Text =
        $total.ToString()


    $txtStartedLayers.Text =
        $started.ToString()


    $txtNotStartedLayers.Text =
        $notStarted.ToString()


    $txtRepositories.Text =
        $repos.ToString()
}


# =====================================================================
# FIND: HOME_BUTTON_EVENTS
# Purpose: Global buttons on the main dashboard.
# =====================================================================

$btnClaude.Add_Click({

    Open-ClaudeDesktop

})


$btnDevTools.Add_Click({

    Start-Process `
        explorer.exe `
        $DevToolsPath

})


$btnNotifications.Add_Click({

    Test-Notifications

})


$btnGitHub.Add_Click({

    Start-Process `
        "https://github.com/prtcare"

})


$btnRefreshDeepSeek.Add_Click({

    Refresh-AIServices

})


$btnClaudeUsage.Add_Click({

    Open-ClaudeDesktop

})


$btnRefresh.Add_Click({

    Refresh-Dashboard
    Refresh-AIServices

})


# =====================================================================
# FIND: APP_START
# Purpose: Initial refresh and show the main Nexus window.
# =====================================================================

Refresh-Dashboard
Refresh-AIServices

$window.ShowDialog() |
    Out-Null