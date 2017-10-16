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
    Setup script that will add a Hard disk to a VM.

.Description
     This is a setup script that will run before the VM is booted.
     The script will create a .vhd file, and mount it to the
     specified hard drive.  If the hard drive does not exist, it
     will be created.

   The .xml entry for a startup script would look like:

         <setupScript>SetupScripts\AddHardDisk.ps1</setupScript>

   The ICA always pass the vmName, hvServer, and a string of testParams
   to statup (and cleanup) scripts.  The testParams for this script have
   the format of:

      ControllerType=Controller Index, Lun or Port, vhd type

   Where
      ControllerType   = The type of disk controller.  IDE or SCSI
      Controller Index = The index of the controller, 0 based.
                         Note: IDE can be 0 - 1, SCSI can be 0 - 3
      Lun or Port      = The IDE port number of SCSI Lun number
      Vhd Type         = Type of VHD to use.
                         Valid VHD types are:
                             Dynamic
                             Fixed
                             Diff (Differencing)
   The following are some examples

   SCSI=0,0,Dynamic : Add a hard drive on SCSI controller 0, Lun 0, vhd type of Dynamic
   SCSI=1,0,Fixed   : Add a hard drive on SCSI controller 1, Lun 0, vhd type of Fixed
   IDE=0,1,Dynamic  : Add a hard drive on IDE controller 0, IDE port 1, vhd type of Fixed

     <testParams>
         <param>SCSI=0,0,Dynamic,4096</param>
         <param>IDE=1,1,Fixed,512</param>
     <testParams>

   will be parsed into the following string by the scripts and passed
   to the setup script:

       "SCSI=0,0,Dynamic;IDE=1,1,Fixed"

   All setup and cleanup scripts must return a boolean ($true or $false)
   to indicate if the script completed successfully.

   Where
      ControllerType   = The type of disk controller.  IDE or SCSI
      Controller Index = The index of the controller, 0 based.
                         Note: IDE can be 0 - 1, SCSI can be 0 - 3
      Lun or Port      = The IDE port number of SCSI Lun number
      Vhd Type         = Type of VHD to use.
                         Valid VHD types are:
                             Dynamic
                             Fixed

   The following are some examples

   SCSI=0,0,Dynamic : Add a hard drive on SCSI controller 0, Lun 0, vhd type of Dynamic disk
   IDE=1,1,Fixed  : Add a hard drive on IDE controller 1, IDE port 1, vhd type of Fixed disk

    A typical XML definition for this test case would look similar
    to the following:
       <test>
            <testName>VHD_SCSI_Fixed</testName>
            <testScript>STOR_Lis_Disk.sh</testScript>
            <files>remote-scripts/ica/STOR_Lis_Disk.sh</files>
            <setupScript>setupscripts\AddHardDisk.ps1</setupScript>
            <cleanupScript>setupscripts\RemoveHardDisk.ps1</cleanupScript>
            <timeout>18000</timeout>
            <testparams>
                    <param>SCSI=0,0,Fixed</param>
            </testparams>
            <onError>Abort</onError>
        </test>

.Parameter vmName
    Name of the VM to remove disk from .

.Parameter hvServer
    Name of the Hyper-V server hosting the VM.

.Parameter testParams
    Test data for this test case

.Example
    setupScripts\AddHardDisk -vmName sles11sp3x64 -hvServer localhost -testParams "SCSI=0,0,Dynamic;sshkey=rhel5_id_rsa.ppk;ipv4=IPaddress;RootDir="

.Link
    None.
#>

param([string] $vmName, [string] $hvServer, [string] $testParams)

$global:MinDiskSize = "1GB"

