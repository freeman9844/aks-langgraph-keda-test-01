. "$PSScriptRoot\Common.ps1"
Get-LabSession
$token = az account get-access-token --subscription $state.subscription --resource https://prometheus.monitor.azure.com --query accessToken -o tsv
$samples = [Collections.Generic.List[object]]::new()
$file = "$LabDir\evidence-$(Get-Date -Format yyyyMMdd-HHmmss).json"
function Nodes { ((k get nodes -o name) | Sort-Object) -join ',' }
function Pods { (k -n run-lab get pods -l app=agent-runtime -o json | ConvertFrom-Json).items }
function Invoke-Pod($Pod,$Method,$Path) {
    if ($Method -eq 'POST') {
        $id = $Path.Split('/')[-1]
        k -n run-lab exec load-client '--' python probe.py start $id "http://$($Pod.status.podIP):8000/streams/$id"
        return
    }
    $url = "http://$($Pod.status.podIP):8000/$Path"
    $cmd = @(Get-ProbeArgs $url $Method)
    k @cmd
    if ($Method -eq 'DELETE') {
        k -n run-lab exec load-client '--' python probe.py done $Path.Split('/')[-1]
    }
}
function Local-Gauge($Pod) {
    $line = @(Invoke-Pod $Pod GET metrics | Where-Object { $_ -match '^agent_runs_active ([0-9.]+)$' })
    if ($line.Count -ne 1) { throw 'Missing local Gauge' }
    [int]($line[0] -split ' ')[1]
}
function Wait-Phase($Phase,$ExpectedRuns,$ExpectedPods,$Seconds) {
    $end = [DateTime]::UtcNow.AddSeconds($Seconds)
    do {
        $nodes = Nodes
        $pods = @(Pods)
        $old = @($pods | Where-Object { $_.metadata.uid -eq $initial.metadata.uid })
        if ($Phase -ne 'released' -and $old.Count -ne 1) { throw 'Lost original Pod' }
        Assert-Stable $initialNodes $nodes ($old.status.containerStatuses.restartCount | Measure-Object -Sum).Sum
        $series = @(Read-RunSeries $cfg.endpoint.value $token (Get-Selector))
        $n = if ($series.Count) { Measure-RunSeries $series } else { $null }
        $hpa = (k -n run-lab get hpa keda-hpa-agent-runtime -o json | ConvertFrom-Json).status
        $deployment = (k -n run-lab get deploy agent-runtime -o json | ConvertFrom-Json).status
        $healthy = @($hpa.conditions | Where-Object { $_.type -eq 'ScalingActive' -and $_.status -eq 'True' }).Count -eq 1
        $sample = [ordered]@{utc=[DateTime]::UtcNow.ToString('o');phase=$Phase;runs=$n;desired=$hpa.desiredReplicas;ready=$deployment.readyReplicas;nodes=$nodes;scalingActive=$healthy}
        $samples.Add($sample)
        Write-Host ($sample | ConvertTo-Json -Compress)
        $ids = @($pods | ForEach-Object {$_.metadata.name} | Sort-Object)
        $scraped = @($series | ForEach-Object {$_.metric.pod} | Sort-Object)
        if ($healthy -and $null -ne $n -and ($ids -join ',') -eq ($scraped -join ',') -and (Test-Phase $n $hpa.desiredReplicas $deployment.readyReplicas $ExpectedRuns $ExpectedPods)) { return }
        Start-Sleep 5
    } while ([DateTime]::UtcNow -lt $end)
    throw "Timeout: $Phase"
}
$initialNodes = Nodes
$before = @(Pods)
if ($before.Count -ne 1) { throw 'Start with exactly one runtime Pod' }
$initial = $before[0]
$idsToStart = 1..6 | ForEach-Object { "probe-$_" }
try {
    Wait-Phase baseline 0 1 900
    foreach ($id in $idsToStart) { Invoke-Pod $initial POST "runs/$id" | Out-Null }
    if ((Local-Gauge $initial) -ne 6) { throw 'Original Pod did not start 6 runs' }
    Wait-Phase loaded 6 3 300
    $new = Select-NewPod @(Pods) $initial.metadata.uid
    Invoke-Pod $new POST 'runs/new-pod' | Out-Null
    if ((Local-Gauge $new) -ne 1) { throw 'New Pod did not execute run' }
    Invoke-Pod $new DELETE 'runs/new-pod' | Out-Null
    if ((Local-Gauge $new) -ne 0) { throw 'New Pod did not release run' }
    foreach ($id in $idsToStart) { Invoke-Pod $initial DELETE "runs/$id" | Out-Null }
    Wait-Phase released 0 1 600
} catch {
    $samples.Add(@{error=$_.Exception.Message; utc=[DateTime]::UtcNow.ToString('o')})
    try { k -n run-lab describe 'scaledobject,hpa' | Out-File "$file.diagnostics.txt" } catch { Write-Warning $_ }
    try { k -n run-lab get events --sort-by=.lastTimestamp | Out-File "$file.diagnostics.txt" -Append } catch { Write-Warning $_ }
    throw
} finally {
    ConvertTo-Json -InputObject $samples -Depth 6 | Set-Content $file
    Write-Host "관측 기록: $file"
}
