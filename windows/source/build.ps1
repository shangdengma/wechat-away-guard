$ErrorActionPreference = 'Stop'
$fx = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319'
$gac = Join-Path $env:WINDIR 'Microsoft.NET\assembly\GAC_MSIL'
$refs = @('System.dll','System.Core.dll','System.Xml.dll','System.Xml.Linq.dll','System.Drawing.dll','System.Windows.Forms.dll',"$fx\System.Runtime.WindowsRuntime.dll")
foreach ($name in @('System.Runtime','System.Threading.Tasks','System.Runtime.InteropServices.WindowsRuntime')) {
    $refs += (Get-ChildItem -LiteralPath (Join-Path $gac $name) -Recurse -Filter "$name.dll" | Select-Object -First 1).FullName
}
foreach ($name in @('Windows.Foundation','Windows.Devices','Windows.Media','Windows.Graphics','Windows.Storage','Windows.Networking')) {
    $refs += Join-Path $env:WINDIR "System32\WinMetadata\$name.winmd"
}
$target = Join-Path $PSScriptRoot '..\WeChatGuard.exe'
$arguments = @('/nologo','/target:winexe','/platform:x64','/optimize+',"/out:$target")
$arguments += $refs | ForEach-Object { "/r:$_" }
$arguments += (Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.cs').FullName
& (Join-Path $fx 'csc.exe') @arguments
if ($LASTEXITCODE -ne 0) { throw 'Build failed' }
Write-Output "Built: $target"
