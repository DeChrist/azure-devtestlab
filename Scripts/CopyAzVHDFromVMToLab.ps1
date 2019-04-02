[CmdletBinding()]
Param(
    # Enter the subscription ID. It is assumed that both source VM and destination lab are both in
    # this subscription.
    [Parameter(Mandatory = $false)]
    [string]
    $SubscriptionId = '095fe58b-9d09-4c71-ac8a-bb2917647356',

    # Enter the name of the Lab where you want to copy the VHD file.
    [Parameter(Mandatory = $false)]
    [string]
    $LabName = 'dtl_logfas_dev_vm_static',
    
    # Enter the resource group name of the Lab where you want to copy the VHD file.
    [Parameter(Mandatory = $false)]
    [string]
    $LabResourceGroupName = 'rg_logfas_infra',
    
    # Enter the name of the Disk. The VHD file associated with the VM will be copied to the Lab.
    [Parameter(Mandatory = $false)]
    [string]
    $DiskName = 'lgfdvvmbuild02_OsDisk',

    # Enter the name of the VM resource group. The VHD file associated with the VM in this resource group will be copied to the Lab.
    [Parameter(Mandatory = $false)]
    [string]
    $DiskResourceGroupName = 'rg_logfas_migration',

    # Enter the name of the VHD file with extension as .vhd. You will identify the file with this
    # name while creating template.
    [Parameter(Mandatory = $false)]
    [string]
    $VHDFileName = 'lgf-build-srv.vhd',

    # Enter the seconds after the Shared Access Signature on source will expired. Default value is 3600.
    [Parameter(Mandatory = $false)]
    [int]
    $SignatureExpire = 3600
)

###################################################################################################
#
# PowerShell configurations
#

# NOTE: Because the $ErrorActionPreference is "Stop", this script will stop on first failure.
#       This is necessary to ensure we capture all errors inside the try-finally block.
$ErrorActionPreference = 'Stop'

# Ensure we set the working directory to that of the script.
Push-Location $PSScriptRoot

# Used throughout, so define globally.
$Done = 'done.'

###################################################################################################
#
# Handle all errors in this script.
#

trap
{
    # NOTE: This trap will handle all errors. There should be no need to use a catch below in this
    #       script, unless you want to ignore a specific error.
    $message = $error[0].Exception.Message
    if ($message)
    {
        Write-Host -Object "`nERROR: $message" -ForegroundColor Red
    }
    
    # IMPORTANT NOTE: Throwing a terminating error (using $ErrorActionPreference = "Stop") still
    # returns exit code zero from the PowerShell script when using -File. The workaround is to
    # NOT use -File when calling this script and leverage the try-finally block and return
    # a non-zero exit code from the trap.
    exit -1
}

###################################################################################################
#
# Functions used in this script.
#

function Get-AzDtlLab
{
    [CmdletBinding()]
    param(
        [string]
        $Name,
        [string]
        $ResourceGroupName
    )

    return Get-AzResource -ResourceName "$Name" -ResourceGroupName "$ResourceGroupName" -ResourceType 'Microsoft.DevTestLab/labs' -ExpandProperties
}

function Get-AzDtlVirtualMachine
{
    [CmdletBinding()]
    param(
        [string]
        $Name,
        [string]
        $ResourceGroupName
    )

    $vm = Get-AzVM -Name "$Name" -ResourceGroupName "$ResourceGroupName" | Select-Object -First 1
    if (-not $vm)
    {
        throw "Unable to find virtual machine with name '$Name' in resource group '$ResourceGroupName'."
    }
    
    return $vm
}

function Get-AzDtlDisk
{
    [CmdletBinding()]
    param(
        [string]
        $Name,
        [string]
        $ResourceGroupName
    )

    $disk = Get-AzDisk -Name "$Name" -ResourceGroupName "$ResourceGroupName" | Select-Object -First 1
    if (-not $disk)
    {
        throw "Unable to find disk with name '$Name' in resource group '$ResourceGroupName'."
    }
    
    return $disk
}

