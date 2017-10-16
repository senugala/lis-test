########################################################################
#
# Linux on Hyper-V and Azure Test Code, ver. 1.0.0
# Copyright (c) Microsoft Corporation
#
# All rights reserved.
# Licensed under the Apache License, Version 2.0 (the ""License"");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#     http://www.apache.org/licenses/LICENSE-2.0
#
# THIS CODE IS PROVIDED *AS IS* BASIS, WITHOUT WARRANTIES OR CONDITIONS
# OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING WITHOUT LIMITATION
# ANY IMPLIED WARRANTIES OR CONDITIONS OF TITLE, FITNESS FOR A PARTICULAR
# PURPOSE, MERCHANTABLITY OR NON-INFRINGEMENT.
#
# See the Apache Version 2.0 License for specific language governing
# permissions and limitations under the License.
#
########################################################################

<#
.Synopsis
    This script tests the functionality of copying a 3GB large file multiple times.
.Description
    The script will copy a random generated 2GB file multiple times from a Windows host to
    the Linux VM, and then checks if the size is matching.
    A typical XML definition for this test case would look similar
    to the following:
       <test>
		<testName>FCOPY_repeat</testName>
		<setupScript>setupScripts\Add-VHDXForResize.ps1</setupScript>
		<testScript>setupscripts\FCOPY_repeated_delete.ps1</testScript>
		<cleanupScript>SetupScripts\Remove-VHDXHardDisk.ps1</cleanupScript>
		<timeout>1200</timeout>
		<testParams>
			<param>TC_COVERED=FCopy-06</param>
                	<param>Type=Fixed</param>
        		<param>SectorSize=512</param>
                	<param>DefaultSize=3GB</param>
			<param>FileSize=2GB</param>
		</testParams>
		<noReboot>False</noReboot>
	</test>
    NOTE: Make sure DefaultSize is equal or bigger than FileSize.
.Parameter vmName
    Name of the VM to test.
.Parameter hvServer
    Name of the Hyper-V server hosting the VM.
.Parameter testParams
    Test data for this test case.
.Example
    setupScripts\FCOPY_repeated_delete.ps1 -vmName NameOfVm -hvServer localhost -testParams 'sshKey=path/to/ssh;ipv4=ipaddress;FileSize=2GB'
#>

param([string] $vmName, [string] $hvServer, [string] $testParams)

$testfile = $null
$gsi = $null

#######################################################################
#
#   Checks if the file copy daemon is running on the Linux guest
#
#######################################################################
function check_fcopy_daemon()
{
    $filename = ".\fcopy_present"

    .\bin\plink -i ssh\${sshKey} root@${ipv4} "ps -ef | grep '[h]v_fcopy_daemon\|[h]ypervfcopyd' > /tmp/fcopy_present"
    if (-not $?) {
        Write-Error -Message  "ERROR: Unable to verify if the fcopy daemon is running" -ErrorAction SilentlyContinue
        Write-Output "ERROR: Unable to verify if the fcopy daemon is running"
        return $False
    }

    .\bin\pscp -i ssh\${sshKey} root@${ipv4}:/tmp/fcopy_present .
    if (-not $?) {
        Write-Error -Message "ERROR: Unable to copy the confirmation file from the VM" -ErrorAction SilentlyContinue
        Write-Output "ERROR: Unable to copy the confirmation file from the VM"
        return $False
    }

    # When using grep on the process in file, it will return 1 line if the daemon is running
    if ((Get-Content $filename  | Measure-Object -Line).Lines -eq  "1" ) {
        Write-Output "Info: hv_fcopy_daemon process is running."
        $retValue = $True
    }

    del $filename
    return $retValue
}

#######################################################################
#
#   Checks if test file is present
#
#######################################################################
function check_file([String] $testfile)
{
    .\bin\plink -i ssh\${sshKey} root@${ipv4} "wc -c < /mnt/$testfile"
    if (-not $?) {
        Write-Output "ERROR: Unable to read file /mnt/$testfile." -ErrorAction SilentlyContinue
        return $False
    }
    return $True
}

