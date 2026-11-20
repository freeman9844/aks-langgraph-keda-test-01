BeforeAll { . "$PSScriptRoot\..\scripts\Common.ps1" }
Describe 'Scale cycle evidence' {
    It 'forwards exec separator as an argument and probes a distinct pod' {
        $argv = @(Get-ProbeArgs 'http://10.0.0.5:8000/metrics' GET)
        $argv[4] | Should -Be '--'
        $a = @{metadata=@{uid='a'}}
        $b = @{metadata=@{uid='b'}}
        (Select-NewPod @($a,$b) 'a').metadata.uid | Should -Be 'b'
        { Select-NewPod @($a) 'a' } | Should -Throw
    }
    It 'requires both desired and ready to match the measured demand' {
        foreach ($p in @(@(0,1),@(6,3),@(0,1))) {
            (Test-Phase $p[0] $p[1] $p[1] $p[0] $p[1]) | Should -BeTrue
        }
        (Test-Phase 6 3 2 6 3) | Should -BeFalse
    }
    It 'rejects a node change or original pod restart during load' {
        { Assert-Stable 'a,b' 'a,c' 0 } | Should -Throw
        { Assert-Stable 'a,b' 'a,b' 1 } | Should -Throw
    }
}
