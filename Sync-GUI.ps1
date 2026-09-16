<#
.SYNOPSIS
    Dashboard for the iPhone photo sync: live progress, ETA, pause/resume/stop.

.DESCRIPTION
    The GUI is a viewer and remote control - it does not do the copying itself.
    It reads state\status.json (written by Sync-iPhone.ps1) and state\device.json
    (written by Watch-iPhone.ps1), and sends commands by dropping flag files.

    That means it shows a sync correctly whether you started it from here or the
    watcher started it when you plugged the phone in. Closing this window never
    interrupts a running sync.
#>
[CmdletBinding()]
param([string]$ConfigPath)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

$Root = Split-Path -Parent $MyInvocation.MyCommand.Definition
if (-not $ConfigPath) { $ConfigPath = Join-Path $Root 'config.json' }
$cfg = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json

function ConvertTo-WinPath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $Path }
    # Expands %ENV% vars so config.json can ship portable paths like
    # %USERPROFILE%\Pictures instead of a hard-coded C:\Users\<name>\...
    $Path = [Environment]::ExpandEnvironmentVariables($Path)
    return ($Path -replace '/', '\').TrimEnd('\')
}

$LibraryPath = ConvertTo-WinPath $cfg.LibraryPath
$StateDir    = Join-Path $Root 'state'
$LogDir      = Join-Path $Root 'logs'
$StatusPath  = Join-Path $StateDir 'status.json'
$DevicePath  = Join-Path $StateDir 'device.json'
$IndexPath   = Join-Path $StateDir 'index.tsv'
$PauseFlag   = Join-Path $StateDir 'pause.flag'
$StopFlag    = Join-Path $StateDir 'stop.flag'
$SyncScript  = Join-Path $Root 'Sync-iPhone.ps1'
foreach ($d in @($StateDir, $LogDir)) {
    if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
}

