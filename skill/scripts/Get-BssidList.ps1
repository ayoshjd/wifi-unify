<#
.SYNOPSIS
  主动触发一次无线扫描并列出扫描缓存中的全部 BSSID（只读，不改任何网络配置）。

.用途
  Win11 连接态下 `netsh wlan show networks mode=bssid` 常只回报当前信道上的 BSSID，
  无法完成多 BSSID 交叉核对。本脚本调用 wlanapi 的 WlanScan（主动扫描）+ WlanGetNetworkBssList，
  输出 SSID / BSSID / 信道 / RSSI / 链路质量。

.参数
  -WaitSeconds 扫描后等待秒数，默认 6；环境拥挤时可加到 10。
  -SsidFilter  可选。只取某个 SSID 的 BSSID；为空则取全部（dot11BssType=any）。
  -OutFile     可选。把结果写入文件（UTF-8，制表符分隔），便于与 before/after 比对。

.平台
  Windows（依赖 wlanapi.dll）。需要无线网卡处于已连接状态；不连接、不断开。
  非 Windows 请用 `iw dev <if> scan`（Linux）或 Wi-Fi 分析仪类 App（手机）。

.读写
  只读：仅调用 WlanOpenHandle / WlanEnumInterfaces / WlanScan / WlanGetNetworkBssList / WlanFreeMemory。
  不连接、不断开、不改任何设置。

.回滚
  无需回滚。

.示例
  .\Get-BssidList.ps1
  .\Get-BssidList.ps1 -SsidFilter "<SSID>" -WaitSeconds 8 -OutFile .\scan.txt
#>
[CmdletBinding()]
param(
    [int]$WaitSeconds = 6,
    [string]$SsidFilter,
    [string]$OutFile
)

$src = @'
using System;
using System.Runtime.InteropServices;

