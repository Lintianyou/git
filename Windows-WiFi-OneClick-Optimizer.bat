@echo off
setlocal EnableExtensions
chcp 65001 >nul
title Windows Wi-Fi One-Click Optimizer

:: ============================================================
::  Windows 10/11 Wi-Fi one-click optimizer
::  1. Set Preferred Band to 5GHz first
::  2. Uncheck "Allow the computer to turn off this device to save power"
::  3. Restart the Wi-Fi adapter so the settings take effect
::  4. Show a before/after Wi-Fi link rate comparison in a popup
::  Single-file BAT with embedded PowerShell. No extra files needed.
:: ============================================================

:: Require administrator rights (fltmc only works elevated)
set "SELF=%~f0"
fltmc >nul 2>&1
if errorlevel 1 (
    echo Requesting administrator privileges. Click Yes in the UAC prompt...
    powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath $env:SELF -Verb RunAs"
    exit /b
)

:: Run the embedded PowerShell block at the end of this file
powershell -NoProfile -ExecutionPolicy Bypass -Command "$t=[IO.File]::ReadAllText($env:SELF);$m='#___PS_START___';$i=$t.LastIndexOf($m);if($i -lt 0){exit 1};Invoke-Expression $t.Substring($i+$m.Length)"
if errorlevel 1 (
    echo.
    echo Script failed. Right-click this file and choose "Run as administrator".
    pause >nul
)
exit /b

#___PS_START___
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop

function Show-Result {
    param([string]$Text, [string]$Title = 'Wi-Fi 优化结果')
    [System.Windows.Forms.MessageBox]::Show(
        $Text,
        $Title,
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Information
    ) | Out-Null
}

function Get-WifiAdapters {
    @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object {
        $_.PhysicalMediaType -eq 'Native 802.11' -or
        $_.InterfaceDescription -match '(?i)wireless|wi-?fi|wlan|802\.11'
    })
}

function Get-WifiInfo {
    param([string]$AdapterName)

    $adapter = Get-NetAdapter -Name $AdapterName -ErrorAction SilentlyContinue
    $info = [ordered]@{
        Status    = if ($adapter) { [string]$adapter.Status } else { 'Unknown' }
        LinkSpeed = if ($adapter) { [string]$adapter.LinkSpeed } else { 'N/A' }
        Band      = '未知'
        Channel   = '未知'
        Signal    = '未知'
        Rx        = 'N/A'
        Tx        = 'N/A'
    }

    # netsh 的字段在中英文系统上都可能不同，这里同时匹配中英文键名
    $lines = @(netsh wlan show interfaces 2>$null)
    $inSection = $false
    foreach ($line in $lines) {
        if ($line -match '^\s*(Name|名称)\s*:\s*(.+?)\s*$') {
            $inSection = ($Matches[2].Trim() -eq $AdapterName)
        }
        elseif ($inSection) {
            if ($line -match '^\s*(Band|频带|频段)\s*:\s*(.+?)\s*$') {
                $info.Band = $Matches[2].Trim()
            }
            elseif ($line -match '^\s*(Channel|信道)\s*:\s*(.+?)\s*$') {
                $info.Channel = $Matches[2].Trim()
            }
            elseif ($line -match '^\s*(Signal|信号)\s*:\s*(.+?)\s*$') {
                $info.Signal = $Matches[2].Trim()
            }
            elseif ($line -match '^\s*(Receive rate \(Mbps\)|接收速率.*?)\s*:\s*(.+?)\s*$') {
                $info.Rx = $Matches[2].Trim()
            }
            elseif ($line -match '^\s*(Transmit rate \(Mbps\)|发送速率.*?)\s*:\s*(.+?)\s*$') {
                $info.Tx = $Matches[2].Trim()
            }
        }
    }

    # Windows 10 的 netsh 不显示 Band 字段，按信道推断（Win10 不支持 6GHz）
    if ($info.Band -eq '未知' -and $info.Channel -match '^\d+$' -and
        [Environment]::OSVersion.Version.Build -lt 22000) {
        $channelNumber = [int]$info.Channel
        if ($channelNumber -le 14) { $info.Band = '2.4 GHz' }
        elseif ($channelNumber -ge 32 -and $channelNumber -le 196) { $info.Band = '5 GHz' }
    }

    return [pscustomobject]$info
}

