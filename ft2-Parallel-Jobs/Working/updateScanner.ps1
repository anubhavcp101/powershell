#
$session = New-Object -ComObject Microsoft.Update.Session 
$searcher = $session.CreateUpdateSearcher()

$searchResult = $searcher.Search("IsInstalled=0 and IsHidden=0")
$updates = foreach ($update in $searchResult.Updates) {

    #
    [PSCustomObject]@{
        Title = $update.Title
        KB = $update.KBArticleIDs -join ","
        Classification = @(foreach($cate in $update.Categories){ $cate.Name }) -join ","
        #
        Severity = $update.MsrcSeverity
        RebootNeeded = $update.RebootRequired
        EulaAccepted = $update.EulaAccepted
    }
}
$updates