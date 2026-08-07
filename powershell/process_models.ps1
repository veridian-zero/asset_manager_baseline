param (
    [Alias("ModelsDir")]
    [string]$SearchDir = ".\Gladiator_Real_Data",
    [string]$SisoApiUrl = "http://localhost:8000",
    [string]$IdPrefix = "DSC_GLA_",
    [double]$MinConfidence = 75.0,
    [int]$ThrottleLimit = 6,
    [switch]$SkipThumbnails,
    [switch]$RegenerateThumbnails,
    [ValidateSet("DEBUG", "INFO", "WARN", "ERROR", "SUCCESS")]
    [string]$LogLevel = "INFO"
)

$Stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

$script:LogLevels = @{
    "DEBUG"   = 0
    "INFO"    = 1
    "SUCCESS" = 1
    "WARN"    = 2
    "ERROR"   = 3
}

function Write-Log {
    param (
        [string]$Message,
        [string]$Level = "INFO"
    )
    if ($script:LogLevels[$Level] -lt $script:LogLevels[$LogLevel]) { return }

    $TimeStamp = Get-Date -Format "HH:mm:ss"
    switch ($Level) {
        "SUCCESS" { Write-Host "[$TimeStamp] [SUCCESS] $Message" -ForegroundColor Green }
        "WARN"    { Write-Host "[$TimeStamp] [WARN]    $Message" -ForegroundColor Yellow }
        "ERROR"   { Write-Host "[$TimeStamp] [ERROR]   $Message" -ForegroundColor Red }
        "DEBUG"   { Write-Host "[$TimeStamp] [DEBUG]   $Message" -ForegroundColor DarkGray }
        Default   { Write-Host "[$TimeStamp] [INFO]    $Message" -ForegroundColor Cyan }
    }
}