function Get-AzDtlVirtualMachineCopyContext
{
    [CmdletBinding()]
    param(
        $VM,
        $SignatureExpire
    )

    $vmCopyContext = @{
        IsManaged = $false
        SourceUri = ''
        StorageAccountKey = ''
        StorageAccountName = ''
    }

    $properties = (Get-AzResource -ResourceType $VM.Type -ResourceName $VM.Name -ResourceGroupName $VM.ResourceGroupName).Properties
    
    if ($properties.storageProfile.osDisk.managedDisk.id)
    {
        $managedDiskId = $properties.storageProfile.osDisk.managedDisk.id
        $managedDisk = Get-AzResource -ResourceId $managedDiskId
        $managedDiskUrl = Grant-AzDiskAccess -ResourceGroupName $managedDisk.ResourceGroupName -DiskName $managedDisk.Name -Access Read -DurationInSecond $SignatureExpire
        $vmCopyContext.SourceUri = $managedDiskUrl.AccessSAS
        $vmCopyContext.IsManaged = $true
    }
    elseif ($properties.storageProfile.osDisk.vhd.uri)
    {
        $vmCopyContext.SourceUri = $properties.storageProfile.osDisk.vhd.uri
        [System.Uri] $uri = $vmCopyContext.SourceUri
        $vmCopyContext.StorageAccountName = $uri.Host.Split('.')[0]
        $vmStorageAccount = Get-AzResource -Name $vmCopyContext.StorageAccountName -ResourceType 'Microsoft.Storage/storageAccounts'
        $vmCopyContext.StorageAccountKey = (Get-AzStorageAccountKey -Name $vmCopyContext.StorageAccountName -ResourceGroupName $vmStorageAccount.ResourceGroupName)[0].Value
    }
        
    return $vmCopyContext
}

function Get-AzDtlDiskCopyContext
{
    [CmdletBinding()]
    param(
        $Disk,
        $SignatureExpire
    )

    $diskCopyContext = @{
        IsManaged = $false
        SourceUri = ''
        StorageAccountKey = ''
        StorageAccountName = ''
    }
    
    if ($null -eq $Disk.vhd)
    {
        $managedDiskUrl = Grant-AzDiskAccess -ResourceGroupName $Disk.ResourceGroupName -DiskName $Disk.Name -Access Read -DurationInSecond $SignatureExpire
        $diskCopyContext.SourceUri = $managedDiskUrl.AccessSAS
        $diskCopyContext.IsManaged = $true
    }
    else
    {
        Throw "Unmanaged disks are not supported"
        $diskCopyContext.SourceUri = $Disk.vhd.uri
        [System.Uri] $uri = $diskCopyContext.SourceUri
        $diskCopyContext.StorageAccountName = $uri.Host.Split('.')[0]
        $vmStorageAccount = Get-AzResource -Name $diskCopyContext.StorageAccountName -ResourceType 'Microsoft.Storage/storageAccounts'
        $diskCopyContext.StorageAccountKey = (Get-AzStorageAccountKey -Name $diskCopyContext.StorageAccountName -ResourceGroupName $vmStorageAccount.ResourceGroupName)[0].Value
    }
        
    return $diskCopyContext
}

function Stop-AzDtlVirtualMachine
{
    [CmdletBinding()]
    param(
        $VM
    )

    Stop-AzVM -Name $VM.Name -ResourceGroupName $VM.ResourceGroupName -Force | Out-Null
}

