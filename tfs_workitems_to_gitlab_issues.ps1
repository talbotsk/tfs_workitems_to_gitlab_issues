# TODO Links to Changesets?
# TODO Description changes in History?
#   https://learn.microsoft.com/en-us/previous-versions/azure/devops/integrate/previous-apis/wit/reporting-work-item-revisions?view=tfs-2017
#   https://learn.microsoft.com/en-us/previous-versions/azure/devops/integrate/previous-apis/wit/revisions?view=tfs-2017
#   http://tfs1:8080/tfs/TFSProjectCollection/_apis/wit/workItems/12715/revisions
#   http://tfs1:8080/tfs/TFSProjectCollection/_apis/wit/workItems/12715?api-version=2.1&$expand=all
#   http://tfs1:8080/tfs/TFSProjectCollection/_apis/wit/workItems/12715/history?api-version=2.1&$expand=all

###########################################
# Migrate TFS work items to GitLab Issues #
###########################################

# Prerequisites:
# 1. Install Node.js
# 2. Install TFS CLI (npm install -g tfx-cli@0.6.4 not https://www.npmjs.com/package/tfx-cli due to error "Failed to find api location for area: Location id")
# 3. Install gitlab cli (https://gitlab.com/gitlab-org/cli/-/releases)
# 4. Set GitLab Host/Configuration in c:\Users\USER\.config\glab-cli\config.yml
# 5. create a label for EACH work item type that is being migrated (as lower case)
#      - ie: "user story", "bug", "task", "issue"
# 6. define under what area path you want to migrate
#      - You can modify the WIQL if you want to use a different way to migrate work items, such as [TAG] = "migrate"
# 7. Use PowerShell 5.1

# How to run:
# ./tfs_workitems_to_gitlab_issues.ps1 -tfs_username "xxx" -tfs_password "***" -tfs_url "http://tfs:8080/tfs/TFSProjectCollection" -tfs_project "TailWindTraders" -tfs_team "TailWindTraders Team" -tfs_area_path "TailWindTraders\AREA_PATH_LEVEL_1\AREA_PATH_LEVEL_2\..." -tfs_migrate_closed_workitems $true -tfs_production_run $true -gl_group "MainGroup" -gl_project "MyProject" -gl_update_assigned_to $true -gl_assigned_to_user_suffix "" -gl_add_tfs_comments $true -gl_host https://git -gl_pat xxx

#
# Things it migrates:
# 1. Title
# 2. Description (or repro steps + system info for a bug)
# 3. State (if the work item is done / closed, it will be closed in GitLab)
# 4. It will try to assign the work item to the correct user in GitLab - based on TFS email (-gl_update_assigned_to and -gl_assigned_to_user_suffix options) - they of course have to be in GitLab already
# 5. Migrate acceptance criteria as part of issue body (if present)
# 6. Adds in the following as a comment to the issue:
#   a. Original work item url
#   b. Basic details in a expanded markdown table
#   c. Entire work item as JSON in a collapsed section
#   d. History comments
#   e. Attachments
# 7. Creates tag "copied-to-gitlab" and a history on the TFS work item with `-$tfs_production_run $true` . The tag prevents duplicate copying.
#

#
# Things it won't ever migrate:
# 1. Created date/update dates
#

#region CmdletBinding

