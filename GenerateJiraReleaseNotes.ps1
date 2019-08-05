<#
    This script is based on article:
    https://blogg.bekk.no/generating-a-project-change-log-with-teamcity-and-powershell-45323f956437
#>
$buildId = "%teamcity.build.id%"
$buildNumber = "%build.number%"
$releaseVersion = "%changelog.version%"
$latestCommit = "%build.vcs.number%"
$outputFile = "%changelog.output.filename%"
$metaDataFile = "%changelog.output.metadata.filename%"
$teamcityUrl = "%teamcity.serverUrl%"
$teamcityExternalUrl = "%changelog.teamcity.external.url%"
$jiraUrl = "%changelog.jira.url%"
$teamCityAuthToken = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("%changelog.teamcity.username%:%changelog.teamcity.password%"))
$jiraAuthToken = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("%changelog.jira.username%:%changelog.jira.password%"))
# Requests TeamCity API and retruns XML
function RequestTeamCityApi($url)
{
    Write-Host "Request TeamCity API: " + $url
    
    $request = [System.Net.WebRequest]::Create($url)     
    $request.Headers.Add("Authorization", "Basic $teamCityAuthToken");
    [xml](new-object System.IO.StreamReader $request.GetResponse().GetResponseStream()).ReadToEnd()    
}
# Requests Jira API and returns JSON
function RequestJiraApi($url)
{
    Write-Host "Request Jira API: " + $url
    $request = [System.Net.WebRequest]::Create($url)     
    $request.Headers.Add("Authorization", "Basic $jiraAuthToken");
    (new-object System.IO.StreamReader $request.GetResponse().GetResponseStream()).ReadToEnd() | ConvertFrom-Json
}
# Formats XML to readable commit message
function FormatCommitsInfo($commitsInfoXml)
{
   Microsoft.PowerShell.Utility\Select-Xml $commitsInfoXml -XPath "/change" |
        foreach { "* $($_.Node.version) - $($_.Node["user"].name, $_.Node["user"].username, $_.Node.username | Select -First 1): $($_.Node["comment"].InnerText)`r`n" }
}
# Formats XML to readable commit message
function AddCommitsToMetaData($commitsInfoXml, $metaData)
{
   Microsoft.PowerShell.Utility\Select-Xml $commitsInfoXml -XPath "/change" |
        foreach {
			$metaData.Commits += @{
				Id = $_.Node.version
				Comment = $_.Node["comment"].InnerText
			}
		}
}
# Gets Jira issues by keys and format them
function GetJiraIssues($jiraIssueKeys)
{
    $result = ""
    foreach ($key in $jiraIssueKeys)
    {
        Try 
        {
            $jiraJson = RequestJiraApi($jiraUrl + "/rest/api/2/issue/" + $key)
            $result += "* [$($key) [$($jiraJson.fields.status.name)]]($($jiraUrl)/browse/$($key)): $($jiraJson.fields.summary)`n"
        }
        Catch
        {
            Write-Host "Unable to get information for $key" 
        }
    }
    return $result
}
$buildInfo = RequestTeamCityApi("$teamcityUrl/app/rest/changes?locator=build:$($buildId)")
$commitsInfo = Microsoft.PowerShell.Utility\Select-Xml $buildInfo -XPath "/changes/change" | 
                foreach { RequestTeamCityApi("$teamcityUrl/app/rest/changes/id:$($_.Node.id)") };
if ($commitsInfo -ne $null)
{
    $jiraIssueKeys = Microsoft.PowerShell.Utility\Select-Xml $commitsInfo -XPath "/change/comment/text()" | 
                    Select-String -Pattern "\b([A-Z]{2,10}-\d+)\b" -AllMatches -CaseSensitive |
                    foreach { $_.Matches } |
                    foreach { $_.Value } |
                    select -uniq
}
if ($releaseVersion -ne $null)
{
  $changelog = "Release notes for version " + $releaseVersion
}
else
{
  $changelog = "Release notes for build " + $buildNumber
}
$changelog += "`n"
if ($jiraIssueKeys -ne $null)
{
    $changelog = "#### Issues:  `n`n"
    $changelog += GetJiraIssues($jiraIssueKeys)
    $changelog += "`n`n"
}
if ($commitsInfo -ne $null)
{
    $changelog += "#### Commit messages:  `n`n "
    $changelog += FormatCommitsInfo($commitsInfo)
    $metadata = [ordered]@{
        BuildEnvironment = "TeamCity"
        CommentParser = "Jira"
        BuildNumber = $buildNumber
        BuildUrl = "$teamcityExternalUrl/viewLog.html?buildId=$buildId"
        VcsType = "git"
        VcsRoot = ""
        VcsCommitNumber = "$latestCommit"
        Commits = @()
    }
	AddCommitsToMetaData -commitsInfoXml $commitsInfo -metaData $metadata
	
    $jsonString = $metadata | ConvertTo-Json -Depth 10
    Set-Content -Value $jsonString -Path $metaDataFile
}
$changelog > $outputFile
Write-Host "Changelog saved to ${outputFile}"