#######################################################################
#
#   Mount disk
#
#######################################################################
function mount_disk()
{
    . .\setupScripts\TCUtils.ps1

    $driveName = "/dev/sdb"

    $sts = SendCommandToVM $ipv4 $sshKey "(echo d;echo;echo w)|fdisk ${driveName}"
    if (-not $sts) {
        Write-Output "ERROR: Failed to format the disk in the VM $vmName." | Tee-Object -Append -file $summaryLog
        return $False
    }

    $sts = SendCommandToVM $ipv4 $sshKey "(echo n;echo p;echo 1;echo;echo;echo w)|fdisk ${driveName}" | Tee-Object -Append -file $summaryLog
    if (-not $sts) {
        Write-Output "ERROR: Failed to format the disk in the VM $vmName."
        return $False
    }

    $sts = SendCommandToVM $ipv4 $sshKey "mkfs.ext3 ${driveName}1"
    if (-not $sts) {
        Write-Output "ERROR: Failed to make file system in the VM $vmName." | Tee-Object -Append -file $summaryLog
        return $False
    }

    $sts = SendCommandToVM $ipv4 $sshKey "mount ${driveName}1 /mnt"
    if (-not $sts) {
        Write-Output "ERROR: Failed to mount the disk in the VM $vmName." | Tee-Object -Append -file $summaryLog
        return $False
    }

    "Info: $driveName has been mounted to /mnt in the VM $vmName."
    return $True
}

#################################################################
#
# Remove file from vm
#
#################################################################
function remove_file_vm(){
    . .\setupScripts\TCUtils.ps1
    $sts = SendCommandToVM $ipv4 $sshKey "rm -f /mnt/$testfile"
    if (-not $sts) {
        return $False
    }
    return $True
}

################################################################
#
# Copy the file to the Linux guest VM
#
################################################################
function copy_file_vm(){
    $Error.Clear()
    Copy-VMFile -vmName $vmName -ComputerName $hvServer -SourcePath $filePath -DestinationPath "/mnt/" -FileSource host -ErrorAction SilentlyContinue
    if ($Error.Count -ne 0) {
        return $False
    }
    return $True
}

####################################################################################
#
# Checking if the file is present on the guest and file size is matching
#
####################################################################################
function check_file_vm(){
    $sts = check_file $testfile
    if (-not $sts[-1]) {
        Write-Output "ERROR: File is not present on the guest VM '${vmName}'!" | Tee-Object -Append -file $summaryLog
        return $False
    }
    elseif ($sts[0] -ne $fileSize) {
        Write-Output "ERROR: The file copied doesn't match the ${originalFileSize} size!" | Tee-Object -Append -file $summaryLog
        return $False
    }
    return $True
}

#######################################################################
#
#   Main body script
#
#######################################################################
$retVal = $false

# Checking the input arguments
if (-not $vmName) {
    "Error: VM name is null!"
    return $retVal
}

if (-not $hvServer) {
    "Error: hvServer is null!"
    return $retVal
}

if (-not $testParams) {
    "Error: No testParams provided!"
    "This script requires the test case ID and VM details as the test parameters."
    return $retVal
}

#
# Checking the mandatory testParams. New parameters must be validated here.
#
$params = $testParams.Split(";")
foreach ($p in $params) {
    $fields = $p.Split("=")

    if ($fields[0].Trim() -eq "TC_COVERED") {
        $TC_COVERED = $fields[1].Trim()
    }
    if ($fields[0].Trim() -eq "rootDir") {
        $rootDir = $fields[1].Trim()
    }
    if ($fields[0].Trim() -eq "ipv4") {
        $IPv4 = $fields[1].Trim()
    }
    if ($fields[0].Trim() -eq "sshkey") {
        $sshkey = $fields[1].Trim()
    }
    if ($fields[0].Trim() -eq "FileSize") {
        $fileSize = $fields[1].Trim()
    }
}

