# LangGraph Run 기반 AKS Pod 확장·축소 구현 계획

> **실행 담당자:** `superpowers:subagent-driven-development` 또는 `superpowers:executing-plans`로 작업별로 진행한다. `- [ ]`로 진행을 기록한다.

**Goal:** 실제 LangGraph 동시 실행 수 0 → 6 → 0이 Managed Prometheus와 KEDA를 거쳐 Pod 1 → 3 → 1로 이어지는지 입증한다.

**Architecture:** 고정 노드 풀의 내부 테스트 앱을 Pod별로 수집한다. KEDA는 앱에 직접 접속하지 않고 Azure Monitor workspace를 조회한다. 클러스터 안에서 부하를 발생시키고 운영자는 Azure CLI와 kubectl로 결과를 대조한다.

**Tech Stack:** Python, LangGraph, FastAPI, prometheus-client, AKS, ACR, Azure Monitor managed service for Prometheus, KEDA, Bicep, PowerShell.

**Spec:** [승인된 설계](../specs/2026-11-20-langgraph-aks-keda-design.md)

## Global Constraints

- 단일 프로세스 Python Pod, 외부 모델·공개 인그레스·노드 자동 증설 없음.
- `AverageValue`, 목표 2 Run/Pod, 최소 1·최대 4 Pod. 기본·종료 상태에서 빈 응답은 0이 아니다.
- 유료 리소스 생성은 구독·리전·예상 비용·정리 대상에 대한 별도 승인 후에만 수행한다.

## Review Focus

- 실행 취소·예외로 Gauge가 남지 않는가 (작업 1).
- 구독·리소스 그룹이 다를 때 생성·정리가 차단되는가 (작업 2).
- 스크레이프 중복이 실행 6개를 12개로 보이게 하지 않는가 (작업 3).
- Azure 인증 오류나 빈 시계열이 확장·축소 성공으로 기록되지 않는가 (작업 3).
- 초기 Pod에서 실행 중인 Run을 새 Pod로 옮긴 것처럼 잘못 판정하지 않는가 (작업 4).

---

### 작업 1: 실행 중인 그래프 수를 노출하는 테스트 앱

**파일:** `app\main.py`, `app\requirements.txt`, `app\Dockerfile`, `tests\test_runs.py`. **인터페이스:** `POST /runs/{id}`는 비동기 실행을 등록하고 `202`를 반환한다. `DELETE /runs/{id}`는 해당 프로세스에서 실행을 해제하고 `204`를 반환한다. `GET /metrics`, `GET /ready` 제공.

- [ ] `test_six_real_runs`에서 그래프 대기 노드 진입 후 `assert gauge() == 6`, 모두 해제한 뒤 `assert gauge() == 0`을 검사한다. `test_cancel_and_error`에서 취소·예외 각각 종료 후에도 `assert gauge() == 0`을 검사한다.
- [ ] `python -m unittest discover -s tests -p test_runs.py` 실행 → 앱 부재로 실패 확인.
- [ ] 비동기 `StateGraph` 하나를 컴파일하고 `graph.ainvoke()` **전체**를 `agent_runs_active.track_inprogress()`로 감싼다. Run ID별 이벤트로 해제하고 15분 타임아웃으로 무한 대기를 방지한다. Gauge에는 Run ID 라벨을 넣지 않는다. 컨테이너는 Uvicorn worker 1개로 실행한다.
- [ ] 같은 테스트 명령 PASS 후 `feat: add instrumented LangGraph probe`로 커밋한다.

### 작업 2: 비용 승인과 격리된 Azure 인프라

**파일:** `infra\main.bicep`, `scripts\Lab.ps1`, `tests\Lab.Tests.ps1`. **인터페이스:** `Lab.ps1 -Action Preview|Create|Remove -SubscriptionId ... -Region ... -ResourceGroup ...`. 출력은 AKS 이름, ACR 로그인 서버, workspace 쿼리 URL, KEDA 조회용 identity client ID.

