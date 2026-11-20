BeforeAll { . "$PSScriptRoot\..\scripts\Common.ps1" }
Describe 'Measured per-pod series' {
    It 'accepts a measured zero, not an empty or duplicated series or a failed query' {
        $s = @{metric=@{pod='agent-runtime-a'}; value=@([DateTimeOffset]::UtcNow.ToUnixTimeSeconds(),'0')}
        (Measure-RunSeries @($s)) | Should -Be 0
        { Measure-RunSeries @() } | Should -Throw
        { Measure-RunSeries @($s,$s) } | Should -Throw
        Mock Invoke-RestMethod { throw '403' }
        { Read-RunSeries 'https://test.invalid' token query } | Should -Throw
    }
}
