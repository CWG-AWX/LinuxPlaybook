# Checkmk Local Check: Windows Password Expiration$WarningDays = 7$CriticalDays = 0# Get all local users who are enabled and have a password that expires$users = Get-LocalUser | Where-Object { $_.Enabled -eq $true -and $_.PasswordExpires -ne $null }
foreach ($user in $users) {
    $expiryDate = $user.PasswordExpires
    $daysLeft = ($expiryDate - (Get-Date)).Days
    $userName = $user.Name

    if ($daysLeft -le $CriticalDays) {
        $state = 2$statusText = "CRITICAL"    } elseif ($daysLeft -le $WarningDays) {
        $state = 1$statusText = "WARNING"    } else {
        $state = 0$statusText = "OK"
    }

    Write-Host "$state PasswordExpiry_$userName days_left=$daysLeft $statusText: Password for $userName expires in $daysLeft days"
}
 
