@{
    Severity     = @('Error', 'Warning')
    ExcludeRules = @(
        'PSAvoidUsingWriteHost',                 # console tool: colored bilingual output is intended
        'PSUseShouldProcessForStateChangingFunctions',
        'PSUseSingularNouns',
        'PSAvoidUsingPositionalParameters',
        'PSUseBOMForUnicodeEncodedFile',         # checked by tests\Test-Parse.ps1 instead
        'PSReviewUnusedParameter'                # false positives: parameters used inside scriptblocks / event args
    )
    Rules = @{
        PSUseCompatibleSyntax = @{ Enable = $true; TargetVersions = @('5.1', '7.0') }
    }
}
