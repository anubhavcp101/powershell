#
# replace virtualbox with app you want to uninstall
$app = Get-WmiObject -Class Win32_Product | Where Name -Like "*Virtualbox*"
#$app | gm
$app.Uninstall()