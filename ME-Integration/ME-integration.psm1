
# enable logging function
function Enable-MEIntegrationLogging() {
    if (-not (Get-Module -ListAvailable PSNlog)) {
        Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Scope CurrentUser -Force
        Install-Module PSNlog -Scope CurrentUser -Force
    } else {
        Import-Module PSNlog
        Enable-NLogLogging 
        Read-NLogConfiguration "$scriptPath\ME-integration-logging.config" | Set-NLogConfiguration
    }
}

function Get-AADCredeitials()
{
    return Import-Clixml $config.'AAD Cred file'
}

function Get-AADUsers()
{
    Param
    (
        [Parameter(Mandatory=$true, Position=0)]
        [string] $GroupName
    )
    $group = Get-AzureADGroup -SearchString $GroupName
    if (-not [String]::IsNullOrWhiteSpace($group))
    {

        $members = Get-AzureADGroupMember -ObjectId $group.ObjectId -All:$true
    }
    else
    { 
        $members = $null
    }
    return $members
}



function Get-SdpUserSQL(){
    Param
    (
        [Parameter(Mandatory=$true, Position=0)]
        [string] $userEmail,
        [Parameter(Position=1)]
        [string] $AADUserID
    )
    if ([String]::IsNullOrWhiteSpace($userEmail)) {throw "Empty Email"}
    
    $header = @{authtoken=$config.'service desk api key'}
    
    $query = "
    select
	    aaauser.USER_ID
    from aaauser
        inner join AaaLogin on aaauser.USER_ID = aaalogin.USER_ID
        left join AaaUserContactInfo on aaauser.USER_ID = AaaUserContactInfo.USER_ID
        left join AaaContactInfo on AaaUserContactInfo.CONTACTINFO_ID = AaaContactInfo.CONTACTINFO_ID
        left join UserAdditionalFields on aaauser.USER_ID = UserAdditionalFields.INSTANCE_ID
	where Aaalogin.name = '$($userEmail)' or AaaContactInfo.EMAILID = '$($userEmail)' or ('$($AADUserID)' is not null and [UserAdditionalFields].UDF_CHAR3 = '$($AADUserID)')
    "
    try
    {
        $SdpUserId = Invoke-Sqlcmd -ServerInstance $config.'SDP DB Server' -Database $config.'SDP DB Name' -Query $query
    }
    catch
    {
         $errorMessage = $_
        Write-Error $errorMessage
        $logValue = "{0}`t {1}`t {2}" -f (Get-Date).ToString("dd-MM-yyyy hh:mm:ss.mm"), $errorMessage
        Add-Content -Path $config.'sync errors log file' -Value $logValue
        throw $errorMessage
    }

    if ($SdpUserId -is [system.array] )
    {
        $errorMessage = "There are more than one user in SDP wth the same email $($userEmail) or AadUserID $($AadUserID)"
        throw $errorMessage
    }

    if ($null -ne $SdpUserId.USER_ID)
    {
        Write-Verbose "User with email '$($userEmail)' found. SDP id is $($SdpUserId.USER_ID)"   
        $url = $config.'service desk api url' + "/api/v3/users/$($SdpUserId.USER_ID)"
        while($true)
        {
            try
            {
                $response = Invoke-RestMethod -Uri $url -Headers $header  -Method get 
                $sdpUser = $response.user
                break
            }
            catch
            {
                $errorMessage = $_
                Write-Error $errorMessage
                $logValue = "{0}`t SdpUser: {1}`t {2}" -f (Get-Date).ToString("dd-MM-yyyy hh:mm:ss.mm"), $sdpUser.id, $errorMessage
                Add-Content -Path $config.'sync errors log file' -Value $logValue
                if ($errorMessage -contains "URL blocked as maximum access limit for the page is exceeded") 
                {
                    Write-Verbose $("Pausing for " + $config.'sleep time' + " seconds")
                    Start-Sleep -Seconds $config.'sleep time'
                    continue
                }
                break
            }
        }
    }
    else {
        Write-Verbose "User with email '$userEmail' or AADUser ID '$($AadUserID)' not found."
    }

    return $sdpUser
}

