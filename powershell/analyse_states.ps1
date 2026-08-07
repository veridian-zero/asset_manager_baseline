# summarize_states.ps1
param (
    [string]$CsvPath = ".\Gladiator_Export_CSV\Air\model_inventory.csv"
)

if (-not (Test-Path $CsvPath)) {
    Write-Error "CSV file not found at $CsvPath"
    exit 1
}

$data = Import-Csv -Path $CsvPath

$uniqueDamage = [System.Collections.Generic.HashSet[string]]::new()
$uniqueArticulations = [System.Collections.Generic.HashSet[string]]::new()
$uniqueAppearances = [System.Collections.Generic.HashSet[string]]::new()

foreach ($row in $data) {
    # 1. Damage States
    if ($row.DamageStates) {
        $lines = $row.DamageStates -split "`n"
        foreach ($line in $lines) {
            if ($line -match "^DamageStateName=(.+)$") {
                [void]$uniqueDamage.Add($matches[1].Trim())
            }
        }
    }

    # 2. Articulations
    if ($row.Articulations) {
        $lines = $row.Articulations -split "`n"
        foreach ($line in $lines) {
            if ($line -match "^Description=(.+)$") {
                [void]$uniqueArticulations.Add($matches[1].Trim())
            }
        }
    }

    # 3. Appearance States
    if ($row.AppearanceStates) {
        $lines = $row.AppearanceStates -split "`n"
        foreach ($line in $lines) {
            if ($line -match "^Description=(.+)$") {
                [void]$uniqueAppearances.Add($matches[1].Trim())
            }
            if ($line -match "^States=(.+)$") {
                $states = $matches[1] -split ","
                foreach ($s in $states) {
                    if ($s.Trim()) { [void]$uniqueAppearances.Add($s.Trim()) }
                }
            }
        }
    }
}

Write-Host "==========================================" -ForegroundColor Cyan
Write-Host " 3D CATALOG BEHAVIORAL STATES AUDIT REPORT" -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan

Write-Host "`n[1] UNIQUE DAMAGE STATES (Total: $($uniqueDamage.Count))" -ForegroundColor Yellow
$uniqueDamage | Sort-Object | ForEach-Object { Write-Host "  - $_" }

Write-Host "`n[2] UNIQUE ARTICULATION DOFs (Total: $($uniqueArticulations.Count))" -ForegroundColor Yellow
$uniqueArticulations | Sort-Object | ForEach-Object { Write-Host "  - $_" }

Write-Host "`n[3] UNIQUE APPEARANCE / SWITCH STATES (Total: $($uniqueAppearances.Count))" -ForegroundColor Yellow
$uniqueAppearances | Sort-Object | ForEach-Object { Write-Host "  - $_" }