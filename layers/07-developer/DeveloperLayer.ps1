# ============================================================
# NEXUS - DEVELOPER LAYER MODULE
# ============================================================

function Show-NexusLayer {

    param(
        $Layer,
        [string]$DevToolsPath
    )

    Add-Type -AssemblyName PresentationFramework

    $taskFile =
        Join-Path $DevToolsPath `
        "layers\07-developer\current-task.json"


    # --------------------------------------------------------
    # LOAD CURRENT TASK
    # --------------------------------------------------------

    if (Test-Path $taskFile) {

        $task =
            Get-Content $taskFile -Raw |
            ConvertFrom-Json

    }
    else {

        $task = [pscustomobject]@{
            milestone = "-"
            task       = "No current task"
            repository = "-"
            solution   = "-"
            model      = "-"
            status     = "IDLE"

            workflow = [pscustomobject]@{
                design     = "Pending"
                checkpoint = "Pending"
                implement  = "Pending"
                verify     = "Pending"
                review     = "Pending"
                commit     = "Pending"
            }
        }
    }


    # ========================================================
    # WINDOW
    # ========================================================

    [xml]$xaml = @"

<Window
    xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"

    Title="Nexus Developer"

    Width="1100"
    Height="720"

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
                Value="14,8"/>

            <Setter
                Property="Margin"
                Value="0,0,8,8"/>

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


    <Grid Margin="28">

        <Grid.RowDefinitions>

            <RowDefinition Height="Auto"/>
            <RowDefinition Height="20"/>

            <RowDefinition Height="Auto"/>
            <RowDefinition Height="20"/>

            <RowDefinition Height="Auto"/>
            <RowDefinition Height="20"/>

            <RowDefinition Height="*"/>

        </Grid.RowDefinitions>


        <!-- HEADER -->

        <DockPanel Grid.Row="0">

            <StackPanel>

                <TextBlock
                    Text="07 — DEVELOPER"
                    FontSize="28"
                    FontWeight="SemiBold"/>

                <TextBlock
                    Text="Plan, implement, verify and review Nexus development"
                    FontSize="13"
                    Foreground="#8B949E"
                    Margin="0,5,0,0"/>

            </StackPanel>

        </DockPanel>


        <!-- CURRENT TASK -->

        <Border
            Grid.Row="2"
            Background="#161B22"
            BorderBrush="#30363D"
            BorderThickness="1"
            CornerRadius="8"
            Padding="20">

            <Grid>

                <Grid.ColumnDefinitions>

                    <ColumnDefinition Width="160"/>
                    <ColumnDefinition Width="*"/>

                </Grid.ColumnDefinitions>


                <Grid.RowDefinitions>

                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="Auto"/>

                </Grid.RowDefinitions>


                <TextBlock
                    Grid.Row="0"
                    Grid.Column="0"
                    Text="Milestone"
                    Foreground="#8B949E"/>

                <TextBlock
                    Grid.Row="0"
                    Grid.Column="1"
                    Name="TxtMilestone"
                    FontWeight="SemiBold"/>


                <TextBlock
                    Grid.Row="1"
                    Grid.Column="0"
                    Text="Task"
                    Foreground="#8B949E"
                    Margin="0,8,0,0"/>

                <TextBlock
                    Grid.Row="1"
                    Grid.Column="1"
                    Name="TxtTask"
                    Margin="0,8,0,0"/>


                <TextBlock
                    Grid.Row="2"
                    Grid.Column="0"
                    Text="Repository"
                    Foreground="#8B949E"
                    Margin="0,8,0,0"/>

                <TextBlock
                    Grid.Row="2"
                    Grid.Column="1"
                    Name="TxtRepository"
                    Margin="0,8,0,0"/>


                <TextBlock
                    Grid.Row="3"
                    Grid.Column="0"
                    Text="Solution"
                    Foreground="#8B949E"
                    Margin="0,8,0,0"/>

                <TextBlock
                    Grid.Row="3"
                    Grid.Column="1"
                    Name="TxtSolution"
                    Margin="0,8,0,0"/>


                <TextBlock
                    Grid.Row="4"
                    Grid.Column="0"
                    Text="Implementation model"
                    Foreground="#8B949E"
                    Margin="0,8,0,0"/>

                <TextBlock
                    Grid.Row="4"
                    Grid.Column="1"
                    Name="TxtModel"
                    Margin="0,8,0,0"/>


                <TextBlock
                    Grid.Row="5"
                    Grid.Column="0"
                    Text="Status"
                    Foreground="#8B949E"
                    Margin="0,8,0,0"/>

                <TextBlock
                    Grid.Row="5"
                    Grid.Column="1"
                    Name="TxtStatus"
                    Foreground="#3FB950"
                    FontWeight="Bold"
                    Margin="0,8,0,0"/>

            </Grid>

        </Border>


        <!-- WORKFLOW -->

        <Border
            Grid.Row="4"
            Background="#161B22"
            BorderBrush="#30363D"
            BorderThickness="1"
            CornerRadius="8"
            Padding="20">

            <StackPanel>

                <TextBlock
                    Text="DEVELOPMENT WORKFLOW"
                    Foreground="#8B949E"
                    FontWeight="Bold"
                    FontSize="11"
                    Margin="0,0,0,14"/>


                <Grid>

                    <Grid.ColumnDefinitions>

                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="*"/>

                    </Grid.ColumnDefinitions>


                    <StackPanel Grid.Column="0">

                        <TextBlock
                            Text="DESIGN"
                            HorizontalAlignment="Center"
                            FontWeight="Bold"/>

                        <TextBlock
                            Name="WorkflowDesign"
                            HorizontalAlignment="Center"
                            Margin="0,8,0,0"/>

                    </StackPanel>


                    <StackPanel Grid.Column="1">

                        <TextBlock
                            Text="CHECKPOINT"
                            HorizontalAlignment="Center"
                            FontWeight="Bold"/>

                        <TextBlock
                            Name="WorkflowCheckpoint"
                            HorizontalAlignment="Center"
                            Margin="0,8,0,0"/>

                    </StackPanel>


                    <StackPanel Grid.Column="2">

                        <TextBlock
                            Text="IMPLEMENT"
                            HorizontalAlignment="Center"
                            FontWeight="Bold"/>

                        <TextBlock
                            Name="WorkflowImplement"
                            HorizontalAlignment="Center"
                            Margin="0,8,0,0"/>

                    </StackPanel>


                    <StackPanel Grid.Column="3">

                        <TextBlock
                            Text="VERIFY"
                            HorizontalAlignment="Center"
                            FontWeight="Bold"/>

                        <TextBlock
                            Name="WorkflowVerify"
                            HorizontalAlignment="Center"
                            Margin="0,8,0,0"/>

                    </StackPanel>


                    <StackPanel Grid.Column="4">

                        <TextBlock
                            Text="CLAUDE REVIEW"
                            HorizontalAlignment="Center"
                            FontWeight="Bold"/>

                        <TextBlock
                            Name="WorkflowReview"
                            HorizontalAlignment="Center"
                            Margin="0,8,0,0"/>

                    </StackPanel>


                    <StackPanel Grid.Column="5">

                        <TextBlock
                            Text="COMMIT"
                            HorizontalAlignment="Center"
                            FontWeight="Bold"/>

                        <TextBlock
                            Name="WorkflowCommit"
                            HorizontalAlignment="Center"
                            Margin="0,8,0,0"/>

                    </StackPanel>

                </Grid>

            </StackPanel>

        </Border>


        <!-- ACTIONS -->

        <Border
            Grid.Row="6"
            Background="#161B22"
            BorderBrush="#30363D"
            BorderThickness="1"
            CornerRadius="8"
            Padding="20">

            <StackPanel>

                <TextBlock
                    Text="DEVELOPER TOOLS"
                    Foreground="#8B949E"
                    FontWeight="Bold"
                    FontSize="11"
                    Margin="0,0,0,14"/>


                <WrapPanel>

                    <Button
                        Name="BtnDeepSeek"
                        Content="DeepSeek"/>

                    <Button
                        Name="BtnClaude"
                        Content="Claude Desktop"/>

                    <Button
                        Name="BtnCheckpoint"
                        Content="Checkpoint"/>

                    <Button
                        Name="BtnVerify"
                        Content="Verify"/>

                    <Button
                        Name="BtnGitStatus"
                        Content="Git Status"/>

                    <Button
                        Name="BtnDevTools"
                        Content="Open DevTools"/>

                </WrapPanel>

            </StackPanel>

        </Border>

    </Grid>

</Window>

"@


    $reader =
        New-Object System.Xml.XmlNodeReader $xaml


    $window =
        [Windows.Markup.XamlReader]::Load(
            $reader
        )


    # ========================================================
    # CONTROLS
    # ========================================================

    $txtMilestone =
        $window.FindName("TxtMilestone")

    $txtTask =
        $window.FindName("TxtTask")

    $txtRepository =
        $window.FindName("TxtRepository")

    $txtSolution =
        $window.FindName("TxtSolution")

    $txtModel =
        $window.FindName("TxtModel")

    $txtStatus =
        $window.FindName("TxtStatus")


    $workflowDesign =
        $window.FindName("WorkflowDesign")

    $workflowCheckpoint =
        $window.FindName("WorkflowCheckpoint")

    $workflowImplement =
        $window.FindName("WorkflowImplement")

    $workflowVerify =
        $window.FindName("WorkflowVerify")

    $workflowReview =
        $window.FindName("WorkflowReview")

    $workflowCommit =
        $window.FindName("WorkflowCommit")


    # ========================================================
    # POPULATE
    # ========================================================

    $txtMilestone.Text =
        $task.milestone

    $txtTask.Text =
        $task.task

    $txtRepository.Text =
        $task.repository

    $txtSolution.Text =
        $task.solution

    $txtModel.Text =
        $task.model

    $txtStatus.Text =
        $task.status


    function Set-WorkflowText {

        param(
            $Control,
            [string]$Value
        )


        switch ($Value) {

            "Complete" {

                $Control.Text =
                    "✓ COMPLETE"

                $Control.Foreground =
                    "#3FB950"
            }


            "Active" {

                $Control.Text =
                    "● ACTIVE"

                $Control.Foreground =
                    "#58A6FF"
            }


            default {

                $Control.Text =
                    "○ PENDING"

                $Control.Foreground =
                    "#6E7681"
            }

        }

    }


    Set-WorkflowText `
        $workflowDesign `
        $task.workflow.design


    Set-WorkflowText `
        $workflowCheckpoint `
        $task.workflow.checkpoint


    Set-WorkflowText `
        $workflowImplement `
        $task.workflow.implement


    Set-WorkflowText `
        $workflowVerify `
        $task.workflow.verify


    Set-WorkflowText `
        $workflowReview `
        $task.workflow.review


    Set-WorkflowText `
        $workflowCommit `
        $task.workflow.commit


    # ========================================================
    # BUTTONS
    # ========================================================

    $btnDeepSeek =
        $window.FindName("BtnDeepSeek")

    $btnClaude =
        $window.FindName("BtnClaude")

    $btnCheckpoint =
        $window.FindName("BtnCheckpoint")

    $btnVerify =
        $window.FindName("BtnVerify")

    $btnGitStatus =
        $window.FindName("BtnGitStatus")

    $btnDevTools =
        $window.FindName("BtnDevTools")


    $btnDeepSeek.Add_Click({

        [System.Windows.MessageBox]::Show(
            "Select the target implementation repository from the Nexus home page.",
            "Nexus Developer"
        ) | Out-Null

    })


    $btnClaude.Add_Click({

        if (
            Get-Command Open-ClaudeDesktop `
            -ErrorAction SilentlyContinue
        ) {

            Open-ClaudeDesktop
        }

    })


    $btnCheckpoint.Add_Click({

        [System.Windows.MessageBox]::Show(
            "Checkpoint will operate on the current implementation repository.",
            "Nexus Developer"
        ) | Out-Null

    })


    $btnVerify.Add_Click({

        [System.Windows.MessageBox]::Show(
            "Verification will operate on the current implementation repository.",
            "Nexus Developer"
        ) | Out-Null

    })


    $btnGitStatus.Add_Click({

        [System.Windows.MessageBox]::Show(
            "Git Status will operate on the current implementation repository.",
            "Nexus Developer"
        ) | Out-Null

    })


    $btnDevTools.Add_Click({

        Start-Process `
            explorer.exe `
            $DevToolsPath

    })


    $window.ShowDialog() |
        Out-Null
}