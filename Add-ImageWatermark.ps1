#requires -Version 5.1
<#
.SYNOPSIS
    Creates copies of images with repeated text watermarks.
.DESCRIPTION
    Windows-only advanced script with wildcard and literal paths, pipeline input,
    recursive directory processing, tiled color text, outlines, a second pass,
    format-aware encoding, and optional ExifTool metadata. Sources are never
    intentionally overwritten. Writes occur only after ShouldProcess approval.
    The input plan is collected before any image output is created.
.PARAMETER Path
    One or more file/directory paths. Supports wildcards and string pipeline input.
.PARAMETER LiteralPath
    Paths used exactly as supplied. Binds FileInfo.FullName from the pipeline.
.PARAMETER Text
    Single-line watermark text. Required; no personal identity is built in.
.PARAMETER Destination
    Output directory. Defaults to Watermarked beneath each input directory, or
    beside each explicitly supplied file. Relative directory structure is retained.
.PARAMETER OutFile
    Exact output filename for one explicitly supplied file. Cannot be combined
    with Destination, Recurse, or pipeline input. Extension must match the encoder.
.PARAMETER Recurse
    Include input subdirectories. Output directories and reparse points are skipped.
.PARAMETER OutputFormat
    Preserve, Png, Jpeg, Bmp, or Tiff. Preserve maps static GIF input to PNG.
.PARAMETER Force
    Replace an existing output using File.Replace. Does not permit source overwrite
    or bypass WhatIf/Confirm. Without Force, an existing output is an error.
.PARAMETER PassThru
    Return one structured result per planned file, including failures and previews.
.PARAMETER Opacity
    Text alpha from 0 (transparent) to 255 (opaque). Default 20.
.PARAMETER FontFamily
    Installed font family. Default Arial. Missing fonts cause a configuration error.
.PARAMETER FontSize
    Font size in pixels, 6 through 1000. Default 32.
.PARAMETER AutoFontSize
    Fit the text to approximately one quarter of image width and the row spacing.
.PARAMETER LineCount
    Approximate row-density target before rotation. Default 10; not an exact count.
.PARAMETER HorizontalSpacing
    Pixels between successive watermark text runs. Default 160.
.PARAMETER VerticalSpacing
    Extra pixels between watermark rows. Default 40.
.PARAMETER ColorMode
    Rainbow, SingleColor, or Palette. Default Rainbow.
.PARAMETER Color
    HTML color or #RRGGBB value for SingleColor mode. Default #FF0000.
.PARAMETER Palette
    Named palette for Palette mode. Default Cool.
.PARAMETER ColorPalette
    Custom colors for Palette mode; overrides the named palette.
.PARAMETER RotationAngle
    Primary rotation in degrees, -180 through 180. Default -30.
.PARAMETER SecondPass
    Add another rotated layer of repeated watermark text.
.PARAMETER SecondPassAngle
    Secondary rotation in degrees. Default 30.
.PARAMETER Outline
    Draw a path-based outline around the watermark glyphs.
.PARAMETER OutlineWidth
    Outline pen width in pixels, 0.1 through 20. Default 1.
.PARAMETER OutlineColor
    HTML or #RRGGBB outline color. Default #000000. Outline alpha follows Opacity
    with a 1.35 multiplier, capped at 255.
.PARAMETER Dense
    Reduce spacing and enable the second pass. This is a visual-density option.
.PARAMETER JpegQuality
    JPEG encoder quality, 1 through 100. Default 90.
.PARAMETER BackgroundColor
    Opaque background for JPEG/BMP output. Default White.
.PARAMETER FrameHandling
    Reject (default) or First for animated/multipage input. First emits a warning.
.PARAMETER MaxPixelCount
    Maximum decoded source pixel count. Default 100000000. Not a hard memory limit.
.PARAMETER MetadataProfile
    None (default) or Pixel8Pro. The latter writes a synthetic camera profile.
.PARAMETER Metadata
    Hashtable of supported text metadata tags. See README for the allowlist.
    Values override profile text tags. Requires ExifTool and JPEG/PNG/TIFF output.
.PARAMETER ExifToolPath
    Literal path to exiftool.exe; otherwise discover ExifTool from PATH when needed.
.PARAMETER ExifToolTimeoutSeconds
    Timeout for each ExifTool invocation. Default 60, range 1 through 600.
.EXAMPLE
    .\Add-ImageWatermark.ps1 -LiteralPath 'D:\Art\painting.jpg' -Text 'Preview' -WhatIf
.EXAMPLE
    .\Add-ImageWatermark.ps1 -Path 'D:\Art' -Text 'Studio Example' -Recurse -AutoFontSize
.EXAMPLE
    Get-ChildItem 'D:\Art' -File | .\Add-ImageWatermark.ps1 -Text 'Preview' -PassThru
.OUTPUTS
    ImageWatermark.Result when PassThru is supplied. Otherwise no success output.
