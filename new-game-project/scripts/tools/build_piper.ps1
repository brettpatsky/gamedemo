# Composite Piper's v3 animation frames into 124px horizontal strips for
# resources/piper8/, following docs/pixellab_8dir_character_guide.md (§5a + §6).
# Reads the bulk-download zip's extracted tree:
#   <Name>/animations/<action-prefix>/<dir>/frame_NNN.png
# and writes <out>_<facing>.png. Then mirrors right->left where needed.
# Usage: build_piper.ps1 <extracted-char-root> [mirror]
Add-Type -AssemblyName System.Drawing

$envDir = "c:\projects\gamedemo\new-game-project\resources\piper8"
New-Item -ItemType Directory -Force -Path $envDir | Out-Null

# extracted root holding "<Name>/animations/..."
$src = $args[0]
if (-not $src) { throw "pass the extracted character root (folder containing 'animations')" }

# PixelLab dir -> in-game facing filename
$dirToFacing = @{
  "south"      = "down"
  "north"      = "up"
  "east"       = "right"
  "west"       = "left"
  "south-east" = "down_right"
  "south-west" = "down_left"
  "north-east" = "up_right"
  "north-west" = "up_left"
}

# action-prefix (slugified action_description) -> output anim name.
# Match by the leading word so we don't depend on the full slug.
function Map-AnimName($folderName) {
  if ($folderName -like "standing*") { return "idle" }
  if ($folderName -like "walking*")  { return "walk" }
  if ($folderName -like "holding*")  { return "shoot" }  # staff cast (downward tap)
  if ($folderName -like "staggering*") { return "die" }
  return $null
}

function Build-Strip($frameFiles, $outPath) {
  $imgs = @()
  foreach ($f in $frameFiles) { $imgs += [System.Drawing.Image]::FromFile($f) }
  $fw = $imgs[0].Width; $fh = $imgs[0].Height
  $strip = New-Object System.Drawing.Bitmap (($fw * $imgs.Count), $fh, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
  $g = [System.Drawing.Graphics]::FromImage($strip)
  $g.Clear([System.Drawing.Color]::Transparent)
  $g.CompositingMode = [System.Drawing.Drawing2D.CompositingMode]::SourceCopy
  for ($i = 0; $i -lt $imgs.Count; $i++) { $g.DrawImage($imgs[$i], ($i * $fw), 0, $fw, $fh) }
  $g.Dispose()
  $strip.Save($outPath, [System.Drawing.Imaging.ImageFormat]::Png)
  $strip.Dispose(); foreach ($im in $imgs) { $im.Dispose() }
}

$animRoot = Join-Path $src "animations"
$built = @{}
Get-ChildItem -Directory $animRoot | ForEach-Object {
  $anim = Map-AnimName $_.Name
  if (-not $anim) { Write-Host "skip unknown anim folder: $($_.Name)"; return }
  Get-ChildItem -Directory $_.FullName | ForEach-Object {
    $facing = $dirToFacing[$_.Name]
    if (-not $facing) { Write-Host "skip unknown dir: $($_.Name)"; return }
    $frames = Get-ChildItem $_.FullName -Filter "frame_*.png" | Sort-Object Name | Select-Object -ExpandProperty FullName
    if ($frames.Count -eq 0) { Write-Host "no frames in $($_.FullName)"; return }
    $outFile = Join-Path $envDir ("{0}_{1}.png" -f $anim, $facing)
    Build-Strip $frames $outFile
    $built["$anim`_$facing"] = $true
    Write-Host ("built {0}_{1}  ({2} frames)" -f $anim, $facing, $frames.Count)
  }
}

# ---- Mirror right -> left per frame for the directions v3 renders back-facing.
function Mirror-Frames($srcFile, $dstFile) {
  $sp = Join-Path $envDir $srcFile
  if (-not (Test-Path $sp)) { Write-Host "mirror source missing: $srcFile"; return }
  $s = [System.Drawing.Image]::FromFile($sp)
  $fh = $s.Height; $count = [int]($s.Width / $fh)
  $out = New-Object System.Drawing.Bitmap ($s.Width, $fh, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
  $g = [System.Drawing.Graphics]::FromImage($out)
  $g.Clear([System.Drawing.Color]::Transparent); $g.CompositingMode = [System.Drawing.Drawing2D.CompositingMode]::SourceCopy
  for ($i = 0; $i -lt $count; $i++) {
    $frame = New-Object System.Drawing.Bitmap ($fh, $fh, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $fg = [System.Drawing.Graphics]::FromImage($frame); $fg.Clear([System.Drawing.Color]::Transparent); $fg.CompositingMode = [System.Drawing.Drawing2D.CompositingMode]::SourceCopy
    $fg.DrawImage($s, (New-Object System.Drawing.Rectangle 0, 0, $fh, $fh), (New-Object System.Drawing.Rectangle ($i * $fh), 0, $fh, $fh), [System.Drawing.GraphicsUnit]::Pixel)
    $fg.Dispose()
    $frame.RotateFlip([System.Drawing.RotateFlipType]::RotateNoneFlipX)
    $g.DrawImage($frame, ($i * $fh), 0, $fh, $fh)
    $frame.Dispose()
  }
  $g.Dispose(); $s.Dispose()
  $out.Save((Join-Path $envDir $dstFile), [System.Drawing.Imaging.ImageFormat]::Png); $out.Dispose()
  Write-Host "mirrored $srcFile -> $dstFile"
}

if ($args[1] -eq "mirror") {
  foreach ($a in @("idle","walk","shoot","die")) {
    Mirror-Frames "$a`_right.png"    "$a`_left.png"
    Mirror-Frames "$a`_up_right.png" "$a`_up_left.png"
  }
}

Write-Host "done. strips: $($built.Keys.Count)"
