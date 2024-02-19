#TODO Debug

###########################################
# Migrate TFS work items to GitLab Issues #
###########################################

# Prerequisites:
# 1. Install tfs-cli (https://www.npmjs.com/package/tfx-cli) and gitlab cli (https://gitlab.com/gitlab-org/cli/-/releases)
# 2. create a label for EACH work item type that is being migrated (as lower case)
#      - ie: "user story", "bug", "task", "issue"
# 3. define under what area path you want to migrate
#      - You can modify the WIQL if you want to use a different way to migrate work items, such as [TAG] = "migrate"

# How to run:
# ./tfs_workitems_to_gitlab_issues.ps1 -tfs_username "xxx" -tfs_password "***" -tfs_url "http://tfs:8080/tfs/TFSProjectCollection" -tfs_project "TailWindTraders" -tfs_team "TailWindTraders Team" -tfs_area_path "TailWindTraders\AREA_PATH_LEVEL_1\AREA_PATH_LEVEL_2\..." -tfs_migrate_closed_workitems $true -tfs_production_run $true -gl_group "MainGroup" -gl_project "MyProject" -gl_update_assigned_to $true -gl_assigned_to_user_suffix "" -gl_add_tfs_comments $true

#
# Things it migrates:
# 1. Title
# 2. Description (or repro steps + system info for a bug)
# 3. State (if the work item is done / closed, it will be closed in GitLab)
# 4. It will try to assign the work item to the correct user in GitLab - based on TFS email (-gl_update_assigned_to and -gl_assigned_to_user_suffix options) - they of course have to be in GitLab already
# 5. Migrate acceptance criteria as part of issue body (if present)
# 6. Adds in the following as a comment to the issue:
#   a. Original work item url
#   b. Basic details in a collapsed markdown table
#   c. Entire work item as JSON in a collapsed section
# 7. Creates tag "copied-to-gitlab" and a comment on the TFS work item with `-$tfs_production_run $true` . The tag prevents duplicate copying.
#

#
# Things it won't ever migrate:
# 1. Created date/update dates
#

[CmdletBinding()]
param (
    # [string]$tfs_pat, # TODO TFS PAT used for TFS 2017 https://stackoverflow.com/a/35101750/1145859
    [string]$tfs_username, # TFS username used for TFS 2015 https://stackoverflow.com/a/35101750/1145859
    [SecureString]$tfs_password, # TFS password used for TFS 2015 https://stackoverflow.com/a/35101750/1145859
    [string]$tfs_url, # TFS URL, eg: "http://tfs:8080/tfs/TFSProjectCollection"
    [string]$tfs_project, # Project name that contains the work items, eg: "TailWindTraders"
    [string]$tfs_team, # Team name that contains the work items, eg: "TailWindTraders Team"
    [string]$tfs_area_path, # Area path in TFS to migrate; uses the 'UNDER' operator)
    [bool]$tfs_migrate_closed_workitems = $true, # migrate work items with the state of done, closed, resolved, and removed
    [bool]$tfs_production_run = $false, # tag migrated work items with 'migrated-to-gitlab' and add discussion comment

    # [string]$gl_host, # TODO GitLab host, eg: "git" or "git.domain"
    # [string]$gl_pat, # TODO GitLab PAT. Note: PAT works only for TFS 2017 and above. Basic authentification is needed for TFS 2015. https://stackoverflow.com/a/35101750/1145859
    [string]$gl_group, # GitLab project group, eg: "MainGroup" part of https://gitlab/MainGroup/MyProject
    [string]$gl_project, # GitLab project name, eg: "MyProject" part of https://gitlab/MainGroup/MyProject
    [bool]$gl_update_assigned_to = $false, # try to update the assigned to field in GitLab
    [string]$gl_assigned_to_user_suffix = "", # the emu suffix, ie: "_corp"
    [bool]$gl_add_tfs_comments = $true # try to get tfs comments
)

Function NameToLink {
    param (
        [System.Object]$name
    )

    if ( $null -eq $name.displayName ) {
        return "unknown"
    }

    # return "[$($name.displayName)](mailto:$($name.uniqueName))"
    return "[$($name.displayName)]($($name.uniqueName))"
}

# Set the auth token for tfx commands. Note: PAT works only for TFS 2017 and above. Basic authentification is needed for TFS 2015. https://stackoverflow.com/a/35101750/1145859
# $env:TFS_EXT_PAT = $tfs_pat;
# Set the auth token for gl commands
# $env:GL_TOKEN = $gl_pat;
# $env:GITLAB_HOST = $gl_host;  # Note: Set GitLab Host/Configuration in c:\Users\USER\.config\glab-cli\config.yml

