Import-Module .\me-integration.psm1 -Force

# load config file
$config = getConfig

$cred = Get-AADCredeitials

try
{
    Write-Verbose "Connecting to AzureAD"
    Connect-AzureAD -Credential $cred
}
catch
{
    $errorMessage = $_
    Write-Error $errorMessage
    $logValue = "{0}`t{1}" -f (Get-Date).ToString("dd-MM-yyyy hh:mm:ss.mm"), $errorMessage
    Add-Content -Path $config.'sync errors log file' -Value $logValue
    throw $errorMessage
}

Write-Verbose "Fetching SDP Accounts"
$sdpAccounts = Get-SdpAccounts

#iterating by accounts
foreach ($sdpAccount in $sdpAccounts)
{
    Write-Verbose "Fetching members of $($sdpAccount.Account) groups"

    foreach ($aadUser in $sdpAccount.AADGroups.Split(";") | ForEach-Object{Get-AADUsers -GroupName $_} )
    {
        $sdpUser=$null
        $count ++
        if (($count % $config.'batch size') -eq 0) {
            Write-Verbose $("Pausing for " + $config.'sleep time' + " seconds")
            Start-Sleep -Seconds $config.'sleep time'
        }
        
        #AADUsers with enmpty emails should be skipped
        if ([string]::IsNullOrWhiteSpace($aadUser.Mail))
        {
            Write-Verbose "The user $($aadUser.DisplayName) with ObjectID: $($aadUser.ObjectId) has empty email. User skipped."
        }
        elseif([string]::IsNullOrWhiteSpace($aadUser.Department) -and [string]::IsNullOrWhiteSpace($aadUser.UsageLocation) -and [string]::IsNullOrWhiteSpace($aadUser.CompanyName))
        {
            Write-Verbose "The user $($aadUser.DisplayName) with ObjectID: $($aadUser.ObjectId) has empty Department, UsageLocation and CompanyName. This is probably a service account. Skipped"
        }
        else
        
        {
            try
            { 
                $sdpUser  = Get-SdpUserSQL -userEmail $aadUser.Mail -AADUserID $aadUser.ObjectId
            }
            catch
            {
                $errorMessage = $_
                Write-Error $errorMessage
                $logValue = "{0}`t{1}" -f (Get-Date).ToString("dd-MM-yyyy hh:mm:ss.mm"), $errorMessage
                Add-Content -Path $config.'sync errors log file' -Value $logValue
                continue

            }
            #if user in SDP tagged as "Excluded from sync"
            if ($sdpUser.user_udf_fields.udf_pick_2701.name -eq "Yes")
            {
                Write-Verbose "The user $($sdpUser.email_id) tagged as not updatable in SDP."
                continue
            }
            #SDP User found, we will compare and update him if required
            if ($null -ne $sdpUser)
            {
                $updateUser = Compare-Users -aadUser $aadUser -sdpUser $sdpUser -SdpAccount $sdpAccount
                if (-not [string]::IsNullOrWhiteSpace( $updateUser.user))
                {
                    Write-Verbose "The user $($sdpUser.email_id) will be updated with following attributes $($updateUser | ConvertTo-Json -Depth 3)"
                    $result = Update-SdpUser -UpdateUser $updateUser -UserId $sdpUser.id
        
                }
                else
                {
                    Write-Verbose "The user $($sdpUser.email_id) has the same attributes in AAD and SDP. Nothing to update"
                }
            }
            #SDP user not found, we will create him if required
            else
            {
                if ($aadUser.AccountEnabled)
                {
                    Write-Verbose "User $($aadUser.Mail) will be created in SDP"
                    $resp = New-SdpUser -AzureUser $aadUser -DeptId $sdpAccount.DEPTID
                }
                else
                {
                    Write-Verbose "User $($aadUser.Mail) is disabled in AAD, we will not create an account for him in SDP."
                }
            }
        }
    }
}

Disconnect-AzureAD