- [ ] Pester에서 현재 구독 불일치, 기존 비실험 그룹 재사용, 실험 태그 불일치 삭제 요청에 각각 `Should -Throw`를 지정한다. `Invoke-Pester .\tests\Lab.Tests.ps1`에서 실패를 확인한다.
- [ ] 고정 노드 풀, AKS의 OIDC·Workload Identity·KEDA·Managed Prometheus, workspace 수집 규칙과 AKS 연결, ACR 이미지 pull 권한을 구성한다. KEDA operator 서비스 계정용 federated credential 및 workspace 조회 역할은 실험 자원에만 부여한다.
- [ ] `az bicep build --file .\infra\main.bicep --stdout`과 Pester 통과를 확인한다. `Preview`는 생성하지 않고 SKU·노드 수·예상 유지시간·지역별 비용 항목을 제시한다. `Create`·`Remove`는 명시적으로 지정한 구독·전용 그룹만 다룬다. `feat: provision isolated AKS metrics lab`으로 커밋한다.

### 작업 3: Managed Prometheus 수집과 KEDA 트리거

**파일:** `k8s\workload.yaml`, `k8s\monitor.yaml`, `k8s\scaler.yaml`, `scripts\Deploy.ps1`, `tests\Metrics.Tests.ps1`. **입력:** 작업 2 출력과 작업 1 이미지. **출력:** `run-lab` 네임스페이스의 `agent-runtime` Deployment, Pod별 스크레이프, 인증된 KEDA ScaledObject.

- [ ] 쿼리 검증 테스트에 초기 Pod 고유 시계열 1개·값 0은 성공, 동일 Pod 시계열 2개·빈 결과·HTTP 403은 실패하도록 단언한다. `Invoke-Pester .\tests\Metrics.Tests.ps1`에서 실패 확인.
- [ ] Managed Prometheus의 `azmonitoring.coreos.com/v1` PodMonitor로 앱 포트의 `/metrics`를 한 번만 수집한다. 실제 cluster·namespace·앱 식별 라벨을 확인하고 **동일 Pod에 시계열이 하나인지** 원시 쿼리로 검증한다.
- [ ] KEDA의 Prometheus 쿼리를 해당 시계열의 `sum(...)` 하나로 한정한다. `AverageValue`, `threshold: "2"`, `ignoreNullValues: "false"`, `minReplicaCount: 1`, `maxReplicaCount: 4`와 Azure Workload Identity 인증을 지정한다. 합계가 비었을 때 `or vector(0)`으로 채우지 않는다.
- [ ] Pester PASS 후 `feat: wire managed metrics to KEDA`로 커밋한다. 실제 배포 시에는 부하 발생 전 workspace 원시 값 0과 `ScaledObject Ready=True` 둘 다 확인한다.

### 작업 4: 실험 실행·판정·정리

**파일:** `scripts\Verify.ps1`, `tests\Verify.Tests.ps1`, `README.md`. **입력:** 작업 1~3. **출력:** 각 관측 시각·지표·HPA·Ready·노드 수를 담은 로컬 결과 JSON과 성공/실패 종료 코드.

- [ ] 판정 테스트에서 `6 → desired=3 → ready=3` 중 Ready가 2로 끝나거나 초기 Pod가 재시작한 기록은 실패, `0/1 → 6/3 → 0/1` 및 노드 수 불변 기록은 성공으로 검사한다. `Invoke-Pester .\tests\Verify.Tests.ps1` 실패 확인.
- [ ] 클러스터 내부 테스트 클라이언트로 초기 Pod IP에 서로 다른 ID의 Run 6개를 등록한다. 재시작·노드 수를 감시하며 앱 로컬 6, workspace 6, HPA 희망 3, Ready 3을 각각 타임스탬프로 남긴다. 확장 판정 후 새 Pod IP로 별도 짧은 Run을 보내 로컬 Gauge 1 → 0을 확인한다.
- [ ] 초기 Pod IP로 원래 Run을 해제한다. workspace 값 0과 HPA·Ready 1을 확인한다. 각 전환이 5분 내 관측되지 않으면 기본 HPA 축소 안정화 시간을 고려해 **축소만 10분**까지 기다린다. 실패 시 workspace 쿼리, HPA·ScaledObject 상태, Pod 이벤트를 보존하고 비정상 종료한다.
- [ ] Pester PASS 후 `test: verify scale cycle and capture evidence`로 커밋한다. **Azure 생성 승인 후에만** Preview → Create → Deploy → Verify를 수행한다. 성공·실패와 관계없이 실험 전용 리소스를 정리하고 그룹 부재 및 생성했던 역할 할당 정리를 확인한다. 실제 실행 전에는 설계의 예상값을 관측값으로 보고하지 않는다.
