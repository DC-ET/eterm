# eterm Windows 发布：bump build 号 → 构建 → NSIS 打包 → 覆盖上传 → 校验。
# 约定（docs/plan/eterm-Windows客户端技术方案.md §7.2、docs/eterm-发布流程.md）：
#   - pubspec.yaml 是 build 号唯一事实源；异机双发布脚本（mac: release_android.sh）
#     都必须基于最新 pubspec bump，故前置校验：工作区干净 + git pull --ff-only
#   - bump 结果由本脚本在上传校验通过后自动 commit+push（防跨机撞号）
#   - 磁盘紧张约定：产物覆盖同一文件 eterm-windows-setup.exe，勿新增版本副本
#   - -NoUpload：本地演练（bump/构建/打包/哈希齐全，跳过上传/回读/commit）
#   - eterm-windows.json 按「自动更新方案」三端 schema 生成；应用内更新（M4）
#     未实施前先随包发布占位
#   - VC++ 运行库兜底：打包前确保 installer\vc_redist.x64.exe 就位（缺则下载），
#     安装器在目标机缺运行库时引导安装（§5 核验项 #7）
# 注意：本脚本含中文，保存为 UTF-8 with BOM（PowerShell 5.1 无 BOM 会按 ANSI 误读）。
param([switch]$NoUpload)

$ErrorActionPreference = "Stop"
Set-Location -LiteralPath (Split-Path -Parent $PSScriptRoot)  # client/app

# 发布目标全部走环境变量（仓库内不落真实服务器/IP/域名；fork 部署自行导出）：
#   ETERM_SERVER / ETERM_SSH_KEY / ETERM_REMOTE_DIR / ETERM_UPDATE_BASE_URL
$Server    = if ($env:ETERM_SERVER) { $env:ETERM_SERVER } else { "root@YOUR_SERVER_IP" }
$RemoteDir = if ($env:ETERM_REMOTE_DIR) { $env:ETERM_REMOTE_DIR } else { "/opt/mao-data/uploads/eterm" }
# 更新元数据基址：eterm-windows.json 的下载地址与客户端 --dart-define 同源，必须显式提供
$BaseUrl   = if ($env:ETERM_UPDATE_BASE_URL) { $env:ETERM_UPDATE_BASE_URL } else { "" }
$Key       = if ($env:ETERM_SSH_KEY) { $env:ETERM_SSH_KEY } else { "$HOME\.ssh\your-server.pem" }

# 镜像（与 release_android.sh 同口径）
$env:PUB_HOSTED_URL           = "https://pub.flutter-io.cn"
$env:FLUTTER_STORAGE_BASE_URL = "https://storage.flutter-io.cn"

function Fail([string]$msg) { Write-Host "❌ $msg"; exit 1 }
function CheckLastExit([string]$what) {
  if ($LASTEXITCODE -ne 0) { Fail "$what 失败（exit=$LASTEXITCODE）" }
}
# UTF-8 无 BOM 对称读写（PS 5.1 Get-Content 对无 BOM 文件按 ANSI 解码会写坏中文）
function ReadUtf8([string]$path) {
  [System.IO.File]::ReadAllText($path, (New-Object System.Text.UTF8Encoding $false))
}
function NoBomWrite([string]$path, [string]$text) {
  [System.IO.File]::WriteAllText($path, $text, (New-Object System.Text.UTF8Encoding $false))
}

if (-not $BaseUrl) {
  Fail "必须设置 ETERM_UPDATE_BASE_URL（如 https://hub.example.com/updates）：更新元数据 JSON 的下载地址与客户端 --dart-define 都取自此值"
}

# 0. 前置校验（§7.2：异机 bump 必须基于最新 pubspec，否则可能撞号）
$dirty = git status --porcelain
if ($dirty) { Fail "工作区不干净，请先提交后再发布：`n$dirty" }
git pull --ff-only
CheckLastExit "git pull --ff-only"

$fv = (flutter --version | Select-Object -First 1)
if ($fv -notmatch 'Flutter\s+3\.50') { Fail "Flutter 版本须为 3.50.x（与 mac 端同主版本），当前: $fv" }
Write-Host "== $fv =="

# 0.5 VC++ 运行库兜底文件就位（§5：缺运行库的干净机首启必挂，安装器按需引导安装）
$vcRedist = Join-Path $PSScriptRoot "vc_redist.x64.exe"
if (-not (Test-Path $vcRedist)) {
  Write-Host "== 下载 vc_redist.x64.exe（首次发布）=="
  curl.exe -fsSL -o $vcRedist "https://aka.ms/vs/17/release/vc_redist.x64.exe"
  CheckLastExit "下载 vc_redist"
}

