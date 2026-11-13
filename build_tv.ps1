# 构建多媒体+TV 合并版 HAP：复制到纯 ASCII 副本后 hvigorw assembleHap（不删除副本内既有文件）
$ErrorActionPreference = "Stop"
$src    = "D:\播放器\PlayerArkTS"
$dst    = "C:\hb_tv_build"
$dev    = "D:\Program Files\Huawei\DevEco Studio"
$hvigor = Join-Path $dev "tools\hvigor\bin\hvigorw.bat"

New-Item -ItemType Directory -Force -Path $dst | Out-Null
robocopy "$src\entry" "$dst\entry" /E /XD build /XF *.log *.hap | Out-Null
robocopy "$src\AppScope" "$dst\AppScope" /E | Out-Null
robocopy "$src\hvigor" "$dst\hvigor" /E | Out-Null
Copy-Item "$src\build-profile.json5","$src\oh-package.json5","$src\hvigorfile.ts" $dst -Force

$env:DEVECO_SDK_HOME = Join-Path $dev "sdk"
Set-Location $dst
& $hvigor --mode module -p product=default -p buildMode=debug assembleHap --no-daemon
if ($LASTEXITCODE -ne 0) { throw "hvigor 构建失败，退出码 $LASTEXITCODE" }

$out = Get-ChildItem (Join-Path $dst "entry\build\default\outputs\default") -Filter *.hap -ErrorAction SilentlyContinue
$out | ForEach-Object { Write-Host ("HAP: " + $_.FullName + "  " + $_.Length + "B") }
Write-Host "构建完成"
