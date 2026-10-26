<#
.SYNOPSIS
    Azure DocumentDB MongoRequestDurationMs 메트릭을 CSV로 추출합니다.

.DESCRIPTION
    지정한 connection failure UTC를 기준으로 전후 30분을 1분 단위로 조회하여
    다음 CSV 파일을 생성합니다.

    01-count-by-operation.csv
    02-count-by-status-code-class.csv
    03-errors-4xx-5xx.csv
    04-latency-sasl-start.csv
    05-latency-is-master.csv
    00-request-info.csv

.REQUIREMENTS
    - Azure CLI 설치
    - az login 완료
    - 대상 DocumentDB 리소스에 대한 Microsoft.Insights/metrics/read 권한
#>

[CmdletBinding()]
param(
    # Azure subscription ID
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$SubscriptionId,

    # DocumentDB resource group
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$ResourceGroup,

    # Azure DocumentDB cluster name
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$ClusterName,

    # Connection failure가 발생한 UTC
    # 반드시 2026-10-26T10:24:31Z 형식으로 입력
    [Parameter(Mandatory = $true)]
    [ValidatePattern(
        '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z$'
    )]
    [string]$FailureUtc,

    # 기본: 실패 시각 전후 각각 30분
    [ValidateRange(1, 720)]
    [int]$WindowMinutes = 30,

    # 생략하면 failure UTC를 사용하여 자동 생성
    [string]$OutputDirectory
)

$ErrorActionPreference = 'Stop'

# =============================================================================
# 입력 시각 및 출력 폴더
# =============================================================================

$failureTime = [datetimeoffset]::Parse(
    $FailureUtc,
    [System.Globalization.CultureInfo]::InvariantCulture,
    [System.Globalization.DateTimeStyles]::AssumeUniversal `
        -bor
    [System.Globalization.DateTimeStyles]::AdjustToUniversal
)

$startTime = $failureTime.AddMinutes(-$WindowMinutes)
$endTime = $failureTime.AddMinutes($WindowMinutes)

$failureIso = $failureTime.ToString('yyyy-MM-ddTHH:mm:ssZ')
$startIso = $startTime.ToString('yyyy-MM-ddTHH:mm:ssZ')
$endIso = $endTime.ToString('yyyy-MM-ddTHH:mm:ssZ')

if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $folderTimestamp = $failureTime.ToString('yyyyMMdd-HHmmss')
    $OutputDirectory = Join-Path `
        (Get-Location) `
        "documentdb-metrics-$folderTimestamp"
}

New-Item `
    -ItemType Directory `
    -Force `
    -Path $OutputDirectory |
    Out-Null

$OutputDirectory = (Resolve-Path $OutputDirectory).Path

Write-Host ''
Write-Host '============================================================'
Write-Host ' Azure DocumentDB metric export'
Write-Host '============================================================'
Write-Host "Failure UTC : $failureIso"
Write-Host "Start UTC   : $startIso"
Write-Host "End UTC     : $endIso"
Write-Host "Granularity : PT1M"
Write-Host "Output      : $OutputDirectory"
Write-Host '============================================================'
Write-Host ''

# =============================================================================
# Azure CLI 확인
# =============================================================================

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw 'Azure CLI가 설치되어 있지 않습니다.'
}

az account show --only-show-errors 1>$null 2>$null

if ($LASTEXITCODE -ne 0) {
    throw 'Azure CLI 로그인이 필요합니다. az login을 먼저 실행하십시오.'
}

az account set `
    --subscription $SubscriptionId `
    --only-show-errors

if ($LASTEXITCODE -ne 0) {
    throw "Azure subscription 선택에 실패했습니다: $SubscriptionId"
}

# =============================================================================
# DocumentDB resource ID 확인
# =============================================================================