function Get-SdpUser(){
    Param
    (
        [Parameter(Mandatory=$true, Position=0)]
        [string] $userEmail
    )

    if ([String]::IsNullOrWhiteSpace($userEmail)) {throw "Empty Email"}
    _prepareSdpRequest

    #Search users in SDP by Primary email

    $encodedEmail = [System.Web.HttpUtility]::UrlEncode($userEmail)
    $url = $config.'service desk api url' + "/api/v3/users?input_data={""list_info"": {""search_fields"": {""email_id"": ""$encodedEmail""}}}"
    Write-Verbose "The service desk request url is '$url'"
    $header = @{authtoken=$config.'service desk api key'}
    Write-Verbose "Send request to SDP"
    try
    {
        $response = Invoke-RestMethod -Uri $url -Headers $header  -Method get 
    }
    catch
    {
        $errorMessage = $_
        Write-Error $errorMessage
        $logValue = "{0}`t {1}" -f (Get-Date).ToString("dd-MM-yyyy hh:mm:ss.mm"), $errorMessage
        Add-Content -Path $config.'sync errors log file' -Value $logValue
    }

    Write-Verbose "Response is $response"
    $sdpUser = $response| Select -ExpandProperty users

    <#
        if we found more than one SDPUuser with the same email - throw exception and go to next user,
        because this case should be resolved manually (merge or delete duplicated users)
    #>
    if ($sdpUser -is [system.array])
    {
        $errorMessage = "There are more than one user in SDP wth the same email $($userEmail)"
        throw $errorMessage
    }

    if ($null -ne $sdpUser){
        Write-Verbose "User with email '$userEmail' found. SDP id is $($sdpUser.id)"

        $url = $config.'service desk api url' + "/api/v3/users/$($sdpUser.id)"
        try
        {
            $response = Invoke-RestMethod -Uri $url -Headers $header  -Method get 
            $sdpUser = $response.user
        }
        catch
        {
            $errorMessage = $_
            Write-Error $errorMessage
            $logValue = "{0}`t SdpUser: {1}`t {2}" -f (Get-Date).ToString("dd-MM-yyyy hh:mm:ss.mm"), $sdpUser.id, $errorMessage
            Add-Content -Path $config.'sync errors log file' -Value $logValue
        }
        
    }
    else {
        Write-Verbose "User with email '$userEmail' not found."
    }


    return $sdpUser
}

