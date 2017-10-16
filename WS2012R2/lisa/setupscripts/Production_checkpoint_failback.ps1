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

<#
.Synopsis
    Verify Production Checkpoint feature.

.Description
    This script will check the Production Checkpoint failback feature.
    VSS daemon will be stopped inside the VM and Hyper-V should be able
    to create a standard checkpoint in this case. 
    The test will pass if a Standard Checkpoint will be made in this case.

    A typical test case definition for this test script would look
    similar to the following:
        <test>
            <testName>ProductionCheckpoint_Failback</testName>
            <testScript>setupscripts\Production_checkpoint_failback.ps1</testScript> 
            <testParams>
                <param>TC_COVERED=PC-02</param>
            </testParams>
            <timeout>2400</timeout>
            <OnError>Continue</OnError>
        </test>

.Parameter vmName
    Name of the VM to perform the test with.

.Parameter hvServer
    Name of the Hyper-V server hosting the VM.

.Parameter testParams
    A semicolon separated list of test parameters.

.Example
    setupScripts\STOR_TakeRevert_Snapshot.ps1 -vmName "myVm" -hvServer "localhost" 
    -TestParams "TC_COVERED=PC-02"
#>

param([string] $vmName, [string] $hvServer, [string] $testParams)

$retVal = $false

#######################################################################
#
# Main script body
#
#######################################################################

# Define and cleanup the summaryLog
$summaryLog  = "${vmName}_summary.log"
echo "Covers Production Checkpoint Testing" > $summaryLog

# Check input arguments
if ($vmName -eq $null)
{
    "ERROR: VM name is null"
    return $retVal
}

# Check input params
$params = $testParams.Split(";")

foreach ($p in $params)
{
  $fields = $p.Split("=")

  switch ($fields[0].Trim())
    {
    "TC_COVERED"  { $TC_COVERED = $fields[1].Trim() }
    "sshKey"      { $sshKey = $fields[1].Trim() }
    "ipv4"        { $ipv4 = $fields[1].Trim() }
    "rootdir"     { $rootDir = $fields[1].Trim() }
     default  {}
    }
}

if ($null -eq $sshKey)
{
    "ERROR: Test parameter sshKey was not specified"
    return $False
}

if ($null -eq $ipv4)
{
    "ERROR: Test parameter ipv4 was not specified"
    return $False
}

if ($null -eq $rootdir)
{
    "ERROR: Test parameter rootdir was not specified"
    return $False
}

echo $params

# Change the working directory to where we need to be
cd $rootDir

Write-output "This script covers test case: ${TC_COVERED}" | Tee-Object -Append -file $summaryLog

# Source the TCUtils.ps1 file
. .\setupscripts\TCUtils.ps1

# if host build number lower than 10500, skip test
$BuildNumber = GetHostBuildNumber $hvServer
if ($BuildNumber -eq 0) {
    return $False
}
elseif ($BuildNumber -lt 10500) {
	"Info: Feature supported only on WS2016 and newer"
    return $Skipped
}

# Check if the Vm VHD in not on the same drive as the backup destination
$vm = Get-VM -Name $vmName -ComputerName $hvServer
if (-not $vm)
{
    "Error: VM '${vmName}' does not exist"
    return $False
}

# Check to see Linux VM is running VSS backup daemon
$sts = RunRemoteScript "STOR_VSS_Check_VSS_Daemon.sh"
if (-not $sts[-1])
{
    Write-Output "ERROR executing STOR_VSS_Check_VSS_Daemon.sh on VM. Exiting test case!" >> $summaryLog
    Write-Output "ERROR: Running STOR_VSS_Check_VSS_Daemon.sh script failed on VM!"
    return $False
}

#Stop the VSS daemon gracefully
$sts = RunRemoteScript "PC_Stop_VSS_Daemon.sh"
if (-not $sts[-1])
{
    Write-Output "ERROR executing PC_Stop_VSS_Daemon.sh on VM. Exiting test case!" >> $summaryLog
    Write-Output "ERROR: Running PC_Stop_VSS_Daemon.sh script failed on VM!"
    return $False
}
Write-Output "VSS Daemon was successfully stopped" >> $summaryLog

#Check if we can set the Production Checkpoint as default
if ($vm.CheckpointType -ne "Production"){
    Set-VM -Name $vmName -CheckpointType Production -ComputerName $hvServer
    if (-not $?)
    {
       Write-Output "Error: Could not set Production as Checkpoint type"  | Out-File -Append $summaryLog
       return $false
    }
}

$random = Get-Random -minimum 1024 -maximum 4096
$snapshot = "TestSnapshot_$random"
Checkpoint-VM -Name $vmName -SnapshotName $snapshot -ComputerName $hvServer
if (-not $?)
{
    Write-Output "Error: Could not create a Standard Checkpoint" | Out-File -Append $summaryLog
    $error[0].Exception.Message
    return $False
}
else {
     Write-Output "Standard Checkpoint successfully created" | Out-File -Append $summaryLog   
}

#
# Delete the snapshot
#
"Info : Deleting Snapshot ${Snapshot} of VM ${vmName}"
Remove-VMSnapshot -VMName $vmName -Name $snapshot -ComputerName $hvServer
if ( -not $?)
{
   Write-Output "Error: Could not delete snapshot"  | Out-File -Append $summaryLog
}

return $true
