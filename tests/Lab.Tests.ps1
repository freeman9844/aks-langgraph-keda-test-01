BeforeAll { . "$PSScriptRoot\..\scripts\Common.ps1" }
Describe 'Lab ownership' {
    It 'allocates a distinct group for each experiment with the same prefix' {
        (New-LabGroupName 'rg-runlab-demo') | Should -Not -Be (New-LabGroupName 'rg-runlab-demo')
    }
    It 'allows a new group only in the selected subscription' {
        Assert-LabTarget Create sub sub $false $null id
        { Assert-LabTarget Create sub other $false $null id } | Should -Throw
    }
    It 'never adopts existing groups or removes an unowned group' {
        { Assert-LabTarget Create sub sub $true id id } | Should -Throw
        { Assert-LabTarget Remove sub sub $true other id } | Should -Throw
        Assert-LabTarget Remove sub sub $true id id
    }
}
