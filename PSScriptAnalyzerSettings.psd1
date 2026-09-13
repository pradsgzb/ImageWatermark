@{
    # Default analyzer rules, with public command semantics tested separately.
    Severity = @('Error', 'Warning')
    ExcludeRules = @(
        # New-* helpers only construct in-memory plans/tiles. External writes
        # live beneath the public script's ShouldProcess gate, tested with WhatIf.
        'PSUseShouldProcessForStateChangingFunctions'
    )
}