function Compare-Users()
{
    Param(
    [Parameter(Mandatory=$true, Position=0)]
    $SdpUser,
    [Parameter(Mandatory=$true, Position=1)]
    $AADUser,
    [Parameter(Mandatory=$true, Position=2)]
    $SdpAccount
)
    Add-Type -AssemblyName System.Web
      
    $updateUser = @{user=(New-Object -TypeName PSObject) }

    #if user disabled in AAD - let's disable him in SDP by clearing login_name
    if (-not $aadUser.AccountEnabled)
    {
        Write-Verbose "The user $($sdpUser.email_id) will be blocked in SDP"
        $updateUser.user | Add-Member @{login_name = $null}
        $updateUser.user | Add-Member @{email_id = $null}
    }
    else
    {
        #if user enabled in AAD, but has no login name in SDP - let's enable him in SDP
        if ([string]::IsNullOrWhiteSpace($SdpUser.login_name))
        {
            $updateUser.user | Add-Member @{login_name = $AADUser.Mail}
            #Set Password
            $updateUser.user | Add-Member @{password = ([System.Web.Security.Membership]::GeneratePassword(10,2))}

        }
        if ($aadUser.Mail -ne $sdpUser.email_id)
        {
            $updateUser.user | Add-Member @{email_id = $aadUser.Mail}   
        }
        if($aadUser.GivenName -ne $sdpUser.first_name) 
        {
            $updateUser.user | Add-Member @{first_name = $aadUser.GivenName}   
        }
        if ($aadUser.Surname -ne $sdpUser.last_name)
        {
            $updateUser.user | Add-Member @{last_name = $aadUser.Surname}
        }
        if ($aadUser.DisplayName -ne $sdpUser.name)
        {
            $updateUser.user | Add-Member @{name = $aadUser.DisplayName}
        }
        if ($aadUser.TelephoneNumber -ne $sdpUser.phone)
        {
            if (-not [string]::IsNullOrWhiteSpace($aadUser.TelephoneNumber))
            {
                $updateUser.user | Add-Member @{phone = $aadUser.TelephoneNumber.Substring(0,30)}
            }
            else 
            {
                $updateUser.user | Add-Member @{phone = $null}
            }
        }
        if ($aadUser.Mobile -ne $sdpUser.mobile)
        {
            if (-not [string]::IsNullOrWhiteSpace($aadUser.Mobile))
            {
                $updateUser.user | Add-Member @{mobile = $aadUser.Mobile.Substring(0,30)}
            }
            else
            {
                $updateUser.user | Add-Member @{mobile = $null}
            }
        }
        if ($aadUser.JobTitle -ne $sdpUser.jobtitle)
        {
            $updateUser.user | Add-Member @{jobtitle = $aadUser.JobTitle}
        }
    
        if ($aadUser.OtherMails -ne $sdpUser.secondary_emailids)
        {
            $updateUser.user | Add-Member @{secondary_emailids = $aadUser.OtherMails}
        }
        #External AADlogin ID
        if($aadUser.ObjectId -ne $sdpUser.user_udf_fields.udf_sline_317)
        {
            $updateUser.user | Add-Member @{user_udf_fields = New-Object -TypeName PSObject}
            $updateUser.user.user_udf_fields | Add-Member @{udf_sline_317 = $aadUser.ObjectId}
        }
        #if SDP user not in current Account - let's move him to it
        if ($SdpUser.account.id -ne $SdpAccount.AccountId -and $SdpUser.is_technician -ne $true)
        {
            $updateUser.user | Add-Member @{department = New-Object -TypeName psobject}
            $updateUser.user.department | Add-Member @{id = $SdpAccount.DEPTID}
        }
    }
    
    #if SDPUser has updates - we should update Last sync date
    if (-not [String]::IsNullOrWhiteSpace($updateUser.user))
    {
        if ($null -eq $updateUser.user.user_udf_fields)
        {
            $updateUser.user | Add-Member @{user_udf_fields = New-Object -TypeName PSObject}  
        }
              
        $DateTime = Get-Date
        
        $unixDate= ([DateTimeOffset]$DateTime).ToUnixTimeSeconds()
       
        #SDP uses 13-digit unixtime
        if ($unixDate.ToString().Length -eq 10) {$unixDate*=1000}
        elseif ($unixDate.ToString().Length -eq 11) {$unixDate*=100}
        elseif ($unixDate.ToString().Length -eq 12) {$unixDate*=10}
        
        $updateUser.user.user_udf_fields | Add-Member @{udf_date_320 = New-Object -TypeName psobject}
        $updateUser.user.user_udf_fields.udf_date_320 | Add-Member -Name "value" -Value $unixDate -MemberType NoteProperty
 
    }

    # if SdpUser has updates - change Source to AAD LTS
    if (-not [string]::IsNullOrWhiteSpace( $updateUser.user))
    {
        if ($null -eq $updateUser.user.user_udf_fields)
        {
            $updateUser.user | Add-Member @{user_udf_fields=New-Object -TypeName PSObject}  
        }
        $updateUser.user.user_udf_fields | Add-Member @{udf_pick_316 = "AAD LTS"}
    }
  
    return $updateUser
}

function Update-SdpUser()
{
    Param
    (
        [Parameter(Mandatory=$true, Position=0)]
        $UserId,
        [Parameter(Mandatory=$true, Position=1)]
        $UpdateUser
    )
    _prepareSdpRequest

    $url = $config.'service desk api url' + "/api/v3/users/$($UserId)"
    $header = @{authtoken=$config.'service desk api key'}
    $data = @{input_data=($UpdateUser| ConvertTo-Json -Depth 3);format='json'}
   
    try
    {
        $response =  Invoke-RestMethod -Uri $url -Method put -Body $data -Headers $header -ContentType "application/x-www-form-urlencoded"
        if ($response.response_status.status_code -eq 2000)
        {
            Write-Verbose "Attributes for the user $($sdpUser.email_id) were successfully updated in SDP"
        }
        else
        {
            $errorMessage = "Updating user was failed with $($response.response_status.messages)"
            $logValue = "{0}`t SdpUser: {1}`t {2}" -f (Get-Date).ToString("dd-MM-yyyy hh:mm:ss.mm"), $UserId, $errorMessage
            Add-Content -Path $config.'sync errors log file' -Value $logValue
        }
    }
    catch
    {
        $errorMessage = $_
        Write-Error $errorMessage
        $logValue = "{0}`t SdpUser: {1}`t {2}" -f (Get-Date).ToString("dd-MM-yyyy hh:mm:ss.mm"), $UserId, $errorMessage
        Add-Content -Path $config.'sync errors log file' -Value $logValue
    }
        
    return $response
}