# ------------------------------------------------------------------ XAML ----
$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="iPhone Photo Sync" Height="660" Width="820"
        MinHeight="600" MinWidth="720"
        WindowStartupLocation="CenterScreen"
        WindowStyle="None" ResizeMode="CanResize"
        Background="#0F1116" FontFamily="Segoe UI">

  <Window.Resources>
    <SolidColorBrush x:Key="Bg"      Color="#0F1116"/>
    <SolidColorBrush x:Key="Card"    Color="#191C23"/>
    <SolidColorBrush x:Key="Line"    Color="#272B35"/>
    <SolidColorBrush x:Key="Text"    Color="#E8EAEF"/>
    <SolidColorBrush x:Key="Muted"   Color="#848B9C"/>
    <SolidColorBrush x:Key="Accent"  Color="#4C8DFF"/>
    <SolidColorBrush x:Key="Green"   Color="#35C27E"/>
    <SolidColorBrush x:Key="Amber"   Color="#F5A623"/>
    <SolidColorBrush x:Key="Red"     Color="#FF5C5C"/>

    <Style x:Key="CardBox" TargetType="Border">
      <Setter Property="Background" Value="{StaticResource Card}"/>
      <Setter Property="BorderBrush" Value="{StaticResource Line}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="CornerRadius" Value="10"/>
    </Style>

    <Style x:Key="StatLabel" TargetType="TextBlock">
      <Setter Property="Foreground" Value="{StaticResource Muted}"/>
      <Setter Property="FontSize" Value="11"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
    </Style>
    <Style x:Key="StatValue" TargetType="TextBlock">
      <Setter Property="Foreground" Value="{StaticResource Text}"/>
      <Setter Property="FontSize" Value="21"/>
      <Setter Property="Margin" Value="0,2,0,0"/>
    </Style>

    <Style x:Key="Btn" TargetType="Button">
      <Setter Property="Foreground" Value="{StaticResource Text}"/>
      <Setter Property="Background" Value="#242832"/>
      <Setter Property="BorderBrush" Value="{StaticResource Line}"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="Padding" Value="16,9"/>
      <Setter Property="Margin" Value="0,0,8,0"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="SnapsToDevicePixels" Value="True"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="b" CornerRadius="8" Background="{TemplateBinding Background}"
                    BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="1">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"
                                Margin="{TemplateBinding Padding}"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="b" Property="Background" Value="#2E3340"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="b" Property="Background" Value="#3A4152"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter TargetName="b" Property="Opacity" Value="0.35"/>
                <Setter Property="Cursor" Value="Arrow"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="BtnPrimary" TargetType="Button" BasedOn="{StaticResource Btn}">
      <Setter Property="Background" Value="#2C5FB8"/>
      <Setter Property="BorderBrush" Value="#3B78DC"/>
    </Style>

    <Style x:Key="TitleBtn" TargetType="Button">
      <Setter Property="Foreground" Value="{StaticResource Muted}"/>
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="FontSize" Value="15"/>
      <Setter Property="Width" Value="42"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="b" Background="{TemplateBinding Background}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="b" Property="Background" Value="#2A2F3A"/>
                <Setter Property="Foreground" Value="{StaticResource Text}"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="Bar" TargetType="ProgressBar">
      <Setter Property="Height" Value="10"/>
      <Setter Property="Background" Value="#22262F"/>
      <Setter Property="Foreground" Value="{StaticResource Accent}"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ProgressBar">
            <Border CornerRadius="5" Background="{TemplateBinding Background}" ClipToBounds="True">
              <Grid>
                <Rectangle x:Name="PART_Track"/>
                <Border x:Name="PART_Indicator" CornerRadius="5" HorizontalAlignment="Left"
                        Background="{TemplateBinding Foreground}"/>
              </Grid>
            </Border>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>

  <Border BorderBrush="#272B35" BorderThickness="1" CornerRadius="0">
  <Grid>
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>   <!-- title bar -->
      <RowDefinition Height="Auto"/>   <!-- header -->
      <RowDefinition Height="Auto"/>   <!-- progress -->
      <RowDefinition Height="Auto"/>   <!-- stats -->
      <RowDefinition Height="Auto"/>   <!-- buttons -->
      <RowDefinition Height="*"/>      <!-- log -->
      <RowDefinition Height="Auto"/>   <!-- footer -->
    </Grid.RowDefinitions>

    <!-- ===== title bar ===== -->
    <Grid x:Name="TitleBar" Grid.Row="0" Background="#141720" Height="38">
      <TextBlock Text="iPhone Photo Sync" Foreground="#9AA1B2" FontSize="12"
                 FontWeight="SemiBold" VerticalAlignment="Center" Margin="16,0,0,0"/>
      <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
        <Button x:Name="BtnMin"   Style="{StaticResource TitleBtn}" Content="&#x2013;"/>
        <Button x:Name="BtnClose" Style="{StaticResource TitleBtn}" Content="&#x2715;"/>
      </StackPanel>
    </Grid>

    <!-- ===== header: device + connection ===== -->
    <Grid Grid.Row="1" Margin="20,18,20,0">
      <StackPanel>
        <StackPanel Orientation="Horizontal">
          <Ellipse x:Name="Dot" Width="10" Height="10" Fill="#6B7280" VerticalAlignment="Center"/>
          <TextBlock x:Name="DeviceName" Text="No device" Foreground="{StaticResource Text}"
                     FontSize="17" FontWeight="SemiBold" Margin="10,0,0,0"/>
          <Border x:Name="AutoPill" Background="#1C2A1F" CornerRadius="9" Padding="9,2"
                  Margin="12,0,0,0" VerticalAlignment="Center">
            <TextBlock x:Name="AutoText" Text="Auto-sync on" Foreground="#35C27E" FontSize="11"/>
          </Border>
        </StackPanel>
        <TextBlock x:Name="StatusLine" Text="Starting up" Foreground="{StaticResource Muted}"
                   FontSize="12" Margin="20,4,0,0"/>
      </StackPanel>
    </Grid>

    <!-- ===== progress ===== -->
    <Border Grid.Row="2" Style="{StaticResource CardBox}" Margin="20,16,20,0" Padding="18,16">
      <StackPanel>
        <Grid>
          <TextBlock x:Name="BigStatus" Text="Idle" Foreground="{StaticResource Text}"
                     FontSize="24" FontWeight="Light"/>
          <TextBlock x:Name="Pct" Text="" Foreground="{StaticResource Accent}" FontSize="24"
                     FontWeight="Light" HorizontalAlignment="Right"/>
        </Grid>
        <ProgressBar x:Name="Bar" Style="{StaticResource Bar}" Minimum="0" Maximum="100"
                     Value="0" Margin="0,14,0,0"/>
        <TextBlock x:Name="CurrentFile" Text="" Foreground="{StaticResource Muted}"
                   FontSize="12" Margin="0,10,0,0" TextTrimming="CharacterEllipsis"/>
      </StackPanel>
    </Border>

    <!-- ===== stat cards ===== -->
    <Grid Grid.Row="3" Margin="20,14,20,0">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="*"/><ColumnDefinition Width="*"/>
        <ColumnDefinition Width="*"/><ColumnDefinition Width="*"/>
      </Grid.ColumnDefinitions>
      <Grid.RowDefinitions>
        <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
      </Grid.RowDefinitions>

      <Border Grid.Row="0" Grid.Column="0" Style="{StaticResource CardBox}" Margin="0,0,6,6" Padding="14,11">
        <StackPanel>
          <TextBlock Text="IMPORTED" Style="{StaticResource StatLabel}"/>
          <TextBlock x:Name="VDone" Text="0" Style="{StaticResource StatValue}"/>
        </StackPanel>
      </Border>
      <Border Grid.Row="0" Grid.Column="1" Style="{StaticResource CardBox}" Margin="6,0,6,6" Padding="14,11">
        <StackPanel>
          <TextBlock Text="REMAINING" Style="{StaticResource StatLabel}"/>
          <TextBlock x:Name="VLeft" Text="0" Style="{StaticResource StatValue}"/>
        </StackPanel>
      </Border>
      <Border Grid.Row="0" Grid.Column="2" Style="{StaticResource CardBox}" Margin="6,0,6,6" Padding="14,11">
        <StackPanel>
          <TextBlock Text="TIME LEFT" Style="{StaticResource StatLabel}"/>
          <TextBlock x:Name="VEta" Text="&#8212;" Style="{StaticResource StatValue}"
                     Foreground="#4C8DFF"/>
        </StackPanel>
      </Border>
      <Border Grid.Row="0" Grid.Column="3" Style="{StaticResource CardBox}" Margin="6,0,0,6" Padding="14,11">
        <StackPanel>
          <TextBlock Text="SPEED" Style="{StaticResource StatLabel}"/>
          <TextBlock x:Name="VSpeed" Text="&#8212;" Style="{StaticResource StatValue}"/>
        </StackPanel>
      </Border>

      <Border Grid.Row="1" Grid.Column="0" Style="{StaticResource CardBox}" Margin="0,6,6,0" Padding="14,11">
        <StackPanel>
          <TextBlock Text="DATA COPIED" Style="{StaticResource StatLabel}"/>
          <TextBlock x:Name="VBytes" Text="0 MB" Style="{StaticResource StatValue}"/>
        </StackPanel>
      </Border>
      <Border Grid.Row="1" Grid.Column="1" Style="{StaticResource CardBox}" Margin="6,6,6,0" Padding="14,11">
        <StackPanel>
          <TextBlock Text="ALREADY HAD" Style="{StaticResource StatLabel}"/>
          <TextBlock x:Name="VHad" Text="0" Style="{StaticResource StatValue}"/>
        </StackPanel>
      </Border>
      <Border Grid.Row="1" Grid.Column="2" Style="{StaticResource CardBox}" Margin="6,6,6,0" Padding="14,11">
        <StackPanel>
          <TextBlock Text="PHOTO DATE" Style="{StaticResource StatLabel}"/>
          <TextBlock x:Name="VDate" Text="&#8212;" Style="{StaticResource StatValue}"/>
        </StackPanel>
      </Border>
      <Border Grid.Row="1" Grid.Column="3" Style="{StaticResource CardBox}" Margin="6,6,0,0" Padding="14,11">
        <StackPanel>
          <TextBlock Text="FAILED" Style="{StaticResource StatLabel}"/>
          <TextBlock x:Name="VFailed" Text="0" Style="{StaticResource StatValue}"/>
        </StackPanel>
      </Border>
    </Grid>

    <!-- ===== buttons ===== -->
    <Grid Grid.Row="4" Margin="20,18,20,0">
      <StackPanel Orientation="Horizontal">
        <Button x:Name="BtnPause" Style="{StaticResource Btn}" Content="Pause" Width="110" IsEnabled="False"/>
        <Button x:Name="BtnStop"  Style="{StaticResource Btn}" Content="Stop"  Width="100" IsEnabled="False"/>
      </StackPanel>
      <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
        <Button x:Name="BtnFolder" Style="{StaticResource Btn}" Content="Open library"/>
        <Button x:Name="BtnLogs"   Style="{StaticResource Btn}" Content="Logs"/>
        <Button x:Name="BtnSync"   Style="{StaticResource BtnPrimary}" Content="Sync now" Width="120" Margin="0"/>
      </StackPanel>
    </Grid>

    <!-- ===== log tail ===== -->
    <Border Grid.Row="5" Style="{StaticResource CardBox}" Margin="20,16,20,0" Padding="14,12">
      <StackPanel>
        <TextBlock Text="ACTIVITY" Style="{StaticResource StatLabel}" Margin="0,0,0,7"/>
        <TextBlock x:Name="LogTail" Text="" Foreground="#7F8698" FontSize="11.5"
                   FontFamily="Consolas" LineHeight="17" TextWrapping="NoWrap"/>
      </StackPanel>
    </Border>

    <!-- ===== footer ===== -->
    <Grid Grid.Row="6" Margin="20,12,20,16">
      <TextBlock x:Name="LibInfo" Text="" Foreground="{StaticResource Muted}" FontSize="11.5"/>
      <TextBlock x:Name="LastSync" Text="" Foreground="{StaticResource Muted}" FontSize="11.5"
                 HorizontalAlignment="Right"/>
    </Grid>
  </Grid>
  </Border>