[CmdletBinding()]
param (
    # [string]$tfs_pat, # TODO TFS PAT used for TFS 2017 https://stackoverflow.com/a/35101750/1145859
    [string]$tfs_username, # TFS username used for TFS 2015 https://stackoverflow.com/a/35101750/1145859
    [string]$tfs_password, # TFS password used for TFS 2015 https://stackoverflow.com/a/35101750/1145859 #TODO Use [SecureString] type for password
    [string]$tfs_url, # TFS URL, eg: "http://tfs:8080/tfs/TFSProjectCollection"
    [string]$tfs_project, # Project name that contains the work items, eg: "TailWindTraders"
    [string]$tfs_team, # Team name that contains the work items, eg: "TailWindTraders Team"
    [string]$tfs_area_path, # Area path in TFS to migrate; uses the 'UNDER' operator)
    [bool]$tfs_migrate_closed_workitems = $true, # migrate work items with the state of done, closed, resolved, and removed
    [bool]$tfs_production_run = $false, # tag migrated work items with 'migrated-to-gitlab' and add discussion comment
    [string]$tfs_regex_user_unique_name = '[\w-\.]+(?=\>)', # Regex used to extract user unique name https://stackoverflow.com/questions/201323/how-can-i-validate-an-email-address-using-a-regular-expression
    [string]$tfs_regex_user_display_name = '.*(?=\s*\<)', # Regex used to extract user display name
    [string]$tfs_rest_api_version = 'api-version=2.1', # http://tfs1:8080/tfs/_home/About "Version 14.0.24712.0" https://learn.microsoft.com/sk-sk/archive/blogs/tfssetup/what-version-of-team-foundation-server-do-i-have "TFS 2015 Update 1	2.1" https://learn.microsoft.com/en-us/previous-versions/azure/devops/integrate/previous-apis/overview?view=tfs-2017#api-and-tfs-version-mapping

    [string]$gl_host, # GitLab host, eg: "https://git" or "https://git.domain"
    [string]$gl_pat, # GitLab PAT (Personal Access Token). Note: PAT works only for TFS 2017 and above. Basic authentification is needed for TFS 2015. https://stackoverflow.com/a/35101750/1145859
    [string]$gl_group, # GitLab project group, eg: "MainGroup" part of https://gitlab/MainGroup/MyProject
    [string]$gl_project, # GitLab project name, eg: "MyProject" part of https://gitlab/MainGroup/MyProject
    [bool]$gl_update_assigned_to = $false, # try to update the assigned to field in GitLab
    [string]$gl_assigned_to_user_suffix = "", # the emu suffix, ie: "_corp"
    [bool]$gl_add_tfs_comments = $true, # try to get tfs comments

    [string]$curlExecutable = "C:\Windows\System32\curl.exe"
)

#region Functions

# Converts user name to mailto link
Function NameToLink([System.Object]$name) {
    $prefix = "@"
    if ($null -ne $gl_assigned_to_user_suffix) {
        $prefix = "mailto:"
        $suffix = "@" + $gl_assigned_to_user_suffix
    }

    if ($null -eq $name.displayName) {
        "$($name)" -match $tfs_regex_user_unique_name > $null
        $user_unique_name = $Matches[0]
        if ($null -eq $user_unique_name) {
            return "unknown"
        }

        "$($name)" -match $tfs_regex_user_display_name > $null
        $user_display_name = $Matches[0]
        if ($null -eq $user_display_name) {
            $user_display_name = "unknown"
        }

        $user_display_name = $user_display_name.Trim()

        return "[$($user_display_name)]($prefix$user_unique_name$suffix)"
    }

    return "[$($name.displayName)]($prefix$($name.uniqueName)$suffix)"
}

Function UtcStringToLocalDateTimeString([string] $text) {
    $utcDateTime = [datetime]::Parse($text)
    $localDateTime = $utcDateTime.ToLocalTime()
    return $localDateTime.ToString("yyyy-MM-dd HH:mm:ss")
}

