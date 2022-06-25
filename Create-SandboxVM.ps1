###########################################################################################################################################################
<#
# .SYNOPSIS
#       Create a new Managed Azure VM to be used as a sandbox.
#
# .DESCRIPTION
#       Create a new Azure VM with a Managed Disk. The VM utilizes Windows Sandbox to mount a (possibly compromised) VHD so you can safely view the contents. If you'd like to modify the defaults, please review & change the code prior to running. Based on https://github.com/rjmccallumbigl/Azure-PowerShell---Create-New-VM/blob/master/createNewVM.ps1.
#
# .NOTES
        Version: 0.1.0
#
#
# .PARAMETER VMLocalAdminUser
#       The username you will use on your VM. The following restrictions apply:
#       Windows: https://docs.microsoft.com/en-us/azure/virtual-machines/windows/faq#what-are-the-username-requirements-when-creating-a-vm-
#       Linux: https://docs.microsoft.com/en-us/azure/virtual-machines/linux/faq#what-are-the-username-requirements-when-creating-a-vm-
#
# .PARAMETER VMLocalAdminSecurePassword
#       The password you will use on your VM. The following restrictions apply:
#       Windows: https://docs.microsoft.com/en-us/azure/virtual-machines/windows/faq#what-are-the-password-requirements-when-creating-a-vm-
#       Linux: https://docs.microsoft.com/en-us/azure/virtual-machines/linux/faq#what-are-the-password-requirements-when-creating-a-vm-
#
#>
###########################################################################################################################################################

# Set the Parameters for the script
param (
	[Parameter(Mandatory = $true, HelpMessage = "The username you will use on your VM.")]
	[Alias('u')]
	[string]
	$VMLocalAdminUser,
	[Parameter(Mandatory = $true, HelpMessage = "The password you will use on your VM.")]
	[Alias('p')]
	[SecureString]
	$VMLocalAdminSecurePassword
)

# Declare variables, modify as necessary
$vmName = "sandboxVM"
$offerName = "Windows-10"
$skuName = "win10-21h2-ent"
$version = "latest"
$publisherName = "microsoftwindowsdesktop"
$LocationName = "eastus"
$ResourceGroupName = $VMName + "RG"
$VMSize = "Standard_D4s_v3"
$NetworkName = $VMName + "Net"
$NICName = $VMName + "NIC"
$SubnetName = $VMName + "Subnet"
$SubnetAddressPrefix = "10.0.0.0/24"
$VnetAddressPrefix = "10.0.0.0/16"
$PublicIPAddressName = $VMName + "PIP"

# Example image version for all images, modify as necessary
if ([String]::IsNullOrWhiteSpace($version)) {
	$version = "latest"
}