</Window>
'@

$window = [Windows.Markup.XamlReader]::Parse($xaml)

# ------------------------------------------------------------- controls -----
$ctl = @{}
foreach ($n in @('TitleBar','BtnMin','BtnClose','Dot','DeviceName','AutoPill','AutoText',
                 'StatusLine','BigStatus','Pct','Bar','CurrentFile','VDone','VLeft','VEta',
                 'VSpeed','VBytes','VHad','VDate','VFailed','BtnPause','BtnStop','BtnFolder',
                 'BtnLogs','BtnSync','LogTail','LibInfo','LastSync')) {
    $ctl[$n] = $window.FindName($n)
}

# ------------------------------------------------------------- helpers ------
function Format-Bytes {
    param([double]$B)
    if ($B -ge 1TB) { return ('{0:N2} TB' -f ($B / 1TB)) }
    if ($B -ge 1GB) { return ('{0:N2} GB' -f ($B / 1GB)) }
    if ($B -ge 1MB) { return ('{0:N1} MB' -f ($B / 1MB)) }
    if ($B -ge 1KB) { return ('{0:N0} KB' -f ($B / 1KB)) }
    return ('{0:N0} B' -f $B)
}

function Format-Duration {
    param([int]$Sec)
    if ($Sec -lt 0) { return [char]0x2014 }
    if ($Sec -lt 60) { return ('{0}s' -f $Sec) }
    $t = [TimeSpan]::FromSeconds($Sec)
    if ($t.TotalHours -ge 1) { return ('{0}h {1:00}m' -f [int]$t.TotalHours, $t.Minutes) }
    return ('{0}m {1:00}s' -f $t.Minutes, $t.Seconds)
}

