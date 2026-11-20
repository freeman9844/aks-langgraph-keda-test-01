param(
    [Parameter(Mandatory)][ValidateSet('Preview','Create','Remove')]$Action,
    [Parameter(Mandatory)][guid]$SubscriptionId,
    [Parameter(Mandatory)][ValidatePattern('^[a-z0-9]+$')]$Region,
    [Parameter(Mandatory)][ValidatePattern('^rg-runlab-[a-z0-9-]+$')]$ResourceGroup
)
. "$PSScriptRoot\Common.ps1"
$actual = az account show --query id -o tsv
$stateFile = "$LabDir\state.json"
$state = if (Test-Path $stateFile) { Get-Content -Raw $stateFile | ConvertFrom-Json }
$prefix = $ResourceGroup
if ($Action -eq 'Create') { $ResourceGroup = New-LabGroupName $prefix }
if ($Action -eq 'Remove') {
    if (!$state -or $state.prefix -ne $prefix) { throw 'Local lab prefix mismatch' }
    $ResourceGroup = $state.group
}
$exists = (az group exists --subscription $SubscriptionId -n $ResourceGroup) -eq 'true'
$tag = if ($exists) { az group show -n $ResourceGroup --subscription $SubscriptionId --query tags.runLab -o tsv }
Assert-LabTarget $Action "$SubscriptionId" $actual $exists $tag $state.owner
if ($Action -eq 'Preview') {
    Write-Output "구독 $SubscriptionId / $Region / $ResourceGroup (존재: $exists). 고정 D4s_v5 VM 2대 × 예상 유지 2시간, OS 디스크, LB·IP, ACR Basic·Build, Prometheus 수집/조회. 운영 요금은 계약/리전별 확인. 자동 삭제되지 않습니다."
    return
}
if ($Action -eq 'Remove') {
    if ($state.group -ne $ResourceGroup -or $state.subscription -ne "$SubscriptionId") { throw 'State mismatch' }
    az group delete -n $ResourceGroup --subscription $SubscriptionId --yes
    if ((az group exists -n $ResourceGroup --subscription $SubscriptionId) -ne 'false') { throw 'Group still exists' }
    Remove-Item -LiteralPath $stateFile
    return
}
if ($state) { throw 'Existing local lab state: resolve it before creating another lab' }
New-Item $LabDir -ItemType Directory -Force | Out-Null
$owner = [guid]::NewGuid().ToString()
@{owner=$owner;group=$ResourceGroup;prefix=$prefix;subscription="$SubscriptionId"} | ConvertTo-Json | Set-Content $stateFile
az group create -n $ResourceGroup -l $Region --subscription $SubscriptionId --tags "runLab=$owner" -o none
$outputs = az deployment group create --subscription $SubscriptionId -g $ResourceGroup -n runlab --template-file "$PSScriptRoot\..\infra\main.bicep" --query properties.outputs -o json
$outputs | Set-Content "$LabDir\outputs.json"
