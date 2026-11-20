. "$PSScriptRoot\Common.ps1"
Get-LabSession
$pod = ((k -n run-lab get pods -l app=agent-runtime -o json | ConvertFrom-Json).items | Where-Object { !$_.metadata.deletionTimestamp -and $_.status.containerStatuses[0].ready } | Select-Object -First 1)
if (!$pod) { throw 'No ready runtime' }
$url = "http://$($pod.status.podIP):8000"
$name = 'drain-' + [guid]::NewGuid().ToString('N')
$first = k -n run-lab exec load-client '--' python probe.py start $name "$url/streams/${name}?backend=foundry&pace=0.6" | ConvertFrom-Json
if (!$first.deltas -or $first.done) { throw 'Expected an open model stream' }
$metricArgs = Get-ProbeArgs "$url/metrics" GET
if (!(k @metricArgs | Select-String '^agent_runs_active 1\.0$')) { throw 'Expected 1 active stream on target' }
$timer = [Diagnostics.Stopwatch]::StartNew()
k -n run-lab delete pod $pod.metadata.name --wait=false
$reject = "import sys,time,urllib.request as r,urllib.error as e`nfor n in range(20):`n try:`n  r.urlopen(sys.argv[1]+'/ready',timeout=1).close()`n except e.HTTPError as ex:`n  if ex.code==503: break`n time.sleep(.15)`nelse: sys.exit('drain not observed')`ntry: r.urlopen(sys.argv[1]+'/streams/rejected',timeout=2)`nexcept e.HTTPError as ex: sys.exit(0 if ex.code==503 else 1)`nsys.exit('accepted during drain')"
k -n run-lab exec load-client '--' python -c $reject $url
$done = k -n run-lab exec load-client '--' python probe.py done $name | ConvertFrom-Json
if (!$done.done -or $done.deltas -le $first.deltas -or $timer.Elapsed.TotalSeconds -le 10 -or $timer.Elapsed.TotalSeconds -ge 120) { throw 'Model stream did not drain within budget after preStop' }
$result = @{model='gpt-4.1-nano'; activeBeforeDelete=1; rejectedNewStream=503; firstDeltas=$first.deltas; finalDeltas=$done.deltas; done=$done.done; secondsAfterDelete=[math]::Round($timer.Elapsed.TotalSeconds,1)}
$result | ConvertTo-Json | Tee-Object "$LabDir\drain-result.json"
k -n run-lab rollout status deploy/agent-runtime --timeout=3m