$resourceId = az resource show `
    --subscription $SubscriptionId `
    --resource-group $ResourceGroup `
    --resource-type 'Microsoft.DocumentDB/mongoClusters' `
    --name $ClusterName `
    --query id `
    --output tsv `
    --only-show-errors

if (
    $LASTEXITCODE -ne 0 -or
    [string]::IsNullOrWhiteSpace($resourceId)
) {
    throw (
        "Azure DocumentDB cluster를 찾지 못했습니다. " +
        "Subscription=$SubscriptionId, " +
        "ResourceGroup=$ResourceGroup, " +
        "ClusterName=$ClusterName"
    )
}

$resourceId = $resourceId.Trim()

Write-Host "Resource ID: $resourceId"
Write-Host ''

# =============================================================================
# 공통 함수
# =============================================================================

function Invoke-DocumentDbMetricQuery {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Filter,

        [Parameter(Mandatory = $true)]
        [string[]]$Aggregations
    )

    $arguments = @(
        'monitor', 'metrics', 'list',
        '--resource', $resourceId,
        '--start-time', $startIso,
        '--end-time', $endIso,
        '--interval', 'PT1M',
        '--metrics', 'MongoRequestDurationMs',
        '--filter', $Filter,
        '--aggregation'
    )

    $arguments += $Aggregations

    $arguments += @(
        '--top', '10000',
        '--output', 'json',
        '--only-show-errors'
    )

    $rawOutput = & az @arguments 2>&1 | Out-String

    if ($LASTEXITCODE -ne 0) {
        throw (
            "Azure Monitor 조회에 실패했습니다.`n" +
            "Filter: $Filter`n" +
            $rawOutput
        )
    }

    if ([string]::IsNullOrWhiteSpace($rawOutput)) {
        return $null
    }

    try {
        return $rawOutput | ConvertFrom-Json
    }
    catch {
        throw (
            "Azure Monitor 결과를 JSON으로 해석하지 못했습니다.`n" +
            $_.Exception.Message
        )
    }
}

function Get-DimensionValue {
    param(
        $TimeSeries,

        [Parameter(Mandatory = $true)]
        [string]$DimensionName
    )

    $metadata = $TimeSeries.metadatavalues |
        Where-Object {
            $_.name.value -ieq $DimensionName -or
            $_.name.localizedValue -ieq $DimensionName
        } |
        Select-Object -First 1

    if ($null -eq $metadata) {
        return ''
    }

    return [string]$metadata.value
}

function Convert-MetricResponseToRows {
    param(
        $MetricResponse,

        [string[]]$Dimensions = @()
    )

    if ($null -eq $MetricResponse) {
        return @()
    }

    $rows = foreach ($metric in @($MetricResponse.value)) {
        foreach ($series in @($metric.timeseries)) {
            $dimensionValues = [ordered]@{}

            foreach ($dimension in $Dimensions) {
                $dimensionValues[$dimension] = Get-DimensionValue `
                    -TimeSeries $series `
                    -DimensionName $dimension
            }

            foreach ($point in @($series.data)) {
                $timestamp = (
                    [datetimeoffset]$point.timeStamp
                ).ToUniversalTime().ToString(
                    'yyyy-MM-ddTHH:mm:ssZ'
                )

                $row = [ordered]@{
                    TimestampUtc = $timestamp
                }

                foreach ($dimension in $Dimensions) {
                    $row[$dimension] = $dimensionValues[$dimension]
                }

                $countProperty = $point.PSObject.Properties['count']

                $row['Count'] = if (
                    $null -ne $countProperty -and
                    $null -ne $countProperty.Value
                ) {
                    [double]$countProperty.Value
                }
                else {
                    0
                }

                $row['AverageMs'] = if ($null -ne $point.average) {
                    [math]::Round(
                        [double]$point.average,
                        6
                    )
                }
                else {
                    $null
                }

                $row['MaximumMs'] = if ($null -ne $point.maximum) {
                    [math]::Round(
                        [double]$point.maximum,
                        6
                    )
                }
                else {
                    $null
                }

                [pscustomobject]$row
            }
        }
    }

    return @($rows)
}