public static class WlanNative
{
    [StructLayout(LayoutKind.Sequential)]
    public struct GUID { public uint Data1; public ushort Data2; public ushort Data3; [MarshalAs(UnmanagedType.ByValArray, SizeConst=8)] public byte[] Data4; }

    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
    public struct WLAN_INTERFACE_INFO
    {
        public GUID InterfaceGuid;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst=256)] public string strInterfaceDescription;
        public uint isState;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct WLAN_INTERFACE_INFO_LIST
    {
        public uint dwNumberOfItems;
        public uint dwIndex;
        [MarshalAs(UnmanagedType.ByValArray, SizeConst=8)] public WLAN_INTERFACE_INFO[] InterfaceInfo;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct DOT11_SSID
    {
        public uint uSSIDLength;
        [MarshalAs(UnmanagedType.ByValArray, SizeConst=32)] public byte[] ucSSID;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct WLAN_BSS_ENTRY
    {
        public DOT11_SSID dot11Ssid;
        public uint uPhyId;
        [MarshalAs(UnmanagedType.ByValArray, SizeConst=6)] public byte[] dot11Bssid;
        public uint dot11BssType;
        public uint dot11BssPhyType;
        public int lRssi;
        public uint uLinkQuality;
        public byte bInRegDomain;
        public ushort usBeaconPeriod;
        public ulong ullTimestamp;
        public ulong ullHostTimestamp;
        public ushort usCapabilityInformation;
        public uint ulChCenterFrequency;
        [MarshalAs(UnmanagedType.ByValArray, SizeConst=126)] public ushort[] usRateSet;
        public uint ulIeOffset;
        public uint ulIeSize;
    }

    [DllImport("wlanapi.dll")]
    public static extern uint WlanOpenHandle(uint dwClientVersion, IntPtr pReserved, out uint pdwNegotiatedVersion, out IntPtr phClientHandle);

    [DllImport("wlanapi.dll")]
    public static extern uint WlanCloseHandle(IntPtr hClientHandle, IntPtr pReserved);

    [DllImport("wlanapi.dll")]
    public static extern uint WlanEnumInterfaces(IntPtr hClientHandle, IntPtr pReserved, out IntPtr ppInterfaceList);

    [DllImport("wlanapi.dll")]
    public static extern uint WlanScan(IntPtr hClientHandle, ref GUID pInterfaceGuid, IntPtr pDot11Ssid, IntPtr pIeData, IntPtr pReserved);

    [DllImport("wlanapi.dll")]
    public static extern uint WlanGetNetworkBssList(IntPtr hClientHandle, ref GUID pInterfaceGuid, IntPtr pDot11Ssid, uint dot11BssType, bool bSecurityEnabled, IntPtr pReserved, out IntPtr ppWlanBssList);

    [DllImport("wlanapi.dll")]
    public static extern void WlanFreeMemory(IntPtr pMemory);

    public static int BssEntrySize() { return Marshal.SizeOf(typeof(WLAN_BSS_ENTRY)); }
}
'@

Add-Type -TypeDefinition $src -Language CSharp | Out-Null

$lines = New-Object System.Collections.Generic.List[string]
$handle = [IntPtr]::Zero
$ver = 0
$rc = [WlanNative]::WlanOpenHandle(2, [IntPtr]::Zero, [ref]$ver, [ref]$handle)
if ($rc -ne 0) { throw "WlanOpenHandle 失败，错误码 $rc" }

try {
    $listPtr = [IntPtr]::Zero
    $rc = [WlanNative]::WlanEnumInterfaces($handle, [IntPtr]::Zero, [ref]$listPtr)
    if ($rc -ne 0) { throw "WlanEnumInterfaces 失败，错误码 $rc" }

    $count = [Runtime.InteropServices.Marshal]::ReadInt32($listPtr)
    $infoSize = [Runtime.InteropServices.Marshal]::SizeOf([type][WlanNative+WLAN_INTERFACE_INFO])
    $firstOffset = 8  # dwNumberOfItems + dwIndex

    for ($i = 0; $i -lt $count; $i++) {
        $infoPtr = [IntPtr]::Add($listPtr, $firstOffset + $i * $infoSize)
        $info = [Runtime.InteropServices.Marshal]::PtrToStructure($infoPtr, [type][WlanNative+WLAN_INTERFACE_INFO])
        if ($info.isState -ne 1) { continue } # 1 = connected

        $guid = $info.InterfaceGuid
        $scanRc = [WlanNative]::WlanScan($handle, [ref]$guid, [IntPtr]::Zero, [IntPtr]::Zero, [IntPtr]::Zero)
        $lines.Add("# 接口: $($info.strInterfaceDescription) / WlanScan rc=$scanRc / $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
        Start-Sleep -Seconds $WaitSeconds

        $bssPtr = [IntPtr]::Zero
        $ssidPtr = [IntPtr]::Zero
        if ($SsidFilter) {
            $ssidBytes = [Text.Encoding]::ASCII.GetBytes($SsidFilter)
            $ssidPtr = [Runtime.InteropServices.Marshal]::AllocHGlobal(36)
            [Runtime.InteropServices.Marshal]::WriteInt32($ssidPtr, $ssidBytes.Length)
            [Runtime.InteropServices.Marshal]::Copy($ssidBytes, 0, [IntPtr]::Add($ssidPtr, 4), $ssidBytes.Length)
        }
        # 未指定 SSID 时必须用 dot11_BSS_type_any(3)，否则部分驱动返回空列表
        $bssType = if ($SsidFilter) { 1 } else { 3 }
        $rc = [WlanNative]::WlanGetNetworkBssList($handle, [ref]$guid, $ssidPtr, $bssType, $false, [IntPtr]::Zero, [ref]$bssPtr)
        if ($ssidPtr -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::FreeHGlobal($ssidPtr) }
        if ($rc -ne 0) { $lines.Add("WlanGetNetworkBssList 失败，错误码 $rc"); continue }

        try {
            $bssCount = [Runtime.InteropServices.Marshal]::ReadInt32([IntPtr]::Add($bssPtr, 4))
            $entrySize = [WlanNative]::BssEntrySize()
            $lines.Add("扫描缓存 BSSID 条目数: $bssCount")
            $lines.Add("SSID`tBSSID`tCHANNEL`tRSSI`tQUALITY`tFREQ_MHZ")
            for ($j = 0; $j -lt $bssCount; $j++) {
                $ePtr = [IntPtr]::Add($bssPtr, 8 + $j * $entrySize)
                $e = [Runtime.InteropServices.Marshal]::PtrToStructure($ePtr, [type][WlanNative+WLAN_BSS_ENTRY])
                $ssidLen = [Math]::Min([int]$e.dot11Ssid.uSSIDLength, 32)
                $ssidText = [Text.Encoding]::ASCII.GetString($e.dot11Ssid.ucSSID, 0, $ssidLen)
                $bssid = ($e.dot11Bssid | ForEach-Object { $_.ToString('x2') }) -join ':'
                $freq = [double]$e.ulChCenterFrequency / 1000
                $ch = if ($freq -ge 2407 -and $freq -le 2484) { [int](($freq - 2407) / 5) }
                      elseif ($freq -ge 5000 -and $freq -le 5900) { [int](($freq - 5000) / 5) }
                      elseif ($freq -ge 5950 -and $freq -le 7125) { [int](($freq - 5950) / 5 + 1) }
                      else { 0 }
                $lines.Add(("{0}`t{1}`t{2}`t{3}`t{4}`t{5}" -f $ssidText, $bssid, $ch, $e.lRssi, $e.uLinkQuality, $freq))
            }
        } finally { [WlanNative]::WlanFreeMemory($bssPtr) }
    }
} finally {
    [WlanNative]::WlanCloseHandle($handle, [IntPtr]::Zero)
}

$text = $lines -join "`n"
Write-Output $text
if ($OutFile) { $text | Out-File $OutFile -Encoding utf8; Write-Host "已写入 $OutFile" -ForegroundColor Cyan }