# az devops configure --defaults organization="https://dev.azure.com/$ado_org" project="$tfs_project"
tfx login --auth-type basic --username "$tfs_username" --password "$tfs_password" -service-url "$tfs_url" --output json --project "$tfs_project" --save

# add the wiql to not migrate closed work items
if (!$tfs_migrate_closed_workitems) {
    $closed_wiql = "[State] <> 'Done' and [State] <> 'Closed' and [State] <> 'Resolved' and [State] <> 'Removed' and"
}

if ($null -ne $tfs_production_run) {
    $top = "top 1"
}

$wiql = "select $top [ID], [Title], [System.Tags] from workitems where $closed_wiql [System.AreaPath] UNDER '$tfs_area_path' and not [System.Tags] Contains 'copied-to-gitlab' order by [ID] desc";

# $wiql=az boards query --wiql $wiql | ConvertFrom-Json
$query = tfx workitem query --query $wiql | ConvertFrom-Json

Remove-Item -Path ./temp_comment_body.txt -ErrorAction SilentlyContinue
Remove-Item -Path ./temp_issue_body.txt -ErrorAction SilentlyContinue
$count = 0;

ForEach ($workitem in $query) {
    $workitemId = $workitem.id;

    # $details_json = az boards work-item show --id $workitem.id --output json
    $details_json = tfx workitem show --work-item-id $workitem.id
    $details = $details_json | ConvertFrom-Json

    # double quotes in the title must be escaped with \ to be passed to gh cli
    # workaround for https://github.com/cli/cli/issues/3425 and https://stackoverflow.com/questions/6714165/powershell-stripping-double-quotes-from-command-line-arguments
    $title = $details.fields.{ System.Title } -replace "`"", "`\`""

    Write-Host "Copying work item $workitemId to $gl_group/$gl_project on gitlab";

    $description = ""

    # bug doesn't have Description field - add repro steps and/or system info
    if ($details.fields.{ System.WorkItemType } -eq "Bug") {
        if (![string]::IsNullOrEmpty($details.fields.{ Microsoft.VSTS.TCM.ReproSteps })) {
            # Fix line # reference in "Repository:" URL.
            $reproSteps = ($details.fields.{ Microsoft.VSTS.TCM.ReproSteps }).Replace('/tree/', '/blob/').Replace('?&amp;path=', '').Replace('&amp;line=', '#L');
            $description += "## Repro Steps`n`n" + $reproSteps + "`n`n";
        }
        if (![string]::IsNullOrEmpty($details.fields.{ Microsoft.VSTS.TCM.SystemInfo })) {
            $description += "## System Info`n`n" + $details.fields.{ Microsoft.VSTS.TCM.SystemInfo } + "`n`n"
        }
    }
    else {
        $description += $details.fields.{ System.Description }
        # add in acceptance criteria if it has it
        if (![string]::IsNullOrEmpty($details.fields.{ Microsoft.VSTS.Common.AcceptanceCriteria })) {
            $description += "`n`n## Acceptance Criteria`n`n" + $details.fields.{ Microsoft.VSTS.Common.AcceptanceCriteria }
        }
    }

    $description | Out-File -FilePath ./temp_issue_body.txt -Encoding ASCII;

    # $url="[Original Work Item URL](https://dev.azure.com/$ado_org/$tfs_project/_workitems/edit/$($workitem.id))"
    # http://tfs:8080/tfs/TFSProjectCollection/project/team/_workitems#id=1&triage=true&_a=edit
    $url_base = "$tfs_url/$tfs_project/$tfs_team"
    $url = "[$($details.fields.{System.WorkItemType})]($url_base/_workitems#id=$($workitem.id)&triage=true&_a=edit) $($workitem.id)"
    $url | Out-File -FilePath ./temp_comment_body.txt -Encoding ASCII;

    $gl_note = $url

    # use empty string if there is no user is assigned
    if ( $null -ne $details.fields.{ System.AssignedTo }.displayName ) {
        # $tfs_assigned_to_display_name = $details.fields.{ System.AssignedTo }.displayName
        $tfs_assigned_to_unique_name = $details.fields.{ System.AssignedTo }.uniqueName
    }
    else {
        # $tfs_assigned_to_display_name = ""
        $tfs_assigned_to_unique_name = ""
    }

    # create the details table
    $tfs_details_beginning = "`n`n<details><summary>Original Work Item Details</summary><p>" + "`n`n"
    $tfs_details_beginning | Add-Content -Path ./temp_comment_body.txt -Encoding ASCII;
    $gl_note += $tfs_details_beginning
    $tfs_details = "| Created date | Created by | Changed date | Changed By | Assigned To | State | Type | Area Path | Iteration Path|`n|---|---|---|---|---|---|---|---|---|`n"
    # $tfs_details+="| $($details.fields.{System.CreatedDate}) | $($details.fields.{System.CreatedBy}.displayName) | $($details.fields.{System.ChangedDate}) | $($details.fields.{System.ChangedBy}.displayName) | $tfs_assigned_to_display_name | $($details.fields.{System.State}) | $($details.fields.{System.WorkItemType}) | $($details.fields.{System.AreaPath}) | $($details.fields.{System.IterationPath}) |`n`n"
    # $tfs_details+="| $($details.fields.{System.CreatedDate}) | [$($details.fields.{System.CreatedBy}.displayName)]($($details.fields.{System.CreatedBy}.uniqueName) | $($details.fields.{System.ChangedDate}) | $($details.fields.{System.ChangedBy}.displayName) | $tfs_assigned_to_display_name | $($details.fields.{System.State}) | $($details.fields.{System.WorkItemType}) | $($details.fields.{System.AreaPath}) | $($details.fields.{System.IterationPath}) |`n`n"
    $tfs_details += "| $($details.fields.{System.CreatedDate}) | $(NameToLink($details.fields.{System.CreatedBy})) | $($details.fields.{System.ChangedDate}) | $(NameToLink($details.fields.{System.ChangedBy})) | $(NameToLink($details.fields.{System.AssignedTo})) | $($details.fields.{System.State}) | $($details.fields.{System.WorkItemType}) | $($details.fields.{System.AreaPath}) | $($details.fields.{System.IterationPath}) |`n`n"
    $tfs_details | Add-Content -Path ./temp_comment_body.txt -Encoding ASCII;
    $gl_note += $tfs_details
    $tfs_details_end = "`n" + "`n</p></details>"
    $tfs_details_end | Add-Content -Path ./temp_comment_body.txt -Encoding ASCII;
    $gl_note += $tfs_details_end

    # prepare the comment
    $original_workitem_json_beginning = "`n`n<details><summary>Original Work Item JSON</summary><p>" + "`n`n" + '```json'
    $original_workitem_json_beginning | Add-Content -Path ./temp_comment_body.txt -Encoding ASCII;
    $gl_note += $original_workitem_json_beginning
    $details_json | Add-Content -Path ./temp_comment_body.txt -Encoding ASCII;
    $gl_note += $details_json
    $original_workitem_json_end = "`n" + '```' + "`n</p></details>"
    $original_workitem_json_end | Add-Content -Path ./temp_comment_body.txt -Encoding ASCII;
    $gl_note += $original_workitem_json_end

    # getting comments if enabled
    if ($gl_add_tfs_comments -eq $true) {
        $headers = New-Object "System.Collections.Generic.Dictionary[[String],[String]]"
        # $base64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes(":$tfs_pat"))
        # https://en.wikipedia.org/wiki/Basic_access_authentication
        $credentials = "$($tfs_username):$($tfs_password)"
        $base64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($credentials))
        $headers.Add("Authorization", "Basic $base64")
        # $response = Invoke-RestMethod "https://dev.azure.com/$ado_org/$ado_project/_apis/wit/workItems/$($workitem.id)/comments?api-version=7.1-preview.3" -Method 'GET' -Headers $headers
        # https://learn.microsoft.com/en-us/previous-versions/azure/devops/integrate/previous-apis/overview?view=tfs-2017&viewFallbackFrom=tfs-2015
        $response = Invoke-RestMethod "$url_base/_apis/wit/workItems/$($workitem.id)/comments?api-version=2.0-preview.1" -Method 'GET' -Headers $headers

        if ($response.count -gt 0) {
            $tfs_comments_details = ""
            $tfs_original_workitem_json_beginning = "`n`n<details><summary>Work Item Comments ($($response.count))</summary><p>" + "`n`n"
            $tfs_original_workitem_json_beginning | Add-Content -Path ./temp_comment_body.txt -Encoding ASCII;
            $gl_note += $tfs_original_workitem_json_beginning
            ForEach ($comment in $response.comments) {
                $tfs_comments_details = "| Created date | Created by | JSON URL |`n|---|---|---|`n"
                # $tfs_comments_details+="| $($comment.createdDate) | $($comment.createdBy.displayName) | [URL]($($comment.url)) |`n`n"
                # $tfs_comments_details+="| $($comment.createdDate) | [$($comment.createdBy.displayName)]($($comment.createdBy.uniqueName)) | [URL]($($comment.url)) |`n`n"
                $tfs_comments_details += "| $($comment.createdDate) | $(NameToLink($comment.createdBy)) | [URL]($($comment.url)) |`n`n"
                $tfs_comments_details += "**Comment text**: $($comment.text)`n`n-----------`n`n"
                $tfs_comments_details | Add-Content -Path ./temp_comment_body.txt -Encoding ASCII;
                $gl_note += $tfs_comments_details
            }
            $tfs_original_workitem_json_end = "`n" + "`n</p></details>"
            $tfs_original_workitem_json_end | Add-Content -Path ./temp_comment_body.txt -Encoding ASCII;
            $gl_note += $tfs_original_workitem_json_end
        }
    }

    # setting the label on the issue to be the work item type
    $work_item_type = $details.fields.{ System.WorkItemType }.ToLower()

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

    # create the issue
    # $issue_url=gh issue create --body-file ./temp_issue_body.txt --repo "$gl_org/$gl_repo" --title "$title" --label $work_item_type
    # API https://docs.gitlab.com/ee/api/issues.html#new-issue https://stackoverflow.com/a/72943845/1145859
    # Rate limits on issue and epic creation https://docs.gitlab.com/ee/administration/settings/rate_limit_on_issues_creation.html
    # glab issue create -t "test title" -d "test descr" -R GROUP/PROJECT -y
    $issue_url = glab issue create -l "$work_item_type" -t "$title" -d "$description" -R "$gl_group/$gl_project" -y $linked_issues

    $issue_id = $issue_url.Split("/-/issues/")[-1]

    if (![string]::IsNullOrEmpty($issue_url.Trim())) {
        Write-Host "  Issue created: $issue_url";
        $count++;
    }
    else {
        Write-Host "  Issue NOT created: $issue_url";
        throw "Issue creation failed.";
    }

    # update assigned to in GitLab if the option is set - tries to use TFS email to map to GitLab username
    if ($gl_update_assigned_to -eq $true -and $tfs_assigned_to_unique_name -ne "") {
        # TODO map e-mails from one domain to another.
        # https://learn.microsoft.com/en-us/previous-versions/azure/devops/integrate/previous-apis/wit/work-items?view=tfs-2017#get-a-work-item
        $gl_assignee = $tfs_assigned_to_unique_name.Split("@")[0]
        $gl_assignee = $gl_assignee.Replace(".", "-") + $gl_assigned_to_user_suffix
        Write-Host "  trying to assign to: $gl_assignee"
        # $assigned = glab issue edit $issue_url --add-assignee "$gl_assignee"
        $assigned = glab issue update $issue_id -a "$gl_assignee" -R "$gl_group/$gl_project"
        Write-Host "  issue assignee updated: $assigned"
    }

    # add the comment
    # $comment_url=gh issue comment $issue_url --body-file ./temp_comment_body.txt
    $note_url = glab issue note $issue_id -m "$gl_note" -R "$gl_group/$gl_project"
    Write-Host "  comment created: $note_url"

    Remove-Item -Path ./temp_comment_body.txt -ErrorAction SilentlyContinue
    Remove-Item -Path ./temp_issue_body.txt -ErrorAction SilentlyContinue

    # Add the tag "copied-to-gitlab" plus a comment to the work item
    if ($tfs_production_run) {
        $workitemTags = $workitem.fields.'System.Tags';
        $discussion = "This work item was copied to gitlab as issue <a href=`"$issue_url`">$issue_url</a>";
        # az boards work-item update --id "$workitemId" --fields "System.Tags=copied-to-gitlab; $workitemTags" --discussion "$discussion" | Out-Null;
        tfx workitem update --work-item-id "$workitemId" --values "{`\`"System.Tags`\`":`\`"copied-to-gitlab`\`"}; $workitemTags" --description "$discussion" #| Out-Null;
    }

    # close out the issue if it's closed on the TFS side
    $tfs_closure_states = "Done", "Closed", "Resolved", "Removed"
    if ($tfs_closure_states.Contains($details.fields.{ System.State })) {
        # gh issue close $issue_url
        glab issue close $issue_id
    }
}

Write-Host "Total items copied: $count"