# 1. bump pubspec build 号（+1；[ \t]*$ 不吞 CRLF 工作副本的行尾 \r）
$content = ReadUtf8 (Join-Path (Get-Location) "pubspec.yaml")
if ($content -notmatch '(?m)^version:\s*(\d+\.\d+\.\d+)\+(\d+)[ \t]*$') { Fail "pubspec.yaml version 行解析失败" }
$ver   = $Matches[1]
$build = [int]$Matches[2] + 1
$updated = [regex]::Replace($content, '(?m)^version:\s*\d+\.\d+\.\d+\+\d+[ \t]*$', "version: $ver+$build")
NoBomWrite (Join-Path (Get-Location) "pubspec.yaml") $updated
Write-Host "== bump build → $ver+$build =="

# 2. 构建（产物 build\windows\x64\runner\Release\）
flutter build windows --release --dart-define=ETERM_UPDATE_BASE_URL="$BaseUrl"
CheckLastExit "flutter build windows"
$releaseDir = "build\windows\x64\runner\Release"
if (-not (Test-Path (Join-Path $releaseDir "Eterm.exe"))) { Fail "构建产物缺失 Eterm.exe" }

# 3. NSIS 打包（相对路径以 installer/ 为基准，故 Push-Location；-DVERSION 带 build 号对齐 pubspec）
$makensis = Get-Command makensis -ErrorAction SilentlyContinue
if ($makensis) { $makensis = $makensis.Source }
elseif (Test-Path "${env:ProgramFiles(x86)}\NSIS\makensis.exe") { $makensis = "${env:ProgramFiles(x86)}\NSIS\makensis.exe" }
else { Fail "未找到 makensis（安装 NSIS 3）" }
Push-Location -LiteralPath "installer"
try { & $makensis -DVERSION="$ver+$build" "eterm.nsis" } finally { Pop-Location }
CheckLastExit "NSIS 打包"
$setup = "build\eterm-windows-setup.exe"
if (-not (Test-Path $setup)) { Fail "安装包未生成: $setup" }

# 4. sha256
$hash = (Get-FileHash -LiteralPath $setup -Algorithm SHA256).Hash.ToLower()
$size = (Get-Item -LiteralPath $setup).Length
Write-Host "== sha256 $hash / size $size =="

# 5. 生成 eterm-windows.json（自动更新方案三端 schema）
NoBomWrite (Join-Path (Get-Location) "build\eterm-windows.json") (@{
  version = $ver
  build   = $build
  url     = "$BaseUrl/eterm-windows-setup.exe"
  sha256  = $hash
  size    = $size
  notes   = ""
} | ConvertTo-Json)

# 6. 上传（覆盖同一文件）+ 校验
if ($NoUpload) {
  Write-Host "== -NoUpload 本地演练完成：$setup（未上传/未提交）=="
  exit 0
}
scp -i $Key "$setup" "${Server}:${RemoteDir}/eterm-windows-setup.exe"
CheckLastExit "scp setup"
scp -i $Key "build\eterm-windows.json" "${Server}:${RemoteDir}/eterm-windows.json"
CheckLastExit "scp json"
# 公网回读 JSON 校验 version/build（§7.2 步骤 6；curl.exe 输出按行拆分数组，先合并再解析）
$remoteJson = (curl.exe -fsS "$BaseUrl/eterm-windows.json") -join "`n"
if (-not $remoteJson) { Fail "公网回读 eterm-windows.json 失败" }
$meta = $remoteJson | ConvertFrom-Json
if ($meta.version -ne $ver -or $meta.build -ne $build) { Fail "回读版本不一致: $($meta.version)+$($meta.build)，期望 $ver+$build" }
# 远端文件哈希对齐（与 release_android.sh 校验模式同构）
$remoteSumRaw = ssh -i $Key $Server "sha256sum $RemoteDir/eterm-windows-setup.exe"
CheckLastExit "ssh sha256sum"
$remoteSum = ($remoteSumRaw -split '\s+')[0]
if (-not $remoteSum) { Fail "远端哈希为空" }
if ($remoteSum.ToLower() -ne $hash) { Fail "远端哈希不一致: $remoteSum / $hash" }

# 7. bump 持久化：自动提交并推送（唯一事实源不变式，防跨机撞号）
git add pubspec.yaml
git commit -m "release: windows $ver+$build（发布脚本自动 bump）"
CheckLastExit "git commit bump"
git push
CheckLastExit "git push bump"

Write-Host "✅ 发布完成: $Server:$RemoteDir/eterm-windows-setup.exe ($ver+$build)"