#
# Change the working directory for the log files
# Delete any previous summary.log file, then create a new one
#
if (-not (Test-Path $rootDir)) {
    "Error: The directory `"${rootDir}`" does not exist"
    return $retVal
}
cd $rootDir

# Source TCUtils.ps1
if (Test-Path ".\setupScripts\TCUtils.ps1") {
    . .\setupScripts\TCUtils.ps1
} else {
    "Error: Could not find setupScripts\TCUtils.ps1"
}

# if host build number lower than 9600, skip test
$BuildNumber = GetHostBuildNumber $hvServer
if ($BuildNumber -eq 0)
{
    return $false
}
elseif ($BuildNumber -lt 9600)
{
    return $Skipped
}
# Delete any previous summary.log file, then create a new one
$summaryLog = "${vmName}_summary.log"
del $summaryLog -ErrorAction SilentlyContinue
Write-Output "This script covers test case: ${TC_COVERED}" | Tee-Object -Append -file $summaryLog

$retVal = $True

#
# Verify if the Guest services are enabled for this VM
#
$originalFileSize = $fileSize
$fileSize = $fileSize/1

$gsi = Get-VMIntegrationService -vmName $vmName -ComputerName $hvServer -Name "Guest Service Interface"
if (-not $gsi) {
    "Error: Unable to retrieve Integration Service status from VM '${vmName}'" | Tee-Object -Append -file $summaryLog
    return $False
}

if (-not $gsi.Enabled) {
    "Warning: The Guest services are not enabled for VM '${vmName}'" | Tee-Object -Append -file $summaryLog
    if ((Get-VM -ComputerName $hvServer -Name $vmName).State -ne "Off") {
        Stop-VM -ComputerName $hvServer -Name $vmName -Force -Confirm:$false
    }

    # Waiting until the VM is off
    while ((Get-VM -ComputerName $hvServer -Name $vmName).State -ne "Off") {
        Start-Sleep -Seconds 5
    }

    Enable-VMIntegrationService -Name "Guest Service Interface" -vmName $vmName -ComputerName $hvServer
    Start-VM -Name $vmName -ComputerName $hvServer

    # Waiting for the VM to run again and respond to SSH - port 22
    do {
        sleep 5
    } until (Test-NetConnection $IPv4 -Port 22 -WarningAction SilentlyContinue | ? { $_.TcpTestSucceeded } )
}

# Get VHD path of tested server; file will be copied there
$vhd_path = Get-VMHost -ComputerName $hvServer | Select -ExpandProperty VirtualHardDiskPath

# Fix path format if it's broken
if ($vhd_path.Substring($vhd_path.Length - 1, 1) -ne "\"){
    $vhd_path = $vhd_path + "\"
}

$vhd_path_formatted = $vhd_path.Replace(':','$')

# Define the file-name to use with the current time-stamp
$testfile = "testfile-$(get-date -uformat '%H-%M-%S-%Y-%m-%d').file"

$filePath = $vhd_path + $testfile
$file_path_formatted = $vhd_path_formatted + $testfile

if ($gsi.OperationalStatus -ne "OK") {
    "Error: The Guest services are not working properly for VM '${vmName}'!" | Tee-Object -Append -file $summaryLog
    $retVal = $False
}
else {
    # Create a sample file
    $createfile = fsutil file createnew \\$hvServer\$file_path_formatted $fileSize

    if ($createfile -notlike "File *testfile-*.file is created") {
        "Error: Could not create the sample test file in the working directory!" | Tee-Object -Append -file $summaryLog
        $retVal = $False
    }
}

# Verifying if /tmp folder on guest exists; if not, it will be created
.\bin\plink.exe -i ssh\${sshKey} root@${ipv4} "[ -d /tmp ]"
if (-not $?){
    Write-Output "Folder /tmp not present on guest. It will be created"
    .\bin\plink.exe -i ssh\${sshKey} root@${ipv4} "mkdir /tmp"
}

#
# The fcopy daemon must be running on the Linux guest VM
#
$sts = check_fcopy_daemon
if (-not $sts[-1]) {
    Write-Output "ERROR: File copy daemon is not running inside the Linux guest VM!" | Tee-Object -Append -file $summaryLog
    $retVal = $False
}

$sts = mount_disk
if (-not $sts[-1]) {
    Write-Output "ERROR: Failed to mount the disk in the VM." | Tee-Object -Append -file $summaryLog
    $retVal = $False
}

#
# Run the test
#
for($i=0; $i -ne 4; $i++){
    if ($retval) {
        $sts = copy_file_vm
        if (-not $sts) {
            Write-Output "ERROR: File could not be copied!" | Tee-Object -Append -file $summaryLog
            $retVal = $False
            break
        }
        Write-Output "Info: File has been successfully copied to guest VM '${vmName}'"

        $sts = check_file_vm
        if (-not $sts) {
            Write-Output "ERROR: File check error on the guest VM '${vmName}'!" | Tee-Object -Append -file $summaryLog
            $retVal = $False
            break
        }
        Write-Output "Info: The file copied matches the ${originalFileSize} size."

        $sts = remove_file_vm
        if (-not $sts) {
            Write-Output "ERROR: Failed to remove file from VM $vmName." | Tee-Object -Append -file $summaryLog
            $retVal = $False
            break
        }
        Write-Output "Info: File has been successfully removed from guest VM '${vmName}'"
    }
    else {
        break
    }
}

#
# Removing the temporary test file
#
Remove-Item -Path \\$hvServer\$file_path_formatted -Force
if (-not $?) {
    Write-Output "ERROR: Cannot remove the test file '${testfile}'!" | Tee-Object -Append -file $summaryLog
}

return $retVal