function New-SdpUser()
{
    Param
    (
        [Parameter(Mandatory=$true, Position=0)]
        $AzureUser,
        [Parameter(Mandatory=$false, Position=1)]
        $DeptId
    )
    Add-Type -AssemblyName System.Web
    $createUser = @{user=(New-Object -TypeName PSObject) }
    #First Name
    $createUser.user | Add-Member @{first_name=$AzureUser.GivenName}   
    #Last Name
    $createUser.user | Add-Member @{last_name=$AzureUser.Surname}
    #Display Name
    $createUser.user | Add-Member @{name=$AzureUser.DisplayName}
    #Phone
    if (-not [string]::IsNullOrWhiteSpace($AzureUser.TelephoneNumber))
    {
        $createUser.user | Add-Member @{phone=$AzureUser.TelephoneNumber.SubString(0,30)}
    }
    #Mobile
    if (-not [string]::IsNullOrWhiteSpace($AzureUser.Mobile))
    {
        $createUser.user | Add-Member @{mobile=$AzureUser.Mobile.Substring(0,30)}
    }
    #JobTitle
    $createUser.user | Add-Member @{jobtitle=$AzureUser.JobTitle}
    #Secondary Emails
    $createUser.user | Add-Member @{secondary_emailids=$AzureUser.OtherMails}
    #Login Name
    $createUser.user | Add-Member @{login_name=$AzureUser.Mail}
    #Email Id
    $createUser.user | Add-Member @{email_id = $AzureUser.Mail}
    
    #Udf Fields
    $createUser.user | Add-Member @{user_udf_fields=New-Object -TypeName PSObject}
    #Source
    $createUser.user.user_udf_fields | Add-Member @{udf_pick_316 = "AAD LTS"}
    #External AAD login ID
    $createUser.user.user_udf_fields | Add-Member @{udf_sline_317 = $AzureUser.ObjectId}

    $DateTime = Get-Date
    $unixDate= ([DateTimeOffset]$DateTime).ToUnixTimeSeconds()

    #SDP uses 13-digit unixtime
    if ($unixDate.ToString().Length -eq 10) {$unixDate*=1000}
    elseif ($unixDate.ToString().Length -eq 11) {$unixDate*=100}
    elseif ($unixDate.ToString().Length -eq 12) {$unixDate*=10}
    #Last sync day
    $createUser.user.user_udf_fields | Add-Member @{udf_date_320 = New-Object -TypeName psobject}
    $createUser.user.user_udf_fields.udf_date_320 | Add-Member -Name "value" -Value $unixDate -MemberType NoteProperty

    #Department
    #$department = Get-SdpDepartment($AzureUser)
    if (-not [string]::IsNullOrWhiteSpace($DeptId))
    {
        $createUser.user | Add-Member @{department = New-Object -TypeName psobject}
        $createUser.user.department | Add-Member @{id = $DeptId}
    }
    #Password
    $createUser.user | Add-Member @{password = ([System.Web.Security.Membership]::GeneratePassword(10,2))}


    _prepareSdpRequest

    $url = $config.'service desk api url' + "/api/v3/users"
    $header = @{authtoken=$config.'service desk api key'}
    $data = @{input_data=($createUser| ConvertTo-Json -Depth 3);format='json'}
   
    try
    {
        $response =  Invoke-RestMethod -Uri $url -Method Post -Body $data -Headers $header -ContentType "application/x-www-form-urlencoded"
        if ($response.response_status.status_code -eq 2000)
        {
            Write-Verbose "The user $($AzureUser.Mail) was successfully created in SDP with ID $($response.user.id) in $($response.user.account.name) account"
        }
        else
        {
            $errorMessage = "Creating user in SDP was failed with $($response.response_status.messages)"
            Write-Error $errorMessage
            $logValue = "{0}`t AzureUser: {1}`t {2}" -f (Get-Date).ToString("dd-MM-yyyy hh:mm:ss.mm"), $AzureUser.Mail, $errorMessage
            Add-Content -Path $config.'sync errors log file' -Value $logValue
           
            
        }
    }
    catch
    {
        $errorMessage = $_
        Write-Error $errorMessage
        $logValue = "{0}`t AzureUser: {1}`t {2}" -f (Get-Date).ToString("dd-MM-yyyy hh:mm:ss.mm"), $AzureUser.Mail, $errorMessage
        Add-Content -Path $config.'sync errors log file' -Value $logValue
        
    }
    
    return $response
 
}

