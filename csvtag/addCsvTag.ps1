#
$TagFilepath = "" # csv file for tags with column Key and Value
$resourceFilepath = "" # csv file for resources with columns ResourceId
$csvtags = Import-Csv -Path $TagFilepath
$tags=@{}
$csvtags | ForEach-Object { $tags[$_.Key] = $_.Value}
$resources = Import-Csv $resourceFilepath
#
foreach( $res in $resources) {
    Set-AzContext -Subscription (($res.ResourceId -split("/")[2]))
    Update-AzTag -Operation Merge -ResourceId $res.ResourceId -Tag $tags
}