function Format-WifiInfo {
    param($Info)
    $speed = if ($Info.LinkSpeed -and $Info.LinkSpeed -ne 'N/A') { $Info.LinkSpeed } else { '未知' }
    return ("{0} | 信道 {1} | 链路速率 {2} | 信号 {3}" -f $Info.Band, $Info.Channel, $speed, $Info.Signal)
}

function Convert-SpeedToMbps {
    param([string]$Speed)
    if ($Speed -match '([\d.]+)\s*(Gbps|Mbps|Kbps)') {
        $value = [double]$Matches[1]
        switch ($Matches[2].ToLowerInvariant()) {
            'gbps' { return [math]::Round($value * 1000, 1) }
            'kbps' { return [math]::Round($value / 1000, 1) }
            default { return [math]::Round($value, 1) }
        }
    }
    return $null
}

function Set-PreferredBand {
    param($Adapter)

    $props = @(Get-NetAdapterAdvancedProperty -Name $Adapter.Name -ErrorAction SilentlyContinue)
    if ($props.Count -eq 0) {
        return [pscustomobject]@{ Changed = $false; Ok = $false; Text = '未找到网卡高级属性' }
    }

    # 优先用 RegistryKeyword 精确识别，避免受系统语言影响
    $candidates = @($props | Where-Object {
        $_.RegistryKeyword -match '(?i)prefer.*band|band.*prefer|preferredband|bandpreference|roamingpreferredbandtype|wlanpreferredband'
    })
    if ($candidates.Count -eq 0) {
        $candidates = @($props | Where-Object {
            $_.RegistryKeyword -match '(?i)band' -and $_.RegistryKeyword -notmatch '(?i)bandwidth|6g|protocol'
        })
    }
    if ($candidates.Count -eq 0) {
        $candidates = @($props | Where-Object {
            $_.DisplayName -match '(?i)preferred\s*band|首选频带|首选频段'
        })
    }

    # 候选中优先选带 5GHz 选项的那一个
    $bandProp = $candidates | Where-Object {
        @($_.ValidDisplayValues) -match '(?i)5\s*G'
    } | Select-Object -First 1
    if (-not $bandProp) {
        $bandProp = $candidates | Select-Object -First 1
    }
    if (-not $bandProp) {
        return [pscustomobject]@{ Changed = $false; Ok = $false; Text = '该驱动未提供「首选频带」选项' }
    }

    $validValues = @($bandProp.ValidDisplayValues | Where-Object { $null -ne $_ })
    $target = $validValues | Where-Object {
        $_ -match '(?i)(^|[^0-9.])5\s*G(?:Hz)?([^0-9a-z]|$)' -and
        $_ -notmatch '(?i)2\.4|6\s*G'
    } | Select-Object -First 1

    if (-not $target) {
        if ($bandProp.DisplayValue -match '(?i)(^|[^0-9.])5\s*G(?:Hz)?([^0-9a-z]|$)') {
            return [pscustomobject]@{ Changed = $false; Ok = $true; Text = ("已是 「{0}」" -f $bandProp.DisplayValue) }
        }
        return [pscustomobject]@{ Changed = $false; Ok = $false; Text = '驱动没有可识别的 5GHz 选项' }
    }

    if ($bandProp.DisplayValue -eq $target) {
        return [pscustomobject]@{ Changed = $false; Ok = $true; Text = ("已是 「{0}」" -f $target) }
    }

    try {
        Set-NetAdapterAdvancedProperty -Name $Adapter.Name -DisplayName $bandProp.DisplayName -DisplayValue $target -NoRestart -ErrorAction Stop
        return [pscustomobject]@{ Changed = $true; Ok = $true; Text = ("已设置 「{0}」 -> 「{1}」" -f $bandProp.DisplayValue, $target) }
    }
    catch {
        # 某些驱动只接受 RegistryValue，按显示值索引再试一次
        $index = [array]::IndexOf($validValues, $target)
        $regValues = @($bandProp.ValidRegistryValues | Where-Object { $null -ne $_ })
        if ($index -ge 0 -and $regValues.Count -gt $index) {
            try {
                Set-NetAdapterAdvancedProperty -Name $Adapter.Name -DisplayName $bandProp.DisplayName -RegistryValue $regValues[$index] -NoRestart -ErrorAction Stop
                return [pscustomobject]@{ Changed = $true; Ok = $true; Text = ("已设置 「{0}」 -> 「{1}」" -f $bandProp.DisplayValue, $target) }
            }
            catch {
                return [pscustomobject]@{ Changed = $false; Ok = $false; Text = ('设置失败：' + $_.Exception.Message) }
            }
        }
        return [pscustomobject]@{ Changed = $false; Ok = $false; Text = ('设置失败：' + $_.Exception.Message) }
    }
}

