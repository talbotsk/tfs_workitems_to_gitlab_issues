[CmdletBinding()]
param (
    [string]$gl_host, # GitLab host, eg: "git" or "git.domain"
    [string]$gl_pat, # GitLab PAT (Personal Access Token). Note: PAT works only for TFS 2017 and above. Basic authentification is needed for TFS 2015. https://stackoverflow.com/a/35101750/1145859
    [string]$gl_group, # GitLab project group, eg: "MainGroup" part of https://gitlab/MainGroup/MyProject
    [string]$gl_project, # GitLab project name, eg: "MyProject" part of https://gitlab/MainGroup/MyProject
    [string]$curlExecutable = "C:\Windows\System32\curl.exe"
)

Clear-Host

Remove-Item -Path "./.temp/error.txt" -ErrorAction SilentlyContinue

$gl_project_url = "$gl_host/api/v4/projects/$gl_group%2F$gl_project/"



do {
    $issues = & $curlExecutable --header "PRIVATE-TOKEN: $gl_pat" "$($gl_project_url)issues" 2>>.temp\error.txt | ConvertFrom-Json
    ForEach ($issue in $issues) {
        Write-Host "Deleting $($issue.iid)"
        $delete_issue_response = & $curlExecutable --header "PRIVATE-TOKEN: $gl_pat" --request DELETE "$($gl_project_url)issues/$($issue.iid)" 2>>.temp\error.txt
    }
} while ($issues.Count -gt 0)

Write-Host "Succesfully deleted all issues."



$labels = & $curlExecutable --header "PRIVATE-TOKEN: $gl_pat" "$($gl_project_url)labels" 2>>.temp\error.txt | ConvertFrom-Json
ForEach ($label in $labels) {
    if (!$label.name.StartsWith("epic:")) {
        continue
    }
    $label_response = & $curlExecutable --header "PRIVATE-TOKEN: $gl_pat" --request DELETE "$($gl_project_url)labels/$([URI]::EscapeUriString($label.name))" 2>>.temp\error.txt
}

Write-Host "Succesfully deleted all epic labels."



$milestones = & $curlExecutable --header "PRIVATE-TOKEN: $gl_pat" "$($gl_project_url)milestones" 2>>.temp\error.txt | ConvertFrom-Json
ForEach ($milestone in $milestones) {
    $milestone_response = & $curlExecutable --header "PRIVATE-TOKEN: $gl_pat" --request DELETE "$($gl_project_url)milestones/$($milestone.id)" 2>>.temp\error.txt
}

Write-Host "Succesfully deleted all milestones."