function Get-RelativePathCompat {
    param (
        [string]$BasePath,
        [string]$TargetPath
    )
    $baseFull = [System.IO.Path]::GetFullPath($BasePath).TrimEnd('\') + "\"
    $targetFull = [System.IO.Path]::GetFullPath($TargetPath)

    if ($targetFull.StartsWith($baseFull, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $targetFull.Substring($baseFull.Length) -replace '\\', '/'
    }

    $baseUri = New-Object System.Uri($baseFull)
    $targetUri = New-Object System.Uri($targetFull)
    $relativeUri = $baseUri.MakeRelativeUri($targetUri)
    return [System.Uri]::UnescapeDataString($relativeUri.ToString()) -replace '\\', '/'
}

$GetRelativePathStr = (Get-Command Get-RelativePathCompat).ScriptBlock.ToString()

Write-Log "==========================================================" "INFO"
Write-Log " Starting DMSC Sidecar Inspector & Model Processor" "INFO"
Write-Log " Input Directory: $SearchDir" "INFO"
Write-Log " Parallel Workers: $ThrottleLimit" "INFO"
Write-Log " Log Level: $LogLevel" "INFO"
Write-Log "==========================================================" "INFO"

$WorkDir = (Get-Location).ProviderPath
$SearchDirFull = (Get-Item $SearchDir).FullName.TrimEnd('\')

$TempExtractDir = Join-Path $SearchDirFull ".zip_staging"
if (Test-Path $TempExtractDir) { Remove-Item $TempExtractDir -Recurse -Force }
New-Item -ItemType Directory -Path $TempExtractDir | Out-Null

Write-Log "Searching and extracting ZIP files in $SearchDirFull..." "INFO"

Get-ChildItem -Path $SearchDirFull -Recurse -Filter "*.zip" | ForEach-Object {
    $zipPath = $_.FullName
    $relZipDir = $zipPath.Substring($SearchDirFull.Length).TrimStart('\', '/')
    $targetDir = Join-Path $TempExtractDir $relZipDir
    $targetDir = $targetDir.Substring(0, $targetDir.LastIndexOf('.'))
    Expand-Archive -Path $zipPath -DestinationPath $targetDir -Force
}

$rawFltItems = @()
$rawFltItems += Get-ChildItem -Path $SearchDirFull -Recurse -Filter "*.flt" | Where-Object { $_.FullName -notlike "$TempExtractDir*" }
$rawFltItems += Get-ChildItem -Path $TempExtractDir -Recurse -Filter "*.flt"

$totalCount = $rawFltItems.Count
Write-Log "Found $totalCount OpenFlight (.flt) file(s) to process." "SUCCESS"

$workItems = [System.Collections.Generic.List[PSCustomObject]]::new()
for ($i = 0; $i -lt $totalCount; $i++) {
    $flt = $rawFltItems[$i]
    $idx = $i + 1
    $assetId = "{0}{1:D3}" -f $IdPrefix, $idx
    
    $workItems.Add([PSCustomObject]@{
        Index    = $idx
        AssetId  = $assetId
        FltItem  = $flt
    })
}

$workItems | ForEach-Object -Parallel {
    Set-Item -Path "function:Get-RelativePathCompat" -Value ([scriptblock]::Create($using:GetRelativePathStr))

    $LogLevel = $using:LogLevel
    $LogLevels = @{ "DEBUG"=0; "INFO"=1; "SUCCESS"=1; "WARN"=2; "ERROR"=3 }
    $totalCount = $using:totalCount

    function Write-ThreadLog {
        param([string]$msg, [string]$lvl = "INFO")
        if ($LogLevels[$lvl] -lt $LogLevels[$LogLevel]) { return }
        $ts = Get-Date -Format "HH:mm:ss"
        Write-Host "[$ts] [$lvl] $msg"
    }

    function Invoke-RestMethodWithRetry {
        param (
            [string]$Url,
            [int]$MaxRetries = 2
        )
        $attempt = 0
        while ($attempt -lt $MaxRetries) {
            try {
                return (Invoke-RestMethod -Uri $Url -Method Get -TimeoutSec 3 -ErrorAction Stop)
            } catch {
                $attempt++
                if ($attempt -ge $MaxRetries) { return $null }
                Start-Sleep -Milliseconds 250
            }
        }
        return $null
    }

    $item = $_
    $flt = $item.FltItem
    $currIndex = $item.Index
    $currentAssetId = $item.AssetId

    $WorkDir = $using:WorkDir
    $SearchDir = $using:SearchDir
    $SearchDirFull = $using:SearchDirFull
    $TempExtractDir = $using:TempExtractDir
    $MinConfidence = $using:MinConfidence
    $SisoApiUrl = $using:SisoApiUrl
    $SkipThumbnails = $using:SkipThumbnails
    $RegenerateThumbnails = $using:RegenerateThumbnails

    $fltFileName = $flt.Name
    $modelName = $flt.BaseName
    $containerName = "thumb_${currIndex}_" + [guid]::NewGuid().ToString().Substring(0, 8)

    try {
        $fileHash = (Get-FileHash -Path $flt.FullName -Algorithm MD5).Hash
    } catch {
        $fileHash = ""
    }
    
    $storageSizeKB = [math]::Round($flt.Length / 1KB)

    Write-ThreadLog "Processing [$currIndex/$totalCount]: $modelName ($currentAssetId)" "INFO"

    # Sidecar Check
    $sidecarPath = Join-Path $flt.DirectoryName ".${modelName}.metadata.json"
    $sidecarOverride = $null
    $modelStatus = "Active"
    $exclusionReason = ""

    if (Test-Path $sidecarPath) {
        try {
            $sidecarOverride = Get-Content -Path $sidecarPath -Raw -ErrorAction SilentlyContinue | ConvertFrom-Json
            if ($sidecarOverride.status) { $modelStatus = $sidecarOverride.status }
            if ($sidecarOverride.exclusionReason) { $exclusionReason = $sidecarOverride.exclusionReason }
        } catch {}
    }

    # --- INSPECTOR DATA ---
    $packageListStr = ""; $texResFormatted = ""; $boundingBoxStr = ""
    $enumerationStr = ""; $texWarningsStr = "None"
    $lodFinal = ""; $articFinal = ""; $damageFinal = ""; $appFinal = ""

    $hasValidInspectorCache = $sidecarOverride -and 
                              $sidecarOverride.inspector -and 
                              (-not [string]::IsNullOrWhiteSpace([string]$sidecarOverride.inspector.lods))

    if ($hasValidInspectorCache) {
        Write-ThreadLog " -> Loaded metadata from JSON sidecar ($modelStatus)" "DEBUG"
        $lodFinal        = $sidecarOverride.inspector.lods
        $articFinal      = $sidecarOverride.inspector.articulations
        $damageFinal     = $sidecarOverride.inspector.damageStates
        $appFinal        = $sidecarOverride.inspector.appearanceStates
        $packageListStr  = $sidecarOverride.inspector.packageList
        $boundingBoxStr  = $sidecarOverride.inspector.boundingBox
        $texResFormatted = $sidecarOverride.inspector.textureResolution
        $enumerationStr  = $sidecarOverride.inspector.enumeration
        $texWarningsStr  = $sidecarOverride.inspector.textureWarnings
    } else {
        Write-ThreadLog " -> Inspecting geometry via Podman container..." "INFO"
        $containerFltPath = Get-RelativePathCompat -BasePath $WorkDir -TargetPath $flt.FullName
        
        $tempOutFile = [System.IO.Path]::GetTempFileName()
        $p = Start-Process -FilePath "podman" -ArgumentList "run --name `"$containerName`" --rm --interactive=false -v `"${WorkDir}:/data:Z`" osg-inspector `"$containerFltPath`"" -NoNewWindow -RedirectStandardOutput $tempOutFile -PassThru
        
        if (-not $p.WaitForExit(15000)) {
            Start-Process -FilePath "podman" -ArgumentList "rm -f `"$containerName`"" -NoNewWindow -ErrorAction SilentlyContinue
            try { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue } catch {}
        }

        $rawOutput = if (Test-Path $tempOutFile) { Get-Content -Path $tempOutFile -ErrorAction SilentlyContinue } else { @() }
        if (Test-Path $tempOutFile) { Remove-Item $tempOutFile -Force -ErrorAction SilentlyContinue }

        $texResX = ""; $texResY = ""; $dateBuiltStr = ""; $textureWarnings = @()
        $lodBlocks = @(); $articBlocks = @(); $damageBlocks = @(); $appearanceBlocks = @()
        $currentLodCount = 0; $currentArticCount = 0; $currentDamageCount = 0; $currentAppCount = 0
        $currentSection = "None"; $tempPoly = ""; $currentDesc = ""

        foreach ($lineRaw in $rawOutput) {
            $line = ([string]$lineRaw).Trim()
            if ([string]::IsNullOrWhiteSpace($line)) { continue }

            if ($line -match "Warning:.*(?:texture|image|file).*not found" -or $line -match "Could not find plugin") {
                $textureWarnings += $line
            }
            elseif ($line -match "^PackageList\s*=\s*(.+)$") {
                $rawFiles = $matches[1] -split "\s*\|\s*"
                $packageListStr = ($rawFiles | ForEach-Object { "./$_" }) -join "|"
            }
            elseif ($line -match "^TextureResolutionX=(\d+)$") { $texResX = $matches[1] }
            elseif ($line -match "^TextureResolutionY=(\d+)$") { $texResY = $matches[1] }
            elseif ($line -match "^BoundingBox=(.+)$") { $boundingBoxStr = "Yes`nBoundingBox=$($matches[1])" }
            elseif ($line -match "^Enumeration=(.+)$") { $enumerationStr = $matches[1] }
            elseif ($line -match "^LODCount\s*=\s*(\d+)$") { $currentLodCount = [int]$matches[1]; $currentSection = "LOD" }
            elseif ($line -match "^PolygonCount=(\d+)$") { $tempPoly = $matches[1].Trim() }
            elseif ($line -match "^Range=(.+)$") { $lodBlocks += "LOD$($lodBlocks.Count + 1)`nPolygonCount=$tempPoly`nRange=$($matches[1].Trim())" }
            elseif ($line -match "^ArticulationCount=(\d+)$") { $currentArticCount = [int]$matches[1]; $currentSection = "Articulation" }
            elseif ($line -match "^Description=(.+)$" -and $currentSection -eq "Articulation") { $currentDesc = $matches[1].Trim() }
            elseif ($line -match "^Details=(.+)$" -and $currentSection -eq "Articulation") { $articBlocks += "Articulation$($articBlocks.Count + 1)`nDescription=$currentDesc`nDetails=$($matches[1].Trim())" }
            elseif ($line -match "^DamageStateCount=(\d+)$") { $currentDamageCount = [int]$matches[1]; $currentSection = "Damage" }
            elseif ($line -match "^DamageStateName=(.+)$") { $damageBlocks += "DamageState$($damageBlocks.Count + 1)`nDamageStateName=$($matches[1].Trim())" }
            elseif ($line -match "^AppearanceCount=(\d+)$") { $currentAppCount = [int]$matches[1]; $currentSection = "Appearance" }
            elseif ($line -match "^Description=(.+)$" -and $currentSection -eq "Appearance") { $currentDesc = $matches[1].Trim() }
            elseif ($line -match "^States=(.+)$" -and $currentSection -eq "Appearance") { $appearanceBlocks += "Appearance$($appearanceBlocks.Count + 1)`nDescription=$currentDesc`nStates=$($matches[1].Trim())" }
        }

        $texResFormatted = if ($texResX -and $texResY) { "X=$texResX`nY=$texResY" } else { "" }
        $lodFinal        = if ($currentLodCount -gt 0)   { ("LODCount=$currentLodCount`n`n" + ($lodBlocks -join "`n`n")).Trim() } else { "LODCount=0`n`nLOD1`nPolygonCount=N/A`nRange=N/A" }
        $articFinal      = if ($currentArticCount -gt 0) { ("ArticulationCount=$currentArticCount`n`n" + ($articBlocks -join "`n`n")).Trim() } else { "" }
        $damageFinal     = if ($currentDamageCount -gt 0){ ("DamageStateCount=$currentDamageCount`n`n" + ($damageBlocks -join "`n`n")).Trim() } else { "" }
        $appFinal        = if ($currentAppCount -gt 0)   { ("AppearanceCount=$currentAppCount`n`n" + ($appearanceBlocks -join "`n`n")).Trim() } else { "" }
        $texWarningsStr  = if ($textureWarnings.Count -gt 0) { ($textureWarnings -join " | ") } else { "None" }
    }

    $inferredDomain = ""
    if ($flt.DirectoryName -match "Air|Aircraft|Jet|Plane|Tornado|Raptor|Helicopter") { $inferredDomain = "Air" }
    elseif ($flt.DirectoryName -match "Sea|Maritime|Ship|Carrier|Vessel|Navy") { $inferredDomain = "Surface" }
    elseif ($flt.DirectoryName -match "Land|Vehicle|Tank|Ground|Building") { $inferredDomain = "Land" }

    $matchedEnum    = if ($sidecarOverride -and $sidecarOverride.siso.enumeration) { $sidecarOverride.siso.enumeration } else { $enumerationStr }
    $matchedDomain  = if ($sidecarOverride -and $sidecarOverride.siso.domain) { $sidecarOverride.siso.domain } else { $inferredDomain }
    $matchedCountry = if ($sidecarOverride -and $sidecarOverride.siso.countryOfOrigin) { $sidecarOverride.siso.countryOfOrigin } else { "" }
    $matchedType    = if ($sidecarOverride -and $sidecarOverride.siso.type) { $sidecarOverride.siso.type } else { "" }
    $matchedKind    = if ($sidecarOverride -and $sidecarOverride.siso.kind) { $sidecarOverride.siso.kind } else { "Platform" }
    $matchedCategory= if ($sidecarOverride -and $sidecarOverride.siso.category) { $sidecarOverride.siso.category } else { "" }
    $matchedSubType = if ($sidecarOverride -and $sidecarOverride.siso.subType) { $sidecarOverride.siso.subType } else { "" }
    $overrideName   = if ($sidecarOverride -and $sidecarOverride.modelName) { $sidecarOverride.modelName } else { $modelName }

    if (-not $sidecarOverride) {
        $cleanQuery = ($modelName -replace '(?i)Gladiator_|_v\d+|MOD_|CAMO|DESERT|WOODLAND|HIGH|LOW|_LOD\d*|\d+$', '' -replace '[_\-\.]', ' ').Trim()
        try {
            $topMatch = $null
            if ($enumerationStr) {
                $queryUrl = "${SisoApiUrl}/search?q=$([System.Uri]::EscapeDataString($enumerationStr))"
                $apiResp = Invoke-RestMethodWithRetry -Url $queryUrl
                if ($apiResp -and $apiResp.Count -gt 0) { $topMatch = $apiResp[0] }
            }
            if (-not $topMatch) {
                $queryUrl = "${SisoApiUrl}/search?q=$([System.Uri]::EscapeDataString($cleanQuery))&limit=5"
                $apiResp = Invoke-RestMethodWithRetry -Url $queryUrl
                if ($apiResp -and $apiResp.Count -gt 0 -and $apiResp[0].score -ge $MinConfidence) { $topMatch = $apiResp[0] }
            }
            if ($topMatch) {
                Write-ThreadLog "  [SISO MATCH] ($($topMatch.score)%) -> $($topMatch.match.enumeration) ($($topMatch.match.subType))" "SUCCESS"
                $matchedEnum    = $topMatch.match.enumeration
                $matchedDomain  = $topMatch.match.domain
                $matchedKind    = if ($topMatch.match.kind) { $topMatch.match.kind } else { "Platform" }
                $matchedCountry = $topMatch.match.country
                $matchedCategory= $topMatch.match.category
                $matchedType    = $topMatch.match.type
                $matchedSubType = $topMatch.match.subType
            } else {
                Write-ThreadLog "  [SISO NO MATCH] No candidates above ${MinConfidence}% threshold for '$cleanQuery'." "WARN"
            }
        } catch {
            Write-ThreadLog "  [SISO API OFFLINE] Could not reach siso-service at $SisoApiUrl" "WARN"
        }
    }

    # --- DYNAMIC DESCRIPTION BUILDER ---
    if ($sidecarOverride -and $sidecarOverride.description -and $sidecarOverride.description -ne "OpenFlight 3D visual asset.") {
        $autoDescription = $sidecarOverride.description
    } else {
        $descParts = @()
        $descParts += "OpenFlight 3D visual model."

        if ($currentLodCount -gt 0) {
            $descParts += "Includes $currentLodCount Level(s) of Detail (LODs)."
        } elseif ($lodFinal -match "LODCount=(\d+)") {
            $descParts += "Includes $($matches[1]) Level(s) of Detail (LODs)."
        }

        if ($currentArticCount -gt 0) {
            $descParts += "Contains $currentArticCount articulated part(s)."
        } elseif ($articFinal -match "ArticulationCount=(\d+)") {
            $descParts += "Contains $($matches[1]) articulated part(s)."
        }

        if ($currentDamageCount -gt 0) {
            $descParts += "Features $currentDamageCount damage state(s)."
        } elseif ($damageFinal -match "DamageStateCount=(\d+)") {
            $descParts += "Features $($matches[1]) damage state(s)."
        }

        if ($currentAppCount -gt 0) {
            $descParts += "Supports $currentAppCount appearance switch state(s)."
        } elseif ($appFinal -match "AppearanceCount=(\d+)") {
            $descParts += "Supports $($matches[1]) appearance switch state(s)."
        }

        $autoDescription = ($descParts -join " ").Trim()
        $autoDescription = $autoDescription -replace '\.\.+', '.' -replace '\s+', ' '
    }

    # --- THUMBNAIL PASS ---
    $localThumbDir = Join-Path $flt.DirectoryName ".${modelName}_thumbs"
    if (-not (Test-Path $localThumbDir)) { 
        New-Item -ItemType Directory -Path $localThumbDir -Force | Out-Null 
    }

    if (-not $SkipThumbnails) {
        $frontThumb = Join-Path $localThumbDir "${modelName}_front.png"
        $hasCachedThumbs = Test-Path $frontThumb

        if (-not $hasCachedThumbs -or $RegenerateThumbnails) {
            $containerFltPath = Get-RelativePathCompat -BasePath $WorkDir -TargetPath $flt.FullName
            $containerPrefix = Get-RelativePathCompat -BasePath $WorkDir -TargetPath (Join-Path $localThumbDir $modelName)
            
            # Direct execution capturing output and error stream
            $thumbResult = & podman run --rm --interactive=false -v "${WorkDir}:/data:Z" osg-thumb "$containerFltPath" "$containerPrefix" "all" "white" 2>&1
            $exitCode = $LASTEXITCODE

            if ($exitCode -ne 0) {
                Write-ThreadLog " -> [RENDER FAILED] ($exitCode) for ${modelName}: ${thumbResult}" "ERROR"
            } elseif (-not (Test-Path $frontThumb)) {
                Write-ThreadLog " -> [RENDER MISSING] Container finished but ${modelName}_front.png was not created!" "WARN"
            } else {
                Write-ThreadLog " -> Rendered thumbnails for $modelName" "SUCCESS"
            }
        }
    }

    try {
        $sidecarPayload = @{
            fileHash        = $fileHash
            assetId         = $currentAssetId
            modelName       = $overrideName
            status          = $modelStatus
            exclusionReason = $exclusionReason
            storageSizeKB   = $storageSizeKB
            description     = $autoDescription
            inspector       = @{
                lods              = $lodFinal
                articulations     = $articFinal
                damageStates      = $damageFinal
                appearanceStates = $appFinal
                packageList       = $packageListStr
                boundingBox       = $boundingBoxStr
                textureResolution = $texResFormatted
                enumeration       = $enumerationStr
                textureWarnings   = $texWarningsStr
            }
            siso            = @{ 
                enumeration     = $matchedEnum
                kind            = $matchedKind
                domain          = $matchedDomain
                countryOfOrigin = $matchedCountry
                category        = $matchedCategory
                type            = $matchedType
                subType         = $matchedSubType 
            }
        } | ConvertTo-Json -Depth 5
        
        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($sidecarPath, $sidecarPayload, $utf8NoBom)
        Write-ThreadLog " -> Saved sidecar: $sidecarPath" "DEBUG"
    } catch {
        Write-ThreadLog " -> Failed to write sidecar: $_" "ERROR"
    }

} -ThrottleLimit $ThrottleLimit

if (Test-Path $TempExtractDir) { Remove-Item $TempExtractDir -Recurse -Force }

$Stopwatch.Stop()
$ElapsedTime = $Stopwatch.Elapsed
$FormattedTime = "{0:D2}h:{1:D2}m:{2:D2}s.{3:D3}ms" -f $ElapsedTime.Hours, $ElapsedTime.Minutes, $ElapsedTime.Seconds, $ElapsedTime.Milliseconds

Write-Log "==========================================================" "SUCCESS"
Write-Log " PROCESSING COMPLETE!" "SUCCESS"
Write-Log " Total Execution Time: $FormattedTime" "SUCCESS"
Write-Log " All sidecars successfully synced on disk." "SUCCESS"
Write-Log "==========================================================" "SUCCESS"