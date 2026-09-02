function Show-NexusLayerPage {

    param(
        $Layer,
        [string]$DevToolsPath
    )

    Add-Type -AssemblyName PresentationFramework
    Add-Type -AssemblyName PresentationCore

    $pageConfigPath =
        Join-Path $DevToolsPath "config\layer-pages.json"

    if (-not (Test-Path $pageConfigPath)) {

        [System.Windows.MessageBox]::Show(
            "Layer page configuration not found:`n$pageConfigPath",
            "Nexus"
        ) | Out-Null

        return
    }

    $allPageConfig =
        Get-Content $pageConfigPath -Raw |
        ConvertFrom-Json

    $pageConfig =
        $allPageConfig.($Layer.number)

    if (-not $pageConfig) {

        [System.Windows.MessageBox]::Show(
            "No page configuration exists for Layer $($Layer.number).",
            "Nexus"
        ) | Out-Null

        return
    }


    # ========================================================
    # WINDOW
    # ========================================================

    [xml]$xaml = @"

<Window
    xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"

    Title="Nexus - $($Layer.name)"

    Width="1350"
    Height="820"

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
                Value="12,8"/>

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


    <Grid>

        <Grid.RowDefinitions>

            <RowDefinition Height="64"/>

            <RowDefinition Height="*"/>

        </Grid.RowDefinitions>


        <!-- ================================================= -->
        <!-- TOP BAR -->
        <!-- ================================================= -->

        <Border
            Grid.Row="0"
            Background="#161B22"
            BorderBrush="#30363D"
            BorderThickness="0,0,0,1">

            <DockPanel Margin="16,10">


                <StackPanel
                    Orientation="Horizontal"
                    DockPanel.Dock="Left">

                    <Button
                        Name="BtnHamburger"
                        Content="☰"
                        FontSize="18"
                        Width="46"/>


                    <Button
                        Name="BtnHome"
                        Content="Home"
                        Width="70"/>

                </StackPanel>


                <StackPanel
                    Margin="15,0,0,0">

                    <TextBlock
                        Text="LAYER $($Layer.number) - $($Layer.name)"
                        FontSize="20"
                        FontWeight="SemiBold"/>


                    <TextBlock
                        Text="Solution: $(if ($Layer.solution) { $Layer.solution } else { 'Not assigned' })"
                        FontSize="11"
                        Foreground="#8B949E"/>

                </StackPanel>

            </DockPanel>

        </Border>


        <!-- ================================================= -->
        <!-- BODY -->
        <!-- ================================================= -->

        <Grid Grid.Row="1">

            <Grid.ColumnDefinitions>

                <ColumnDefinition Width="Auto"/>

                <ColumnDefinition Width="*"/>

            </Grid.ColumnDefinitions>


            <!-- ============================================= -->
            <!-- HAMBURGER MENU -->
            <!-- ============================================= -->

            <Border
                Name="MenuPanel"
                Grid.Column="0"
                Width="230"
                Background="#161B22"
                BorderBrush="#30363D"
                BorderThickness="0,0,1,0"
                Padding="12">

                <StackPanel>

                    <TextBlock
                        Text="$($Layer.name)"
                        FontSize="16"
                        FontWeight="SemiBold"
                        Margin="5,5,5,5"/>


                    <TextBlock
                        Text="$($Layer.description)"
                        Foreground="#8B949E"
                        TextWrapping="Wrap"
                        FontSize="11"
                        Margin="5,0,5,18"/>


                    <StackPanel
                        Name="MenuItems"/>

                </StackPanel>

            </Border>


            <!-- ============================================= -->
            <!-- CONTENT -->
            <!-- ============================================= -->

            <Grid
                Grid.Column="1"
                Margin="28">

                <Grid.RowDefinitions>

                    <RowDefinition Height="Auto"/>

                    <RowDefinition Height="12"/>

                    <RowDefinition Height="*"/>

                </Grid.RowDefinitions>


                <TextBlock
                    Name="TxtPageTitle"
                    Text="Overview"
                    FontSize="26"
                    FontWeight="SemiBold"/>


                <Border
                    Grid.Row="2"
                    Background="#161B22"
                    BorderBrush="#30363D"
                    BorderThickness="1"
                    CornerRadius="8"
                    Padding="20">

                    <Grid>

                        <Grid.RowDefinitions>

                            <RowDefinition Height="Auto"/>

                            <RowDefinition Height="12"/>

                            <RowDefinition Height="*"/>

                        </Grid.RowDefinitions>


                        <TextBlock
                            Name="TxtContent"
                            TextWrapping="Wrap"
                            Foreground="#C9D1D9"
                            FontSize="13"/>


                        <ListBox
                            Name="ContentList"
                            Grid.Row="2"
                            Background="#0D1117"
                            Foreground="#F0F6FC"
                            BorderBrush="#30363D"
                            Visibility="Collapsed"/>

                    </Grid>

                </Border>

            </Grid>

        </Grid>

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
    # REFERENCES
    # ========================================================

    $btnHamburger =
        $window.FindName("BtnHamburger")


    $btnHome =
        $window.FindName("BtnHome")


    $menuPanel =
        $window.FindName("MenuPanel")


    $menuItems =
        $window.FindName("MenuItems")


    $txtPageTitle =
        $window.FindName("TxtPageTitle")


    $txtContent =
        $window.FindName("TxtContent")


    $contentList =
        $window.FindName("ContentList")


    # ========================================================
    # CONTENT RENDERER
    # ========================================================

    function Show-LayerSection {

        param(
            [string]$Section
        )


        $txtContent.Visibility =
            "Visible"


        $contentList.Visibility =
            "Collapsed"


        $contentList.Items.Clear()


        switch ($Section) {


            # ------------------------------------------------
            # OVERVIEW
            # ------------------------------------------------

            "overview" {

                $txtPageTitle.Text =
                    "Overview"


                $repoText =
                    if ($Layer.repository) {
                        $Layer.repository
                    }
                    else {
                        "Not assigned"
                    }


                $pathText =
                    if ($Layer.path) {
                        $Layer.path
                    }
                    else {
                        "Not assigned"
                    }


                $solutionText =
                    if ($Layer.solution) {
                        $Layer.solution
                    }
                    else {
                        "Not assigned"
                    }


                $txtContent.Text = @"
Layer:       $($Layer.number) - $($Layer.name)

Purpose:
$($Layer.description)

Status:      $($Layer.status)

Solution:    $solutionText

Repository:  $repoText

Path:        $pathText
"@

            }


            # ------------------------------------------------
            # FILES
            # ------------------------------------------------

            "files" {

                $txtPageTitle.Text =
                    "Files"


                $txtContent.Visibility =
                    "Collapsed"


                $contentList.Visibility =
                    "Visible"


                if (
                    [string]::IsNullOrWhiteSpace(
                        [string]$Layer.path
                    )
                ) {

                    $contentList.Items.Add(
                        "No repository has been assigned to this layer."
                    ) | Out-Null

                    return
                }


                if (-not (Test-Path $Layer.path)) {

                    $contentList.Items.Add(
                        "Repository folder not found: $($Layer.path)"
                    ) | Out-Null

                    return
                }


                $files =
                    Get-ChildItem `
                        -Path $Layer.path `
                        -File `
                        -Recurse `
                        -ErrorAction SilentlyContinue |
                    Where-Object {

                        $_.FullName -notmatch "\\node_modules\\" -and

                        $_.FullName -notmatch "\\\.git\\" -and

                        $_.FullName -notmatch "\\bin\\" -and

                        $_.FullName -notmatch "\\obj\\"

                    } |
                    Select-Object -First 150


                foreach ($file in $files) {

                    $relative =
                        $file.FullName.Substring(
                            $Layer.path.Length
                        ).TrimStart("\")


                    $contentList.Items.Add(
                        $relative
                    ) | Out-Null

                }

            }


            # ------------------------------------------------
            # PRODUCTS
            # ------------------------------------------------

            "products" {

                $txtPageTitle.Text =
                    "Products"


                $txtContent.Visibility =
                    "Collapsed"


                $contentList.Visibility =
                    "Visible"


                $products =
                    @($pageConfig.products)


                if ($products.Count -eq 0) {

                    $contentList.Items.Add(
                        "No products have been configured yet."
                    ) | Out-Null

                }
                else {

                    foreach ($product in $products) {

                        $contentList.Items.Add(
                            $product
                        ) | Out-Null

                    }

                }

            }


            # ------------------------------------------------
            # FEATURES
            # ------------------------------------------------

            "features" {

                $txtPageTitle.Text =
                    "Features"


                $txtContent.Visibility =
                    "Collapsed"


                $contentList.Visibility =
                    "Visible"


                $features =
                    @($pageConfig.features)


                if ($features.Count -eq 0) {

                    $contentList.Items.Add(
                        "No features have been configured yet."
                    ) | Out-Null

                }
                else {

                    foreach ($feature in $features) {

                        $contentList.Items.Add(
                            $feature
                        ) | Out-Null

                    }

                }

            }


            # ------------------------------------------------
            # EXISTING SPECIALIST MODULE
            # ------------------------------------------------

            "module" {

                if (
                    [string]::IsNullOrWhiteSpace(
                        [string]$Layer.module
                    )
                ) {

                    $txtPageTitle.Text =
                        "Layer Console"


                    $txtContent.Text =
                        "No specialist module exists for this layer yet."

                    return
                }


                if (-not (Test-Path $Layer.module)) {

                    $txtContent.Text =
                        "Layer module not found:`n$($Layer.module)"

                    return
                }


                try {

                    . $Layer.module


                    if (
                        Get-Command Show-NexusLayer `
                        -ErrorAction SilentlyContinue
                    ) {

                        Show-NexusLayer `
                            -Layer $Layer `
                            -DevToolsPath $DevToolsPath

                    }

                }
                catch {

                    $txtContent.Text =
                        "Unable to open layer module:`n$($_.Exception.Message)"

                }

            }


            # ------------------------------------------------
            # FUTURE SECTIONS
            # ------------------------------------------------

            default {

                $menu =
                    $pageConfig.menus |
                    Where-Object {
                        $_.id -eq $Section
                    } |
                    Select-Object -First 1


                $title =
                    if ($menu) {
                        $menu.label
                    }
                    else {
                        $Section
                    }


                $txtPageTitle.Text =
                    $title


                $txtContent.Text = @"
$title

This section belongs specifically to the $($Layer.name) layer.

The common Nexus Layer Framework is ready for this section.

Its detailed implementation will be added as the layer develops.
"@

            }

        }

    }


    # ========================================================
    # CREATE MENU
    # ========================================================

    foreach ($menu in $pageConfig.menus) {

        $button =
            New-Object System.Windows.Controls.Button


        $button.Content =
            $menu.label


        $button.Tag =
            $menu.id


        $button.HorizontalContentAlignment =
            "Left"


        $button.Width =
            200


        $button.Add_Click({

            param(
                $sender,
                $eventArgs
            )


            Show-LayerSection `
                -Section ([string]$sender.Tag)

        })


        $menuItems.Children.Add(
            $button
        ) | Out-Null

    }


    # ========================================================
    # HAMBURGER
    # ========================================================

    $btnHamburger.Add_Click({

        if (
            $menuPanel.Visibility -eq "Visible"
        ) {

            $menuPanel.Visibility =
                "Collapsed"

        }
        else {

            $menuPanel.Visibility =
                "Visible"

        }

    })


    # ========================================================
    # HOME
    # ========================================================

    $btnHome.Add_Click({

        $window.Close()

    })


    # ========================================================
    # DEFAULT PAGE
    # ========================================================

    Show-LayerSection `
        -Section "overview"


    $window.ShowDialog() |
        Out-Null
}