#requires -Version 5.1
# Run using Pester 5.7.1 on Windows. All images and outputs stay in TestDrive.
BeforeAll {
    $utility = Join-Path (Split-Path $PSScriptRoot -Parent) 'Add-ImageWatermark.ps1'
}

Describe 'PowerShell command contract' {
    It 'parses with the actual PowerShell parser' {
        $tokens = $null
        $parseErrors = $null
        $null = [Management.Automation.Language.Parser]::ParseFile($utility, [ref]$tokens, [ref]$parseErrors)
        @($parseErrors).Count | Should -Be 0
    }

    It 'exposes standard safety parameters and literal-path input' {
        $command = Get-Command $utility
        foreach ($name in @('Path', 'LiteralPath', 'Text', 'Destination', 'OutFile', 'Recurse', 'Force', 'PassThru', 'WhatIf', 'Confirm', 'Verbose', 'ErrorAction')) {
            $command.Parameters.ContainsKey($name) | Should -BeTrue
        }
        $command.Parameters['Text'].Aliases | Should -Contain 'WatermarkText'
        $command.Parameters['LiteralPath'].Aliases | Should -Contain 'FullName'
    }
}

Describe 'Windows image and filesystem behavior' -Skip:([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
    BeforeAll {
        Add-Type -AssemblyName System.Drawing
        function New-FixtureImage {
            param ([string]$Name, [string]$Format = 'Png', [int]$Width = 240, [int]$Height = 160, [switch]$Transparent)
            $parent = [IO.Path]::GetDirectoryName($Name)
            $null = [IO.Directory]::CreateDirectory($parent)
            $bitmap = [Drawing.Bitmap]::new($Width, $Height, [Drawing.Imaging.PixelFormat]::Format32bppArgb)
            $graphics = [Drawing.Graphics]::FromImage($bitmap)
            try {
                if ($Transparent) { $graphics.Clear([Drawing.Color]::Transparent) }
                else { $graphics.Clear([Drawing.Color]::White) }
                $graphics.FillRectangle([Drawing.Brushes]::Blue, 0, 0, [int]($Width / 3), [int]($Height / 3))
                $formats = @{ Png = [Drawing.Imaging.ImageFormat]::Png; Jpeg = [Drawing.Imaging.ImageFormat]::Jpeg; Bmp = [Drawing.Imaging.ImageFormat]::Bmp; Gif = [Drawing.Imaging.ImageFormat]::Gif; Tiff = [Drawing.Imaging.ImageFormat]::Tiff }
                $bitmap.Save($Name, $formats[$Format])
            } finally { $graphics.Dispose(); $bitmap.Dispose() }
        }
        function Get-FixtureInfo {
            param ([string]$Name)
            $image = [Drawing.Bitmap]::new($Name)
            try { [pscustomobject]@{ Width = $image.Width; Height = $image.Height; Format = $image.RawFormat.Guid; CornerAlpha = $image.GetPixel($image.Width - 1, $image.Height - 1).A } }
            finally { $image.Dispose() }
        }
    }
    BeforeEach {
        $caseRoot = Join-Path $TestDrive ([Guid]::NewGuid().ToString('N'))
        $null = [IO.Directory]::CreateDirectory($caseRoot)
        $source = Join-Path $caseRoot 'source.png'
        New-FixtureImage -Name $source
        $expected = Join-Path $caseRoot 'Watermarked\source.png'
    }

    It 'writes pixels while preserving source bytes and dimensions' {
        $before = (Get-FileHash -LiteralPath $source).Hash
        $result = & $utility -LiteralPath $source -Text 'TEST' -Opacity 255 -FontSize 18 -ColorMode SingleColor -PassThru -ErrorAction Stop
        $result.Status | Should -Be 'Succeeded'
        $result.Width | Should -Be 240
        $result.Height | Should -Be 160
        (Get-FileHash -LiteralPath $source).Hash | Should -Be $before
        (Get-FileHash -LiteralPath $expected).Hash | Should -Not -Be $before
        $output = [Drawing.Bitmap]::new($expected)
        $original = [Drawing.Bitmap]::new($source)
        try {
            $changed = 0
            for ($y = 0; $y -lt 160; $y += 4) {
                for ($x = 0; $x -lt 240; $x += 4) {
                    if ($output.GetPixel($x, $y).ToArgb() -ne $original.GetPixel($x, $y).ToArgb()) { $changed++ }
                }
            }
            $changed | Should -BeGreaterThan 0
        } finally { $output.Dispose(); $original.Dispose() }
    }

    It 'creates no files or folders in WhatIf, even with Force' {
        $destination = Join-Path $caseRoot 'preview\nested'
        $result = & $utility -LiteralPath $source -Destination $destination -Text 'TEST' -WhatIf -Force -PassThru -ErrorAction Stop
        $result.Status | Should -Be 'WhatIf'
        Test-Path -LiteralPath (Join-Path $caseRoot 'preview') | Should -BeFalse
        @(Get-ChildItem -LiteralPath $caseRoot -Recurse -File).Count | Should -Be 1
    }

    It 'accepts literal brackets and Unicode watermark text' {
        $bracket = Join-Path $caseRoot 'painting[1].png'
        Move-Item -LiteralPath $source -Destination $bracket
        $textValue = 'Studio ' + [char]0x00A9 + ' ' + [char]0x00E9
        $result = & $utility -LiteralPath $bracket -Text $textValue -Outline -PassThru -ErrorAction Stop
        $result.Status | Should -Be 'Succeeded'
        Test-Path -LiteralPath (Join-Path $caseRoot 'Watermarked\painting[1].png') | Should -BeTrue
    }

    It 'processes a wildcard and the one-file directory case' {
        $result = @(& $utility -Path (Join-Path $caseRoot '*.png') -Text 'TEST' -PassThru -ErrorAction Stop)
        $result.Count | Should -Be 1
        $result[0].Status | Should -Be 'Succeeded'
        $secondDestination = Join-Path $caseRoot 'second'
        $result = @(& $utility -LiteralPath $caseRoot -Destination $secondDestination -Text 'TEST' -PassThru -ErrorAction Stop)
        $result.Count | Should -Be 1
    }

    It 'binds FileInfo objects and deduplicates overlapping file input' {
        $files = @((Get-Item -LiteralPath $source), (Get-Item -LiteralPath $source))
        $result = @($files | & $utility -Text 'TEST' -PassThru -ErrorAction Stop)
        $result.Count | Should -Be 1
        $result[0].SourcePath | Should -Be $source
    }

    It 'accepts multiple pipeline strings' {
        $other = Join-Path $caseRoot 'other.png'
        New-FixtureImage -Name $other
        $result = @(@($source, $other) | & $utility -Text 'TEST' -PassThru -ErrorAction Stop)
        $result.Count | Should -Be 2
        @($result | Where-Object Status -eq Succeeded).Count | Should -Be 2
    }

    It 'preserves nested paths and excludes its destination on repeat scans' {
        New-FixtureImage -Name (Join-Path $caseRoot 'album\nested.png')
        $first = @(& $utility -LiteralPath $caseRoot -Text 'TEST' -Recurse -PassThru -ErrorAction Stop)
        $first.Count | Should -Be 2
        Test-Path -LiteralPath (Join-Path $caseRoot 'Watermarked\album\nested.png') | Should -BeTrue
        $second = @(& $utility -LiteralPath $caseRoot -Text 'TEST' -Recurse -Force -PassThru -ErrorAction Stop)
        $second.Count | Should -Be 2
        Test-Path -LiteralPath (Join-Path $caseRoot 'Watermarked\Watermarked') | Should -BeFalse
    }

    It 'refuses existing output without Force and leaves its bytes intact' {
        $null = & $utility -LiteralPath $source -Text 'FIRST' -ErrorAction Stop
        $before = (Get-FileHash -LiteralPath $expected).Hash
        $records = @()
        $result = & $utility -LiteralPath $source -Text 'SECOND' -PassThru -ErrorAction SilentlyContinue -ErrorVariable +records
        $result.Status | Should -Be 'Failed'
        $records.Count | Should -BeGreaterThan 0
        (Get-FileHash -LiteralPath $expected).Hash | Should -Be $before
    }

    It 'replaces a valid output with Force and removes temporary files' {
        $null = & $utility -LiteralPath $source -Text 'FIRST' -Opacity 255 -ErrorAction Stop
        $before = (Get-FileHash -LiteralPath $expected).Hash
        $result = & $utility -LiteralPath $source -Text 'SECOND' -Opacity 255 -Force -PassThru -ErrorAction Stop
        $result.Status | Should -Be 'Succeeded'
        (Get-FileHash -LiteralPath $expected).Hash | Should -Not -Be $before
        @(Get-ChildItem -LiteralPath (Split-Path $expected) -Force -Filter '.watermark-*').Count | Should -Be 0
    }

    It 'preserves an existing output if rendering fails during Force' {
        $null = & $utility -LiteralPath $source -Text 'FIRST' -ErrorAction Stop
        $before = (Get-FileHash -LiteralPath $expected).Hash
        [IO.File]::WriteAllText($source, 'not an image')
        { & $utility -LiteralPath $source -Text 'SECOND' -Force -ErrorAction Stop } | Should -Throw
        (Get-FileHash -LiteralPath $expected).Hash | Should -Be $before
    }

    It 'continues to a valid file after a corrupt file by default' {
        $broken = Join-Path $caseRoot 'broken.png'
        [IO.File]::WriteAllText($broken, 'invalid')
        $result = @(& $utility -LiteralPath @($broken, $source) -Text 'TEST' -PassThru -ErrorAction SilentlyContinue)
        $result.Count | Should -Be 2
        $result[0].Status | Should -Be 'Failed'
        $result[1].Status | Should -Be 'Succeeded'
    }

    It 'stops on a corrupt first file with ErrorAction Stop' {
        $broken = Join-Path $caseRoot 'broken.png'
        [IO.File]::WriteAllText($broken, 'invalid')
        { & $utility -LiteralPath @($broken, $source) -Text 'TEST' -ErrorAction Stop } | Should -Throw
        Test-Path -LiteralPath $expected | Should -BeFalse
    }

    It 'never overwrites a selected source even with Force' {
        $before = (Get-FileHash -LiteralPath $source).Hash
        { & $utility -LiteralPath $source -OutFile $source -Text 'TEST' -Force -ErrorAction Stop } | Should -Throw
        (Get-FileHash -LiteralPath $source).Hash | Should -Be $before
    }

    It 'fails destination collisions before writing any output' {
        $jpeg = Join-Path $caseRoot 'source.jpg'
        New-FixtureImage -Name $jpeg -Format Jpeg
        { & $utility -LiteralPath @($source, $jpeg) -Text 'TEST' -OutputFormat Png -Force -ErrorAction Stop } | Should -Throw
        Test-Path -LiteralPath (Join-Path $caseRoot 'Watermarked') | Should -BeFalse
    }

    It 'uses the requested encoder and a matching filename' {
        $out = Join-Path $caseRoot 'export\final.jpg'
        $result = & $utility -LiteralPath $source -OutFile $out -Text 'TEST' -OutputFormat Jpeg -JpegQuality 95 -PassThru -ErrorAction Stop
        $result.Format | Should -Be 'Jpeg'
        (Get-FixtureInfo $out).Format | Should -Be ([Drawing.Imaging.ImageFormat]::Jpeg.Guid)
    }

    It 'rejects a misleading output extension before writing' {
        $out = Join-Path $caseRoot 'export\final.jpg'
        { & $utility -LiteralPath $source -OutFile $out -Text 'TEST' -ErrorAction Stop } | Should -Throw
        Test-Path -LiteralPath (Join-Path $caseRoot 'export') | Should -BeFalse
    }

    It 'rejects source content that does not match its extension' {
        $misnamed = Join-Path $caseRoot 'fake.jpg'
        Copy-Item -LiteralPath $source -Destination $misnamed
        { & $utility -LiteralPath $misnamed -Text 'TEST' -ErrorAction Stop } | Should -Throw
        Test-Path -LiteralPath (Join-Path $caseRoot 'Watermarked\fake.jpg') | Should -BeFalse
    }

    It 'retains PNG transparency when the watermark is transparent' {
        New-FixtureImage -Name $source -Transparent
        $null = & $utility -LiteralPath $source -Text 'TEST' -Opacity 0 -ErrorAction Stop
        (Get-FixtureInfo $expected).CornerAlpha | Should -Be 0
    }

    It 'converts a static GIF to PNG' {
        $gif = Join-Path $caseRoot 'still.gif'
        New-FixtureImage -Name $gif -Format Gif
        $result = & $utility -LiteralPath $gif -Text 'TEST' -PassThru -ErrorAction Stop
        $result.Format | Should -Be 'Png'
        (Get-FixtureInfo $result.DestinationPath).Format | Should -Be ([Drawing.Imaging.ImageFormat]::Png.Guid)
    }

    It 'handles BMP, TIFF, dense tiling, and custom palettes' {
        foreach ($format in @('Bmp', 'Tiff')) {
            $name = Join-Path $caseRoot ('example.' + $format.ToLowerInvariant())
            if ($format -eq 'Tiff') { $name = [IO.Path]::ChangeExtension($name, '.tif') }
            New-FixtureImage -Name $name -Format $format
            $result = & $utility -LiteralPath $name -Text 'TEST' -ColorMode Palette -ColorPalette '#123456','#FEDCBA' -AutoFontSize -Outline -Dense -PassThru -ErrorAction Stop
            $result.Status | Should -Be 'Succeeded'
            $result.Format | Should -Be $format
        }
    }

    It 'rejects a pixel count beyond the configured limit without a final output' {
        { & $utility -LiteralPath $source -Text 'TEST' -MaxPixelCount 10 -ErrorAction Stop } | Should -Throw
        Test-Path -LiteralPath $expected | Should -BeFalse
    }

    It 'applies EXIF rotation and writes normalized dimensions' {
        $fixture = Join-Path $PSScriptRoot 'fixtures\orientation-6.jpg'
        $out = Join-Path $caseRoot 'rotated.png'
        $result = & $utility -LiteralPath $fixture -Text 'TEST' -Opacity 0 -OutputFormat Png -OutFile $out -PassThru -ErrorAction Stop
        $result.Width | Should -Be 64
        $result.Height | Should -Be 96
        $image = [Drawing.Bitmap]::new($out)
        try {
            # Blue starts at top left; orientation 6 rotates it to top right.
            $pixel = $image.GetPixel(54, 10)
            $pixel.B | Should -BeGreaterThan 150
            $pixel.R | Should -BeLessThan 80
        } finally { $image.Dispose() }
    }

    It 'rejects animation by default and flattens only when requested' {
        $fixture = Join-Path $PSScriptRoot 'fixtures\animated.gif'
        $out = Join-Path $caseRoot 'first-frame.png'
        { & $utility -LiteralPath $fixture -Text 'TEST' -OutFile $out -ErrorAction Stop } | Should -Throw
        Test-Path -LiteralPath $out | Should -BeFalse
        $warnings = @()
        $result = & $utility -LiteralPath $fixture -Text 'TEST' -OutFile $out -FrameHandling First -PassThru -WarningVariable +warnings -WarningAction SilentlyContinue -ErrorAction Stop
        $result.Status | Should -Be 'Succeeded'
        $warnings.Count | Should -BeGreaterThan 0
        (Get-FixtureInfo $out).Format | Should -Be ([Drawing.Imaging.ImageFormat]::Png.Guid)
    }

    It 'rejects invalid color and text before creating an output folder' {
        { & $utility -LiteralPath $source -Text 'TEST' -ColorMode SingleColor -Color 'not-a-color' -ErrorAction Stop } | Should -Throw
        { & $utility -LiteralPath $source -Text "line1`nline2" -ErrorAction Stop } | Should -Throw
        Test-Path -LiteralPath (Join-Path $caseRoot 'Watermarked') | Should -BeFalse
    }

    It 'rejects an invalid metadata tag and a missing ExifTool dependency' {
        { & $utility -LiteralPath $source -Text 'TEST' -Metadata @{ 'System:FileName' = 'bad' } -ErrorAction Stop } | Should -Throw
        { & $utility -LiteralPath $source -Text 'TEST' -MetadataProfile Pixel8Pro -ExifToolPath (Join-Path $caseRoot 'missing.exe') -ErrorAction Stop } | Should -Throw
        Test-Path -LiteralPath (Join-Path $caseRoot 'Watermarked') | Should -BeFalse
    }

    It 'returns no success-stream data unless PassThru is requested' {
        $result = @(& $utility -LiteralPath $source -Text 'TEST' -ErrorAction Stop)
        $result.Count | Should -Be 0
    }

    Context 'ExifTool integration' -Skip:(-not [bool](Get-Command exiftool.exe -CommandType Application -ErrorAction SilentlyContinue)) {
        It 'writes and verifies requested attribution on PNG and JPEG outputs' {
            foreach ($format in @('Png', 'Jpeg')) {
                $out = Join-Path $caseRoot ('metadata-' + $format + $(if ($format -eq 'Png') { '.png' } else { '.jpg' }))
                $artist = 'Studio ' + [char]0x00E9
                $tags = @{ 'EXIF:Artist' = $artist; 'XMP-dc:Rights' = 'Test fixture'; 'XMP-dc:Creator' = 'Unit Test' }
                $result = & $utility -LiteralPath $source -Text 'TEST' -OutputFormat $format -OutFile $out -Metadata $tags -PassThru -ErrorAction Stop
                $result.Status | Should -Be 'Succeeded'
                $result.MetadataApplied | Should -BeTrue
                $data = @((& exiftool.exe '-j' '-G0' '-EXIF:Artist' $out) | ConvertFrom-Json)
                $LASTEXITCODE | Should -Be 0
                $data[0].'EXIF:Artist' | Should -Be $artist
            }
        }

        It 'writes the optional camera profile while honoring custom attribution' {
            $out = Join-Path $caseRoot 'profile.jpg'
            $result = & $utility -LiteralPath $source -Text 'TEST' -OutputFormat Jpeg -OutFile $out -MetadataProfile Pixel8Pro `
                -Metadata @{ 'EXIF:Copyright' = 'Unit test rights'; 'XMP-dc:Identifier' = 'fixture-id' } -PassThru -ErrorAction Stop
            $result.MetadataApplied | Should -BeTrue
            $data = @((& exiftool.exe '-j' '-G0' '-EXIF:Make' '-EXIF:Model' '-EXIF:Copyright' '-XMP-dc:Identifier' $out) | ConvertFrom-Json)
            $LASTEXITCODE | Should -Be 0
            $data[0].'EXIF:Make' | Should -Be 'Google'
            $data[0].'EXIF:Model' | Should -Be 'Pixel 8 Pro'
            $data[0].'EXIF:Copyright' | Should -Be 'Unit test rights'
            $data[0].'XMP:Identifier' | Should -Be 'fixture-id'
        }
    }
}