function Copy-AzDtlVirtualMachineVhd
{
    [CmdletBinding()]
    param(
        $CopyContext
    )

    Write-Host "  preparing the destination context ... " -NoNewline
    $destContext = New-AzStorageContext -StorageAccountName $CopyContext.LabStorageAccountName -StorageAccountKey $CopyContext.LabStorageAccountKey
    Write-Host $Done

    $destContainerName = 'uploads'
    Write-Host "  ensuring destination container '$destContainerName' exists ... " -NoNewline
    New-AzStorageContainer -Name $destContainerName -Context $destContext -Permission Off -ErrorAction SilentlyContinue | Out-Null
    Write-Host $Done

    if ($CopyContext.IsVMDiskManaged)
    {
        Write-Host "  copying managed disk ... " -NoNewline
        $copyHandle = Start-AzStorageBlobCopy -AbsoluteUri $CopyContext.VMSourceUri -DestContainer $destContainerName -DestBlob $CopyContext.VHDFileName -DestContext $destContext
    }
    else
    {
        Write-Host "  preparing the source context ... " -NoNewline
        $srcContext = New-AzStorageContext -StorageAccountName $CopyContext.VMStorageAccountName -StorageAccountKey $CopyContext.VMStorageAccountKey
        Write-Host $Done

        Write-Host "  copying unmanaged disk ... " -NoNewline
        $copyHandle = Start-AzStorageBlobCopy -AbsoluteUri $CopyContext.VMSourceUri -Context $srcContext -DestContainer $destContainerName -DestBlob $CopyContext.VHDFileName -DestContext $destContext
    }

    $copyStatus = $copyHandle | Get-AzStorageBlobCopyState
    while ($copyStatus.Status -eq "Pending")
    {
        $copyStatus = $copyHandle | Get-AzStorageBlobCopyState 
        $perComplete = ($copyStatus.BytesCopied / $copyStatus.TotalBytes) * 100
        Write-Progress -Activity "Copying blob ... " -Status "Percentage Complete" -PercentComplete "$perComplete"
        Start-Sleep 10
    }

    Write-Host $Done

    return $copyStatus
}

###################################################################################################
#
# Main execution block.
#

try
{
    Write-Host "Selecting subscription '$SubscriptionId' ... " -NoNewline
    #Select-AzSubscription -SubscriptionId $SubscriptionId | Out-Null # Not yet supported: https://github.com/Azure/azure-powershell/issues/5440
    Set-AzContext -SubscriptionId $SubscriptionId | Out-Null
    Write-Host $Done
    
    Write-Host "Getting lab '$LabName' under resource group '$LabResourceGroupName' ... " -NoNewline
    $lab = Get-AzDtlLab -Name "$LabName" -ResourceGroupName "$LabResourceGroupName"
    Write-Host $Done
    
    Write-Host 'Fetching lab storage account information ... ' -NoNewline
    $labStorageAccountName = $lab.Properties.DefaultStorageAccount.Split('/')[-1]
    $labStorageAccountKey = (Get-AzStorageAccountKey -Name $labStorageAccountName -ResourceGroupName $LabResourceGroupName)[0].Value
    Write-Host $Done

    Write-Host "Getting disk '$DiskName' ... " -NoNewline
    $disk = Get-AzDtlDisk -Name "$DiskName" -ResourceGroupName "$DiskResourceGroupName"
    Write-Host $Done

    # Write-Host "Stopping source virtual machine '$VMName' ... " -NoNewline
    # Stop-AzDtlVirtualMachine -VM $vm
    # Write-Host $Done

    Write-Host 'Preparing copy context ... ' -NoNewline
    $diskCopyContext = Get-AzDtlDiskCopyContext -Disk $disk -SignatureExpire $SignatureExpire
    $copyContext = @{
        VHDFileName = $VHDFileName
        VMSourceUri = $diskCopyContext.SourceUri
        VMStorageAccountKey = $diskCopyContext.StorageAccountKey
        VMStorageAccountName = $diskCopyContext.StorageAccountName
        IsVMDiskManaged = $diskCopyContext.IsManaged
        LabStorageAccountKey = $labStorageAccountKey
        LabStorageAccountName = $labStorageAccountName
        SignatureExpire = $SignatureExpire
    }
    Write-Host $Done

    Write-Host 'Dumping properties used for copy operation.'
    Write-Host "  Lab ID = $($lab.ResourceId)"
    Write-Host "  VM ID = $($vm.Id)"
    Write-Host "  Copy Context: $(ConvertTo-Json $copyContext)"

    Write-Host "Copying VHD '$VHDFileName' to lab '$LabName' ... "
    $copyStatus = Copy-AzDtlVirtualMachineVhd -CopyContext $copyContext
    if ($copyStatus.Status -ne 'Success')
    {
        throw "Unable to copy VHD '$vhdFileName' to lab '$labName'"
    }
    Write-Host $Done
}
finally
{
    1..3 | ForEach-Object { [console]::beep(2500,300) } # Make a sound to indicate we're done.
    Pop-Location
}