function Get-SdpAccounts()
{
        
    $query = "SELECT account.ATTRIBUTE_312 AS AADGroups, 
 cisite.NAME AS Site, 
 ad.ORG_NAME AS Account,
 ad.ORG_ID as AccountID,
dep.DEPTNAME,
dep.DEPTID
FROM AccountCI account 
LEFT JOIN BaseElement as baseci ON account.CIID = baseci.CIID 
LEFT JOIN CI as ci ON baseci.CIID = ci.CIID 
LEFT JOIN SDOrganization cisite ON ci.SITEID = cisite.ORG_ID 
LEFT JOIN AccountSiteMapping asm ON ci . SITEID = asm.SITEID 
LEFT JOIN AccountDefinition ad ON asm.ACCOUNTID = ad.ORG_ID
Left join DepartmentDefinition as Dep on CI.SITEID = Dep.SITEID and Dep.DEPTNAME like '%Common Dept.'
where account.ATTRIBUTE_312 is not null"
    
    try
    {
        $SdpAccounts = Invoke-Sqlcmd -ServerInstance $config.'SDP DB Server' -Database $config.'SDP DB Name' -Query $query
    }
    catch
    {
        $errorMessage = $_
        Write-Error $errorMessage
        $logValue = "{0}`t {1}`t {2}" -f (Get-Date).ToString("dd-MM-yyyy hh:mm:ss.mm"), $errorMessage
        Add-Content -Path $config.'sync errors log file' -Value $logValue
        throw $errorMessage

    }

    return $SdpAccounts
}

function _prepareSdpRequest() {
    # check required config params
    if ($null -eq $config.'service desk api url' -or $null -eq $config.'service desk api key') {
        $errorMessage = "Unable to find 'service desk api url' or/and 'service desk api key' property in the config file."
        Write-Error $errorMessage
        throw $errorMessage
    }
    # disable certificate validation
    #[System.Net.ServicePointManager]::ServerCertificateValidationCallback = {$true}
}

function _EncodeTo-DecimalUnicode($string) {
    [RegEx]::Replace($string, '\P{IsBasicLatin}', { param($match) '&#{0};' -f [int][char]$match.Value })
}

function getConfig() {
    # load config file
    $configPath = $scriptPath + "\me-integration-config.json"
    Write-Verbose "Load config file - $configPath"
    $config = Get-Content -Raw -Path $configPath | ConvertFrom-Json
    return $config
}
# get script path
if ($PSScriptRoot) { $scriptPath = $PSScriptRoot } else { $scriptPath = $pwd.Path }
# enable logging on module loading
Enable-MEIntegrationLogging
$iam = whoami
#chcp 1251
Write-Verbose "Running under $iam"
Write-Verbose "Encoding is $([Console]::OutputEncoding.EncodingName)"

# load config file
$config = getConfig

Export-ModuleMember -Function New-SdpUser
Export-ModuleMember -Function Get-SdpAccounts
Export-ModuleMember -Function Update-SdpUser
Export-ModuleMember -Function Compare-Users
Export-ModuleMember -Function Get-SdpUser
Export-ModuleMember -Function Get-SdpUserSQL
Export-ModuleMember -Function Get-AADCredeitials
Export-ModuleMember -Function Get-AADUsers
Export-ModuleMember -Function getConfig