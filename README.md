# azure-documentdb-connection-test

Export-DocumentDbFailureMetrics.ps1 를 저장 후 powershell에서 다음을 실행합니다.

```
az login

.\Export-DocumentDbFailureMetrics.ps1 `
    -SubscriptionId '<subscription-id>' `
    -ResourceGroup '<resource-group>' `
    -ClusterName '<documentdb-cluster-name>' `
    -FailureUtc '2026-10-26T10:24:31Z'
```

FailureUtc 값에는 connection failure가 발생했던 실제 시각 정보를 입력합니다.

FailureUtc 등 필수 입력 정보를 생략하면 PowerShell이 필수 입력을 요청합니다.

```
Supply values for the following parameters:
SubscriptionId:
ResourceGroup:
ClusterName:
FailureUtc:
```

### 생성 결과
```
documentdb-metrics-20261026-102431/
├── 00-request-info.csv
├── 01-count-by-operation.csv
├── 02-count-by-status-code-class.csv
├── 03-errors-4xx-5xx.csv
├── 04-latency-sasl-start.csv
└── 05-latency-is-master.csv
```

각 파일의 내용은 다음과 같습니다.

| 파일 | 내용 |
|---|---|
| `00-request-info.csv` | 리소스, 실패 UTC, 실제 조회 범위 및 granularity |
| `01-count-by-operation.csv` | IsMaster, SaslStart, SaslContinue의 1분별 Count |
| `02-count-by-status-code-class.csv` | 2xx, 4xx, 5xx의 1분별 Count |
| `03-errors-4xx-5xx.csv` | 4xx/5xx의 ErrorCode, StatusText, Operation 상세 |
| `04-latency-sasl-start.csv` | SaslStart의 1분별 Average/Maximum 지연 |
| `05-latency-is-master.csv` | IsMaster의 1분별 Average/Maximum 지연 |

인증 방식이 OIDC여서 SaslStart가 없다면 해당 CSV는 헤더만 있고 데이터 행은 없는 상태로 생성됩니다.
