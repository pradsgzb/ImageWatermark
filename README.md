# Add-ImageWatermark

**Repeated text watermarks for image collections, with predictable PowerShell behavior.**

Create watermarked copies using diagonal tiling, named or custom color palettes, automatic font sizing, outlines, and an optional second layer. Process one image, a folder, wildcard matches, or pipeline input.

The utility is a standalone script for **Windows PowerShell 5.1 and PowerShell 7 on Windows**. ExifTool is optional and is needed only for metadata writing.

[Quick start](#quick-start) · [Examples](#examples) · [Parameters](#parameters) · [Output behavior](#output-behavior) · [Metadata](#metadata) · [Migration](#migration-from-wmps1) · [Validation](#validation-and-development)

## Features

- **PowerShell conventions:** `Path`, `LiteralPath`, `Destination`, `OutFile`, `Recurse`, `Force`, and `PassThru`, with standard `WhatIf`, `Confirm`, `Verbose`, and `ErrorAction` behavior.
- **Originals retained:** watermarked copies are written separately; selected source paths cannot be output targets, even with `Force`.
- **Predictable output names:** correct filename extensions for the chosen encoder, with recursive subfolder structure retained.
- **Controlled publication:** encode to a temporary file, apply optional metadata, reopen to verify format and dimensions, then publish the result.
- **Efficient tiling:** render text and outlines to a reusable bitmap once per image, then repeat that tile across the image.
- **Orientation handling:** apply EXIF orientation to image pixels before rendering.
- **Explicit animation handling:** reject animated/multipage inputs unless the first-frame conversion is requested.
- **Automation support:** typed result objects on request, per-file errors, and caller-controlled fail-fast behavior.
- **Repository checks:** Pester tests, synthetic image fixtures, PSScriptAnalyzer configuration, and Windows GitHub Actions jobs.

This is an independent utility designed around documented PowerShell conventions. It is not a Microsoft product, certification, or endorsement.

## Quick start

Save [Add-ImageWatermark.ps1](./Add-ImageWatermark.ps1), open PowerShell in its folder, and replace the example path and text with your own.

**Preview the proposed output:**

```powershell
.\Add-ImageWatermark.ps1 -LiteralPath 'D:\Art\painting.jpg' -Text 'Studio Example' -WhatIf
```

**Create the watermarked copy:**

```powershell
.\Add-ImageWatermark.ps1 -LiteralPath 'D:\Art\painting.jpg' -Text 'Studio Example'
```

Default output: `D:\Art\Watermarked\painting.jpg`.

**Process a folder and its subfolders:**

```powershell
.\Add-ImageWatermark.ps1 -Path 'D:\Art' -Text 'Studio Example' -Recurse -AutoFontSize -Verbose
```

Default opacity is **20 out of 255**, matching the previous script's subtle watermark. Use a higher value, such as `-Opacity 80`, for a more visible result.

## Requirements

- Windows with Windows PowerShell 5.1 or PowerShell 7. The script explicitly rejects other operating systems.
- An installed font family with a bold face. The default is Arial; a missing font produces a configuration error.
- Read access to the input and write access to the output location. Administrator access is not normally needed.
- Enough memory for decoded images and drawing buffers; large images can require substantially more memory than their compressed file size.
- Optional: ExifTool's Windows executable for `Metadata` or `MetadataProfile`.

No shared PowerShell helper, external image library, or PowerShell module is required for watermarking. The script uses `System.Drawing`, which Microsoft supports on Windows in current .NET. [Microsoft platform guidance](https://learn.microsoft.com/en-us/dotnet/core/compatibility/core-libraries/6.0/system-drawing-common-windows-only).

## Examples

### Choose a destination directory

```powershell
.\Add-ImageWatermark.ps1 -Path 'D:\Art' -Destination 'D:\Exports' -Text 'Preview' -Recurse
```

For directory input, paths remain relative to that directory:

| Input | Output |
| --- | --- |
| `D:\Art\painting.jpg` | `D:\Exports\painting.jpg` |
| `D:\Art\landscapes\lake.png` | `D:\Exports\landscapes\lake.png` |

`Destination` always means a **directory**. To choose an exact filename, use `OutFile`.

### Choose an exact filename and convert to PNG

```powershell
.\Add-ImageWatermark.ps1 -LiteralPath 'D:\Art\painting.jpg' -OutFile 'D:\Exports\painting-preview.png' -OutputFormat Png -Text 'Preview'
```

`OutFile` requires exactly one resolved file and cannot be combined with `Destination`, `Recurse`, or pipeline input. Its extension must agree with `OutputFormat` or the preserved format.

### Use one color with an outline

```powershell
.\Add-ImageWatermark.ps1 -Path 'D:\Art' -Text 'Studio Example' -ColorMode SingleColor -Color '#FFFFFF' -Opacity 100 -Outline -OutlineColor '#000000' -OutlineWidth 1.5 -AutoFontSize
```

`FontSize`, outline width, and spacing are measured in pixels. Watermark opacity does not alter the opacity of the source image.

### Use a custom palette and two layers

```powershell
$options = @{
    LiteralPath = 'D:\Art\painting.jpg'
    Text = 'Studio Example'
    ColorMode = 'Palette'
    ColorPalette = @('#2563EB', '#7C3AED', '#DB2777')
    Opacity = 70
    AutoFontSize = $true
    RotationAngle = -30
    SecondPass = $true
    SecondPassAngle = 30
    Outline = $true
}
.\Add-ImageWatermark.ps1 @options
```

`Dense` reduces spacing and enables a second pass. `LineCount` is an approximate density target; rotation, text size, spacing, and image shape determine the visible row count.

### Process wildcard or pipeline input

```powershell
# Wildcard-aware paths
.\Add-ImageWatermark.ps1 -Path 'D:\Art\*.jpg' -Text 'Preview'

# FileInfo objects bind through their FullName property
Get-ChildItem -LiteralPath 'D:\Art' -File -Filter '*.png' |
    .\Add-ImageWatermark.ps1 -Text 'Preview' -PassThru

# Filenames containing wildcard characters, such as brackets
.\Add-ImageWatermark.ps1 -LiteralPath 'D:\Art\painting[1].jpg' -Text 'Preview'
```

The script collects a finite input plan before writing outputs. Repeated references to the same source are processed once; the first occurrence determines its relative output path. For the most predictable directory layout, supply one directory root per invocation.

### Replace a previous output

```powershell
.\Add-ImageWatermark.ps1 -LiteralPath 'D:\Art\painting.jpg' -Text 'Updated preview' -Force -Confirm
```

Without `Force`, existing outputs produce errors. `Force` permits replacement of output files; it does not permit overwriting a selected source or bypass `WhatIf`/`Confirm`.

### Capture results or stop at the first error

```powershell
$results = .\Add-ImageWatermark.ps1 -Path 'D:\Art' -Text 'Preview' -Recurse -PassThru
$results | Select-Object SourcePath, DestinationPath, Status, ErrorMessage

# For a job that must stop when a file fails:
.\Add-ImageWatermark.ps1 -Path 'D:\Art' -Text 'Preview' -ErrorAction Stop
```

By default, image-processing errors use PowerShell's error stream and the next planned image is attempted. Input resolution/planning errors also use that stream. Invalid global configuration and conflicting output plans terminate the invocation. `PassThru` results cover planned image files; input-resolution errors have no result row. Handle both errors and results in automation.

## Parameters

### Input and output

| Parameter | Default | Meaning |
| --- | --- | --- |
| `Path <string[]>` | Required in its parameter set | Files/directories with wildcard support. Accepts pipeline strings. |
| `LiteralPath <string[]>` | Required in its parameter set | Exact files/directories. Aliases: `FullName`, `PSPath`. |
| `Text <string>` | Required | Nonblank, single-line text, up to 512 UTF-16 characters. Alias: `WatermarkText`. |
| `Destination <string>` | `Watermarked` beneath each directory input, or beside each explicit file | Output directory; created after approval if needed. |
| `OutFile <string>` | Unset | Exact output file for one explicit source. |
| `Recurse` | Off | Include input subfolders. |
| `OutputFormat <string>` | `Preserve` | `Preserve`, `Png`, `Jpeg`, `Bmp`, or `Tiff`. |
| `Force` | Off | Replace an existing output after successful rendering and verification. |
| `PassThru` | Off | Emit `ImageWatermark.Result` objects. |
| `FrameHandling <string>` | `Reject` | `Reject` or `First` for animated/multipage images. |
| `JpegQuality <int>` | `90` | JPEG quality, from 1 through 100. |
| `BackgroundColor <string>` | `White` | Opaque background used when flattening transparency for JPEG/BMP output. |
| `MaxPixelCount <long>` | `100000000` | Maximum source pixel count checked after the decoder opens it; configurable up to one billion. |

### Watermark appearance

| Parameter | Default | Meaning |
| --- | --- | --- |
| `Opacity <int>` | `20` | Alpha from 0 (transparent) through 255 (opaque). |
| `FontFamily <string>` | `Arial` | Installed font family; bold is used. |
| `FontSize <single>` | `32` | Font size in pixels, from 6 through 1000. |
| `AutoFontSize` | Off | Choose a size based on image width and target row density. Minimum 6 pixels. |
| `LineCount <int>` | `10` | Approximate row-density target, from 2 through 100. |
| `HorizontalSpacing <int>` | `160` | Gap between text runs, from 0 through 5000 pixels. |
| `VerticalSpacing <int>` | `40` | Additional row gap, from 0 through 5000 pixels. |
| `ColorMode <string>` | `Rainbow` | `Rainbow`, `SingleColor`, or `Palette`. |
| `Color <string>` | `#FF0000` | Color for `SingleColor` mode. |
| `Palette <string>` | `Cool` | Named palette for `Palette` mode. |
| `ColorPalette <string[]>` | Unset | Custom colors; requires `ColorMode Palette` and overrides its named palette. |
| `RotationAngle <single>` | `-30` | Primary angle in degrees, from -180 through 180. |
| `SecondPass` | Off | Enable a second watermark layer. |
| `SecondPassAngle <single>` | `30` | Secondary angle in degrees, from -180 through 180. |
| `Outline` | Off | Draw an antialiased path outline around glyphs. |
| `OutlineWidth <single>` | `1` | Outline width, from 0.1 through 20 pixels. |
| `OutlineColor <string>` | `#000000` | Outline color; alpha is 1.35 times `Opacity`, capped at 255. |
| `Dense` | Off | Reduce spacing and enable a second layer. |

Colors accept opaque HTML color names or `#RRGGBB` values. Set transparency with `Opacity`, not the color string.

Named palettes: `Rainbow`, `Brand`, `Warm`, `Cool`, `Grayscale`, `RedAlert`, `BlueMix`, and `GreenMix`.

### Metadata and PowerShell controls

| Parameter | Default | Meaning |
| --- | --- | --- |
| `MetadataProfile <string>` | `None` | `None` or the explicit synthetic `Pixel8Pro` profile. |
| `Metadata <hashtable>` | Empty | Supported text metadata tags and their values. |
| `ExifToolPath <string>` | Discover `exiftool.exe` on `PATH` when needed | Literal path to the Windows executable. |
| `ExifToolTimeoutSeconds <int>` | `60` | Per-invocation timeout, from 1 through 600 seconds. |
| `WhatIf` | Off | Show planned writes without creating output directories, images, metadata, or temporary image files. |
| `Confirm` | PowerShell default | Ask before each output operation. |
| `Verbose` | Off | Show diagnostic messages on the verbose stream. |
| `ErrorAction` | Caller preference | Standard PowerShell error control, including `Stop`. |

`WhatIf` validates paths and configuration, including font and optional ExifTool availability. It does not decode every image, render pixels, or invoke ExifTool, so it cannot prove that a subsequent real run will succeed.

## Output behavior

### Formats

| Input | Extensions | `Preserve` output |
| --- | --- | --- |
| JPEG | `.jpg`, `.jpeg` | JPEG, `.jpg` |
| PNG | `.png` | PNG, `.png` |
| BMP | `.bmp` | BMP, `.bmp` |
| GIF | `.gif` | PNG, `.png`; first-frame conversion requires consent via `FrameHandling First` when animated |
| TIFF | `.tif`, `.tiff` | TIFF, `.tif`; multipage input requires `FrameHandling First` |

An explicitly chosen `OutputFormat` converts any supported decoded input to that format. GIF output is not provided. WebP, HEIC, AVIF, SVG, and camera RAW are outside the supplied decoder workflow. Directory scans skip unsupported extensions; explicit unsupported files produce errors. Input content must agree with its extension.

JPEG is re-encoded and can introduce compression changes. PNG/TIFF output retains alpha where supported by the encoder; JPEG/BMP uses `BackgroundColor`. This is an 8-bit raster workflow, not an archival color-management or HDR pipeline. EXIF orientation is applied to pixels; original metadata is not copied, although encoders may write their own format headers and resolution information.

### Paths and existing files

- The destination belonging to a directory scan is excluded from that scan, including when it is inside the source tree. New outputs are not added midway through processing.
- Reparse points and junctions are skipped during traversal. Explicit input/output paths with existing reparse-point ancestors are rejected.
- A destination directory cannot equal or be an ancestor of its input directory.
- Two sources mapping to the same output path terminate planning before any image is written. For example, converting both `photo.jpg` and `photo.png` to `photo.png` requires separate output directories or renamed sources.
- Output files are not automatically numbered. Rerun with `Force` to replace prior outputs, or choose another destination.

### Publication and failure handling

Each approved output is encoded to a uniquely named temporary file in its destination directory. Requested metadata is applied there. The result is reopened and checked for expected format and dimensions before it receives its final name.

New outputs use `File.Move`, which refuses to overwrite an existing file, including one that appears after the initial check. Existing outputs with `Force` use `File.Replace` with a temporary backup. There is no delete-then-move fallback: if the filesystem cannot replace the file, the operation fails. Replacement guarantees depend on the underlying filesystem; prefer a local Windows filesystem for predictable behavior.

Temporary files are removed on handled failures where possible. Empty output directories may remain, and abrupt process termination can leave temporary files or backups. The batch is not one transaction, and it has no resume manifest: previously completed files remain completed if a later file fails. On repeat runs, existing outputs are errors unless `Force` is supplied.

### Result objects

With `PassThru`, each planned file can produce:

| Field | Meaning |
| --- | --- |
| `SourcePath`, `DestinationPath` | Fully resolved source and planned output paths. |
| `Status` | `Succeeded`, `Failed`, `Skipped` after declined confirmation, or `WhatIf`. |
| `Format` | Selected output encoder. |
| `Width`, `Height` | Orientation-normalized rendered dimensions, when rendering completed. |
| `FontSize` | Actual pixel font size used, when available. |
| `MetadataApplied` | True only after metadata processing and final publication succeed. |
| `Elapsed` | Per-file elapsed `TimeSpan`. |
| `ErrorMessage` | Error message for a failed planned file. |

Without `PassThru`, the success stream is empty. Errors, warnings, verbose diagnostics, progress, and confirmation remain on their normal PowerShell channels. With `ErrorAction Stop`, a terminating error may prevent the failed file's result object from being emitted.

## Metadata

Metadata writing is optional. Install ExifTool separately and make `exiftool.exe` available on `PATH`, or supply its literal path. JPEG, PNG, and TIFF output can be used with metadata; BMP output is rejected when metadata options are active.

### Add attribution

```powershell
$tags = @{
    'EXIF:Artist' = 'Studio Example'
    'EXIF:Copyright' = 'Copyright 2026 Studio Example. All rights reserved.'
    'XMP-dc:Rights' = 'Contact Studio Example for licensing.'
    'XMP-dc:Description' = 'Watermarked preview of the original artwork.'
}
.\Add-ImageWatermark.ps1 -LiteralPath 'D:\Art\painting.jpg' -Text 'Studio Example' -Metadata $tags
```

Supported text tags:

| EXIF | XMP |
| --- | --- |
| `EXIF:Artist` | `XMP-dc:Identifier` |
| `EXIF:Copyright` | `XMP-dc:Creator` |
| `EXIF:ImageDescription` | `XMP-dc:Rights` |
| `EXIF:Make`, `EXIF:Model` | `XMP-dc:Description` |
| `EXIF:LensMake`, `EXIF:LensModel` | |
| `EXIF:Software` | |

Values must be nonblank, single-line strings of at most 4096 characters. Arbitrary ExifTool options and filesystem tags are not accepted through `Metadata`.

ExifTool is invoked without a shell. Arguments are passed as UTF-8 lines through standard input, ambient ExifTool configuration is disabled, and output/error streams are drained. A nonzero exit code, timeout, or failed text-tag verification prevents the temporary file from being published. Each requested text tag is read back and compared; numeric values from the camera profile rely on ExifTool's write status rather than individual numerical comparisons. On Windows PowerShell 5.1, timeout cleanup terminates the launched process; PowerShell 7 also requests termination of its child processes.

### Optional Pixel 8 Pro profile

```powershell
.\Add-ImageWatermark.ps1 -LiteralPath 'D:\Art\painting.jpg' -Text 'Studio Example' -MetadataProfile Pixel8Pro -Metadata $tags
```

This deliberately writes a **synthetic camera profile**, carried forward from the supplied helper. It does not detect the camera or establish how the image was captured.

The profile sets Google / Pixel 8 Pro camera and lens tags, a 1/15-second exposure, f/1.68, ISO 400, 6.9 mm focal length, a 24 mm equivalent, and related exposure/scene flags. `Software` identifies this utility, and a GUID supplies `XMP-dc:Identifier` unless you set one. No personal copyright attribution is added automatically. Your `Metadata` text values override matching profile text tags.

## Migration from wm.ps1

This release changes defaults and output handling intentionally. Use named parameters in existing automation and review the following mapping.

| Previous parameter or behavior | Current equivalent |
| --- | --- |
| `wm.ps1` | `Add-ImageWatermark.ps1` |
| Default personal email watermark | Supply required `Text`; no default identity. |
| `WatermarkText` | `Text`; old name remains an alias. |
| Positional argument 1 was `Destination` | Positional argument 1 is now `Text`; use named parameters. |
| `Destination` as a single filename | `OutFile` for an exact filename; `Destination` now always means a directory. |
| Folder mode ignored `Destination` | Folder mode now honors `Destination`. |
| `TargetLineCount` | `LineCount`; old name remains an alias. |
| `HorizontalPadding`, `VerticalPadding` | `HorizontalSpacing`, `VerticalSpacing`; aliases retained. |
| `SingleColor` | `Color`; alias retained. |
| `PaletteName`, `CustomColors` | `Palette`, `ColorPalette`; aliases retained. |
| `Rotation`, `SecondPassRotation` | `RotationAngle`, `SecondPassAngle`; aliases retained. |
| `AddSecondPass`, `AddOutline`, `DenseProtection` | `SecondPass`, `Outline`, `Dense`; aliases retained. |
| `FontSize` in the previous font constructor's point units | `FontSize` is explicitly in pixels. Adjust values to match an old visual result. |
| `Opacity` from 0 through 255 | Same alpha scale, same default of 20. |
| `ShowConsoleLog` | Use standard `Verbose`. |
| `NoLogo` | Removed; the utility prints no banner. |
| `PixelPro` | `MetadataProfile Pixel8Pro`; supply personal attribution through `Metadata`. |
| Camera profile claimed an Adobe Photoshop version | The profile's software tag now identifies this utility. |
| `__filename` and automatic `(1)` collision suffixes | Separate `Watermarked` directory and explicit overwrite control with `Force`. |
| Silent first-frame output | Animated/multipage input requires `FrameHandling First`. |
| `ImageProcessing.Common.ps1` dependency | Integrated; the helper is not required. |

The existing `AutoFontSize`, `FontFamily`, `ColorMode`, `OutlineWidth`, and `OutlineColor` names remain available. Full-text rendering in `SingleColor` mode best preserves shaping. Per-element coloring keeps surrogate pairs and combining sequences together, but complex-script shaping, ligatures, and bidirectional text are not guaranteed in multicolor modes.

## Validation and development

**Validation status for this package:** the PowerShell source was reviewed and parsed with a third-party PowerShell grammar in the authoring environment. PowerShell, Windows `System.Drawing`, Pester, PSScriptAnalyzer, and ExifTool integration were not executable there. The Windows tests and CI workflow are supplied for execution; this README does not claim they have passed.

The test suite creates synthetic images under Pester's `TestDrive`. Included fixtures cover EXIF orientation 6 and an animated GIF. Tests cover command metadata, paths and pipelines, source preservation, actual pixel changes, preview behavior, recursive output exclusion, conflicts, encoding, transparency, frame handling, failure recovery, and metadata-input validation. ExifTool-dependent tests run only when its executable is available; the default CI jobs do not install it.

Install development dependencies and run the checks from the repository root:

```powershell
Install-Module Pester -RequiredVersion 5.7.1 -Scope CurrentUser
Install-Module PSScriptAnalyzer -RequiredVersion 1.24.0 -Scope CurrentUser

Import-Module Pester -RequiredVersion 5.7.1
Import-Module PSScriptAnalyzer -RequiredVersion 1.24.0

Invoke-ScriptAnalyzer -Path .\Add-ImageWatermark.ps1 -Settings .\PSScriptAnalyzerSettings.psd1
Invoke-Pester -Path .\tests -Output Detailed
```

These are explicit development dependency versions, not claims about the latest available releases. [Pester package](https://www.powershellgallery.com/packages/Pester/5.7.1), [PSScriptAnalyzer package](https://www.powershellgallery.com/packages/PSScriptAnalyzer/1.24.0).

The analyzer uses default warning/error rules with one documented exclusion: `PSUseShouldProcessForStateChangingFunctions`, because private `New-*` helpers create in-memory plans and drawing resources. The public script uses `SupportsShouldProcess`, and its no-write preview behavior is covered by filesystem tests. Run and review the actual analyzer output before publishing a release.

The [GitHub Actions workflow](./.github/workflows/validate.yml) runs checks on Windows using both `powershell` and `pwsh`. It requests read-only repository permissions and fails on analyzer findings or failed tests. Copy all package files into the repository root, including the `.github` directory, to enable it.

### Microsoft guidance used

- [Standard parameter names and types](https://learn.microsoft.com/en-us/powershell/scripting/developer/cmdlet/standard-cmdlet-parameter-names-and-types)
- [Path and LiteralPath semantics](https://learn.microsoft.com/en-us/powershell/scripting/developer/cmdlet/resource-parameters)
- [ShouldProcess, WhatIf, and Confirm](https://learn.microsoft.com/en-us/powershell/scripting/learn/deep-dives/everything-about-shouldprocess)
- [PSScriptAnalyzer](https://learn.microsoft.com/en-us/powershell/utility-modules/psscriptanalyzer/overview)

## Troubleshooting

| Problem | Action |
| --- | --- |
| Execution is blocked | Review the downloaded script and follow your machine's execution policy. The utility does not change execution policy. |
| Watermark is too faint | Increase `Opacity`; 20/255 is deliberately subtle. |
| Text is too large for a small image | Use shorter text, lower `FontSize`, or `AutoFontSize`. Automatic sizing has a 6-pixel minimum. |
| Font error | Choose an installed family with a bold face. |
| Output already exists | Use another destination or explicitly add `Force`. |
| Multiple sources map to one output | Separate input roots into different invocations/destinations or rename colliding source files. |
| Literal brackets are interpreted as a pattern | Use `LiteralPath`. |
| Unsupported/misnamed image | Check that the actual format matches its extension and is supported by Windows GDI+. |
| Animation/multipage error | Keep the original, and choose `FrameHandling First` only when one frame/page is the intended output. |
| ExifTool is missing | Provide the full `.exe` path through `ExifToolPath`, or run without metadata options. |
| Metadata verification failed | Review the tag and ExifTool warning. The previous final output is retained if replacement has not occurred. |
| `File.Replace` fails | Check file permissions, locks, and filesystem support. Use a fresh destination filename rather than expecting a delete-and-overwrite fallback. |
| Temporary file remains | Confirm no utility or ExifTool process is using it, then inspect/remove the indicated `.watermark-*` file. |

The utility does not provide image authenticity verification, metadata provenance verification, or irreversible watermark protection. Watermarks can be altered or removed. `MaxPixelCount` is checked after opening an image and is not a sandbox or a hard memory cap.

## Contributing and licensing

Include the command, PowerShell version, relevant error text, and a minimal synthetic image when reporting a defect. Remove personal image data and private paths from public reports. Run the Windows checks when changing path mapping, drawing, formats, metadata, or output publication.

No redistribution license has been selected for this package. Before offering it as an open-source project, the repository owner should add the intended `LICENSE` file. No license or copyright ownership is assumed on the owner's behalf.