function Disable-PowerSave {
    param($Adapter)

    # 首选 WMI 的 MSPower_DeviceEnable，它直接对应设备管理器里的复选框
    $pnpId = [string]$Adapter.PnPDeviceID
    $pm = $null
    if ($pnpId) {
        try {
            $pm = Get-WmiObject -Namespace root\wmi -Class MSPower_DeviceEnable -ErrorAction Stop |
                  Where-Object { $_.InstanceName -and $_.InstanceName.StartsWith($pnpId, [StringComparison]::OrdinalIgnoreCase) } |
                  Select-Object -First 1
        }
        catch { $pm = $null }
    }

    if ($pm) {
        if (-not $pm.Enable) {
            return [pscustomobject]@{ Changed = $false; Ok = $true; Text = '已是关闭（复选框已取消）' }
        }
        try {
            $pm.Enable = $false
            $pm.Put() | Out-Null

            $verify = Get-WmiObject -Namespace root\wmi -Class MSPower_DeviceEnable -ErrorAction SilentlyContinue |
                      Where-Object { $_.InstanceName -and $_.InstanceName.StartsWith($pnpId, [StringComparison]::OrdinalIgnoreCase) } |
                      Select-Object -First 1
            if ($verify -and -not $verify.Enable) {
                return [pscustomobject]@{ Changed = $true; Ok = $true; Text = '已取消「允许计算机关闭此设备以节约电源」' }
            }
        }
        catch {
            # 继续尝试注册表回退
        }
    }

    # 回退方案：设置 PnPCapabilities = 24（业界常用的禁用网卡节电值）
    $classRoot = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e972-e325-11ce-bfc1-08002be10318}'
    $classKey = Get-ChildItem $classRoot -ErrorAction SilentlyContinue | Where-Object {
        $p = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
        $p.NetCfgInstanceId -and ($p.NetCfgInstanceId -ieq $Adapter.InterfaceGuid)
    } | Select-Object -First 1

    if (-not $classKey) {
        return [pscustomobject]@{ Changed = $false; Ok = $false; Text = '该驱动不支持电源管理设置' }
    }

    $oldValue = (Get-ItemProperty $classKey.PSPath -ErrorAction SilentlyContinue).PnPCapabilities
    if ($oldValue -eq 24) {
        return [pscustomobject]@{ Changed = $false; Ok = $true; Text = '已是关闭（PnPCapabilities=24）' }
    }

    try {
        Set-ItemProperty -Path $classKey.PSPath -Name 'PnPCapabilities' -Value 24 -Type DWord -ErrorAction Stop
        return [pscustomobject]@{ Changed = $true; Ok = $true; Text = ("已写入 PnPCapabilities：{0} -> 24" -f $oldValue) }
    }
    catch {
        return [pscustomobject]@{ Changed = $false; Ok = $false; Text = ('设置失败：' + $_.Exception.Message) }
    }
}