############################################################################
#
# CreateControllerVHD
#
# Description
#     Create a SCSI controller if one with the ControllerID does not
#     already exist.
#
############################################################################
function CreateControllerVHD([string] $vmName, [string] $server, [string] $controllerID)
{
    #
    # Hyper-V only allows 4 SCSI controllers - make sure the Controller ID is valid
    #
    if ($ControllerID -lt 0 -or $controllerID -gt 3)
    {
        write-output "    Error: Bad SCSI controller ID: $controllerID"
        return $false
    }

    #
    # Check if the controller already exists
    # Note: If you specify a specific ControllerID, Get-VMDiskController always returns
    #       the last SCSI controller if there is one or more SCSI controllers on the VM.
    #       To determine if the controller needs to be created, count the number of
    #       SCSI controllers.
    #
    $maxControllerID = 0
    $CreateControllerVHD = $true
    $controllers = Get-VMScsiController -VMName $vmName -ComputerName $server

    if ($controllers -ne $null)
    {
        if ($controllers -is [array])
        {
            $maxControllerID = $controllers.Length
        }
        else
        {
            $maxControllerID = 1
        }

        if ($controllerID -lt $maxControllerID)
        {
            "Info : Controller exists - controller not created"
            $CreateControllerVHD = $false
        }
    }

    #
    # If needed, create the controller
    #
    if ($CreateControllerVHD)
    {
        $ctrl = Add-VMSCSIController -VMName $vmName -ComputerName $server -Confirm:$false
        if($? -ne $true)
        {
            "Error: Add-VMSCSIController failed to add 'SCSI Controller $ControllerID'"
            return $retVal
        }
        else
        {
            "SCSI Controller successfully added"
        }
    }
}

