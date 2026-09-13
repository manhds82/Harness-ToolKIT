<#
  Shared project discovery for the fleet operator scripts.

  WHY THIS EXISTS. update-all-projects, set-pdp-enforce and set-member-email
  each had their own one-level `Get-ChildItem $BaseDir` scan. One level is wrong
  as soon as a product keeps several checkouts under one folder --
  <product>\repos\<repo-1..n>, all feeding a single Portal project. A one-level
  scan sees none of them, so a release reports "all projects updated" while
  leaving them behind, and a report that reads as complete coverage is worse
  than a visibly missing one.

  Three copies of the same scan would drift apart the first time one of them was
  fixed, which is exactly how the three copies of the release classifier ended
  up disagreeing (B-13/B-14). One function, dot-sourced.

  A directory that HOLDS .harness IS the project; we only descend where there is
  none, and then only one level plus a conventional repos/apps/projects folder.
  Deeper than that and a stray vendored checkout starts looking like a project.
#>

function Get-HarnessProjects {
    param(
        [Parameter(Mandatory)][string]$BaseDir,
        # Marker that makes a directory a project. update-all-projects wants any
        # installed project (".harness"); the portal-sync scripts want one that
        # is actually wired to a Portal (".harness\portal-sync.json").
        [string]$Marker = ".harness",
        [string[]]$Skip = @("HarnessAI-ToolKIT", "Harness-ToolKIT")
    )

    $isProject = { param($d) Test-Path (Join-Path $d.FullName $Marker) }

    $top = Get-ChildItem $BaseDir -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notin $Skip }

    $found = @($top | Where-Object { & $isProject $_ })

    foreach ($container in ($top | Where-Object { -not (& $isProject $_) })) {
        $inner = @(Get-ChildItem $container.FullName -Directory -ErrorAction SilentlyContinue |
                   Where-Object { $_.Name -in @("repos", "apps", "projects") })
        foreach ($dir in $inner) {
            $nested = Get-ChildItem $dir.FullName -Directory -ErrorAction SilentlyContinue |
                      Where-Object { & $isProject $_ }
            if ($nested) { $found += $nested }
        }
    }

    $found | Sort-Object FullName -Unique
}

<#
  A nested project's folder name is not unique context on its own, so
  -Only/-Exclude and the printed summary use this label: the path relative to
  BaseDir, e.g. "<product>/repos/<repo>". Matching accepts either form, because
  an operator types the short name.
#>
function Get-ProjectLabel {
    param([Parameter(Mandatory)]$Project, [Parameter(Mandatory)][string]$BaseDir)
    $full = $Project.FullName.TrimEnd('\')
    $base = (Resolve-Path $BaseDir).Path.TrimEnd('\')
    if ($full.StartsWith($base, [StringComparison]::OrdinalIgnoreCase)) {
        return $full.Substring($base.Length).TrimStart('\').Replace('\', '/')
    }
    return $Project.Name
}

function Test-ProjectMatch {
    param([Parameter(Mandatory)][string]$Label, [Parameter(Mandatory)][string]$Name, [string[]]$Set)
    if (-not $Set) { return $false }
    foreach ($s in $Set) {
        if ($s -eq $Name -or $s -eq $Label) { return $true }
        # naming the container selects every repo under it
        if ($Label -like "$s/*") { return $true }
    }
    return $false
}