function Format-MonthBucket {
    param([string]$B)
    if ([string]::IsNullOrWhiteSpace($B)) { return [string][char]0x2014 }
    $d = [datetime]::MinValue
    if ([datetime]::TryParseExact($B + '-01', 'yyyy-MM-dd', $null, 'None', [ref]$d)) {
        return $d.ToString('MMM yyyy')
    }
    return $B
}

function Read-JsonFile {
    param([string]$Path)
    for ($i = 0; $i -lt 3; $i++) {
        try {
            if (-not (Test-Path -LiteralPath $Path)) { return $null }
            $raw = [IO.File]::ReadAllText($Path)
            if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
            return ($raw | ConvertFrom-Json)
        } catch { Start-Sleep -Milliseconds 40 }
    }
    return $null
}

function Update-LibraryInfo {
    try {
        $count = 0
        if (Test-Path -LiteralPath $IndexPath) {
            $count = @([IO.File]::ReadAllLines($IndexPath)).Count
        }
        $years = @()
        if (Test-Path -LiteralPath $LibraryPath) {
            $years = @(Get-ChildItem -LiteralPath $LibraryPath -Directory -ErrorAction SilentlyContinue |
                       Where-Object { $_.Name -match '^\d{4}$' } | ForEach-Object { [int]$_.Name } | Sort-Object)
        }
        [long]$size = 0
        if (Test-Path -LiteralPath $LibraryPath) {
            foreach ($f in [IO.Directory]::EnumerateFiles($LibraryPath, '*', 'AllDirectories')) {
                $size += (New-Object IO.FileInfo $f).Length
            }
        }
        $span = if ($years.Count -gt 0) { '{0} - {1}' -f $years[0], $years[-1] } else { 'empty' }
        $ctl.LibInfo.Text = 'Library: {0:N0} items  -  {1}  -  {2}' -f $count, $span, (Format-Bytes $size)
    } catch {
        $ctl.LibInfo.Text = 'Library: ' + $LibraryPath
    }
}