Function EscapeText ([string] $text) {
    $text = $text.Replace("\", "\\")
    $text = $text.Replace('"', '\"')
    return $text;
}   

Function ModifyUrl([string] $url) {
    $url = [URI]::EscapeUriString($url)

    if ($null -eq $gl_assigned_to_user_suffix -or $gl_assigned_to_user_suffix.Trim() -eq "") {
        return $url
    }
    
    $indexOfColon = $url.LastIndexOf(":")
    if ($url.ToLower().StartsWith("http")) {
        if ($indexOfColon -le 5) {
            return $url
        }
    }

    if (-1 -eq $indexOfColon) {
        return $url
    }

    $url = $url.Insert($indexOfColon, ".$gl_assigned_to_user_suffix")
    return $url
}

function TfsAttachmentToGitLab([string] $dateTime, [System.Object] $item) {
    $indexOfSlash = $item.url.LastIndexOf('/')
    $attachmentId = $item.url.Substring($indexOfSlash + 1)
    # https://learn.microsoft.com/en-us/previous-versions/azure/devops/integrate/previous-apis/wit/attachments?view=tfs-2017
    $tfs_work_item_attachment_url = "$tfs_url/_apis/wit/attachments/$attachmentId"
    Remove-Item -Path "./.temp/attachment" -ErrorAction SilentlyContinue
    Remove-Item -Path "./.temp/$($item.attributes.name)" -ErrorAction SilentlyContinue
    $tfs_get_attachment_response = Invoke-RestMethod "$tfs_work_item_attachment_url" -Method 'GET' -Headers $headers -OutFile "./.temp/attachment"

    # Fix of "Cannot perform operation because the wildcard path ...[...]... did not resolve to a file."
    # https://stackoverflow.com/questions/55869623/how-to-escape-square-brackets-in-file-paths-with-invoke-webrequests-outfile-pa
    Rename-Item -Path "./.temp/attachment" -NewName "$($item.attributes.name)"

    # gitlab version "16.7.0-ee"
    # https://docs.gitlab.com/ee/api/projects.html#upload-a-file
    # https://git/XXX/YYY/uploads/c263e46876497601e6d06d5ff71f6048/quokka.jpg
    $curl_response = & $curlExecutable -s -H "PRIVATE-TOKEN: $gl_pat" -X POST -F "file=@./.temp/$($item.attributes.name)" "$($gl_project_url)uploads" 2>>.temp\error.txt

    Remove-Item -Path "./.temp/$($item.attributes.name)" -ErrorAction SilentlyContinue

    $attachment = $curl_response | ConvertFrom-Json
    $attachment_url = $gl_host + $attachment.full_path

    $gl_attachment_comment = $tfs_original_workitem_json_beginning
    $gl_attachment_comment += "| Created date | Created by | JSON URL |`n|---|---|---|`n"
    if ([string]::IsNullOrEmpty($item.attributes.comment)) {
        $createdBy = "UNKNOWN"
    }
    else {
        $createdBy = $(NameToLink($item.attributes.comment.Split(" by ")[-1].Split(" at ")[0]))
    }
    $gl_attachment_comment += "| $(UtcStringToLocalDateTimeString($dateTime)) | $createdBy | [URL]($($tfs_work_item_attachment_url)) |`n`n"

    $attachment_url = "**Attachment:** " + $attachment_url

    $gl_attachment_comment += "<p>`n`n$($attachment_url)</p>"

    $gl_attachment_comment += $tfs_original_workitem_json_end

    $gl_attachment_comment = EscapeText($gl_attachment_comment)
    $gl_add_comment_url = glab issue note $issue_id -R "$gl_group/$gl_project" -m "$gl_attachment_comment"
    if ($?) {
        Write-Host "  attachment added: $attachment_url"
    }
    else {
        Write-Host "  attachment $attachment_url was not added!"
    }
}

function TfsHistoryToGitLabComment([string] $dateTime, [System.Object] $history) {
    $gl_history_comment = $tfs_original_workitem_json_beginning
    $gl_history_comment += "| Created date | Created by | JSON URL |`n|---|---|---|`n"
    $history_url = ModifyUrl($history.url)
    $gl_history_comment += "| $(UtcStringToLocalDateTimeString($dateTime)) | $(NameToLink($history.revisedBy.name)) | [URL]($($history_url)) |`n`n"
    $gl_history_comment += "<p>`n`n$($history.value)</p>"
    $gl_history_comment += $tfs_original_workitem_json_end

    Remove-Item -Path ./.temp/comment.txt -ErrorAction SilentlyContinue
    $gl_history_comment | Out-File -FilePath ./.temp/comment.txt

    $comment_url = Invoke-RestMethod -Method Post -Body @{ body = Get-Content -Raw -Path '.\.temp\comment.txt' } -Headers @{ 'PRIVATE-TOKEN' = $gl_pat } -Uri "$($gl_project_url)issues/$issue_id/notes"
    if ($?) {
        Write-Host "  comment created: $gl_host/$gl_group/$gl_project/-/issues/$issue_id#note_$($comment_url.id)"
    }
    else {
        Write-Host "  comment was not created!"
    }

    Remove-Item -Path ./.temp/comment.txt -ErrorAction SilentlyContinue
}

#region Script Beginning

Clear-Host

if (!(Test-Path -Path .\.temp)) {
    New-Item -Path ".\" -Name ".temp" -ItemType Directory
}

# Set the auth token for tfx commands. Note: PAT works only for TFS 2017 and above. Basic authentification is needed for TFS 2015. https://stackoverflow.com/a/35101750/1145859
# $env:TFS_EXT_PAT = $tfs_pat;
# Set the auth token for gl commands
# $env:GL_TOKEN = $gl_pat;
# $env:GITLAB_HOST = $gl_host;  # Note: Set GitLab Host/Configuration in c:\Users\USER\.config\glab-cli\config.yml

tfx login --auth-type basic --username "$tfs_username" --password "$tfs_password" --service-url "$tfs_url" --output json --project "$tfs_project" --save > $null

# add the wiql to not migrate closed work items
if (!$tfs_migrate_closed_workitems) {
    $closed_wiql = "[State] <> 'Done' and [State] <> 'Closed' and [State] <> 'Resolved' and [State] <> 'Removed' and"
}

#region Get Epics (emulated as Labels)
$gl_project_url = "$gl_host/api/v4/projects/$gl_group%2F$gl_project/"
$labels = [System.Collections.Arraylist]@()
$page = 1
do {
    $gl_labels = & $curlExecutable -s -H "PRIVATE-TOKEN: $gl_pat" "$($gl_project_url)labels?page=$page" 2>>.temp\error.txt | ConvertFrom-Json
    foreach ($gl_label in $gl_labels) {
        $labels.Add($gl_label.name) > $null
    }
    $page += 1
} while ($gl_labels.Count -gt 0)

#region Get Milestones
$milestones = New-Object 'system.collections.generic.dictionary[string,string]'
$page = 1
do {
    $gl_milestones = & $curlExecutable -s -H "PRIVATE-TOKEN: $gl_pat" "$($gl_project_url)milestones?page=$page" 2>>.temp\error.txt | ConvertFrom-Json
    foreach ($gl_milestone in $gl_milestones) {
        $milestones[$gl_milestone.title] = $gl_milestone.id
    }
    $page += 1
} while ($gl_milestones.Count -gt 0)

$unknown_users = New-Object 'system.collections.generic.dictionary[string,string]'

$count = 0;
$highestId = 0
$break = $false

do {
    $where = " and [ID] > $highestId"

    #region Debugging Specific IDs
    # if ($true -ne $tfs_production_run) {
    #     $where += " and ([ID] = 0"
        
    #     # $where += " or [ID] = 12715" # Big Task with Attachments
    #     # $where += " or [ID] = 994"   # Tags test with non-existing user + Extra Long Title
    #     # $where += " or [ID] = 9508"    # acceptance criteria
    #     # $where += " or [ID] = 15835"    # system info
    #     # $where += " or [ID] = 860"     # Username is empty? $gl_attachment_comment += "| $(UtcStringToLocalDateTimeString($dateTime)) | $(NameToLink($item.attributes.comment.Split(" by ")[-1].Split(" at ")[0])) | [URL]($($tfs_work_item_attachment_url)) |`n`n"
    #     # $where += " or [ID] = 1026"    # reproSteps
    #     # $where += " or [ID] = 12638"    # acceptance criteria
    #     # $where += " or [ID] = 12596"    # Program 'glab.exe' failed to run: The filename or extension is too longAt C:\temp\TfsToGitLab\tfs_workitems_to_gitlab_issues.ps1:194 char:20
    #     # $where += " or [ID] = 12677"    # ERROR: History was not created!
    #     # $where += " or [ID] = 12703"    # Invoke-RestMethod : Cannot perform operation because the wildcard path ./.temp/20_hi-res [nb].png did not resolve to a file.
    #     # $where += " or [ID] > 2035"    # test for minimal ID

    #     $where += ")"
    # }

    $wiql = "select [ID], [Title], [System.Tags] from workitems where $closed_wiql [System.AreaPath] UNDER '$tfs_area_path' and not [System.Tags] Contains 'copied-to-gitlab' $where order by [ID]";

    $query = tfx workitem query --query $wiql --json | ConvertFrom-Json

    #region Process WorkItems

    :ForEachWorkItems ForEach ($workitem in $query) {
        $workitemId = $workitem.id;
        if ($workitemId -lt $highestId) {
            Write-Host "Workitem ID is less than highest ID: $workitemId < $highestId"
            break
        }
        $highestId = $workitemId

        $details_json = tfx workitem show --work-item-id $workitem.id --json
        Remove-Item -Path ./.temp/temp_work_item.txt -ErrorAction SilentlyContinue
        $details_json | Out-File -FilePath ./.temp/temp_work_item.txt -Encoding OEM
        $details_json = Get-Content -Path ./.temp/temp_work_item.txt -Encoding UTF8
        $details = $details_json | ConvertFrom-Json

        $title_orig = $details.fields.{System.Title}
        $title = "$($details.fields.{System.WorkItemType}) $workitemId $title_orig"
        $title_truncated = $false
        if ($title.Length -gt 255) {
            $title = $title.Substring(0, [math]::Min($title.Length, 255))
            $title_truncated = $true
        }

        Write-Host "Copying work item $workitemId to $gl_group/$gl_project on gitlab";

        $description = "`n"

        if ($title_truncated -eq $true) {
            $description += "Original title:`n"
            $description += "## $title_orig`n`n"
        }

        # $url="[Original Work Item URL](https://dev.azure.com/$ado_org/$tfs_project/_workitems/edit/$($workitem.id))"
        # http://tfs1:8080/tfs/TFSProjectCollection/project/team/_workitems#id=12715&triage=true&_a=edit
        $url_base = "$tfs_url/$tfs_project/$tfs_team"
        $url = "[$($details.fields.{System.WorkItemType})]($([URI]::EscapeUriString("$url_base/_workitems#id=$($workitem.id)&triage=true&_a=edit"))) $($workitem.id)"

        # bug doesn't have Description field - add repro steps and/or system info
        if ($details.fields.{System.WorkItemType} -eq "Bug") {
            if (![string]::IsNullOrEmpty($details.fields.{Microsoft.VSTS.TCM.ReproSteps})) {
                # Fix line # reference in "Repository:" URL.
                $reproSteps = $details.fields.{Microsoft.VSTS.TCM.ReproSteps}
                # $reproSteps = $reproSteps.Replace('/tree/', '/blob/').Replace('?&amp;path=', '').Replace('&amp;line=', '#L');
                $description += "## Repro Steps`n`n" + $reproSteps + "`n`n";
            }
            if (![string]::IsNullOrEmpty($details.fields.{Microsoft.VSTS.TCM.SystemInfo})) {
                $description += "## System Info`n`n" + $details.fields.{Microsoft.VSTS.TCM.SystemInfo} + "`n`n"
            }
        }
        else {
            $description += $details.fields.{System.Description}
            # User Story - Add in Acceptance Criteria if it has it
            if (![string]::IsNullOrEmpty($details.fields.{Microsoft.VSTS.Common.AcceptanceCriteria})) {
                $description += "`n`n## Acceptance Criteria`n`n" + $details.fields.{Microsoft.VSTS.Common.AcceptanceCriteria}
            }
        }

        $gl_note = $url

        # use empty string if there is no user is assigned
        "$($details.fields.{System.AssignedTo})" -match $tfs_regex_user_unique_name > $null
        $tfs_assigned_to_unique_name = $Matches[0]
        if ($null -eq $tfs_assigned_to_unique_name) {
            $tfs_assigned_to_unique_name = ""
        }

        #region Details table
        $gl_note += "`n`n<details open><summary>Original Work Item Details</summary><p>" + "`n`n"
        $tfs_details = "| Created date | Created by | Changed date | Changed By | Assigned To | State | Type | Area Path (Label) | Iteration Path (Milestone) |`n|---|---|---|---|---|---|---|---|---|`n"
        $area_path = $details.fields.{System.AreaPath}
        $iteration_path = $details.fields.{System.IterationPath}
        $tfs_details += "| $(UtcStringToLocalDateTimeString($details.fields.{System.CreatedDate})) | $(NameToLink($details.fields.{System.CreatedBy})) | $(UtcStringToLocalDateTimeString($details.fields.{System.ChangedDate})) | $(NameToLink($details.fields.{System.ChangedBy})) | $(NameToLink($details.fields.{System.AssignedTo})) | $($details.fields.{System.State}) | $($details.fields.{System.WorkItemType}) | $($area_path) | $($iteration_path) |`n`n"
        $gl_note += $tfs_details
        $gl_note += "`n" + "`n</p></details>"

        # prepare the history
        $gl_note += "`n`n<details><summary>Original Work Item JSON</summary><p>" + "`n`n" + '`'
        $gl_note += $details_json
        $gl_note += "`n" + '`' + "`n</p></details>"

        # setting the label on the issue to be the work item type
        $work_item_type = $details.fields.{System.WorkItemType}.ToLower()

        # TODO linked issues https://gitlab.com/gitlab-org/cli/-/blob/main/docs/source/issue/create.md
        $linked_issues = ""
        # https://learn.microsoft.com/en-us/previous-versions/azure/devops/integrate/previous-apis/wit/work-items?view=tfs-2017#addalink
        ForEach ($relation in $workitem.relations) {
            # $relation.rel # https://learn.microsoft.com/en-us/azure/devops/boards/queries/link-type-reference?view=azure-devops#list-link-types
            # $relatedWorkItemId = $relation.url.Split("/")[-1]
        }

        if (![string]::IsNullOrEmpty($linked_issues)) {
            $linked_issues = "--linked-issues `\`"$linked_issues`\`""
        }

        #region Create the Issue
        # API https://docs.gitlab.com/ee/api/issues.html#new-issue https://stackoverflow.com/a/72943845/1145859
        # Rate limits on issue and epic creation https://docs.gitlab.com/ee/administration/settings/rate_limit_on_issues_creation.html
        Remove-Item -Path ./.temp/description.txt -ErrorAction SilentlyContinue
        $description | Out-File -FilePath ./.temp/description.txt
        $body = @{ 
            title       = "$title" 
            description = Get-Content -Raw -Path '.\.temp\description.txt' 
            labels      = "$work_item_type"
        }
       
        $gl_issue_creation = Invoke-RestMethod -Method Post -Body $body -Headers @{ 'PRIVATE-TOKEN' = $gl_pat } -Uri "$($gl_project_url)issues"
       
        $issue_url = $gl_issue_creation.web_url
        Remove-Item -Path ./.temp/description.txt -ErrorAction SilentlyContinue

        # "<" redirection doesn't work https://stackoverflow.com/questions/11447598/redirecting-standard-input-output-in-windows-powershell
        $issue_id = $issue_url.Split("/-/issues/")[-1]

        if (![string]::IsNullOrEmpty($issue_url.Trim())) {
            Write-Host "  Issue created: $issue_url";
            $count++;
        }
        else {
            Write-Host "ERROR: Issue was not created: $url $issue_url";
            throw "Issue creation failed.";
        }

        #region AssignedTo

        # update assigned to in GitLab if the option is set - tries to use TFS email to map to GitLab username
        if ($gl_update_assigned_to -eq $true -and $tfs_assigned_to_unique_name -ne "") {
            # map e-mails from one domain to another.
            # https://learn.microsoft.com/en-us/previous-versions/azure/devops/integrate/previous-apis/wit/work-items?view=tfs-2017#get-a-work-item
            $gl_assignee = $tfs_assigned_to_unique_name.Split("@")[0]
            $gl_assignee = $gl_assignee.Replace(".", "-") # + $gl_assigned_to_user_suffix
            if ($unknown_users.ContainsKey($gl_assignee)) {
                # Write-Host "  skipping unknown assignee: $gl_assignee"
            }
            else {
                # Write-Host "  trying to assign to: $gl_assignee"
                $assigned = glab issue update $issue_id -a "$gl_assignee" -R "$gl_group/$gl_project" #-m "$($details.fields.{System.IterationPath})" # Unfortunately, creating a board to sort issues with milestones is now a paid feature. https://gitlab.com/gitlab-org/cli/-/issues/1064
                if ($?) {
                    # Write-Host "  issue assignee updated: $($assigned[-1])"
                }
                else {
                    # Write-Host "  issue assignee was not updated to `"$gl_assignee`"!"
                    $unknown_users[$gl_assignee] = $gl_assignee
                }
            }
        }

        # add the history
        Remove-Item -Path ./.temp/history.txt -ErrorAction SilentlyContinue
        $gl_note | Out-File -FilePath ./.temp/history.txt

        $note_response = Invoke-RestMethod -Method Post -Body @{ body = Get-Content -Raw -Path '.\.temp\history.txt' } -Headers @{ 'PRIVATE-TOKEN' = $gl_pat } -Uri "$($gl_project_url)issues/$issue_id/notes"
        if ($?) {
            # Write-Host "  History created: $gl_host/$gl_group/$gl_project/-/issues/$issue_id#note_$($note_response.id)"
        }
        else {
            Write-Host "ERROR: History was not created! $note_response"
        }
        Remove-Item -Path ./.temp/history.txt -ErrorAction SilentlyContinue

        $headers = New-Object "System.Collections.Generic.Dictionary[[String],[String]]"
        # https://en.wikipedia.org/wiki/Basic_access_authentication
        $credentials = "$($tfs_username):$($tfs_password)"
        $base64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($credentials))
        $headers.Add("Authorization", "Basic $base64")

        $tfs_revisions_url = "$tfs_url/_apis/wit/workItems/$($workitem.id)/revisions?$tfs_rest_api_version"
        $tfs_revisions = Invoke-RestMethod "$tfs_revisions_url" -Method 'GET' -Headers $headers #| ConvertFrom-Json

        $items = @{}

        $tfs_original_workitem_json_beginning = "<p>" + "`n`n"
        $tfs_original_workitem_json_end = "</p>"

        #region History/Comments

        # getting comments if enabled
        if ($gl_add_tfs_comments -eq $true) {
            # https://learn.microsoft.com/en-us/previous-versions/azure/devops/integrate/previous-apis/overview?view=tfs-2017&viewFallbackFrom=tfs-2015
            # https://learn.microsoft.com/en-us/rest/api/azure/devops/wit/work-items/get-work-item?view=azure-devops-rest-7.1&source=recommendations&tabs=HTTP
            $tfs_work_item_url = "$tfs_url/_apis/wit/workItems/$($workitem.id)/history?$tfs_rest_api_version"
            $response = Invoke-RestMethod "$tfs_work_item_url" -Method 'GET' -Headers $headers

            if ($response.count -gt 0) {
                ForEach ($history in $response.value) {
                    $tfs_rev = ($tfs_revisions.value | Where-Object { $_.rev -eq $history.rev })[0]
                    $history_hashtable = @{}
                    $history_hashtable["history"] = $history
                    $items[$tfs_rev.fields.'System.ChangedDate'] = $history_hashtable
                    # $items += @( $history.revisedDate, $history )
                }
            }
        }

        #region Attachments (relations)

        # Get TFS Attachments
        # https://stackoverflow.com/questions/56793171/get-a-list-of-attachment-ids-for-each-work-item-on-vsts
        # https://stackoverflow.com/questions/72886118/download-attachments-from-tfs
        # http://tfs1:8080/tfs/TFSProjectCollection/_apis/wit/workItems/994?api-version=2.1&$expand=all
        $tfs_work_item_url = "$tfs_url/_apis/wit/workItems/$($workitem.id)?$tfs_rest_api_version&`$expand=all"
        $response = Invoke-RestMethod "$tfs_work_item_url" -Method 'GET' -Headers $headers 
        if ($true -eq $?) {
            foreach ($item in $response.relations) {
                if ("AttachedFile" -eq $item.rel) {
                    $attachment_hashtable = @{}
                    $attachment_hashtable["attachment"] = $item
                    $items[$item.attributes.authorizedDate] = $attachment_hashtable
                    # $items[$item.attributes.resourceModifiedDate] = $attachment_hashtable
                }
            }
        }

        #region Insert Comments into GitLab - attachments + history

        # Sort attachments and history items by date and time
        $items = $items.GetEnumerator() | Sort-Object -Property Key

        foreach ($item in $items) {
            if ($item.Value.ContainsKey("attachment")) {
                $attachment = $item.Value["attachment"]
                # Write-Host "$($item.Key) Attachment $($attachment.attributes.name)"
                TfsAttachmentToGitLab $item.Key $attachment
            }
            else {
                if ($item.Value.ContainsKey("history")) {
                    $history = $item.Value["history"]
                    # Write-Host "$($item.Key) Comment $($history.url) $($history.rev)"
                    TfsHistoryToGitLabComment $item.Key $history
                }
            }
        }



        #region Area To Epic(Label) emulation - https://pm.stackexchange.com/questions/25038/how-to-implement-epics-on-gitlab-without-enterprise-edition
        $epic = "epic:$area_path"
        if (-not $labels.Contains($epic)) {
            $gl_create_label_response = & $curlExecutable -s -H "PRIVATE-TOKEN: $gl_pat" -d "name=$([URI]::EscapeUriString($epic))&description=$([URI]::EscapeUriString($area_path))&color=#9400d3" "$($gl_project_url)labels" 2>>.temp\error.txt  | ConvertFrom-Json

            if ($gl_create_label_response.id -gt 0 -and $gl_create_label_response.name -eq $epic) {
                $labels.Add($epic)
            }
            else {
                Write-Error "ERROR: Label `"$epic`" was not created!"
            }
        }

        $gl_add_label_response = & $curlExecutable -s -H "PRIVATE-TOKEN: $gl_pat" -X PUT "$($gl_project_url)issues/$($issue_id)?add_labels=$([URI]::EscapeUriString($epic))" 2>>.temp\error.txt | ConvertFrom-Json
        if ($gl_add_label_response.id -gt 0) {
        }
        else {
            Write-Error "ERROR: Label `"$epic`" was not added!"
        }



        #region Iteration Path To Milestone
        $milestone = $iteration_path
        if (-not $milestones.Keys.Contains($milestone)) {
            $gl_create_milestone_response = & $curlExecutable -s -H "PRIVATE-TOKEN: $gl_pat" -X POST -d "title=$([URI]::EscapeUriString($milestone))&description=$([URI]::EscapeUriString($milestone))" "$($gl_project_url)milestones" 2>>.temp\error.txt | ConvertFrom-Json

            if ($gl_create_milestone_response.id -gt 0 -and $gl_create_milestone_response.title -eq $milestone) {
                $milestones[$milestone] = $gl_create_milestone_response.id
            }
            else {
                Write-Error "ERROR: Milestone `"$milestone`" was not created!"
            }
        }

        $gl_add_milestone_response = & $curlExecutable -s -H "PRIVATE-TOKEN: $gl_pat" -X PUT "$($gl_project_url)issues/$($issue_id)?milestone_id=$($milestones[$milestone])" 2>>.temp\error.txt | ConvertFrom-Json
        if ($gl_add_milestone_response.id -gt 0) {
        }
        else {
            Write-Error "ERROR: Milestone `"$milestone`" was not added!"
        }



        #region "copied-to-gitlab" tag 
        if ($true -eq $tfs_production_run) {
            $workitemTags = $workitem.fields.'System.Tags';
            tfx workitem update --work-item-id "$workitemId" --values "{`\`"System.Tags`\`":`\`"copied-to-gitlab; $workitemTags`\`" }" > $null

            # Add gitlab issue link to TFS workitem as Hyperlink
            $tfs_work_item_url = "$tfs_url/_apis/wit/workItems/$($workitem.id)?$tfs_rest_api_version"
            # https://learn.microsoft.com/en-us/previous-versions/azure/devops/integrate/previous-apis/wit/samples?view=tfs-2017
            $response = Invoke-RestMethod "$tfs_work_item_url" -Method 'PATCH' -Headers $headers -ContentType "application/json-patch+json" -Body "[{`"op`": `"add`", `"path`": `"/relations/-`", `"value`": {`"rel`":`"Hyperlink`", `"url`":`"$(EscapeText($issue_url))`" }}]"
        }

        #region close out the issue if it's closed on the TFS side
        $tfs_closure_states = "Done", "Closed", "Resolved", "Removed"
        if ($tfs_closure_states.Contains($details.fields.{System.State})) {
            $close_response = Invoke-RestMethod -Method Put -Headers @{ 'PRIVATE-TOKEN' = $gl_pat } -Uri "$($gl_project_url)issues/$($issue_id)?state_event=close"
            if ($?) {
                Write-Host "  Issue $issue_id was closed"
            }
            else {
                Write-Host "ERROR: Issue $issue_id was NOT closed! $close_response"
            }
        }

        #region Debugging Count
        # if ($count -ge 402) {
        #     $break = $true
        #     break ForEachWorkItems
        # }
    }

    # if ($break) {
    #     break
    # }

} while ($query.Count -gt 0)

Write-Host "Total items copied: $count"