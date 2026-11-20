# Korea Central 실행 증거

**최신 SSE 버전:** [sse-cycle.json](sse-cycle.json)은 열린 SSE 수에 따른 확장·축소 이력이다. [model-drain.json](model-drain.json)은 실제 모델 스트림의 첫 delta 이후 대상 Pod를 삭제한 별도의 종료 시험 결과다. `firstDeltas`, `finalDeltas`는 토큰 수가 아니라 비어 있지 않은 텍스트 이벤트 개수다. 아래는 최초 백그라운드 Run 버전 기록이다.

[scale-cycle.json](scale-cycle.json)은 2026-11-20 실험의 전체 94개 관측점이다. `utc`는 UTC이며 루트 README의 표는 KST다. 원본에서 노드 이름은 공개하지 않고 `nodeCount`로 변환했다. `runs: null`은 **시계열 미수신**이고 `runs: 0`과 다르다.

`runs`는 Azure Monitor workspace에서 조회한 `agent_runs_active`의 합계, `desired`는 HPA 희망 복제본, `ready`는 Deployment의 Ready 수다. `scalingActive`는 HPA가 지표를 사용 가능한지 나타낸다. 한 행은 여러 API를 순서대로 조회한 표본이며 서비스 이벤트의 정확한 발생 시각은 아니다.

| 관측값 | 재확인 방법 |
|---|---|
| T1 → T3 → T5 | `baseline`, `loaded`, `released` 각 구간에서 아래와 같이 Run·희망·Ready 조합을 비교 |
| T2·T4의 Pod 내부 Gauge | [Verify.ps1](../scripts/Verify.ps1)의 로컬 Gauge 단언. 이 값은 workspace JSON 열이 아니다. T4 실패 시 스크립트는 정상적인 `released` 단계로 진행하지 않는다. |
| 확장·축소 소요 시간 | 첫 `loaded/runs=6`과 첫 `loaded/ready=3` 관측 간 약 22초. 첫 `released/runs=0`과 첫 `released/ready=1` 간 약 4분 52초 |

```powershell
$rows = Get-Content -Raw .\evidence\scale-cycle.json | ConvertFrom-Json
$rows | Group-Object phase,runs,desired,ready,nodeCount | Select-Object Name,Count
```

별도의 LLM·SSE 부하를 사용하지 않았다. 이 결과는 애플리케이션의 **실행 중 Run 수로 Pod를 확장할 수 있다**는 근거이며, TTFT 감소나 Pod당 적정 동시성을 입증하지 않는다.
