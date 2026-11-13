# 构建多媒体 HAP
#   1) 复制到纯 ASCII 临时目录规避中文路径规范错误
#   2) 产物：已签名 .app（release/AGC）+ 未签名 .hap（侧载），不再输出已签名 hap
#   3) 产物统一落到项目内 output\，临时目录用完即删
$ErrorActionPreference = "Stop"
$src   = "D:\Player\PlayerArkTS"
$dst   = "C:\hb_pl_build"
$out   = Join-Path $src "output"
$hvigor = "D:\Program Files\Huawei\DevEco Studio\tools\hvigor\bin\hvigorw.bat"
$env:DEVECO_SDK_HOME = "D:\Program Files\Huawei\DevEco Studio\sdk"

New-Item -ItemType Directory -Force -Path $out | Out-Null

robocopy "$src\entry" "$dst\entry" /MIR /XD build /XF *.log | Out-Null
robocopy "$src\AppScope" "$dst\AppScope" /MIR | Out-Null
robocopy "$src\key" "$dst\key" /MIR | Out-Null
robocopy "$src\hvigor" "$dst\hvigor" /MIR | Out-Null
Copy-Item "$src\build-profile.json5","$src\oh-package.json5","$src\hvigorfile.ts" $dst -Force
if (Test-Path "$src\oh-package-lock.json5") { Copy-Item "$src\oh-package-lock.json5" $dst -Force }
if (Test-Path "$src\hvigorw") { Copy-Item "$src\hvigorw" $dst -Force }
if (Test-Path "$src\hvigorw.bat") { Copy-Item "$src\hvigorw.bat" $dst -Force }

Set-Location $dst
# 产物名直接用 AppScope\app.json5 里的 versionName，确保文件名与包内版本号一致
$verLine = Select-String -Path "$src\AppScope\app.json5" -Pattern '"versionName"\s*:\s*"([^"]+)"'
if (-not $verLine) { throw "未能从 AppScope\app.json5 解析 versionName" }
$codeLine = Select-String -Path "$src\AppScope\app.json5" -Pattern '"versionCode"\s*:\s*(\d+)'
$stamp = $verLine.Matches[0].Groups[1].Value
$vcode = if ($codeLine) { $codeLine.Matches[0].Groups[1].Value } else { "?" }
Write-Host "本次构建版本：versionName=$stamp / versionCode=$vcode"

# 2) 已签名 .app（release 全量包，供 AGC 上架/分发）
& $hvigor --mode project -p product=default -p buildMode=release assembleApp --no-daemon
if ($LASTEXITCODE -ne 0) { throw "assembleApp 构建失败，退出码 $LASTEXITCODE" }
$appSrc = Join-Path $dst ("build\outputs\default\" + (Split-Path $dst -Leaf) + "-default-signed.app")
if (Test-Path $appSrc) {
    Copy-Item $appSrc (Join-Path $out "多媒体_${stamp}_signed.app") -Force
    Write-Host "signed.app -> output\多媒体_${stamp}_signed.app"
}

# 3) 未签名 .hap（侧载包，须放在 app 构建之后，避免被 release 产物覆盖）
& $hvigor --mode module -p product=default -p buildMode=debug assembleHap --no-daemon
if ($LASTEXITCODE -ne 0) { throw "assembleHap 构建失败，退出码 $LASTEXITCODE" }
$outputs  = Join-Path $dst "entry\build\default\outputs\default"
$unsigned = Join-Path $outputs "entry-default-unsigned.hap"

if (Test-Path $unsigned) {
    Copy-Item $unsigned (Join-Path $out "多媒体_${stamp}_unsigned.hap") -Force
    Write-Host "unsigned -> output\多媒体_${stamp}_unsigned.hap"
}

Set-Location $src
Write-Host "构建完成（临时目录 $dst 由外部清理）"


