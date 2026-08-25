# Copies the addon into every WoW client listed in dev.local.ps1.
# dev.local.ps1 is gitignored: it holds machine specific paths and nothing else.

$ErrorActionPreference = "Stop"

$localConfig = Join-Path $PSScriptRoot "dev.local.ps1"
if (-not (Test-Path $localConfig)) {
    Write-Host "No dev.local.ps1 found. Create one next to this script containing:" -ForegroundColor Yellow
    Write-Host '  $WowAddOnsPaths = @("X:\path\to\World of Warcraft\_classic_\Interface\AddOns")'
    exit 1
}

. $localConfig

if (-not $WowAddOnsPaths -or $WowAddOnsPaths.Count -eq 0) {
    Write-Host "dev.local.ps1 defines no `$WowAddOnsPaths." -ForegroundColor Red
    exit 1
}

$source = Join-Path (Split-Path $PSScriptRoot -Parent) "addon\MogWhere"

# Which client folder maps to which toc suffix. Copying into a client we ship no
# toc for leaves a folder the game lists as broken, which is a confusing thing to
# find later, so those targets are skipped and named.
$FlavorTocs = @{
    "_retail_"      = "MogWhere_Mainline.toc"
    "_classic_"     = "MogWhere_Mists.toc"
    "_classic_era_" = "MogWhere_Vanilla.toc"
}

foreach ($addons in $WowAddOnsPaths) {
    if (-not (Test-Path $addons)) {
        Write-Host "Skipping missing path: $addons" -ForegroundColor DarkGray
        continue
    }

    # Longest key first: "_classic_" is a substring of "_classic_era_", so testing
    # in arbitrary order made an Era client look like a Mists one.
    $flavor = ($FlavorTocs.Keys |
        Sort-Object -Property Length -Descending |
        Where-Object { $addons -like "*$_*" } |
        Select-Object -First 1)
    if ($flavor) {
        $toc = Join-Path $source $FlavorTocs[$flavor]
        if (-not (Test-Path $toc)) {
            Write-Host "Skipping $flavor : no $($FlavorTocs[$flavor]) to load there" -ForegroundColor DarkGray
            $stale = Join-Path $addons "MogWhere"
            if (Test-Path $stale) {
                Remove-Item -Recurse -Force $stale
                Write-Host "  removed a previous copy that could not load" -ForegroundColor DarkGray
            }
            continue
        }
    }

    $target = Join-Path $addons "MogWhere"
    Write-Host "Deploying to $target"
    New-Item -ItemType Directory -Force -Path $target | Out-Null
    Copy-Item -Path (Join-Path $source "*") -Destination $target -Recurse -Force

    # The toc carries @project-version@ so the CurseForge packager can stamp the
    # real version from the git tag. Left alone, an unpackaged copy shows that raw
    # token in the addon list, which looks broken. So the local copy gets a
    # readable version instead: the newest tag, plus the short commit, plus -dev
    # to make it obvious this build did not come from a release.
    $stamp = "dev"
    try {
        $described = git -C (Split-Path $PSScriptRoot -Parent) describe --tags --always --dirty 2>$null
        if ($described) { $stamp = "$described-dev" }
    } catch { }

    Get-ChildItem -Path $target -Filter "*.toc" | ForEach-Object {
        (Get-Content $_.FullName -Raw).Replace("@project-version@", $stamp) |
            Set-Content $_.FullName -NoNewline
    }
}

Write-Host "Done. Type /reload in game, then /mw probe." -ForegroundColor Green