.NOTES
    Version 2.0.0. Targets Windows PowerShell 5.1 and PowerShell 7 on Windows.
    Use ErrorAction Stop for fail-fast behavior. Metadata is not copied from input.
    No Microsoft endorsement or certification is implied.
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium', DefaultParameterSetName = 'Path')]
[OutputType('ImageWatermark.Result')]
param (
    [Parameter(Mandatory = $true, Position = 0, ValueFromPipeline = $true,
        ValueFromPipelineByPropertyName = $true, ParameterSetName = 'Path')]
    [SupportsWildcards()]
    [ValidateNotNullOrEmpty()]
    [string[]]$Path,

    [Parameter(Mandatory = $true, ValueFromPipelineByPropertyName = $true, ParameterSetName = 'LiteralPath')]
    [Alias('FullName', 'PSPath')]
    [ValidateNotNullOrEmpty()]
    [string[]]$LiteralPath,

    [Parameter(Mandatory = $true, Position = 1)]
    [Alias('WatermarkText')]
    [ValidateNotNullOrEmpty()]
    [ValidateLength(1, 512)]
    [ValidateScript({ -not [string]::IsNullOrWhiteSpace($_) -and $_ -notmatch '[\x00-\x1F\x7F]' })]
    [string]$Text,

    [Parameter()][ValidateNotNullOrEmpty()][string]$Destination,
    [Parameter()][ValidateNotNullOrEmpty()][string]$OutFile,
    [Parameter()][switch]$Recurse,
    [Parameter()][ValidateSet('Preserve', 'Png', 'Jpeg', 'Bmp', 'Tiff')][string]$OutputFormat = 'Preserve',
    [Parameter()][switch]$Force,
    [Parameter()][switch]$PassThru,
    [Parameter()][ValidateRange(0, 255)][int]$Opacity = 20,
    [Parameter()][ValidateNotNullOrEmpty()][string]$FontFamily = 'Arial',
    [Parameter()][ValidateRange(6, 1000)][single]$FontSize = 32,
    [Parameter()][switch]$AutoFontSize,
    [Parameter()][Alias('TargetLineCount')][ValidateRange(2, 100)][int]$LineCount = 10,
    [Parameter()][Alias('HorizontalPadding')][ValidateRange(0, 5000)][int]$HorizontalSpacing = 160,
    [Parameter()][Alias('VerticalPadding')][ValidateRange(0, 5000)][int]$VerticalSpacing = 40,
    [Parameter()][ValidateSet('Rainbow', 'SingleColor', 'Palette')][string]$ColorMode = 'Rainbow',
    [Parameter()][Alias('SingleColor')][ValidateNotNullOrEmpty()][string]$Color = '#FF0000',
    [Parameter()][Alias('PaletteName')]
    [ValidateSet('Rainbow', 'Brand', 'Warm', 'Cool', 'Grayscale', 'RedAlert', 'BlueMix', 'GreenMix')]
    [string]$Palette = 'Cool',
    [Parameter()][Alias('CustomColors')][ValidateNotNullOrEmpty()][string[]]$ColorPalette,
    [Parameter()][Alias('Rotation')][ValidateRange(-180, 180)][single]$RotationAngle = -30,
    [Parameter()][Alias('AddSecondPass')][switch]$SecondPass,
    [Parameter()][Alias('SecondPassRotation')][ValidateRange(-180, 180)][single]$SecondPassAngle = 30,
    [Parameter()][Alias('AddOutline')][switch]$Outline,
    [Parameter()][ValidateRange(0.1, 20)][single]$OutlineWidth = 1,
    [Parameter()][ValidateNotNullOrEmpty()][string]$OutlineColor = '#000000',
    [Parameter()][Alias('DenseProtection')][switch]$Dense,
    [Parameter()][ValidateRange(1, 100)][int]$JpegQuality = 90,
    [Parameter()][ValidateNotNullOrEmpty()][string]$BackgroundColor = 'White',
    [Parameter()][ValidateSet('Reject', 'First')][string]$FrameHandling = 'Reject',
    [Parameter()][ValidateRange(1, 1000000000)][long]$MaxPixelCount = 100000000,
    [Parameter()][ValidateSet('None', 'Pixel8Pro')][string]$MetadataProfile = 'None',
    [Parameter()][ValidateNotNull()][hashtable]$Metadata = @{},
    [Parameter()][ValidateNotNullOrEmpty()][string]$ExifToolPath,
    [Parameter()][ValidateRange(1, 600)][int]$ExifToolTimeoutSeconds = 60
)