# --------------------------------------------------------------- actions ----
$ctl.BtnClose.Add_Click({ $window.Close() })
$ctl.BtnMin.Add_Click({ $window.WindowState = 'Minimized' })
$ctl.TitleBar.Add_MouseLeftButtonDown({ try { $window.DragMove() } catch { } })

$ctl.BtnPause.Add_Click({
    if (Test-Path -LiteralPath $PauseFlag) {
        Remove-Item -LiteralPath $PauseFlag -Force -ErrorAction SilentlyContinue
    } else {
        Set-Content -LiteralPath $PauseFlag -Value 'paused' -Encoding ASCII
    }
})

$ctl.BtnStop.Add_Click({
    Set-Content -LiteralPath $StopFlag -Value 'stop' -Encoding ASCII
    Remove-Item -LiteralPath $PauseFlag -Force -ErrorAction SilentlyContinue
    $ctl.BtnStop.IsEnabled = $false
    $ctl.StatusLine.Text = 'Stopping after the current file...'
})

$ctl.BtnSync.Add_Click({
    $ctl.BtnSync.IsEnabled = $false
    Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -ArgumentList @(
        '-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass',
        '-File', ('"{0}"' -f $SyncScript), '-UnlockWaitSeconds','120'
    )
})

$ctl.BtnFolder.Add_Click({
    if (-not (Test-Path -LiteralPath $LibraryPath)) {
        New-Item -ItemType Directory -Path $LibraryPath -Force | Out-Null
    }
    Start-Process explorer.exe $LibraryPath
})

$ctl.BtnLogs.Add_Click({ Start-Process explorer.exe $LogDir })

# ------------------------------------------------------------- the loop -----
$script:tick        = 0
$script:lastState   = ''
$brushGreen = New-Object Windows.Media.SolidColorBrush ([Windows.Media.ColorConverter]::ConvertFromString('#35C27E'))
$brushGrey  = New-Object Windows.Media.SolidColorBrush ([Windows.Media.ColorConverter]::ConvertFromString('#6B7280'))
$brushAmber = New-Object Windows.Media.SolidColorBrush ([Windows.Media.ColorConverter]::ConvertFromString('#F5A623'))
$brushRed   = New-Object Windows.Media.SolidColorBrush ([Windows.Media.ColorConverter]::ConvertFromString('#FF5C5C'))
$brushBlue  = New-Object Windows.Media.SolidColorBrush ([Windows.Media.ColorConverter]::ConvertFromString('#4C8DFF'))

