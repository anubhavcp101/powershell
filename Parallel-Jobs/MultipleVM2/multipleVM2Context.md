
### Required  

* A script in the same directory  ( see line 19 in the $task script block)
*  A csv file with a heading "Name" basically containing names of the VMs.
*  If you don't want to give any heading in the csv file then uncomment ( -Header "Name" ) in line 3


### Output
It will the run the script in the given list of the VMs and output a alljobs.txt which is basically transcript of the Invoke-AzVMRunCommand output