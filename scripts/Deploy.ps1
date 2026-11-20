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
k apply -f "$templates\monitor.yaml"
(Get-Content -Raw "$templates\scaler.yaml").Replace('__ENDPOINT__',$cfg.endpoint.value.TrimEnd('/')).Replace('__CLIENT_ID__',$cfg.clientId.value).Replace('__SELECTOR__',(Get-Selector)) | kubectl --kubeconfig "$LabDir\kubeconfig" apply -f -
k -n run-lab rollout status deploy/agent-runtime --timeout=5m
k -n run-lab wait pod/load-client --for=condition=Ready --timeout=5m
k -n run-lab wait scaledobject/agent-runtime --for=condition=Ready --timeout=5m
