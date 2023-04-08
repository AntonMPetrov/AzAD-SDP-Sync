# AzAD-SDP-Sync

This is an integration project between AzuredAD and ManageEngine ServiceDesk Plus MSP.

The script gets the list of accounts from the SDP database, then gets the members of the groups listed in the AADGroups field.
AD users are matched with SDP users based on the AD user's email address and the SDP user's primary email address.