$timer = New-Object Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(500)

$timer.Add_Tick({
    $script:tick++

    # ---- device / watcher ----
    $dev       = Read-JsonFile $DevicePath
    $present   = $false
    $watcherOk = $false
    if ($dev) {
        $present = [bool]$dev.Present
        try {
            $age = (Get-Date).ToUniversalTime() - [datetime]::Parse($dev.UpdatedUtc).ToUniversalTime()
            $watcherOk = $age.TotalSeconds -lt ([int]$cfg.PollSeconds * 4 + 15)
        } catch { }
    }
    if ($watcherOk) {
        $ctl.AutoText.Text = 'Auto-sync on'
        $ctl.AutoText.Foreground = $brushGreen
        $ctl.AutoPill.Background = New-Object Windows.Media.SolidColorBrush ([Windows.Media.ColorConverter]::ConvertFromString('#152A1D'))
    } else {
        $ctl.AutoText.Text = 'Auto-sync off'
        $ctl.AutoText.Foreground = $brushAmber
        $ctl.AutoPill.Background = New-Object Windows.Media.SolidColorBrush ([Windows.Media.ColorConverter]::ConvertFromString('#2A2315'))
    }

    # ---- status ----
    $st = Read-JsonFile $StatusPath
    $state = 'Idle'
    if ($st -and $st.State) { $state = [string]$st.State }

    $running = @('Starting','Waiting','Scanning','Copying','Paused','Stopping') -contains $state
    $procAlive = $false
    if ($running -and $st -and $st.Pid) {
        $procAlive = [bool](Get-Process -Id $st.Pid -ErrorAction SilentlyContinue)
        if (-not $procAlive) { $running = $false; $state = 'Idle' }
    }

    # A wedged MTP session leaves the process alive but blocked inside a COM call
    # that never returns: it stops publishing status and cannot honour Pause or
    # Stop, because it never gets back to check them. Showing a cheerful
    # "Importing..." then makes the buttons look broken. Say what is true.
    $script:Stalled = $false
    if ($running -and $st -and $st.UpdatedUtc) {
        try {
            $statusAge = ((Get-Date).ToUniversalTime() - [datetime]::Parse($st.UpdatedUtc).ToUniversalTime()).TotalSeconds
            if ($statusAge -gt 90) { $script:Stalled = $true }
        } catch { }
    }

    # connection dot + name
    if ($present) {
        $ctl.Dot.Fill = $brushGreen
        $n = ''
        if ($dev -and $dev.Name) { $n = [string]$dev.Name }
        if (-not $n -and $st -and $st.Device) { $n = [string]$st.Device }
        if (-not $n) { $n = 'iPhone connected' }
        $ctl.DeviceName.Text = $n
    } else {
        $ctl.Dot.Fill = $brushGrey
        $ctl.DeviceName.Text = 'No device connected'
    }

    if ($st) {
        $done  = [int]$st.Done
        $total = [int]$st.Total
        $left  = [Math]::Max(0, $total - $done - [int]$st.Failed)

        $ctl.VDone.Text   = '{0:N0}' -f $done
        $ctl.VLeft.Text   = '{0:N0}' -f $left
        $ctl.VHad.Text    = '{0:N0}' -f ([int]$st.AlreadyHad)
        $ctl.VFailed.Text = '{0:N0}' -f ([int]$st.Failed)
        $ctl.VBytes.Text  = Format-Bytes ([double]$st.Bytes)
        $ctl.VDate.Text   = Format-MonthBucket ([string]$st.CurrentDate)
        $ctl.VFailed.Foreground = if ([int]$st.Failed -gt 0) { $brushAmber } else { $ctl.VDone.Foreground }

        if ($running -and [double]$st.BytesPerSec -gt 0) {
            $ctl.VSpeed.Text = (Format-Bytes ([double]$st.BytesPerSec)) + '/s'
        } else {
            $ctl.VSpeed.Text = [string][char]0x2014
        }
        $ctl.VEta.Text = if ($running) { Format-Duration ([int]$st.EtaSeconds) } else { [string][char]0x2014 }

        if ($script:Stalled) {
            $ctl.BigStatus.Text  = 'Not responding'
            $ctl.StatusLine.Text = 'The phone stopped responding mid-transfer. Pause and Stop cannot ' +
                                   'work while it is wedged - it recovers by itself, or replug the cable.'
        } else {
            $ctl.BigStatus.Text  = [string]$st.Phase
            $ctl.StatusLine.Text = if ($running) { 'Do not unplug - or do; it resumes where it left off.' }
                                   elseif ($st.LastResult) { [string]$st.LastResult }
                                   else { 'Idle' }
        }

        if ($total -gt 0) {
            $p = [Math]::Min(100, [Math]::Round(($done / [double]$total) * 100, 1))
            $ctl.Bar.Value = $p
            $ctl.Pct.Text  = '{0:N0}%' -f $p
        } elseif (-not $running) {
            $ctl.Bar.Value = 0; $ctl.Pct.Text = ''
        }

        $cf = [string]$st.CurrentFile
        $al = [string]$st.Album
        if ($running -and $cf) {
            $ctl.CurrentFile.Text = if ($al) { "$cf   -   $al" } else { $cf }
        } elseif (-not $running) {
            $ctl.CurrentFile.Text = ''
        }

        if ($st.FinishedUtc) {
            try {
                $f = [datetime]::Parse($st.FinishedUtc).ToLocalTime()
                $ctl.LastSync.Text = 'Last sync: ' + $f.ToString('ddd d MMM, HH:mm')
            } catch { }
        }
    }

    # paused / stopped visual state
    if ($script:Stalled) {
        $ctl.Bar.Foreground   = $brushAmber
        $ctl.Pct.Foreground   = $brushAmber
        $ctl.BtnPause.Content = 'Pause'
    } elseif ($state -eq 'Paused') {
        $ctl.Bar.Foreground   = $brushAmber
        $ctl.Pct.Foreground   = $brushAmber
        $ctl.BtnPause.Content = 'Resume'
    } elseif ($state -eq 'Error') {
        $ctl.Bar.Foreground = $brushRed
        $ctl.Pct.Foreground = $brushRed
    } else {
        $ctl.Bar.Foreground   = $brushBlue
        $ctl.Pct.Foreground   = $brushBlue
        $ctl.BtnPause.Content = 'Pause'
    }

    # Grey these out while wedged rather than letting them look ignored.
    $ctl.BtnPause.IsEnabled = $running -and -not $script:Stalled
    $ctl.BtnStop.IsEnabled  = $running -and -not $script:Stalled -and -not (Test-Path -LiteralPath $StopFlag)
    $ctl.BtnSync.IsEnabled  = -not $running

    # ---- log tail every 2s ----
    if (($script:tick % 4) -eq 0) {
        try {
            $lp = Join-Path $LogDir ('sync-{0}.log' -f (Get-Date -Format 'yyyyMMdd'))
            if (-not (Test-Path -LiteralPath $lp)) {
                $lp = (Get-ChildItem -LiteralPath $LogDir -Filter 'sync-*.log' -ErrorAction SilentlyContinue |
                       Sort-Object LastWriteTime -Descending | Select-Object -First 1 -ExpandProperty FullName)
            }
            if ($lp -and (Test-Path -LiteralPath $lp)) {
                $tail = @(Get-Content -LiteralPath $lp -Tail 7 -ErrorAction SilentlyContinue)
                $ctl.LogTail.Text = if ($tail.Count) { $tail -join "`n" } else { 'Nothing yet.' }
            } else {
                $ctl.LogTail.Text = 'No activity yet - plug in your iPhone, or press Sync now.'
            }
        } catch { }
    }

    # ---- library stats: at startup and whenever a sync finishes ----
    if ($script:lastState -ne $state -and $state -eq 'Idle') { Update-LibraryInfo }
    $script:lastState = $state
})

$window.Add_SourceInitialized({ Update-LibraryInfo; $timer.Start() })
$window.Add_Closed({ $timer.Stop() })

[void]$window.ShowDialog()
