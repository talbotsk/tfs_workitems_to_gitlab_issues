# tfs_workitems_to_gitlab_issues

PowerShell script to migrate TFS work items to GitLab Issues

### Prerequisites

1. Install Node.js
2. Install TFS CLI (npm install -g tfx-cli@0.6.4 not https://www.npmjs.com/package/tfx-cli due to error "Failed to find api location for area: Location id")
3. Install GilLab CLI (glab cli https://gitlab.com/gitlab-org/cli/-/releases) where this is running (ie: action or locally)
4. Set GitLab Host/Configuration in c:\Users\USER\.config\glab-cli\config.yml
5. In GitLab, [create a label](https://docs.gitlab.com/ee/user/project/labels.html#create-a-label) for EACH work item type that is being migrated (as lower case) 
    - ie: "user story", "bug", "task", "issue", "feature"
6. Define under what area path you want to migrate
    - You can modify the WIQL if you want to use a different way to migrate work items, such as `[TAG] = "migrate"`
7. Use PowerShell 5.1

### Things it migrates

1. Title
2. Description (or for a bug, repro steps and/or system info)
3. State (if the work item is done / closed, it will be closed in GitLab)
4. It will try to assign the work item to the correct user in GitLab - based on TFS email before the `@`
    - This uses the `-gl_update_assigned_to` and `-gl_assigned_to_user_suffix` options
    - Users have to be added to GitLab
5. Migrate acceptance criteria as part of issue body (if present)
6. Adds in the following as a comment to the issue:
    - Original work item url 
    - Basic details in a collapsed markdown table
    - Entire work item as JSON in a collapsed section
    - History comments
    - Attachments
7. Creates tag "copied-to-gitlab" (and a comment) on the TFS work item with `-$tfs_production_run $true"`. The tag prevents duplicate copying.

### To Do
1. Provide user mapping option
2. Debug the .gitlab\workflows\migrate-work-items.yml

### Things it won't ever migrate
1. Created date/update dates

### Example

<!-- - [Screenshot](https://user-images.githubusercontent.com/19912012/157745772-69f5cf75-5407-491e-a754-d94b188378ff.png)
- [Migrated GitLab Issue](https://github.com/joshjohanning-org/migrate-ado-workitems/issues/296) -->

## Instructions for Running in Actions

<!-- The recommendation is to use a GitLab App to run the migration - a GitLab app has higher rate limits than using a user PAT. -->

1. Create GitLab project with. Use the following permissions:
    + Repo: `Contents:Read`
    + Repo: `Issues:Read and write`
    + Repo: `Members:Read`
1. Create Private Key for GitLab project
1. Obtain project group name and project name
<!-- 1. Create the following action secrets:
    + `ADO_PAT`: Azure DevOps PAT with appropriate permissions to read work items
    + `PRIVATE_KEY`: The contents of the private key created and downloaded in step #2 -->
<!-- 1. Use the [action](.github/workflows/migrate-work-items.yml) and update the group and project name obtained in step #3 -->
<!-- 1. Update any defaults in the [action](.gitlab/workflows/migrate-work-items.yml) (ie: TFS team and project, GitLab project/repo) -->
1. Ensure the action exists in the repo's default branch
1. Run the workflow

## Instructions for Running Locally

Using the GitLab project might be better so you don't reach a limit on your GitLab account on creating new issues 😀

```pwsh
./tfs_workitems_to_gitlab_issues.ps1 `
    -tfs_username "xxx" `
    -tfs_password "***" `
    -tfs_url "http://tfs1:8080/tfs/TFSProjectCollection" `
    -tfs_project "TailWindTraders" `
    -tfs_team "TailWindTraders Team" `
    -tfs_area_path "TailWindTraders\AREA_PATH_LEVEL_1\AREA_PATH_LEVEL_2\..." `
    -tfs_migrate_closed_workitems $true `
    -tfs_production_run $false `
    -gl_group "MainGroup" `
    -gl_project "MyProject" `
    -gl_update_assigned_to $true `
    -gl_assigned_to_user_suffix "" `
    -gl_add_tfs_comments $true `
    -gl_host https://git `
    -gl_pat xxx
```

## Script Options

| Parameter                       | Required | Default  | Description                                                                                                                                 |
|---------------------------------|----------|----------|---------------------------------------------------------------------------------------------------------------------------------------------|
| `-tfs_username`                 | Yes      |          | TFS username with appropriate permissions to read work items (and update, with `-tfs_production_run $true`)                                 |
| `-tfs_password`                 | Yes      |          | TFS password of the username with appropriate permissions to read work items (and update, with `-tfs_production_run $true`)                 |
| `-tfs_url`                      | Yes      |          | TFS collection URL                                                                                                                          |
| `-tfs_project`                  | Yes      |          | TFS project to migrate from                                                                                                                 |
| `-tfs_team`                     | Yes      |          | TFS team to migrate from                                                                                                                    |
| `-tfs_area_path`                | Yes      |          | TFS area path to migrate from - uses the `UNDER` operator                                                                                   |
| `-tfs_migrate_closed_workitems` | No       | `$true`  | Switch to migrate closed/resoled/done/removed work items                                                                                    |
| `-tfs_production_run`           | No       | `$false` | Switch to add `copied-to-gitlab` tag and comment on TFS work item                                                                           |
| `-gl_group`                     | Yes      |          | GitLab group to migrate work items to                                                                                                       |
| `-gl_project`                   | Yes      |          | GitLab project to migrate work items to                                                                                                     |
| `-gl_update_assigned_to`        | No       | `$false` | Switch to update the GitLab issue's assignee based on the username portion of an email address (before the @ sign)                          |
| `-gl_assigned_to_user_suffix`   | No       | `""`     | Used in conjunction with `-gl_update_assigned_to`, used to suffix the username, e.g. if using GitLab Enterprise Managed User (EMU) instance |
| `-gl_add_tfs_comments`          | No       | `$false` | Switch to add TFS comments as a section with the migrated work item                                                                         |
| `-gl_host`                      | Yes      |          | GitLab host, e.g. https://git |
| `-gl_pat`                       | Yes      |          | GitLab PAT (Personal Access Token) |

+ **Note**: With `-gl_update_assigned_to $true`, you/your users will receive a lot of emails from GitLab when the user is assigned to the issue