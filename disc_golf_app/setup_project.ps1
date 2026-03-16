# Updated setup script for your directory structure
$projectRoot = "C:\Claude Disc Golf App\disc_golf_app"
Set-Location $projectRoot

Write-Host "Setting up Disc Golf App in: $projectRoot" -ForegroundColor Green

# Create directory structure
$dirs = @(
    "lib\models",
    "lib\screens\flight_tracker",
    "lib\screens\form_coach",
    "lib\screens\roulette",
    "lib\services",
    "lib\widgets",
    "lib\utils",
    "assets\data",
    "assets\images",
    "python\api",
    "python\flight_tracking",
    "python\posture_analysis"
)

foreach ($dir in $dirs) {
    New-Item -Path $dir -ItemType Directory -Force | Out-Null
    Write-Host "Created: $dir" -ForegroundColor Cyan
}

Write-Host ""
Write-Host "Directory structure created successfully!" -ForegroundColor Green
Write-Host "Project location: $projectRoot" -ForegroundColor Yellow