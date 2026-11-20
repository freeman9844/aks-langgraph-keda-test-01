param([switch]$WithFoundry)
. "$PSScriptRoot\Common.ps1"
Get-LabSession
$cluster = $cfg.cluster.value
$registry = $cfg.registry.value
$tag = "runprobe:$([guid]::NewGuid().ToString('N'))"
az acr build --subscription $state.subscription -r $registry -t $tag "$PSScriptRoot\..\app" --no-logs -o none
$login = az acr show -n $registry --subscription $state.subscription --query loginServer -o tsv
az aks get-credentials --subscription $state.subscription -g $state.group -n $cluster --file "$LabDir\kubeconfig" --overwrite-existing -o none
$templates = "$PSScriptRoot\..\k8s"
k -n kube-system annotate serviceaccount keda-operator "azure.workload.identity/client-id=$($cfg.clientId.value)" --overwrite
k -n kube-system rollout restart deployment/keda-operator
k -n kube-system rollout status deployment/keda-operator --timeout=5m
(Get-Content -Raw "$templates\workload.yaml").Replace('__IMAGE__', "${login}/$tag") | kubectl --kubeconfig "$LabDir\kubeconfig" apply -f -
if ($WithFoundry) {
    $model = az deployment group create --subscription $state.subscription -g $state.group -n stream-model --template-file "$PSScriptRoot\..\infra\model.bicep" --parameters "clusterName=$cluster" --query properties.outputs -o json | ConvertFrom-Json
    @{apiVersion='v1';kind='ServiceAccount';metadata=@{name='stream-runtime';namespace='run-lab';annotations=@{'azure.workload.identity/client-id'=$model.clientId.value}}} | ConvertTo-Json -Depth 6 | kubectl --kubeconfig "$LabDir\kubeconfig" apply -f -
    $patch = @{spec=@{template=@{metadata=@{labels=@{'azure.workload.identity/use'='true'}};spec=@{serviceAccountName='stream-runtime';containers=@(@{name='runtime';env=@(@{name='MODEL_ENDPOINT';value=$model.endpoint.value})})}}}}
    $patch | ConvertTo-Json -Depth 10 | Set-Content "$LabDir\model-patch.json"
    k -n run-lab patch deploy agent-runtime --patch-file "$LabDir\model-patch.json"
}
k apply -f "$templates\monitor.yaml"
(Get-Content -Raw "$templates\scaler.yaml").Replace('__ENDPOINT__',$cfg.endpoint.value.TrimEnd('/')).Replace('__CLIENT_ID__',$cfg.clientId.value).Replace('__SELECTOR__',(Get-Selector)) | kubectl --kubeconfig "$LabDir\kubeconfig" apply -f -
k -n run-lab rollout status deploy/agent-runtime --timeout=5m
k -n run-lab wait pod/load-client --for=condition=Ready --timeout=5m
k -n run-lab wait scaledobject/agent-runtime --for=condition=Ready --timeout=5m