############################################################################
#
# CreatePassThruDrive
#
# Description
#     If the -SCSI options is false, an IDE drive is created
#
############################################################################
function CreatePassThruDrive([string] $vmName, [string] $server, [switch] $scsi,
                             [string] $controllerID, [string] $Lun)
{
    $retVal = $false

    $controllertype = "IDE"
    if ($scsi)
    {
        $controllertype = "SCSI"

        if ($ControllerID -lt 0 -or $ControllerID -gt 3)
        {
            "Error: CreateHardDrive was passed a bad SCSI Controller ID: $ControllerID"
            return $false
        }

        #
        # Create the SCSI controller if needed
        #
        $sts = CreateControllerVHD $vmName $server $controllerID

        if (-not $sts[$sts.Length-1])
        {
            "Error: Unable to create SCSI controller $controllerID"
            return $false
        }

        $drive = Get-VMScsiController -VMName $vmName -ControllerNumber $ControllerID -ComputerName $server | Get-VMHardDiskDrive -ControllerLocation $Lun
    }
    else
    {
        $drive = Get-VMIdeController -VMName $vmName -ComputerName $server -ControllerNumber $ControllerID | Get-VMHardDiskDrive -ControllerLocation $Lun
    }

    if ($drive)
    {

       if ( $controllerID -eq 0 -and $Lun -eq 0 )
        {
            write-output "Error: drive $controllerType $controllerID $Lun already exists"
            return $retVal
        }
        else
        {
            Remove-VMHardDiskDrive $drive
        }
    }

    $vmGen = GetVMGeneration $vmName $hvServer

    if (($vmGen -eq 1) -and ($controllerType -eq "IDE"))
    {
        $dvd = Get-VMDvdDrive -VMName $vmName -ComputerName $server
        if ($dvd)
        {
            Remove-VMDvdDrive $dvd
        }
    }

    # Create the .vhd file if it does not already exist, then create the drive and mount the .vhdx
    $hostInfo = Get-VMHost -ComputerName $server
    if (-not $hostInfo)
        {
            "ERROR: Unable to collect Hyper-V settings for ${server}"
             return $false
        }

    $defaultVhdPath = $hostInfo.VirtualHardDiskPath
    if (-not $defaultVhdPath.EndsWith("\"))
        {
            $defaultVhdPath += "\"
        }

    $vhdName = $defaultVhdPath + $vmName + "-" + $controllerType + "-" + $controllerID + "-" + $Lun + "-pass"  + ".vhd"
    if(Test-Path $vhdName)
        {
            Dismount-VHD -Path $vhdName -ErrorAction Ignore
            Remove-Item $vhdName
        }
        $newVhd = $null

    $newVhd = New-VHD -Path $vhdName -size 1GB -ComputerName $server -Fixed
    if ($newVhd -eq $null)
        {
            "Error: New-VHD failed to create the new .vhd file: $($vhdName)"
            return $false
        }

    $newVhd = $newVhd | Mount-VHD -Passthru
    $phys_disk = $newVhd | Initialize-Disk -PartitionStyle MBR -PassThru
    $phys_disk | Set-Disk -IsOffline $true

    $ERROR.Clear()
    $phys_disk | Add-VMHardDiskDrive -VMName $vmName -ControllerNumber $controllerID -ControllerLocation $Lun -ControllerType $controllerType -ComputerName $server
    if ($ERROR.Count -gt 0)
        {
            "ERROR: Add-VMHardDiskDrive failed to add drive on ${controllerType} ${controllerID} ${Lun}s"
            $ERROR[0].Exception
            return $false
        }
        else
            {
                $retVal=$true
            }

    "INFO: Successfully attached passthrough drive"
    return $retVal
}

############################################################################
#
# CreateHardDrive
#
# Description
#     If the -SCSI options is false, an IDE drive is created
#
############################################################################
function CreateHardDrive( [string] $vmName, [string] $server, [System.Boolean] $SCSI, [int] $ControllerID,
                          [int] $Lun, [string] $vhdType, [String] $newSize)
{
    $retVal = $false

    "Enter CreateHardDrive $vmName $server $scsi $controllerID $lun $vhdType"

    $controllerType = "IDE"

    #
    # Make sure it's a valid IDE ControllerID.  For IDE, it must 0 or 1.
    # For SCSI it must be 0, 1, 2, or 3
    #
    if ($SCSI)
    {
        if ($ControllerID -lt 0 -or $ControllerID -gt 3)
        {
            "Error: CreateHardDrive was passed a bad SCSI Controller ID: $ControllerID"
            return $false
        }

        #
        # Create the SCSI controller if needed
        #
        $sts = CreateControllerVHD $vmName $server $controllerID
        if (-not $sts[$sts.Length-1])
        {
            "Error: Unable to create SCSI controller $controllerID"
            return $false
        }

        $controllerType = "SCSI"
    }
    else # Make sure the controller ID is valid for IDE
    {
        if ($ControllerID -lt 0 -or $ControllerID -gt 1)
        {
            "Error: CreateHardDrive was passed an invalid IDE Controller ID: $ControllerID"
            return $false
        }
    }

    #
    # If the hard drive exists, complain. Otherwise, add it
    #

    $drive = Get-VMHardDiskDrive -VMName $vmName -ComputerName $hvServer -ControllerType $controllerType -ControllerNumber $controllerID -ControllerLocation $Lun
    if ($drive)
    {

        if ( $controllerID -eq 0 -and $Lun -eq 0 )
        {
            write-output "Error: drive $controllerType $controllerID $Lun already exists"
            return $retVal
        }
        else
        {
             Remove-VMHardDiskDrive $drive
        }
    }

    $vmGen = GetVMGeneration $vmName $hvServer

    if (($vmGen -eq 1) -and ($controllerType -eq "IDE"))
    {
        $dvd = Get-VMDvdDrive -VMName $vmName -ComputerName $hvServer
        if ($dvd)
        {
            Remove-VMDvdDrive $dvd
        }
    }

    #
    # Create the .vhd file if it does not already exist
    #
    $obj = Get-WmiObject -ComputerName $hvServer -Namespace "root\virtualization\v2" -Class "MsVM_VirtualSystemManagementServiceSettingData"

    $defaultVhdPath = $obj.DefaultVirtualHardDiskPath

    if (-not $defaultVhdPath.EndsWith("\"))
    {
        $defaultVhdPath += "\"
    }

    $newVHDSize = ConvertStringToUInt64 $newSize
    $vhdName = $defaultVhdPath + $vmName + "-" + $controllerType + "-" + $controllerID + "-" + $Lun + "-" + $vhdType + ".vhd"
    if(Test-Path $vhdName)
    {
        Dismount-VHD -Path $vhdName -ErrorAction Ignore
        Remove-Item $vhdName
    }
    $fileInfo = GetRemoteFileInfo -filename $vhdName -server $hvServer

    if (-not $fileInfo)
    {
        $newVhd = $null
        switch ($vhdType)
        {
            "Dynamic"
                {
                    $newvhd = New-VHD -Path $vhdName  -size $newVHDSize -ComputerName $server -Dynamic -ErrorAction SilentlyContinue
                }
            "Fixed"
                {
                    $newVhd = New-VHD -Path $vhdName -size $newVHDSize -ComputerName $server -Fixed -ErrorAction SilentlyContinue
                }
            "Physical"
                {
                    Write-Output "Searching for physical drive..."
                    $newVhd = (Get-Disk | Where-Object {($_.OperationalStatus -eq "Offline") -and ($_.Number -eq "$PhyNumber")}).Number
                    Write-Output "Physical drive found: $newVhd"
                }
            "RAID"
                {
                    Write-Host "Searching for RAID disks..."
                    $newVhd = (Get-Disk | Where-Object {($_.OperationalStatus -eq "Offline" -and $_.Number -gt "$PhyNumber")}).Number
                    Write-Output "Physical drive found: $newVhd"
                    sleep 5
                }   
            "Diff"
                {
                    $parentVhdName = $defaultVhdPath + "icaDiffParent.vhd"
                    $parentInfo = GetRemoteFileInfo -filename $parentVhdName -server $hvServer
                    if (-not $parentInfo)
                    {
                        Write-Output "Error: parent VHD does not exist: ${parentVhdName}"
                        return $retVal
                    }
                    $newVhd = New-VHD -Path $vhdName -ParentPath $parentVhdName -ComputerName $server -Differencing
                }
            default
                {
                    Write-Output "Error: unknow vhd type of ${vhdType}"
                    return $retVal
                }
        }
        if ($newVhd -eq $null)
        {
            #On WS2012R2, New-VHD cmdlet throws error even after successfully creation of VHD so re-checking if the VHD available on the server or not
            $newVhdInfo = GetRemoteFileInfo -filename $vhdName -server $hvServer
            if ($newVhdInfo -eq $null)
            {
                write-output "Error: New-VHD failed to create the new .vhd file: $($vhdName)"
                return $retVal
            }
        }
    }
    #
    # Attach the .vhd file to the new drive
    #
    if ($vhdType -eq "RAID")
    {
        Write-Output "Attaching physical drive for RAID..."
        $ERROR.Clear()
        foreach ($i in $newvhd)
        {
            $disk = Add-VMHardDiskDrive -VMName $vmName -ComputerName $server -ControllerType $controllerType -ControllerNumber $controllerID -DiskNumber $i
            if ($ERROR.Count -gt 0)
            {
                "ERROR: Unable to attach physical drive: $i."
                $ERROR[0].Exception
                return $false
            }
        }
    }
    elseif ($vhdType -eq "Physical")
    {
        Write-Output "Attaching physical drive..."
        $ERROR.Clear()
        $disk = Add-VMHardDiskDrive -VMName $vmName -ComputerName $server -ControllerType $controllerType -ControllerNumber $controllerID -DiskNumber $newVhd
        if ($ERROR.Count -gt 0)
        {
            "ERROR: Unable to attach physical drive."
            $ERROR[0].Exception
            return $false
        }
    }
    else
    {
        $disk = Add-VMHardDiskDrive -VMName $vmName -ComputerName $server -ControllerType $controllerType -ControllerNumber $controllerID -ControllerLocation $Lun -Path $vhdName
    }

    if ($disk -contains "Exception")
    {
        write-output "Error: Add_vmharddiskdrive failed to add $($vhdName) to $controllerType $controllerID $Lun $vhdType"
        return $retVal
    }
    else
    {
        write-output "Success"
        $retVal = $true
    }

    return $retVal
}

############################################################################
#
# Main entry point for script
#
############################################################################

$retVal = $true

"AddHardDisk.ps1 -vmName $vmName -hvServer $hvServer -testParams $testParams"

#
# Check input arguments
#
if ($vmName -eq $null -or $vmName.Length -eq 0)
{
    "Error: VM name is null"
    return $false
}

if ($hvServer -eq $null -or $hvServer.Length -eq 0)
{
    "Error: hvServer is null"
    return $false
}

if ($testParams -eq $null -or $testParams.Length -lt 3)
{
    "Error: No testParams provided"
    "AddHardDisk.ps1 requires test params"
    return $false
}

# Source TCUtils
. .\setupScripts\TCUtils.ps1

# Source STOR_VHDXResize_Utils
. .\setupScripts\STOR_VHDXResize_Utils.ps1

#
# Parse the testParams string
#
$params = $testParams.Split(';')
foreach ($p in $params)
{
    if ($p.Trim().Length -eq 0)
    {
        continue
    }

    $temp = $p.Trim().Split('=')

    if ($temp.Length -ne 2)
    {
        "Warn : test parameter '$p' is being ignored because it appears to be malformed"
        continue
    }

    if ($temp[0] -eq "PHYSICAL_NUMBER")
    {
        $PhyNumber = $temp[1]
        continue
    }

    $controllerType = $temp[0]
    if (@("IDE", "SCSI") -notcontains $controllerType)
    {
        # Not a test parameter we are concerned with
        continue
    }

    $SCSI = $false
    if ($controllerType -eq "SCSI")
    {
        $SCSI = $true
    }

    $diskArgs = $temp[1].Trim().Split(',')

    if ($diskArgs.Length -ne 4 -and $diskArgs.Length -ne 3)
    {
        "Error: Incorrect number of arguments: $p"
        $retVal = $false
        continue
    }

    $controllerID = $diskArgs[0].Trim()
    $lun = $diskArgs[1].Trim()
    $vhdType = $diskArgs[2].Trim()

    $VHDSize = $global:MinDiskSize
    if ($diskArgs.Length -eq 4)
    {
        $VHDSize = $diskArgs[3].Trim()
    }

    if (@("Fixed", "Dynamic", "PassThrough", "Diff", "Physical", "RAID") -notcontains $vhdType)
    {
        "Error: Unknown disk type: $p"
        $retVal = $false
        continue
    }

    if ($vhdType -eq "PassThrough")
    {
        "CreatePassThruDrive $vmName $hvServer $scsi $controllerID $Lun"
        $sts = CreatePassThruDrive $vmName $hvServer -SCSI:$scsi $controllerID $Lun
        $results = [array]$sts
        if (! $results[$results.Length-1])
        {
            "Failed to create PassThrough drive"
            $sts
            $retVal = $false
            continue
        }
    }
    else # Must be Fixed, Dynamic, or Diff
    {
        "CreateHardDrive $vmName $hvServer $scsi $controllerID $Lun $vhdType"
        $sts = CreateHardDrive -vmName $vmName -server $hvServer -SCSI:$SCSI -ControllerID $controllerID -Lun $Lun -vhdType $vhdType -newSize $VHDSize
        if (! $sts[$sts.Length-1])
        {
            write-output "Failed to create hard drive"
            $sts
            $retVal = $false
            continue
        }
    }
}

return $retVal