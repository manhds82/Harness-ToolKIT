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

  A directory that holds .harness IS a project, and it can ALSO be a container.
  Those are not exclusive, and treating them as exclusive silently shrank the
  fleet: this scan used to descend only into directories that were not projects
  themselves, so the day a product's ROOT was onboarded, its six checkouts under
  <product>\repos\ dropped out of discovery. The updater then reported 13/13
  while six projects sat a release behind with no sign anywhere -- the same
  "reads as complete coverage" failure this file was written to prevent, one
  level up. Measured: after the 1.7.0 release, 13 projects matched the artifact
  and 6 were still on 1.6.20.

  So: every top-level directory is tested as a project AND descended into. Depth
  stays at one level plus a conventional repos/apps/projects folder -- deeper and
  a stray vendored checkout starts looking like a project.
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

    # EVERY top-level directory is descended into, including ones that are
    # projects themselves. A product repo can hold its own .harness and still
    # carry sibling checkouts under repos/; when this loop skipped those, they
    # left the fleet silently. Sort -Unique below absorbs any overlap.
    foreach ($container in $top) {
        # A project sitting DIRECTLY under a top-level folder, e.g.
        # <BaseDir>\NEW_APPLICATION\fla-gateway. This used to require the middle
        # folder to be named repos/apps/projects, so a project under any other
        # grouping folder was invisible: installed correctly, updated never,
        # and counted as absent by every fleet report. Measured -- it is why the
        # fleet count read 14 while the Handoff said 19.
        #
        # Matching by SHAPE (a directory holding the marker) instead of by the
        # parent's NAME: a name list only ever knows the folder names somebody
        # already thought of, and the failure it produces is silent.
        $direct = Get-ChildItem $container.FullName -Directory -ErrorAction SilentlyContinue |
                  Where-Object { & $isProject $_ }
        if ($direct) { $found += $direct }

        # ...and one level deeper, but ONLY under the conventional folders.
        # Unbounded recursion here would start collecting vendored checkouts
        # and node_modules copies as if they were fleet projects.
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
    # Trim BOTH separators, not just the Windows one.
    #
    # This trimmed only '\'. On Windows that is the separator, so it worked and
    # every local run was green. On Linux the separator is '/', so TrimStart('\')
    # removed nothing and every label came back with a leading slash:
    # "/product" instead of "product".
    #
    # Not cosmetic. Test-ProjectMatch compares -Only/-Exclude against this label,
    # so on a Linux runner every by-name selection silently matched nothing --
    # `-Only product` would skip the project it names, and a fleet script would
    # report "0 projects" as if there were none to do.
    #
    # Found by CI, which had been failing on tests/policy/test_fleet_discovery.py
    # since the test landed. Local runs are Windows-only, so nothing here could
    # have caught it; the red build was the only signal and nobody was reading it.
    $sep = [char[]]@('\', '/')
    $full = $Project.FullName.TrimEnd($sep)
    $base = (Resolve-Path $BaseDir).Path.TrimEnd($sep)
    if ($full.StartsWith($base, [StringComparison]::OrdinalIgnoreCase)) {
        return $full.Substring($base.Length).TrimStart($sep).Replace('\', '/')
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