function Restart-WifiAdapter {
    param([string]$AdapterName)

    try {
        Restart-NetAdapter -Name $AdapterName -Confirm:$false -ErrorAction Stop
    }
    catch {
        try {
            Disable-NetAdapter -Name $AdapterName -Confirm:$false -ErrorAction Stop
            Start-Sleep -Seconds 2
            Enable-NetAdapter -Name $AdapterName -Confirm:$false -ErrorAction Stop
        }
        catch {
            return $false
        }
    }

    for ($i = 0; $i -lt 30; $i++) {
        Start-Sleep -Seconds 1
        $adapter = Get-NetAdapter -Name $AdapterName -ErrorAction SilentlyContinue
        if ($adapter -and $adapter.Status -eq 'Up') {
            Start-Sleep -Seconds 4
            return $true
        }
    }
    return $false
}

try {
    $adapters = Get-WifiAdapters
    if (-not $adapters -or $adapters.Count -eq 0) {
        Show-Result "未检测到无线网卡。`r`n`r`n请确认 Wi-Fi 驱动已安装并在设备管理器中启用。" 'Wi-Fi 优化结果'
        exit 1
    }

    $report = New-Object System.Collections.Generic.List[string]
    $report.Add('Windows Wi-Fi 优化结果')
    $report.Add('')

    foreach ($adapter in $adapters) {
        Write-Host ''
        Write-Host ("正在处理：{0} ({1})" -f $adapter.Name, $adapter.InterfaceDescription) -ForegroundColor Cyan

        $before = Get-WifiInfo -AdapterName $adapter.Name
        Write-Host ('优化前：' + (Format-WifiInfo -Info $before)) -ForegroundColor Gray

        $bandResult = Set-PreferredBand -Adapter $adapter
        $powerResult = Disable-PowerSave -Adapter $adapter
        $changed = $bandResult.Changed -or $powerResult.Changed

        # 如果当前还在 2.4GHz，即使设置已是 5GHz 优先，也重启一次让网卡重新选频
        $needRestart = $changed -or ($before.Band -match '2[.,]4')
        $restarted = $true
        if ($needRestart) {
            Write-Host '正在重启无线网卡以应用设置（网络会短暂中断）...' -ForegroundColor Yellow
            $restarted = Restart-WifiAdapter -AdapterName $adapter.Name
            if (-not $restarted) {
                Write-Host '网卡未在 30 秒内重新连接，设置将在下次重启后生效。' -ForegroundColor Yellow
            }
        }
        else {
            Write-Host '设置已是目标状态，无需重启网卡。' -ForegroundColor Green
        }

        $after = Get-WifiInfo -AdapterName $adapter.Name
        Write-Host ('优化后：' + (Format-WifiInfo -Info $after)) -ForegroundColor Gray

        $report.Add(("适配器：{0} ({1})" -f $adapter.Name, $adapter.InterfaceDescription))
        $report.Add(("• 首选频带：{0}" -f $bandResult.Text))
        $report.Add(("• 节电选项：{0}" -f $powerResult.Text))
        $report.Add(("• 优化前：{0}" -f (Format-WifiInfo -Info $before)))
        $report.Add(("• 优化后：{0}" -f (Format-WifiInfo -Info $after)))

        if ($after.Band -match '2[.,]4') {
            $report.Add('• 提示：当前仍连接 2.4GHz，可能是 5GHz 信号弱或路由器未启用 5GHz。')
        }

        $beforeMbps = Convert-SpeedToMbps -Speed $before.LinkSpeed
        $afterMbps = Convert-SpeedToMbps -Speed $after.LinkSpeed
        if ($null -ne $beforeMbps -and $null -ne $afterMbps) {
            $delta = [math]::Round($afterMbps - $beforeMbps, 1)
            $sign = if ($delta -gt 0) { '+' } else { '' }
            $report.Add(("• 链路速率变化：{0}{1} Mbps" -f $sign, $delta))
        }

        if ($needRestart -and -not $restarted) {
            $report.Add('• 注意：网卡重启后未在 30 秒内连接，请稍后检查 Wi-Fi。')
        }
        $report.Add('')
    }

    $report.Add('说明：以上为 Wi-Fi 协商链路速率，实际宽带速度还取决于路由器、运营商和网络拥塞。')
    Show-Result ($report -join "`r`n")
    exit 0
}
catch {
    Show-Result ("执行失败：`r`n`r`n" + $_.Exception.Message) 'Wi-Fi 优化结果'
    exit 1
}
