# AzAD-SDP-Sync

This is an integration project between AzuredAD and ManageEngine ServiceDesk Plus MSP.

The script gets the list of accounts from the SDP database, then gets the members of the groups listed in the AADGroups field.
AD users are matched with SDP users based on the AD user's email address and the SDP user's primary email address.
# Updates
- 13.07.2023

  If a User has membership in several Accounts we will only log warning about this case (instead of moving between accounts)
- 12.07.2023

  When a User is Disabled in AAD we will clear login and email-id attributes in SDP to avoid logging in
- 10.07.2023

  Script will sleep for "sleep time" every "batch size" requests to SDP. "Sleep time" and "batch size" are defined in me-integration-config.json

- 05.07.2023

  Get-SdpUserSQL added to find users in Sdp DB (By AAD Object ID).

  Phone and Mobile fields in Sdp have max 30 symbols limit.
  
