$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
$LabDir = Join-Path $PSScriptRoot '..\.lab'

function Assert-LabTarget($Action,$Expected,$Actual,[bool]$Exists,$Tag,$Owner) {
    if (!$Expected -or $Expected -ne $Actual) { throw 'Subscription mismatch' }
    if ($Action -eq 'Create' -and $Exists) { throw 'Refusing to adopt existing group' }
    if ($Action -eq 'Remove' -and (!$Exists -or !$Owner -or $Tag -ne $Owner)) { throw 'Group ownership mismatch' }
}
function Get-LabSession {
    $script:state = Get-Content -Raw "$LabDir\state.json" | ConvertFrom-Json
    $script:cfg = Get-Content -Raw "$LabDir\outputs.json" | ConvertFrom-Json
    $actual = az account show --query id -o tsv
    $tag = az group show -n $state.group --subscription $state.subscription --query tags.runLab -o tsv
    Assert-LabTarget Remove $state.subscription $actual $true $tag $state.owner
}
function k { & kubectl --kubeconfig "$LabDir\kubeconfig" @args }
function New-LabGroupName($Prefix) { "$Prefix-$([guid]::NewGuid().ToString('N'))" }
function Get-ProbeArgs($Url,$Method) {
    '-n','run-lab','exec','load-client','--','python','-c','import sys,urllib.request as u;print(u.urlopen(u.Request(sys.argv[1],method=sys.argv[2]),timeout=5).read().decode())',$Url,$Method
}
function Select-NewPod($Pods,$OldUid) {
    $pod = $Pods | Where-Object { $_.metadata.uid -ne $OldUid } | Select-Object -First 1
    if (!$pod) { throw 'No new Pod available' }
    $pod
}
function Get-Selector {
    'agent_runs_active{cluster="' + $cfg.cluster.value + '",namespace="run-lab",pod=~"agent-runtime-.+"}'
}
function Read-RunSeries($Endpoint,$Token,$Query) {
    $uri = $Endpoint.TrimEnd('/') + '/api/v1/query?query=' + [uri]::EscapeDataString($Query)
    $response = Invoke-RestMethod $uri -Headers @{Authorization="Bearer $Token"}
    if ($response.status -ne 'success' -or $response.data.resultType -ne 'vector') { throw 'Invalid workspace response' }
    $response.data.result
}
function Measure-RunSeries($Series) {
    if (!$Series -or !$Series.Count) { throw 'No Run series' }
    $total = 0
    $seen = @{}
    foreach ($s in $Series) {
        $pod = $s.metric.pod
        if (!$pod -or $seen.ContainsKey($pod)) { throw 'Invalid or duplicate pod series' }
        $seen[$pod] = $true
        if ($s.value[1] -notmatch '^\d+(\.0+)?$') { throw 'Invalid Run count' }
        $total += [int]$s.value[1]
    }
    $total
}
function Assert-Stable($InitialNodes,$CurrentNodes,$OriginalRestarts) {
    if ($InitialNodes -ne $CurrentNodes -or $OriginalRestarts -ne 0) { throw 'Node set changed or original pod restarted' }
}
function Test-Phase($Runs,$Desired,$Ready,$ExpectedRuns,$ExpectedPods) {
    $Runs -eq $ExpectedRuns -and $Desired -eq $ExpectedPods -and $Ready -eq $ExpectedPods
}