begin {
    Set-StrictMode -Version 3.0
    # Leave ErrorActionPreference alone: callers choose continuation or fail-fast.
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
        throw [PlatformNotSupportedException]::new('Add-ImageWatermark requires Windows and System.Drawing.')
    }
    Add-Type -AssemblyName System.Drawing -ErrorAction Stop
    if ($PSBoundParameters.ContainsKey('OutFile') -and
        ($PSBoundParameters.ContainsKey('Destination') -or $Recurse -or $MyInvocation.ExpectingInput)) {
        throw [ArgumentException]::new('OutFile requires one explicit file and cannot be used with Destination, Recurse, or pipeline input.')
    }
    if ($ColorPalette -and $ColorMode -ne 'Palette') {
        throw [ArgumentException]::new('ColorPalette requires ColorMode Palette.')
    }

    $inputPlan = [System.Collections.Generic.List[object]]::new()
    $seenSource = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $extensionFormat = @{ '.jpg' = 'Jpeg'; '.jpeg' = 'Jpeg'; '.png' = 'Png'; '.bmp' = 'Bmp'; '.gif' = 'Gif'; '.tif' = 'Tiff'; '.tiff' = 'Tiff' }
    $formatExtension = @{ Png = '.png'; Jpeg = '.jpg'; Bmp = '.bmp'; Tiff = '.tif' }
    $formatGuid = @{
        Png = [Drawing.Imaging.ImageFormat]::Png.Guid; Jpeg = [Drawing.Imaging.ImageFormat]::Jpeg.Guid
        Bmp = [Drawing.Imaging.ImageFormat]::Bmp.Guid; Gif = [Drawing.Imaging.ImageFormat]::Gif.Guid
        Tiff = [Drawing.Imaging.ImageFormat]::Tiff.Guid
    }
    $codecs = @{}
    foreach ($codec in [Drawing.Imaging.ImageCodecInfo]::GetImageEncoders()) { $codecs[$codec.FormatID.ToString()] = $codec }

    function Resolve-FileSystemName {
        param ([string]$Name)
        $provider = $null
        $drive = $null
        $native = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Name, [ref]$provider, [ref]$drive)
        if ($provider.Name -ne 'FileSystem') { throw [ArgumentException]::new('Only FileSystem paths are supported.') }
        return [IO.Path]::GetFullPath($native)
    }

    function Test-PathWithin {
        param ([string]$Candidate, [string]$Root)
        $prefix = $Root.TrimEnd([char[]]'\/') + [IO.Path]::DirectorySeparatorChar
        return $Candidate.Equals($Root, [StringComparison]::OrdinalIgnoreCase) -or $Candidate.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)
    }

    function Confirm-RegularFileSystemPath {
        param ([string]$Name)
        # Reject links/junctions in existing ancestors too, including explicit roots.
        $current = $Name
        while (-not [string]::IsNullOrEmpty($current)) {
            if ([IO.File]::Exists($current) -or [IO.Directory]::Exists($current)) {
                if (([IO.File]::GetAttributes($current) -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                    throw [IO.IOException]::new("Reparse points are not followed: $current")
                }
            }
            $parent = [IO.Path]::GetDirectoryName($current.TrimEnd([char[]]'\/'))
            if ($parent -eq $current) { break }
            $current = $parent
        }
    }

    function ConvertTo-WatermarkColor {
        param ([string]$Value, [int]$Alpha)
        $base = [Drawing.ColorTranslator]::FromHtml($Value)
        if ($base.IsEmpty -or $base.A -ne 255) { throw [ArgumentException]::new("Use an opaque named color or #RRGGBB value: $Value") }
        return [Drawing.Color]::FromArgb($Alpha, $base.R, $base.G, $base.B)
    }

    $paletteMap = @{
        Rainbow = @('#9400D3', '#4B0082', '#0000FF', '#008000', '#FFFF00', '#FFA500', '#FF0000')
        Brand = @('#2563EB', '#7C3AED', '#DB2777', '#EA580C', '#16A34A')
        Warm = @('#B91C1C', '#DC2626', '#EA580C', '#F59E0B', '#EAB308')
        Cool = @('#1D4ED8', '#0F766E', '#0891B2', '#7C3AED', '#4338CA')
        Grayscale = @('#111827', '#374151', '#6B7280', '#9CA3AF', '#D1D5DB')
        RedAlert = @('#7F1D1D', '#B91C1C', '#DC2626', '#EF4444')
        BlueMix = @('#1E3A8A', '#1D4ED8', '#2563EB', '#38BDF8')
        GreenMix = @('#14532D', '#15803D', '#16A34A', '#4ADE80')
    }
    $selectedColors = if ($ColorMode -eq 'SingleColor') { @($Color) }
        elseif ($ColorMode -eq 'Rainbow') { $paletteMap.Rainbow }
        elseif ($ColorPalette) { $ColorPalette } else { $paletteMap[$Palette] }
    $fillColors = @($selectedColors | ForEach-Object { ConvertTo-WatermarkColor -Value $_ -Alpha $Opacity })
    $borderColor = ConvertTo-WatermarkColor -Value $OutlineColor -Alpha ([Math]::Min(255, [int]($Opacity * 1.35)))
    $canvasColor = ConvertTo-WatermarkColor -Value $BackgroundColor -Alpha 255
    $fontProbe = [Drawing.FontFamily]::new($FontFamily)
    try {
        if (-not $fontProbe.IsStyleAvailable([Drawing.FontStyle]::Bold)) {
            throw [ArgumentException]::new("The font family does not support Bold: $FontFamily")
        }
    } finally { $fontProbe.Dispose() }
    $destinationRoot = if ($Destination) { Resolve-FileSystemName -Name $Destination } else { $null }
    $exactOutput = if ($OutFile) { Resolve-FileSystemName -Name $OutFile } else { $null }

    function Get-ImageCandidate {
        param ([string]$Root, [string]$ExcludedRoot)
        $stack = [System.Collections.Generic.Stack[string]]::new()
        $stack.Push($Root)
        while ($stack.Count -gt 0) {
            $directory = $stack.Pop()
            foreach ($entry in @(Get-ChildItem -LiteralPath $directory -Force -ErrorAction Stop)) {
                if (($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                    Write-Verbose "Skipping reparse point: $($entry.FullName)"
                    continue
                }
                if ($entry.PSIsContainer) {
                    if ($Recurse -and -not (Test-PathWithin -Candidate $entry.FullName -Root $ExcludedRoot)) { $stack.Push($entry.FullName) }
                } elseif ($extensionFormat.ContainsKey($entry.Extension.ToLowerInvariant())) { $entry }
            }
        }
    }

    function New-WatermarkPlanItem {
        param ([IO.FileInfo]$File, [string]$Root, [string]$OutputRoot)
        $sourceExtension = $File.Extension.ToLowerInvariant()
        if (-not $extensionFormat.ContainsKey($sourceExtension)) { throw [ArgumentException]::new("Unsupported image extension: $sourceExtension") }
        $format = if ($OutputFormat -eq 'Preserve') { $extensionFormat[$sourceExtension] } else { $OutputFormat }
        if ($format -eq 'Gif') { $format = 'Png' }
        if ($exactOutput) {
            $target = $exactOutput
            $extension = [IO.Path]::GetExtension($target).ToLowerInvariant()
            if (-not $extensionFormat.ContainsKey($extension) -or $extensionFormat[$extension] -ne $format) {
                throw [ArgumentException]::new("OutFile extension must match $format output. Set OutputFormat explicitly to convert formats.")
            }
        } else {
            $relative = $File.FullName.Substring(($Root.TrimEnd([char[]]'\/') + [IO.Path]::DirectorySeparatorChar).Length)
            $target = [IO.Path]::Combine($OutputRoot, [IO.Path]::ChangeExtension($relative, $formatExtension[$format]))
        }
        [pscustomobject]@{ SourcePath = $File.FullName; DestinationPath = $target; Format = $format; SourceFormat = $extensionFormat[$sourceExtension] }
    }

    function Get-WatermarkFontSize {
        param ([Drawing.Graphics]$Graphics, [int]$Width, [int]$Height)
        if (-not $AutoFontSize) { return $FontSize }
        $low = 6
        $high = 400
        $best = 6
        $layout = [Drawing.StringFormat]::GenericTypographic
        try {
            while ($low -le $high) {
                $mid = [int][Math]::Floor(($low + $high) / 2)
                $probe = [Drawing.Font]::new($FontFamily, [single]$mid, [Drawing.FontStyle]::Bold, [Drawing.GraphicsUnit]::Pixel)
                try {
                    $measure = $Graphics.MeasureString($Text, $probe, [int]::MaxValue, $layout)
                    if ($measure.Width -le [Math]::Max(1, $Width * 0.3) -and
                        $measure.Height -le [Math]::Max(1, $Height / $LineCount * 0.65)) {
                        $best = $mid
                        $low = $mid + 1
                    } else { $high = $mid - 1 }
                } finally { $probe.Dispose() }
            }
        } finally { $layout.Dispose() }
        return [single]$best
    }

    function New-WatermarkTile {
        param ([Drawing.Graphics]$MeasureGraphics, [single]$Size)
        $font = $null
        $layout = $null
        $surface = $null
        $tile = $null
        $pen = $null
        $paths = [System.Collections.Generic.List[object]]::new()
        $brushes = [System.Collections.Generic.List[Drawing.SolidBrush]]::new()
        try {
            $font = [Drawing.Font]::new($FontFamily, $Size, [Drawing.FontStyle]::Bold, [Drawing.GraphicsUnit]::Pixel)
            $layout = [Drawing.StringFormat]::GenericTypographic
            $layout.FormatFlags = $layout.FormatFlags -bor [Drawing.StringFormatFlags]::MeasureTrailingSpaces
            $elements = [System.Collections.Generic.List[string]]::new()
            if ($ColorMode -eq 'SingleColor') { $elements.Add($Text) }
            else {
                # Keep surrogate pairs and combining text elements together.
                $iterator = [Globalization.StringInfo]::GetTextElementEnumerator($Text)
                while ($iterator.MoveNext()) { $elements.Add([string]$iterator.GetTextElement()) }
            }
            [single]$advance = 0
            [single]$left = 0
            [single]$top = 0
            [single]$right = 0
            [single]$bottom = $font.GetHeight($MeasureGraphics)
            foreach ($element in $elements) {
                $glyph = [Drawing.Drawing2D.GraphicsPath]::new()
                $paths.Add($glyph)
                $glyph.AddString($element, $font.FontFamily, [int][Drawing.FontStyle]::Bold, $Size,
                    [Drawing.PointF]::new($advance, 0), $layout)
                if ($glyph.PointCount -gt 0) {
                    $bounds = $glyph.GetBounds()
                    $left = [Math]::Min($left, $bounds.Left)
                    $top = [Math]::Min($top, $bounds.Top)
                    $right = [Math]::Max($right, $bounds.Right)
                    $bottom = [Math]::Max($bottom, $bounds.Bottom)
                }
                $advance += $MeasureGraphics.MeasureString($element, $font, [int]::MaxValue, $layout).Width
            }
            $padding = if ($Outline) { [Math]::Ceiling($OutlineWidth) + 2 } else { 2 }
            $width = [int][Math]::Ceiling([Math]::Max($advance, $right) - $left + 2 * $padding)
            $height = [int][Math]::Ceiling($bottom - $top + 2 * $padding)
            if ($width -gt 32767 -or $height -gt 32767 -or [long]$width * $height -gt 16000000) {
                throw [ArgumentException]::new('Watermark tile is too large. Reduce Text length or FontSize, or use AutoFontSize.')
            }
            $tile = [Drawing.Bitmap]::new([Math]::Max(1, $width), [Math]::Max(1, $height), [Drawing.Imaging.PixelFormat]::Format32bppArgb)
            $surface = [Drawing.Graphics]::FromImage($tile)
            $surface.Clear([Drawing.Color]::Transparent)
            $surface.SmoothingMode = [Drawing.Drawing2D.SmoothingMode]::AntiAlias
            $surface.PixelOffsetMode = [Drawing.Drawing2D.PixelOffsetMode]::HighQuality
            $surface.TranslateTransform([single]($padding - $left), [single]($padding - $top))
            foreach ($fill in $fillColors) { $brushes.Add([Drawing.SolidBrush]::new($fill)) }
            if ($Outline) {
                $pen = [Drawing.Pen]::new($borderColor, $OutlineWidth)
                $pen.LineJoin = [Drawing.Drawing2D.LineJoin]::Round
            }
            for ($index = 0; $index -lt $paths.Count; $index++) {
                if ($paths[$index].PointCount -eq 0) { continue }
                if ($Outline) { $surface.DrawPath($pen, $paths[$index]) }
                $surface.FillPath($brushes[$index % $brushes.Count], $paths[$index])
            }
            # Transfer bitmap ownership to caller; all drawing resources stay local.
            $result = $tile
            $tile = $null
            return $result
        } finally {
            foreach ($glyph in $paths) { $glyph.Dispose() }
            foreach ($brush in $brushes) { $brush.Dispose() }
            if ($pen) { $pen.Dispose() }
            if ($surface) { $surface.Dispose() }
            if ($tile) { $tile.Dispose() }
            if ($layout) { $layout.Dispose() }
            if ($font) { $font.Dispose() }
        }
    }

    function Invoke-WatermarkLayer {
        param ([Drawing.Graphics]$Graphics, [Drawing.Bitmap]$Tile, [int]$Width, [int]$Height,
            [single]$Angle, [bool]$DenseLayer, [int]$Rows)
        $gapX = if ($DenseLayer) { [Math]::Floor($HorizontalSpacing / 2) } else { $HorizontalSpacing }
        $gapY = if ($DenseLayer) { [Math]::Floor($VerticalSpacing / 2) } else { $VerticalSpacing }
        $stepX = [Math]::Max(1, $Tile.Width + $gapX)
        $stepY = [Math]::Max($Tile.Height + $gapY, $Height / [double]$Rows + $gapY)
        $radians = $Angle * [Math]::PI / 180
        $cosine = [Math]::Abs([Math]::Cos($radians))
        $sine = [Math]::Abs([Math]::Sin($radians))
        # Axis-aligned bounds in the inverse-rotated coordinate system.
        $halfWidth = ($Width * $cosine + $Height * $sine) / 2
        $halfHeight = ($Width * $sine + $Height * $cosine) / 2
        $columns = [Math]::Ceiling((2 * $halfWidth + 2 * $Tile.Width) / $stepX) + 2
        $rowCount = [Math]::Ceiling((2 * $halfHeight + 2 * $Tile.Height) / $stepY) + 2
        if ($columns * $rowCount -gt 100000) {
            throw [ArgumentException]::new('Watermark density exceeds 100000 tiles per layer. Increase font/spacing or reduce LineCount.')
        }
        $state = $Graphics.Save()
        try {
            $Graphics.TranslateTransform([single]($Width / 2), [single]($Height / 2))
            $Graphics.RotateTransform($Angle)
            $row = 0
            for ($y = -$halfHeight - $Tile.Height; $y -le $halfHeight; $y += $stepY) {
                $offset = if ($row % 2 -eq 0) { 0 } else { $stepX / 2 }
                for ($x = -$halfWidth - $Tile.Width - $offset; $x -le $halfWidth; $x += $stepX) {
                    $Graphics.DrawImage($Tile, [single]$x, [single]$y, [single]$Tile.Width, [single]$Tile.Height)
                }
                $row++
            }
        } finally { $Graphics.Restore($state) }
    }

    function Invoke-WatermarkRender {
        param ([object]$Item, [string]$TemporaryPath)
        $stream = $null
        $source = $null
        $bitmap = $null
        $graphics = $null
        $tile = $null
        $encoderParameters = $null
        $outputStream = $null
        try {
            $stream = [IO.FileStream]::new($Item.SourcePath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
            $source = [Drawing.Image]::FromStream($stream, $true, $true)
            if ($source.RawFormat.Guid -ne $formatGuid[$Item.SourceFormat]) {
                throw [IO.InvalidDataException]::new('The image data does not match its filename extension.')
            }
            if ([long]$source.Width * $source.Height -gt $MaxPixelCount) {
                throw [IO.InvalidDataException]::new("Image exceeds MaxPixelCount ($MaxPixelCount).")
            }
            $multipleFrames = $false
            foreach ($dimension in $source.FrameDimensionsList) {
                if ($source.GetFrameCount([Drawing.Imaging.FrameDimension]::new($dimension)) -gt 1) { $multipleFrames = $true }
            }
            if ($multipleFrames) {
                if ($FrameHandling -eq 'Reject') { throw [IO.InvalidDataException]::new('Animated/multipage input requires FrameHandling First; output contains one frame.') }
                Write-Warning "Only the first frame/page will be written: $($Item.SourcePath)"
            }
            $orientation = 1
            if ($source.PropertyIdList -contains 0x0112) {
                $orientationBytes = $source.GetPropertyItem(0x0112).Value
                if ($orientationBytes.Length -ge 2) { $orientation = [BitConverter]::ToUInt16($orientationBytes, 0) }
            }
            $transforms = @{
                2 = [Drawing.RotateFlipType]::RotateNoneFlipX; 3 = [Drawing.RotateFlipType]::Rotate180FlipNone
                4 = [Drawing.RotateFlipType]::Rotate180FlipX; 5 = [Drawing.RotateFlipType]::Rotate90FlipX
                6 = [Drawing.RotateFlipType]::Rotate90FlipNone; 7 = [Drawing.RotateFlipType]::Rotate270FlipX
                8 = [Drawing.RotateFlipType]::Rotate270FlipNone
            }
            if ($transforms.ContainsKey([int]$orientation)) { $source.RotateFlip($transforms[[int]$orientation]) }
            $bitmap = [Drawing.Bitmap]::new($source.Width, $source.Height, [Drawing.Imaging.PixelFormat]::Format32bppArgb)
            if ($source.HorizontalResolution -gt 0 -and $source.VerticalResolution -gt 0 -and
                $source.HorizontalResolution -lt 100000 -and $source.VerticalResolution -lt 100000) {
                $bitmap.SetResolution($source.HorizontalResolution, $source.VerticalResolution)
            }
            $graphics = [Drawing.Graphics]::FromImage($bitmap)
            $graphics.PageUnit = [Drawing.GraphicsUnit]::Pixel
            $graphics.Clear($(if ($Item.Format -in @('Jpeg', 'Bmp')) { $canvasColor } else { [Drawing.Color]::Transparent }))
            $graphics.DrawImage($source, [Drawing.Rectangle]::new(0, 0, $bitmap.Width, $bitmap.Height),
                0, 0, $source.Width, $source.Height, [Drawing.GraphicsUnit]::Pixel)
            $graphics.CompositingMode = [Drawing.Drawing2D.CompositingMode]::SourceOver
            $graphics.CompositingQuality = [Drawing.Drawing2D.CompositingQuality]::HighQuality
            $resolvedSize = Get-WatermarkFontSize -Graphics $graphics -Width $bitmap.Width -Height $bitmap.Height
            $tile = New-WatermarkTile -MeasureGraphics $graphics -Size $resolvedSize
            Invoke-WatermarkLayer -Graphics $graphics -Tile $tile -Width $bitmap.Width -Height $bitmap.Height `
                -Angle $RotationAngle -DenseLayer ([bool]$Dense) -Rows $LineCount
            if ($SecondPass -or $Dense) {
                Invoke-WatermarkLayer -Graphics $graphics -Tile $tile -Width $bitmap.Width -Height $bitmap.Height `
                    -Angle $SecondPassAngle -DenseLayer $true -Rows ($LineCount + 2)
            }
            $graphics.Dispose()
            $graphics = $null
            $outputStream = [IO.FileStream]::new($TemporaryPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
            $encoder = $codecs[$formatGuid[$Item.Format].ToString()]
            if ($null -eq $encoder) { throw [NotSupportedException]::new("Encoder unavailable: $($Item.Format)") }
            if ($Item.Format -eq 'Jpeg') {
                $encoderParameters = [Drawing.Imaging.EncoderParameters]::new(1)
                $encoderParameters.Param[0] = [Drawing.Imaging.EncoderParameter]::new([Drawing.Imaging.Encoder]::Quality, [long]$JpegQuality)
            }
            $bitmap.Save($outputStream, $encoder, $encoderParameters)
            $outputStream.Flush($true)
            [pscustomobject]@{ Width = $bitmap.Width; Height = $bitmap.Height; FontSize = $resolvedSize }
        } finally {
            if ($outputStream) { $outputStream.Dispose() }
            if ($encoderParameters) { $encoderParameters.Dispose() }
            if ($tile) { $tile.Dispose() }
            if ($graphics) { $graphics.Dispose() }
            if ($bitmap) { $bitmap.Dispose() }
            if ($source) { $source.Dispose() }
            if ($stream) { $stream.Dispose() }
        }
    }

    $textMetadataTags = @(
        'EXIF:Artist', 'EXIF:Copyright', 'EXIF:ImageDescription', 'EXIF:Make', 'EXIF:Model',
        'EXIF:LensMake', 'EXIF:LensModel', 'EXIF:Software',
        'XMP-dc:Identifier', 'XMP-dc:Creator', 'XMP-dc:Rights', 'XMP-dc:Description'
    )
    $metadataValues = @{}
    if ($MetadataProfile -eq 'Pixel8Pro') {
        $metadataValues = @{
            'EXIF:Make' = 'Google'; 'EXIF:Model' = 'Pixel 8 Pro'; 'EXIF:LensMake' = 'Google'
            'EXIF:LensModel' = 'Pixel 8 Pro back camera 6.9mm f/1.68'
            'EXIF:Software' = 'Add-ImageWatermark 2.0.0'
            'EXIF:ExposureTime#' = '0.0666666667'; 'EXIF:FNumber#' = '1.68'; 'EXIF:ISO#' = '400'
            'EXIF:FocalLength#' = '6.9'; 'EXIF:FocalLengthIn35mmFormat#' = '24'
            'EXIF:ExposureProgram#' = '2'; 'EXIF:ExposureMode#' = '0'; 'EXIF:WhiteBalance#' = '0'
            'EXIF:MeteringMode#' = '2'; 'EXIF:Flash#' = '16'; 'EXIF:ColorSpace#' = '1'
            'EXIF:SceneCaptureType#' = '0'; 'EXIF:SceneType#' = '1'; 'EXIF:CustomRendered#' = '1'
            'EXIF:DigitalZoomRatio#' = '0'
        }
    }
    foreach ($key in $Metadata.Keys) {
        if ([string]$key -notin $textMetadataTags) { throw [ArgumentException]::new("Unsupported Metadata tag: $key. See the README allowlist.") }
        if ($Metadata[$key] -isnot [string] -or [string]::IsNullOrWhiteSpace($Metadata[$key]) -or
            $Metadata[$key].Length -gt 4096 -or $Metadata[$key] -match '[\x00-\x1F\x7F]') {
            throw [ArgumentException]::new("Metadata values must be nonempty single-line strings up to 4096 characters: $key")
        }
        $canonicalKey = @($textMetadataTags | Where-Object { $_ -eq $key })[0]
        $metadataValues[$canonicalKey] = $Metadata[$key]
    }
    $needsMetadata = $MetadataProfile -ne 'None' -or $metadataValues.Count -gt 0
    $exifExecutable = $null
    if ($needsMetadata) {
        if ($ExifToolPath) {
            $exifExecutable = Resolve-FileSystemName -Name $ExifToolPath
            if (-not [IO.File]::Exists($exifExecutable)) { throw [IO.FileNotFoundException]::new('ExifTool executable was not found.', $exifExecutable) }
        } else {
            $toolCommand = Get-Command -Name 'exiftool.exe' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($null -eq $toolCommand) { throw [IO.FileNotFoundException]::new('Metadata requires ExifTool. Install exiftool.exe on PATH or supply ExifToolPath.') }
            $exifExecutable = $toolCommand.Source
        }
        if ([IO.Path]::GetExtension($exifExecutable) -ne '.exe') { throw [ArgumentException]::new('ExifToolPath must identify the Windows executable, not a command script.') }
    }

    function Invoke-ExifToolProcess {
        param ([string[]]$ArgumentLine)
        $start = [Diagnostics.ProcessStartInfo]::new()
        $start.FileName = $exifExecutable
        # Argument-file input avoids command-line quoting and length pitfalls.
        # Disable ambient ExifTool config; supply UTF-8 filenames explicitly.
        $start.Arguments = '-config "" -charset filename=UTF8 -@ -'
        $start.UseShellExecute = $false
        $start.CreateNoWindow = $true
        $start.RedirectStandardInput = $true
        $start.RedirectStandardOutput = $true
        $start.RedirectStandardError = $true
        $start.StandardOutputEncoding = [Text.UTF8Encoding]::new($false)
        $start.StandardErrorEncoding = [Text.UTF8Encoding]::new($false)
        $process = [Diagnostics.Process]::new()
        $process.StartInfo = $start
        try {
            $null = $process.Start()
            $stdoutTask = $process.StandardOutput.ReadToEndAsync()
            $stderrTask = $process.StandardError.ReadToEndAsync()
            $payload = [Text.Encoding]::UTF8.GetBytes(($ArgumentLine -join "`n") + "`n")
            $process.StandardInput.BaseStream.Write($payload, 0, $payload.Length)
            $process.StandardInput.Close()
            if (-not $process.WaitForExit($ExifToolTimeoutSeconds * 1000)) {
                try {
                    if ($PSVersionTable.PSEdition -eq 'Core') { $process.Kill($true) } else { $process.Kill() }
                } catch { Write-Verbose "Could not terminate ExifTool: $($_.Exception.Message)" }
                throw [TimeoutException]::new("ExifTool exceeded $ExifToolTimeoutSeconds seconds. Output was not published.")
            }
            if (-not $stdoutTask.Wait(5000) -or -not $stderrTask.Wait(5000)) {
                throw [TimeoutException]::new('ExifTool output streams did not close; output was not published.')
            }
            $stdout = $stdoutTask.Result
            $stderr = $stderrTask.Result
            if ($process.ExitCode -ne 0) { throw [IO.IOException]::new("ExifTool exit code $($process.ExitCode): $stderr $stdout") }
            if (-not [string]::IsNullOrWhiteSpace($stderr)) { Write-Warning $stderr.Trim() }
            return $stdout
        } finally { $process.Dispose() }
    }

    function Invoke-WatermarkMetadata {
        param ([string]$TemporaryPath)
        $tags = $metadataValues.Clone()
        if ($MetadataProfile -eq 'Pixel8Pro' -and -not $tags.ContainsKey('XMP-dc:Identifier')) {
            $tags['XMP-dc:Identifier'] = [Guid]::NewGuid().ToString('N')
        }
        $arguments = [System.Collections.Generic.List[string]]::new()
        $arguments.Add('-overwrite_original')
        foreach ($tag in @($tags.Keys | Sort-Object)) { $arguments.Add('-' + $tag + '=' + $tags[$tag]) }
        $arguments.Add($TemporaryPath)
        $null = Invoke-ExifToolProcess -ArgumentLine $arguments.ToArray()
        # Verify every requested text tag, including custom attribution. Numeric
        # profile values use ExifTool's raw (#) syntax and its process status.
        $readArguments = [System.Collections.Generic.List[string]]::new()
        $readArguments.Add('-j')
        $readArguments.Add('-G0')
        $readArguments.Add('-s')
        foreach ($tag in $tags.Keys) { if (-not $tag.EndsWith('#')) { $readArguments.Add('-' + $tag) } }
        $readArguments.Add($TemporaryPath)
        $json = Invoke-ExifToolProcess -ArgumentLine $readArguments.ToArray()
        $records = @($json | ConvertFrom-Json -ErrorAction Stop)
        if ($records.Count -ne 1) { throw [IO.InvalidDataException]::new('ExifTool returned an unexpected verification response.') }
        foreach ($tag in $tags.Keys) {
            if ($tag.EndsWith('#')) { continue }
            $propertyName = $tag -replace '^XMP-dc:', 'XMP:'
            $property = $records[0].PSObject.Properties[$propertyName]
            if ($null -eq $property -or (@($property.Value) -join ', ') -cne $tags[$tag]) {
                throw [IO.InvalidDataException]::new("Metadata verification failed for $tag. Output was not published.")
            }
        }
    }

    function Test-EncodedImage {
        param ([string]$Name, [string]$Format, [int]$Width, [int]$Height)
        $checkStream = [IO.FileStream]::new($Name, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        $check = $null
        try {
            $check = [Drawing.Image]::FromStream($checkStream, $true, $true)
            if ($check.Width -ne $Width -or $check.Height -ne $Height -or $check.RawFormat.Guid -ne $formatGuid[$Format]) {
                throw [IO.InvalidDataException]::new('Encoded output failed dimension/format verification.')
            }
        } finally {
            if ($check) { $check.Dispose() }
            $checkStream.Dispose()
        }
    }
}

process {
    $requestedPaths = if ($PSCmdlet.ParameterSetName -eq 'LiteralPath') { $LiteralPath } else { $Path }
    $resolvedItems = [System.Collections.Generic.List[object]]::new()
    foreach ($requestedPath in $requestedPaths) {
        try {
            $resolvedPaths = if ($PSCmdlet.ParameterSetName -eq 'LiteralPath') {
                @(Resolve-Path -LiteralPath $requestedPath -ErrorAction Stop)
            } else { @(Resolve-Path -Path $requestedPath -ErrorAction Stop) }
            foreach ($resolved in $resolvedPaths) {
                if ($resolved.Provider.Name -ne 'FileSystem') { throw [ArgumentException]::new('Only FileSystem input paths are supported.') }
                Confirm-RegularFileSystemPath -Name $resolved.ProviderPath
                $resolvedItems.Add((Get-Item -LiteralPath $resolved.ProviderPath -Force -ErrorAction Stop))
            }
        } catch {
            $PSCmdlet.WriteError([Management.Automation.ErrorRecord]::new($_.Exception, 'Watermark.InputResolutionFailed',
                [Management.Automation.ErrorCategory]::InvalidArgument, $requestedPath))
        }
    }
    if ($exactOutput -and ($resolvedItems.Count -ne 1 -or $resolvedItems[0].PSIsContainer)) {
        throw [ArgumentException]::new('OutFile requires exactly one resolved image file.')
    }
    foreach ($item in $resolvedItems) {
        try {
            $root = if ($item.PSIsContainer) { $item.FullName } else { $item.DirectoryName }
            $outputRoot = if ($destinationRoot) { $destinationRoot } else { [IO.Path]::Combine($root, 'Watermarked') }
            if ($item.PSIsContainer -and (Test-PathWithin -Candidate $root -Root $outputRoot)) {
                throw [ArgumentException]::new('Destination must not equal or be an ancestor of an input directory.')
            }
            $candidates = if ($item.PSIsContainer) { @(Get-ImageCandidate -Root $root -ExcludedRoot $outputRoot) } else { @($item) }
            foreach ($candidate in $candidates) {
                if ($seenSource.Contains($candidate.FullName)) { continue }
                $planItem = New-WatermarkPlanItem -File $candidate -Root $root -OutputRoot $outputRoot
                $inputPlan.Add($planItem)
                $null = $seenSource.Add($candidate.FullName)
            }
        } catch {
            $PSCmdlet.WriteError([Management.Automation.ErrorRecord]::new($_.Exception, 'Watermark.InputPlanningFailed',
                [Management.Automation.ErrorCategory]::InvalidArgument, $item.FullName))
        }
    }
}

end {
    if ($inputPlan.Count -eq 0) { Write-Warning 'No supported images were selected.'; return }
    # Validate the entire finite plan before the first output. Force cannot make
    # two sources share a target or turn any selected source into a destination.
    $targets = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($item in $inputPlan) {
        if ($seenSource.Contains($item.DestinationPath)) { throw [IO.IOException]::new("An output path is also a selected source: $($item.DestinationPath)") }
        if (-not $targets.Add($item.DestinationPath)) { throw [IO.IOException]::new("Multiple inputs map to the same output: $($item.DestinationPath). Use separate destinations or rename inputs.") }
        Confirm-RegularFileSystemPath -Name $item.DestinationPath
        if ([IO.Directory]::Exists($item.DestinationPath)) { throw [IO.IOException]::new("An output path is a directory: $($item.DestinationPath)") }
        if ($needsMetadata -and $item.Format -eq 'Bmp') { throw [ArgumentException]::new('Metadata options require JPEG, PNG, or TIFF output. Select OutputFormat Png for BMP input.') }
    }
    $index = 0
    try {
        foreach ($item in $inputPlan) {
            $index++
            $timer = [Diagnostics.Stopwatch]::StartNew()
            $temporaryPath = $null
            $status = 'Skipped'
            $errorMessage = $null
            $dimensions = $null
            try {
                Write-Progress -Activity 'Adding image watermarks' -Status "$index of $($inputPlan.Count): $([IO.Path]::GetFileName($item.SourcePath))" `
                    -PercentComplete (($index - 1) * 100 / $inputPlan.Count)
                if ([IO.File]::Exists($item.DestinationPath) -and -not $Force) {
                    throw [IO.IOException]::new("Output already exists. Use Force to replace it: $($item.DestinationPath)")
                }
                $action = "Create $($item.Format) watermarked copy of '$($item.SourcePath)'"
                if ($Force -and [IO.File]::Exists($item.DestinationPath)) { $action = "Replace output with $($item.Format) watermarked copy of '$($item.SourcePath)'" }
                if ($PSCmdlet.ShouldProcess($item.DestinationPath, $action)) {
                    Confirm-RegularFileSystemPath -Name $item.SourcePath
                    Confirm-RegularFileSystemPath -Name $item.DestinationPath
                    $parent = [IO.Path]::GetDirectoryName($item.DestinationPath)
                    $null = [IO.Directory]::CreateDirectory($parent)
                    $temporaryPath = [IO.Path]::Combine($parent, '.watermark-' + [Guid]::NewGuid().ToString('N') + '.tmp')
                    $dimensions = Invoke-WatermarkRender -Item $item -TemporaryPath $temporaryPath
                    if ($needsMetadata) { Invoke-WatermarkMetadata -TemporaryPath $temporaryPath }
                    Test-EncodedImage -Name $temporaryPath -Format $item.Format -Width $dimensions.Width -Height $dimensions.Height
                    if ([IO.File]::Exists($item.DestinationPath) -and $Force) {
                        $backup = $temporaryPath + '.bak'
                        # A real backup filename avoids PowerShell 5.1 binding
                        # null as an empty filename. Never delete-then-move.
                        [IO.File]::Replace($temporaryPath, $item.DestinationPath, $backup, $true)
                        try { [IO.File]::Delete($backup) }
                        catch { Write-Warning "Output saved, but its previous-version backup could not be removed: $backup" }
                    } else {
                        # File.Move refuses an existing destination, including
                        # one created by another process after the initial check.
                        [IO.File]::Move($temporaryPath, $item.DestinationPath)
                    }
                    $temporaryPath = $null
                    $status = 'Succeeded'
                    Write-Verbose "Saved $($item.DestinationPath) ($($dimensions.Width) x $($dimensions.Height))"
                } elseif ($WhatIfPreference) { $status = 'WhatIf' }
            } catch {
                $status = 'Failed'
                $errorMessage = $_.Exception.Message
                $PSCmdlet.WriteError([Management.Automation.ErrorRecord]::new($_.Exception, 'Watermark.ImageProcessingFailed',
                    [Management.Automation.ErrorCategory]::WriteError, $item.SourcePath))
            } finally {
                $timer.Stop()
                if ($temporaryPath -and [IO.File]::Exists($temporaryPath)) {
                    try { [IO.File]::Delete($temporaryPath) }
                    catch { Write-Warning "Could not remove temporary file: $temporaryPath" }
                }
            }
            if ($PassThru) {
                [pscustomobject]@{
                    PSTypeName = 'ImageWatermark.Result'
                    SourcePath = $item.SourcePath
                    DestinationPath = $item.DestinationPath
                    Status = $status
                    Format = $item.Format
                    Width = if ($dimensions) { $dimensions.Width } else { $null }
                    Height = if ($dimensions) { $dimensions.Height } else { $null }
                    FontSize = if ($dimensions) { $dimensions.FontSize } else { $null }
                    MetadataApplied = $status -eq 'Succeeded' -and $needsMetadata
                    Elapsed = $timer.Elapsed
                    ErrorMessage = $errorMessage
                }
            }
        }
    } finally { Write-Progress -Activity 'Adding image watermarks' -Completed }
}