function Export-CsvWithHeader {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string[]]$Columns,

        [object[]]$Rows = @()
    )

    $Rows = @($Rows)

    if ($Rows.Count -gt 0) {
        $Rows |
            Select-Object $Columns |
            Export-Csv `
                -Path $Path `
                -NoTypeInformation `
                -Encoding utf8
    }
    else {
        # 데이터가 없어도 CSV 파일과 header는 생성
        Set-Content `
            -Path $Path `
            -Value ($Columns -join ',') `
            -Encoding utf8
    }

    Write-Host (
        "Created: {0} ({1} row(s))" -f
        $Path,
        $Rows.Count
    )
}

# =============================================================================
# 00. 요청 정보
# =============================================================================

$requestInfoPath = Join-Path `
    $OutputDirectory `
    '00-request-info.csv'

$requestInfo = @(
    [pscustomobject]@{
        SubscriptionId = $SubscriptionId
        ResourceGroup = $ResourceGroup
        ClusterName = $ClusterName
        ResourceId = $resourceId
        FailureUtc = $failureIso
        StartUtc = $startIso
        EndUtc = $endIso
        WindowMinutesBefore = $WindowMinutes
        WindowMinutesAfter = $WindowMinutes
        TimeGranularity = 'PT1M'
        MetricName = 'MongoRequestDurationMs'
        ExportedUtc = (
            [datetimeoffset]::UtcNow.ToString(
                'yyyy-MM-ddTHH:mm:ssZ'
            )
        )
    }
)

Export-CsvWithHeader `
    -Path $requestInfoPath `
    -Columns @(
        'SubscriptionId',
        'ResourceGroup',
        'ClusterName',
        'ResourceId',
        'FailureUtc',
        'StartUtc',
        'EndUtc',
        'WindowMinutesBefore',
        'WindowMinutesAfter',
        'TimeGranularity',
        'MetricName',
        'ExportedUtc'
    ) `
    -Rows $requestInfo

# =============================================================================
# 01. Count by Operation
# =============================================================================

Write-Host ''
Write-Host 'Querying Count by Operation...' -ForegroundColor Cyan

$operationResponse = Invoke-DocumentDbMetricQuery `
    -Filter "Operation eq '*'" `
    -Aggregations @(
        'Count',
        'Average',
        'Maximum'
    )

$operationRows = @(
    Convert-MetricResponseToRows `
        -MetricResponse $operationResponse `
        -Dimensions @('Operation') |
        Where-Object {
            $_.Operation -in @(
                'IsMaster',
                'SaslStart',
                'SaslContinue'
            )
        } |
        Sort-Object TimestampUtc, Operation
)

Export-CsvWithHeader `
    -Path (
        Join-Path `
            $OutputDirectory `
            '01-count-by-operation.csv'
    ) `
    -Columns @(
        'TimestampUtc',
        'Operation',
        'Count'
    ) `
    -Rows $operationRows

# =============================================================================
# 02. Count by StatusCodeClass
# =============================================================================

Write-Host ''
Write-Host 'Querying Count by StatusCodeClass...' -ForegroundColor Cyan

$statusResponse = Invoke-DocumentDbMetricQuery `
    -Filter "StatusCodeClass eq '*'" `
    -Aggregations @('Count')

$statusRows = @(
    Convert-MetricResponseToRows `
        -MetricResponse $statusResponse `
        -Dimensions @('StatusCodeClass') |
        Where-Object {
            $_.StatusCodeClass -in @(
                '2xx',
                '4xx',
                '5xx'
            )
        } |
        Sort-Object TimestampUtc, StatusCodeClass
)