# Get your IP Address to scope remote access to only your IP
$myipaddress = (Invoke-WebRequest https://myexternalip.com/raw).content;

# Create VM configuration
try {
	New-AzResourceGroup -Name $ResourceGroupName -Location $LocationName -ErrorAction Stop
	$Credential = New-Object System.Management.Automation.PSCredential ($VMLocalAdminUser, $VMLocalAdminSecurePassword)
	$VirtualMachine = New-AzVMConfig -VMName $VMName -VMSize $VMSize -ErrorAction Stop

	$VirtualMachine = Set-AzVMOperatingSystem -VM $VirtualMachine -Windows -ComputerName $VMName -Credential $Credential -ProvisionVMAgent -EnableAutoUpdate -ErrorAction Stop
	$nsgRule = New-AzNetworkSecurityRuleConfig -Name AllowRDP -Protocol Tcp -Direction Inbound -Priority 100 -SourceAddressPrefix $myipaddress -SourcePortRange * -DestinationAddressPrefix * -DestinationPortRange 3389 -Access Allow -ErrorAction Stop

	$nsg = New-AzNetworkSecurityGroup -ResourceGroupName $ResourceGroupName -Location $LocationName -Name "$($VMName)NetworkSecurityGroup" -SecurityRules $nsgRule -ErrorAction Stop
	$SingleSubnet = New-AzVirtualNetworkSubnetConfig -Name $SubnetName -AddressPrefix $SubnetAddressPrefix -NetworkSecurityGroupId $nsg.Id -ErrorAction Stop
	$Vnet = New-AzVirtualNetwork -Name $NetworkName -ResourceGroupName $ResourceGroupName -Location $LocationName -AddressPrefix $VnetAddressPrefix -Subnet $SingleSubnet -ErrorAction Stop
	$PIP = New-AzPublicIpAddress -Name $PublicIPAddressName -ResourceGroupName $ResourceGroupName -Location $LocationName -AllocationMethod Dynamic -ErrorAction Stop
	$NIC = New-AzNetworkInterface -Name $NICName -ResourceGroupName $ResourceGroupName -Location $LocationName -SubnetId $Vnet.Subnets[0].Id -PublicIpAddressId $PIP.Id -NetworkSecurityGroupId $nsg.Id -ErrorAction Stop
	$VirtualMachine = Add-AzVMNetworkInterface -VM $VirtualMachine -Id $NIC.Id -ErrorAction Stop
	$VirtualMachine = Set-AzVMSourceImage -VM $VirtualMachine -PublisherName $publisherName -Offer $offerName -Skus $skuName -Version $version -ErrorAction Stop

	# Create VM
	Write-Host "Creating VM $($VMName)..."
	New-AzVM -ResourceGroupName $ResourceGroupName -Location $LocationName -VM $VirtualMachine -Verbose -ErrorAction Stop
	$publicIP = Get-AzPublicIpAddress -Name $PIP.name -ResourceGroupName $ResourceGroupName -ErrorAction Stop
}
catch {
	throw $_
}

# Create data disk large enough to hold VHD
# https://docs.microsoft.com/en-us/azure/virtual-machines/windows/attach-disk-ps
Write-Host "Creating and attaching new data disk..."
$vm = Get-AzVM -Name $vmName -ResourceGroupName $ResourceGroupName
$dataDiskName = "VHDDisk"
$diskConfig = New-AzDiskConfig -SkuName "Premium_LRS" -Location $LocationName -CreateOption Empty -DiskSizeGB 500
$dataDisk1 = New-AzDisk -DiskName $dataDiskName -Disk $diskConfig -ResourceGroupName $ResourceGroupName
$vm = Add-AzVMDataDisk -VM $vm -Name $dataDiskName -CreateOption Attach -ManagedDiskId $dataDisk1.Id -Lun 1
Update-AzVM -VM $vm -ResourceGroupName $ResourceGroupName

# Create script to initialize new disk, install az PowerShell, and instruct user to download VHD from Azure VM on sign in
Write-Host "Initializing Data disk and installing dependencies..."
$scriptName = "initDisk.ps1"
$scriptContents = @'
$disks = Get-Disk | Where partitionstyle -eq 'raw' | sort number;
$letters = 70..89 | ForEach-Object { [char]$_ };
$count = 0;
$labels = "data1","data2";
foreach ($disk in $disks) {
	$driveLetter = $letters[$count].ToString();
	$disk |
	Initialize-Disk -PartitionStyle MBR -PassThru |
	New-Partition -UseMaximumSize -DriveLetter $driveLetter |
	Format-Volume -FileSystem NTFS -NewFileSystemLabel $labels[$count] -Confirm:$false -Force;
	$count++;
	Write-Host $disk;
}
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12;
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Force -Confirm:$false;
Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -confirm:$false;
Install-Module -Name Az -Scope AllUsers -Repository PSGallery -Force -AllowClobber -confirm:$false;
Enable-WindowsOptionalFeature -FeatureName "Containers-DisposableClientVM" -All -Online -NoRestart;

$startScript = @"
# Run on Sandboxed VM and enter the prompts to copy disk over from Azure
Connect-AzAccount
"@
$startScript += "`n$untrustworthyVMName = Read-Host 'What is the name of the problem VM?'"
$startScript += "`n$untrustworthyVMRGName = Read-Host 'What is the Resource Group of the problem VM?'"
$startScript += "`n$virtualMachine = Get-AzVM -ResourceGroupName $untrustworthyVMRGName -Name $untrustworthyVMName"
$startScript += "`nWrite-Host 'Stopping VM...'"
$startScript += "`nStop-AzVM -Name $untrustworthyVMName -ResourceGroupName $untrustworthyVMRGName -Force"
$startScript += "`nWrite-Host 'Granting access to disk...'"
$startScript += "`n$sas = Grant-AzDiskAccess -ResourceGroupName $untrustworthyVMRGName -DiskName $virtualMachine.StorageProfile.OsDisk.Name -Access 'Read' -DurationInSecond 3600"
$startScript += "`nWrite-Host 'Downloading disk...'"
$startScript += "`nStart-BitsTransfer -Source $sas.AccessSAS -dest 'F:\disk.vhd'"
$startScript | Out-File -FilePath "F:\downloadVHD.ps1" -Force -Encoding Default

$startBatch = @"
powershell "F:\downloadVHD.ps1"
"@
$startBatch | Out-File -FilePath "C:\ProgramData\Microsoft\Windows\Start Menu\Programs\StartUp\downloadVHD.bat" -Force -Encoding Default

$mountScript += "`nWrite-Host 'Mounting disk content...'"
$mountScript += "`n$path = md mountPoint;"
$mountScript += "`nMount-WindowsImage -ImagePath disk.vhd -Path $path.FullName -Index 1;"
$mountScript | Out-File -FilePath "F:\mountVHD.ps1" -Force -Encoding Default

$wsbScript = @"
<Configuration>
<VGpu>Default</VGpu>
<Networking>Disable</Networking>
<MappedFolders>
   <MappedFolder>
     <HostFolder>F:\</HostFolder>
     <ReadOnly>Default</ReadOnly>
   </MappedFolder>
</MappedFolders>
<LogonCommand>
   <Command>powershell "& C:\users\WDAGUtilityAccount\Desktop\mountVHD.ps1"</Command>
</LogonCommand>
</Configuration>
"@
$wsbScript | Out-File -FilePath "F:\sandboxConfig.wsb" -Force -Encoding Default
'@
# (New-Object System.Net.WebClient).DownloadFile($sas.AccessSAS, 'disk.vhd') # Replacing with Start-BitsTransfer to get a progress bar
$ScriptContents | Out-File -FilePath $scriptName -Force -Encoding Default

# Push script to Azure VM
Write-Host "Deploying sandbox setup script..."
Invoke-AzVMRunCommand -ResourceGroupName $ResourceGroupName -Name $vmName -CommandId 'RunPowerShellScript' -ScriptPath "$($pwd.Path)\$($scriptName)" -Verbose -Confirm:$false

# Run on created VM to enable Sandbox and restart
Write-Host "Restarting VM..."
Restart-AzVM -ResourceGroupName $ResourceGroupName -Name $vmName

# Remotely connect after sandbox VM setup is complete
Write-Host "Public IP to connect to: $($publicIP.IpAddress)..."
$testingConnection = $true
while ($testingConnection) {
	$pingResults = Test-NetConnection -ComputerName $publicIP.IpAddress -Port 3389 -InformationLevel Quiet
	if ($pingResults) {
		$testingConnection = $false
		mstsc "/v:$($publicIP.IpAddress)"
	}
}