Export-CsvWithHeader `
    -Path (
        Join-Path `
            $OutputDirectory `
            '02-count-by-status-code-class.csv'
    ) `
    -Columns @(
        'TimestampUtc',
        'StatusCodeClass',
        'Count'
    ) `
    -Rows $statusRows

# =============================================================================
# 03. 4xx/5xx 상세
#
# 4xx와 5xx를 별도 조회한 뒤 하나의 CSV로 합친다.
# =============================================================================

Write-Host ''
Write-Host 'Querying 4xx/5xx details...' -ForegroundColor Cyan

$errorRows = foreach ($statusCodeClass in @('4xx', '5xx')) {
    $errorResponse = Invoke-DocumentDbMetricQuery `
        -Filter (
            "StatusCodeClass eq '$statusCodeClass' and " +
            "ErrorCode eq '*' and " +
            "StatusText eq '*' and " +
            "Operation eq '*'"
        ) `
        -Aggregations @(
            'Count',
            'Average',
            'Maximum'
        )

    Convert-MetricResponseToRows `
        -MetricResponse $errorResponse `
        -Dimensions @(
            'StatusCodeClass',
            'ErrorCode',
            'StatusText',
            'Operation'
        )
}

$errorRows = @(
    $errorRows |
        Where-Object {
            $_.Count -gt 0
        } |
        Sort-Object `
            TimestampUtc,
            StatusCodeClass,
            Operation,
            ErrorCode,
            StatusText
)

Export-CsvWithHeader `
    -Path (
        Join-Path `
            $OutputDirectory `
            '03-errors-4xx-5xx.csv'
    ) `
    -Columns @(
        'TimestampUtc',
        'StatusCodeClass',
        'ErrorCode',
        'StatusText',
        'Operation',
        'Count',
        'AverageMs',
        'MaximumMs'
    ) `
    -Rows $errorRows

# =============================================================================
# 04. SaslStart Average/Maximum latency
# =============================================================================

Write-Host ''
Write-Host 'Exporting SaslStart latency...' -ForegroundColor Cyan

$saslStartRows = @(
    $operationRows |
        Where-Object {
            $_.Operation -eq 'SaslStart'
        } |
        Select-Object `
            TimestampUtc,
            Operation,
            Count,
            AverageMs,
            MaximumMs |
        Sort-Object TimestampUtc
)

Export-CsvWithHeader `
    -Path (
        Join-Path `
            $OutputDirectory `
            '04-latency-sasl-start.csv'
    ) `
    -Columns @(
        'TimestampUtc',
        'Operation',
        'Count',
        'AverageMs',
        'MaximumMs'
    ) `
    -Rows $saslStartRows

# =============================================================================
# 05. IsMaster Average/Maximum latency
# =============================================================================

Write-Host ''
Write-Host 'Exporting IsMaster latency...' -ForegroundColor Cyan

$isMasterRows = @(
    $operationRows |
        Where-Object {
            $_.Operation -eq 'IsMaster'
        } |
        Select-Object `
            TimestampUtc,
            Operation,
            Count,
            AverageMs,
            MaximumMs |
        Sort-Object TimestampUtc
)

Export-CsvWithHeader `
    -Path (
        Join-Path `
            $OutputDirectory `
            '05-latency-is-master.csv'
    ) `
    -Columns @(
        'TimestampUtc',
        'Operation',
        'Count',
        'AverageMs',
        'MaximumMs'
    ) `
    -Rows $isMasterRows

# =============================================================================
# 완료
# =============================================================================

Write-Host ''
Write-Host '============================================================'
Write-Host ' Export complete' -ForegroundColor Green
Write-Host '============================================================'
Write-Host "Output directory: $OutputDirectory"
Write-Host ''
Write-Host 'Files:'
Write-Host '  00-request-info.csv'
Write-Host '  01-count-by-operation.csv'
Write-Host '  02-count-by-status-code-class.csv'
Write-Host '  03-errors-4xx-5xx.csv'
Write-Host '  04-latency-sasl-start.csv'
Write-Host '  05-latency-is-master.csv'
Write-Host ''
Write-Host (
    'Please send all CSV files in the output directory.'
) -ForegroundColor Yellow
