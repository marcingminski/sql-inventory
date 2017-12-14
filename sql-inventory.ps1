<#
----------------------------------------------------------------------------------------
SQL Server Inventory
https://github.com/marcingminski/sql-inventory
----------------------------------------------------------------------------------------
Description:
    Super Simple SQL server inventory tool that produces HTML output with simple
    validation - RAG status of each check. This script can be also run to find SQL servers
    in the environment, if a list of IPs is fed, it will check if the server is SQL and
    then run inventory.

Author: 
    Marcin Gminski

Parameters:
    - InputFile
        Mandatory. Either a txt file with servers or a comma separated server list
    
    - Product
        Not Mandatory. Logical name to group results by i.e. FINANCE, HR, OTHER, PRODUCTION, DEV, etc.

    - OutputPath
        Location of the output html file
 
Current limitations:
    - it does not work with named instances. It can find them through WMI but wont be able to connect.
        to make it work with instances we would have to scan WMI first, get list of instances and
        then connect to each instance for a given hostname. This however bring other challenges
        such as WMI often having permission problems for non-domain joined servers (and even joined ones)
        Also in large enterprise environments often WMI will require different account to SQL
    - it does not work with non-standard ports.

Usage:
    --feed from flat file:
    .\sql-inventory.ps1 -InputList SqlServers1.txt -Product SqlServers1 -MaxThreads 4 -OutputPath C:\SQL-INVENTORY
    
    --feed from list:
    .\sql-inventory.ps1 -InputList sqlserver1,sqlserver2,sqlserver3 -Product ad-hoc -MaxThreads 4 -OutputPath C:\SQL-INVENTORY
#>
param(
    [parameter(Mandatory = $true)] [string[]]$InputList,
    [parameter(Mandatory = $false)] [string]$Product,
    [parameter(Mandatory = $false)] [string]$OutputPath="$((Resolve-Path .\).Path)",
    [parameter(Mandatory = $false)] [int]$MaxThreads=10,
    [parameter(Mandatory = $false)] [boolean]$SimpleInventory=$false
)

#----------------------------------------------------------------------------------------
# basic configuration:
#----------------------------------------------------------------------------------------
$ErrorActionPreference="Continue"

#set the output html file name:
$OutputFile="$OutputPath\sql-inventory_$(if($Product){$Product+"_"})$(Get-Date -format "yyyyMMdd_HHmmss")"

#----------------------------------------------------------------------------------------
# environment definition
# this will help categorise servers with a good naming standard. It will look for the below pattern
# in the hostname and assign LIVE,NON-PROD or WORKSTATION category so for example:
# sql-live-01, sql-prod-01, prod-sql-002 etc will have label LIVE
#----------------------------------------------------------------------------------------
$Environments = @{}
$Environments['LIVE']="PRD,PROD,LIVE"
$Environments['NON-PROD']="DEV,TEST,UAT"
$Environments['WORKSTATIONS']="WKS"

#----------------------------------------------------------------------------------------
# sql product information and end of support dates:
# https://support.microsoft.com/en-gb/lifecycle/search?alpha=sql%20server
# we are going to use this to flag up any servers that are no longer supported
#----------------------------------------------------------------------------------------
$SQLProducts=@{}
$SQLProducts['8*']=@{ProductName='SQL SERVER 2000'; EndOfMainSupport="08/04/2008"; EndOfExtendedSupport="09/04/2013"; RTM="11/07/2002"; SP1="28/02/2002"; SP2="07/04/2003"; SP3="10/07/2007"; SP4="08/04/2008"}
$SQLProducts['9*']=@{ProductName='SQL SERVER 2005'; EndOfMainSupport="12/04/2011"; EndOfExtendedSupport="12/04/2016"; RTM="10/07/2007"; SP1="08/04/2008"; SP2="12/01/2010"; SP3="10/01/2012"; SP4="12/04/2011"}
$SQLProducts['10.0*']=@{ProductName='SQL SERVER 2008'; EndOfMainSupport="08/07/2014"; EndOfExtendedSupport="09/07/2019"; RTM="13/04/2010"; SP1="11/10/2011"; SP2="09/10/2012"; SP3="13/10/2015"; SP4="08/07/2014"} 
$SQLProducts['10.5*']=@{ProductName='SQL SERVER 2008 R2'; EndOfMainSupport="08/07/2014"; EndOfExtendedSupport="09/07/2019"; RTM="10/07/2012"; SP1="08/10/2013"; SP2="13/10/2015"; SP3="08/07/2014"} 
$SQLProducts['11*']=@{ProductName='SQL SERVER 2012'; EndOfMainSupport="11/07/2017"; EndOfExtendedSupport="12/07/2022"; RTM="14/01/2014"; SP1="14/07/2015"; SP2="10/01/2017"; SP3="11/07/2017"}
$SQLProducts['12*']=@{ProductName='SQL SERVER 2014'; EndOfMainSupport="09/07/2019"; EndOfExtendedSupport="09/07/2024"; RTM="12/07/2016"; SP1="10/10/2017"; SP2="09/07/2019"} 
$SQLProducts['13*']=@{ProductName='SQL SERVER 2016'; EndOfMainSupport="13/07/2021"; EndOfExtendedSupport="14/07/2026"; RTM="09/01/2018"; SP1="13/07/2021"}

#----------------------------------------------------------------------------------------
# windows product information:
# https://msdn.microsoft.com/en-gb/library/windows/desktop/ms724832(v=vs.85).aspx
# we are going to use this to tarnslate OS version into human readable string:
#----------------------------------------------------------------------------------------
$WindowsProducts=@{}
$WindowsProducts['5.0*']='Microsoft Windows 2000'
$WindowsProducts['5.1*']='Microsoft Windows XP'
$WindowsProducts['5.2*']='Microsoft Windows Server 2003'
$WindowsProducts['6.0*']='Microsoft Windows Server 2008'
$WindowsProducts['6.1*']='Microsoft Windows Server 2008 R2'
$WindowsProducts['6.2*']='Microsoft Windows Server 2012'
$WindowsProducts['6.3*']='Microsoft Windows Server 2012 R2'
$WindowsProducts['10.0*']='Microsoft Windows Server 2016'

#----------------------------------------------------------------------------------------
# html styling
# sit tight - I am not a web developer...
#----------------------------------------------------------------------------------------
$htmlhead="
<!DOCTYPE HTML PUBLIC '-//W3C//DTD HTML 4.01 Frameset//EN' 'http://www.w3.org/TR/html4/frameset.dtd'/>
<html>
    <head>
    <title>sql-inventory $($Product) $(Get-Date)</title>

    <script type='text/javascript' src='https://code.jquery.com/jquery-2.2.4.min.js'></script>
    <script type='text/javascript' src='https://cdnjs.cloudflare.com/ajax/libs/sticky-table-headers/0.1.19/js/jquery.stickytableheaders.min.js'></script>
    <link href='https://fonts.googleapis.com/css?family=Roboto+Mono' rel='stylesheet'>

    <style type='text/css'>
    <!–
    body {font-family: 'Roboto Mono', monospace; }
    body { margin:0; }
    form {display: inline-block; //Or display: inline; }
    td.error { background: #FF7070; }
    td.warning { background: #FFCC33; }
    td.pass { background: #BDFFBD; }
    .transposedy {white-space: nowrap;}
    .transposedx {max-width: 350px;}

    table{border-collapse: separate;border-spacing: 0; border: 0px solid grey;font: 10pt Verdana, Geneva, Arial, Helvetica, sans-serif;color: black;margin: 0px;padding: 0px;}
    table th {font-size: 10px;font-weight: bold;padding-left: 3px;padding-right: 3px;text-align: left;white-space:nowrap;color: white;background-color: #3D3D3D;border-right: 1px solid grey; border-bottom: 1px solid grey;}
    table td {vertical-align: text-top; font-size: 10px;padding-left: 2px;padding-right: 5px;text-align: left;border-right: 1px solid grey; border-bottom: 1px solid grey; }
    table tr {vertical-align: text-top; transition: background 0.2s ease-in;}
    table tr:hover {background:  #ffff99;filter: brightness(90%);cursor: pointer;}
    .highlight {background:  #ffff99;filter: brightness(90%);}
    table.list{ float: left; }
    br {mso-data-placement:same-cell;}
    –>
    </style>
</head>"

$htmlpre+="<div><input type='submit' value='transpose' id='transpose'><form><input type='text' id='search' placeholder='Type here to search' style='border:0px; margin-left:10px;'></form></div>"

$htmlpost = "<script type='text/javascript'>
`$('#transpose').click(function() {
  var rows = `$('table tr');
  var r = rows.eq(0);
  var nrows = rows.length;
  var ncols = rows.eq(0).find('th,td').length;

  var i = 0;
  var tb = `$('<tbody></tbody>');

  while (i < ncols) {
    cell = 0;
    tem = `$('<tr></tr>');
    while (cell < ncols) {
      next = rows.eq(cell++).find('th,td').eq(0);
      tem.append(next);
    }
    tb.append(tem);
    ++i;
  }
  `$('table').append(tb);
  `$('table').show();
  `$('table td').removeClass('transposedy');
  `$('table td').addClass('transposedx');
});


`$(document).ready(function(){
//replace stupid powershell table tags with proper html tags:
//http://ben.neise.co.uk/formatting-powershell-tables-with-jquery-and-datatables/
	`$('table').each(function(){
		// Grab the contents of the first TR element and save them to a variable
		var tHead = `$(this).find('tr:first').html();
		// Remove the first COLGROUP element 
		`$(this).find('colgroup').remove(); 
		// Remove the first TR element 
		`$(this).find('tr:first').remove();
		// Add a new THEAD element before the TBODY element, with the contents of the first TR element which we saved earlier. 
		`$(this).find('tbody').before('<thead>' + tHead + '</thead>'); 
		});

//add different css based on header position (tranpose)
`$('table td').addClass('transposedy');
`$('table td').removeClass('transposedx');

//data table
	//`$('table').DataTable();
//floating header:
    //`$('table').floatThead({scrollingTop:50});
	//`$('table').stickyTableHeaders();
	
//search table:
	var `$rows = `$('table tbody tr');
	`$('#search').keyup(function() {
		var val = `$.trim(`$(this).val()).replace(/ +/g, ' ').toLowerCase();
		
		`$rows.show().filter(function() {
			var text = `$(this).text().replace(/\s+/g, ' ').toLowerCase();
			return !~text.indexOf(val);
		}).hide();
	});	
	
//change color of clicked row:
	`$('table tr').click(function() {
		var selected = `$(this).hasClass('highlight');
		`$('table tr').removeClass('highlight');
		if(!selected)
				`$(this).addClass('highlight');
	});
});
</script>"

$html = @{
    head=$htmlhead 
    pre = $htmlpre
    post = $htmlpost
}


#----------------------------------------------------------------------------------------
# Workflow Function so we can run inventory in parralel threads. Best performance is to run
# 1 thread per CPU core but I often run 25 threads for over 3000 servers on a 4 core laptop and it
# copes quite well.
#----------------------------------------------------------------------------------------
Workflow Get-SQLInventory {
    param (
        [parameter(Mandatory=$true)] [string[]]$servers,
        [parameter(Mandatory = $true)] [int]$maxThreads,
        [parameter(Mandatory = $true)] [string]$OutputFile,
        [parameter(Mandatory = $true)] [string]$OutputPath,
        [parameter(Mandatory = $true)] [hashtable]$SQLProducts,
        [parameter(Mandatory = $true)] [hashtable]$WindowsProducts,     
        [parameter(Mandatory = $true)] [hashtable]$Environments,
        [parameter(Mandatory = $true)] [boolean]$SimpleInventory,
        [parameter(Mandatory = $true)] [hashtable]$Html,
        [parameter(Mandatory = $true)] [string]$Product
    )

    foreach -parallel -throttlelimit $maxThreads ($server in $servers) {

        $configs = InlineScript {

            $server=$using:server
            $OutputFile=$using:Outputfile
            $OutputPath=$using:OutputPath
            $SQLIdentifier=$using:SQLIdentifier
            $SQLProducts=$using:SQLProducts
            $WindowsProducts=$using:WindowsProducts
            $Environments=$using:Environments
            $Html=$using:Html
            $Product=$using:Product

            #----------------------------------------------------------------------------------------
            # this is required for PS to properly interpret dates it gets from SQL in strings:
            #----------------------------------------------------------------------------------------
            $cultureUS = New-Object system.globalization.cultureinfo(“en-US”)
            $cultureUK = New-Object system.globalization.cultureinfo(“en-GB”)

            #----------------------------------------------------------------------------------------
            # simple implementation of Coalesce function:
            #----------------------------------------------------------------------------------------
            function Coalesce($a, $b) { if ($a -ne $null) { $a } else { $b } }

            #----------------------------------------------------------------------------------------
            # data validation. this is function  will compare input with desire valued
            # and return the input with a prefix that we can later regex in html and 
            # apply specific css styling for error,warning and pass. This is the key
            # function to make this script report red/amber/green for different values.
            #----------------------------------------------------------------------------------------
            function validate{
            param([string]$currentvalue,[string]$desiredvalue,[string]$level)
            [string]$level=$level.ToLower()

                if(!$desiredvalue) {
                    $desiredvalue="N/A"
                    $output=$currentvalue
                } else {
                    if($desiredvalue.ToString().Length -gt 1){
                        switch ($desiredvalue.substring(0,1)){
                        "<" {$output= if([int]$currentvalue -lt [int]$desiredvalue.substring(1,$($desiredvalue.ToString().Length)-1)){"^pass^$currentvalue"}else{"^$level^$currentvalue"}}
                        ">" {$output= if([int]$currentvalue -gt [int]$desiredvalue.substring(1,$($desiredvalue.ToString().Length)-1)){"^pass^$currentvalue"}else{"^$level^$currentvalue"}}
                        "!" {$output= if($currentvalue -ne $desiredvalue.substring(1,$($desiredvalue.ToString().Length)-1)){"^pass^$currentvalue"}else{"^$level^$currentvalue"}}
                        "=" {$output= if($currentvalue -eq $desiredvalue.substring(1,$($desiredvalue.ToString().Length)-1)){"^pass^$currentvalue"}else{"^$level^$currentvalue"}}
                        "*" {$output= if($currentvalue -ne ""){"^pass^$currentvalue"}else{"^$level^$currentvalue"}}
                        }
                    }
                }
                return $output
            }


            #----------------------------------------------------------------------------------------
            # create hashtable to store inventory results.
            # creating empty record upfront allows us to track all servers including those
            # that we could not connect to. The inventory is made out of two parts: SQL and WMI.
            # with SQL being the obvious SQL level and WMI getting all the OS level data.
            #----------------------------------------------------------------------------------------
            $InventoryInfo=[PSCustomObject] @{
                SystemUnderScan=$server
                ServerEnvironment="UNKNOWN"
                ServerRole="NOT-MSSQL"
                InventorySQL=$false
                InventoryWMI=$false
                InventorySQLError=$null
                InventoryWMIError=$null
            }
           
            #----------------------------------------------------------------------------------------
            # get DNS name for any IPs passed into the function:
            #----------------------------------------------------------------------------------------
            if ([bool]($InventoryInfo.SystemUnderScan  -as [ipaddress])) {
                $dns=$nul
                try {
                    $dns=([system.net.dns]::GetHostByAddress($server)).hostname
                    if ($dns) {
                        if ($dns -notlike "unmanaged*") {
                           $server=$dns
                           }
                       }           
                }
                catch {$dns=$($Error[0].Exception.Message)}
            } else {
                $dns="No IP supplied"
                }

            #----------------------------------------------------------------------------------------
            # set array with environments and strings to look for in either server name or domain later on when we get WMI:
            #----------------------------------------------------------------------------------------
            foreach ($Environment in $Environments.GetEnumerator() | Sort-Object {$_.Name}) {
                if($null -ne ($Environment.Value.Split(",") | ? { $server -match $_ })) {
                    $InventoryInfo.ServerEnvironment=$Environment.Name
                    }
                }

            #----------------------------------------------------------------------------------------
            # if name contains the word SQL or DB then flag is as potential SQL instance - i.e. update ServerRole from
            # NOT-MSSQL to POTENTIAL-MSSQL (potential MSSQL)
            #----------------------------------------------------------------------------------------
            if ($null -ne ("SQL,DB".Split(",") | ? { $server -match $_ })) {
                $InventoryInfo.ServerRole="POTENTIAL-MSSQL"
                }

            #----------------------------------------------------------------------------------------
            # check if we can connect to SQL and that we have permissions. Note we do not use PING
            # as ICMP are often disabled in Enterprise enviroments so most fantastic products like
            # SQL Power Doc, Microsoft MAP toolkit do not work. 
            #----------------------------------------------------------------------------------------
            $x = $null
            $InventoryInfo.InventorySQLError=$False
            try {$x = Invoke-Sqlcmd -Query "select top 1 name from master.sys.databases where name='master';" -ServerInstance $server -QueryTimeout 3000 -ErrorAction 'Stop'}
            catch {
                $InventoryInfo.InventorySQLError=$($Error[0].Exception.Message)
                $x = $null
                if ($InventoryInfo.InventorySQLError -notlike "A network-related or instance-specific error occurred while establishing a connection to SQL Server.*") {
                        $InventoryInfo.ServerRole="MSSQL"
                    }
                }
               
            #----------------------------------------------------------------------------------------
            # if we can connect and have permissions, carry on getting SQL inventory:
            #----------------------------------------------------------------------------------------
            if ($x) {
                $InventoryInfo.InventorySQL=$True
                $InventoryInfo.ServerRole="MSSQL"

                # load SMO objects
                [System.Reflection.Assembly]::LoadWithPartialName('Microsoft.SqlServer.SMO') | out-null
                $sql = New-Object ('Microsoft.SqlServer.Management.Smo.Server') $server

                # store SQL inventory details in a hashtable:
                $SQLInventory=[PSCustomObject] @{

                    # setting properties:
                    AuditLevel=$($sql.Settings.Properties | Where-Object {$_.name -eq "AuditLevel"} | select Value).value
                    LoginMode=$($sql.Settings.Properties | Where-Object {$_.name -eq "LoginMode"} | select Value).value
                    NumberOfLogFiles=$($sql.Settings.Properties | Where-Object {$_.name -eq "NumberOfLogFiles"} | select Value).value

                    # information properties:
                    OS = $($sql.Information.Properties | Where-Object  {$_.name -eq "OS"} | select value).value
                    OSVersion = $($sql.Information.Properties | Where-Object  {$_.name -eq "OSVersion"} | select value).value
                    ServerType = $($sql.Information.Properties | Where-Object  {$_.name -eq "ServerType"} | select value).value
                    edition = $($sql.Information.Properties | Where-Object {$_.name -eq "edition"} | select value).value 
                    Platform = $($sql.Information.Properties | Where-Object  {$_.name -eq "Platform"} | select value).value 
                    Product = $($sql.Information.Properties | Where-Object  {$_.name -eq "Product"} | select value).value
                    ProductLevel = $($sql.Information.Properties | Where-Object  {$_.name -eq "ProductLevel"} | select value).value

                    VersionString = $($sql.Information.Properties | Where-Object  {$_.name -eq "VersionString"} | select value).value
                    Language = $($sql.Information.Properties | Where-Object  {$_.name -eq "Language"} | select value).value
                    Processors = $($sql.Information.Properties | Where-Object  {$_.name -eq "Processors"} | select value).value
                    PhysicalMemory = $($sql.Information.Properties | Where-Object  {$_.name -eq "PhysicalMemory"} | select value).value
                    RootDirectory = $($sql.Information.Properties | Where-Object  {$_.name -eq "RootDirectory"} | select value).value
                    ErrorLogPath = $($sql.ErrorLogPath)
                    HasNullSAPassword = $($null -ne $($($sql.Information.Properties | Where-Object {$_.Name -eq 'HasNullSaPassword'} | select value).value))

                    # configuration properties:
                    MaxServerMemory = $($sql.Configuration.Properties | Where-Object  {$_.Displayname -eq "max server memory (MB)"} | select configValue).configValue 
                    MinServerMemory = $($sql.Configuration.Properties | Where-Object  {$_.Displayname -eq "min server memory (MB)"} | select configValue).configValue 
                    xp_cmdshell =  $($sql.Configuration.Properties | Where-Object  {$_.Displayname -eq "xp_cmdshell"} | select configValue).configValue 
                    OptimizeAdhocWorkloads = $($sql.Configuration.Properties | Where-Object  {$_.Displayname -eq "optimize for ad hoc workloads"} | select configValue).configValue 
                    DefaultBackupCompression = $($sql.Configuration.Properties | Where-Object  {$_.Displayname -eq "backup compression default"} | select configValue).configValue
                    DatabaseMail = $($sql.Configuration.Properties | Where-Object  {$_.Displayname -eq "Database Mail XPs"} | select configValue).configValue
                    #DAC = $($sql.Configuration.Properties | Where-Object  {$_.Displayname -eq "remote admin connections"} | select configValue).configValue
                    DefaultTrace = $($sql.Configuration.Properties | Where-Object  {$_.Displayname -eq "default trace enabled"} | select configValue).configValue
                    CLREnabled = $($sql.Configuration.Properties | Where-Object  {$_.Displayname -eq "clr enabled"} | select configValue).configValue
                    ScanForStartupProcs = $($sql.Configuration.Properties | Where-Object  {$_.Displayname -eq "scan for startup procs"} | select configValue).configValue
                    MaxDOP = $($sql.Configuration.Properties | Where-Object  {$_.Displayname -eq "max degree of parallelism"} | select configValue).configValue
                    CostThreshold = $($sql.Configuration.Properties | Where-Object  {$_.Displayname -eq "cost threshold for parallelism"} | select configValue).configValue
                    C2AuditMode = $($sql.Configuration.Properties | Where-Object  {$_.Displayname -eq "c2 audit mode"} | select configValue).configValue
                    NetworkPacketSize = $($sql.Configuration.Properties | Where-Object  {$_.Displayname -eq "network packet size (B)"} | select configValue).configValue
                    BackupChecksumDefault = $($sql.Configuration.Properties | Where-Object  {$_.Displayname -eq "backup checksum default"} | select configValue).configValue
                    RemoteAdminConnections = $($sql.Configuration.Properties | Where-Object  {$_.Displayname -eq "remote admin connections"} | select configValue).configValue

                    # logins
                    IsSaDisabled = $($sql.Logins | Where-Object {$_.Name -eq "sa"} | Select IsDisabled).IsDisabled
                    ServerRoles = [string]$($sql.Roles | ForEach-Object {$_.Name + "`r`n"})

                    # custom sql:
                    DatabaseCount=$sql.Databases.count
                    DatabaseTotalSize="{0:N2}" -f $($($sql.Databases | Measure-Object -Property Size -sum).Sum/1024)
                    Databases=$sql.Databases | ForEach-Object {$_.Name + " (" + "{0:N2}" -f $($_.Size/1024) + " GB; " + $_.RecoveryModel + ")`r`n"}
                    DataFiles = $sql.Databases | Sort-Object {$_.Name} | ForEach-Object {$_.FileGroups | ForEach-Object {$_.Files | ForEach-Object {$_.Name + ': ' + $_.FileName + ': (' + "{0:N2}" -f $($_.Size/1024/1024) + " GB)`r`n"}}}
                    LogFiles = $sql.Databases | Sort-Object {$_.Name} | ForEach-Object {$_.LogFiles  | ForEach-Object {$_.Name + ': ' + $_.FileName + ': (' + "{0:N2}" -f $($_.Size/1024/1024) + " GB)`r`n"}}
                    DbsWithoutChecsum = [string]$($sql.Databases | Where-Object {$_.PageVerify -ne "Checksum"} | Foreach-Object {$_.Name + "`r`n"})
                    DbsNotOwnedBySA = [string]$($sql.Databases | Where-Object {$_.Owner -ne "sa"} | ForEach-Object {$_.Name + "`r`n"})
                    DbsWithOldBackup = [string]$($sql.Databases | Where-Object {$(((Get-Date) - $_.LastBackupDate).TotalHours -gt 48) -and $_.Name -ne "tempdb" } | ForEach-Object {$_.Name + ": " + $([string]$($([datetime]::ParseExact($($_.LastLogBackupDate), "MM/dd/yyyy HH:mm:ss", $cultureUS)).ToString('dd/MM/yyyy HH:mm:ss',$cultureUK))) + "`r`n"})
                    DbsWithOldLogBackup = [string]$($sql.Databases | Where-Object {$(((Get-Date) - $_.LastLogBackupDate).TotalHours -gt 48) -and $_.Name -ne "tempdb" -And $_.RecoveryModel -ne "Simple" } | ForEach-Object {$_.Name + ": " + $([string]$($([datetime]::ParseExact($($_.LastLogBackupDate), "MM/dd/yyyy HH:mm:ss", $cultureUS)).ToString('dd/MM/yyyy HH:mm:ss',$cultureUK))) + "`r`n"})
                    Sysadmins=[string]$($sql.Logins | Where-Object {$_.IsMember('sysadmin')} | ForEach-Object {$_.Name + "`r`n"})
                    DatabaseBackups = [string]$($sql.Databases | Where-Object {$_.Name -ne "tempdb" } | ForEach-Object {$_.Name + ": " + $([string]$($([datetime]::ParseExact($($_.LastBackupDate), "MM/dd/yyyy HH:mm:ss", $cultureUS)).ToString('dd/MM/yyyy HH:mm:ss',$cultureUK))) + "; " + $_.LastBackupType + "`r`n"})

                }

                #----------------------------------------------------------------------------------------
                # the smo minor version returns 0, it does not work, dunno why. 
                # we have to work some magic and extract it from the version string:
                #----------------------------------------------------------------------------------------
                [string]$VersionTmp=$SQLInventory.versionstring
                [string]$VersionMajor=$VersionTmp.Substring(0,$VersionTmp.IndexOf(".",$VersionTmp.IndexOf(".")+1))
                [string]$VersionMinor=$VersionTmp.Substring($VersionMajor.Length+1)
                [string]$VersionMinor=$VersionMinor.Substring(0,$VersionMinor.IndexOf("."))
                [float]$VersionMajor=$VersionMajor
                [float]$VersionMinor=$VersionMinor

                #----------------------------------------------------------------------------------------
                # get OS name from version:
                #----------------------------------------------------------------------------------------
                foreach ($key in $WindowsProducts.GetEnumerator()) {
                    if ($SQLInventory.OSVersion -like $key.Name) {
                         $WindowsProductData=[PSCustomObject] @{
                            Version=$key.Name            
                            ProductName=$key.Value
                            }
                        }
                    }

                #----------------------------------------------------------------------------------------
                # set sql product name and end of support dates
                # https://support.microsoft.com/en-gb/lifecycle/search?alpha=SQL
                #----------------------------------------------------------------------------------------
                $SPEndOfDate=$null
                $EndOfMainSupportDate=$null
                $EndOfEXtSupportDate=$null

                #loop through keys in the SQLProducts hashtable
                foreach ($key in $SQLProducts.GetEnumerator()) {
                    if ($SQLInventory.versionstring -like $key.Name) {
                        
                        #we found the right version. Loop through the sub-hashtable:
                        foreach ($value in $key.Value) {

                            #now get the info for the version we found:
                            $IsSpSupported=$($null -ne ([datetime]::ParseExact($value.Get_Item($SQLInventory.ProductLevel), "dd/MM/yyyy", $null) | ? {$_ -gt $(Get-Date)}))
                            $IsProductSupported=$($null -ne ([datetime]::ParseExact($value.Get_Item("EndOfMainSupport"), "dd/MM/yyyy", $null) | ? {$_ -gt $(Get-Date)}))
            
                            #produce upgrade path:
                            if ($IsProductSupported) {
                                    if (!$IsSpSupported) {$UpgradePath="Install new SP"} else {$UpgradePath="Not required"}
                                } else {$UpgradePath="Upgrade to new SQL"}

                            #build custom object to store data:
                            $SQLProducData=[PSCustomObject] @{
                                ProductName=$value.Get_Item("ProductName")
                                EndOfMainSupport=[datetime]::ParseExact($value.Get_Item("EndOfMainSupport"), "dd/MM/yyyy", $null)
                                EndOfExtendedSupport=[datetime]::ParseExact($value.Get_Item("EndOfExtendedSupport"), "dd/MM/yyyy", $null)
                                EndOfCurrentSP=[datetime]::ParseExact($value.Get_Item($SQLInventory.ProductLevel), "dd/MM/yyyy", $null)
                                IsSPSupported=$IsSpSupported
                                IsProductSupported=$IsProductSupported
                                UpgradePath=$UpgradePath
                            }
                        }
                    }
                }
            } 

            #----------------------------------------------------------------------------------------
            # now do the same for WMI:
            #----------------------------------------------------------------------------------------
            $instances = $null
            $InventoryInfo.InventoryWMIError=$False
            try {
                $instances = Get-WmiObject -ComputerName $server win32_service | where {$_.name -like "MSSQL*"}
                $wmi=$True
                }
            catch {
                $InventoryInfo.InventoryWMIError=$($Error[0].Exception.Message)
                $instances=$null
                $wmi=$false
                }

            $instancecount=$null
            $SQLServices=""
            
            #----------------------------------------------------------------------------------------
            # if we can connect to WMI and have permissions AND we have identified server has SQL installed then
            # get the WMI inventory:
            #----------------------------------------------------------------------------------------    
            if ($wmi) {
			
                $InventoryInfo.InventoryWMI=$true
			    if ($instances) {
                    $InventoryInfo.ServerRole="MSSQL"
                    ForEach ($instance in $instances) {
                        if (($instance.name -eq "MSSQLSERVER") -or ($instance.name -like "MSSQL$*")) {
                        $SQLServices+=$instance.name+"; "
                        $instancecount++         
                        }
                    }
                }

                # calculate processors and sockets
                $wmiprocessors = Get-WmiObject win32_processor -computername $server
                    if (@($wmiprocessors)[0].NumberOfCores) {$cores = @($wmiprocessors).count * @($wmiprocessors)[0].NumberOfCores} 
                    else {$cores = @($wmiprocessors).count}
                $sockets = @(@($wmiprocessors) | % {$_.SocketDesignation} | select-object -unique).count;

                $Volumes = Get-WmiObject Win32_Volume -Property "name", "label", "blocksize", "capacity", "FileSystem" -computername $server | Where-Object {$_.FileSYstem -eq 'NTFS' -And $_.Name -match "^[A-Z]."} 
                $NetworkAdapter = Get-WmiObject Win32_NetworkAdapterConfiguration -Property "IPEnabled", "ipaddress" -computername $server

                #----------------------------------------------------------------------------------------
                # same as for sql part, create hashtable to store WMI data in:
                #----------------------------------------------------------------------------------------
                $WMIInventory=[PSCustomObject] @{
                    OS=@(Get-WmiObject Win32_OperatingSystem -Property "Caption", "version", "CountryCode", "CurrentTimeZone", "ServicePackMajorVersion", "ServicePackMinorVersion" -computername $server)
                    System=@(Get-WmiObject Win32_ComputerSystem -Property "Name", "domain", "manufacturer" -computername $server)
                    Volumes=[string]$($Volumes | Foreach-Object {$_.Name + ' (' + $("{0:N2}" -f $($_.capacity/1024/1024/1024)) + ' GB; ' + $_.blocksize + ' K)' + "`r`n"})
                    Volumes64K=[string]$($Volumes | Where-Object {$_.Blocksize -eq 65536} | Foreach-Object {$_.Name + ' (' + $("{0:N2}" -f $($_.capacity/1024/1024/1024)) + ' GB; ' + $_.blocksize + ' K)' + "`r`n"})
                    PowerPlan=[string]$(Get-WmiObject -Class Win32_PowerPlan -Namespace "root\cimv2\power" -Property "ElementName", "IsActive" -computername $server | Where-Object {$_.IsActive -eq $true}).ElementName
                    IPAddress=[string]$($NetworkAdapter | Where-Object {$_.IPEnabled -eq $True} | ForEach-Object {$_.IpAddress + "`r`n"})
                    DNSReverseLookup=[string]$([system.net.dns]::GetHostByAddress($($NetworkAdapter | Where-Object {$_.IPEnabled -eq $True}).ipaddress).hostname)
                    Sockets=$sockets
                    Cores=$cores
                    SQLInstanceCount=$instancecount
                    SQLServices=$SQLServices

                }
            } 
               #----------------------------------------------------------------------------------------
               # finally, set final output objects with SQL and WMI data joined together. This will piped out to HTML.
               # This is also the place where we do RAG status (validation). 
               # The below example will WARN - set color to amber if the Major version IS NOT 12 or higher - so warn if 
               # SQL is 2000,2005,2008,2012:
               # $(validate -currentvalue $($VersionMajor) -desiredvalue ">11" -level warning) 
               #----------------------------------------------------------------------------------------
               [PSCustomObject] @{
                            "Input Address" = $($InventoryInfo.SystemUnderScan)
                            "Server Name" = $($server)
                            "DNS Lookup" = $($dns)
                            "Scan Timestamp" = (Get-date -uFormat '%Y-%m-%d %r')
                            "Environment" = $($InventoryInfo.ServerEnvironment)
                            "Role" = $($InventoryInfo.ServerRole)
                            "WMI Instance Count"= $(validate -currentvalue $($WMIInventory.SQLInstanceCount) -desiredvalue ">0" -level warning) 
                            "WMI SQL Services"= $($WMIInventory.SQLServices)
                            "SQL OS" = $($WindowsProductData.ProductName)
                            "SQL OSVersion" = $($SQLInventory.OSVersion)
                            "SQL edition" = $(validate -currentvalue $($SQLInventory.edition) -desiredvalue "=Standard Edition (64-bit)" -level warning) 
                            "SQL Platform" = $(validate -currentvalue $($SQLInventory.Platform) -desiredvalue "=NT x64" -level warning)
                            "SQL Product" = $($SQLProducData.ProductName)
                            "SQL ProductLevel" = $($SQLInventory.ProductLevel)
                            "SQL VersionString" = $($SQLInventory.VersionString)
                            "SQL VersionMajor" = $(validate -currentvalue $($VersionMajor) -desiredvalue ">11" -level warning) 
                            "SQL VersionMinor" = $(validate -currentvalue $($VersionMinor) -desiredvalue ">4999" -level warning)
                            "SQL Language" = $(validate -currentvalue $($SQLInventory.Language) -desiredvalue "=English (United States)" -level warning)
                            "SQL Processors" = $(validate -currentvalue $($SQLInventory.Processors) -desiredvalue ">3" -level warning)
                            "SQL PhysicalMemory" = $(validate -currentvalue $($SQLInventory.PhysicalMemory) -desiredvalue ">8000" -level warning) 
                            "SQL MaxServerMemory" = $(validate -currentvalue $($SQLInventory.MaxServerMemory) -desiredvalue "<2147483647" -level error) 
                            "SQL MinServerMemory" = $(validate -currentvalue $($SQLInventory.MinServerMemory) -desiredvalue ">16" -level warning) 
                            "SQL DefaultBackupCompression" = $(validate -currentvalue $($SQLInventory.DefaultBackupCompression) -desiredvalue "=1" -level warning)
                            "SQL BackupChecksumDefault" = $(validate -currentvalue $($SQLInventory.BackupChecksumDefault) -desiredvalue "=1" -level warning)
                            "SQL RemoteAdminConnections" = $(validate -currentvalue $($SQLInventory.RemoteAdminConnections) -desiredvalue "=1" -level warning)
                            "SQL OptimizeAdhocWorkloads" = $(validate -currentvalue $($SQLInventory.OptimizeAdhocWorkloads) -desiredvalue "=1" -level warning)
                            "SQL xp_cmdshell" = $(validate -currentvalue $($SQLInventory.xp_cmdshell) -desiredvalue "=0" -level error)
                            "SQL HasNullSaPassword" = $(validate -currentvalue $($SQLInventory.HasNullSaPassword) -desiredvalue "=False" -level error)
                            "SQL IsSaDisabled" = $(validate -currentvalue $($SQLInventory.IsSaDisabled) -desiredvalue "=True" -level error)
                            "SQL AuditLevel" = $(validate -currentvalue $($SQLInventory.AuditLevel) -desiredvalue "=All" -level error)
                            "SQL LoginMode" = $(validate -currentvalue $($SQLInventory.LoginMode) -desiredvalue "=Mixed" -level error)
                            "SQL DatabaseCount" = $(validate -currentvalue $($SQLInventory.DatabaseCount) -desiredvalue ">4" -level warning)
                            "SQL Databases" = $($SQLInventory.Databases)
                            "SQL DataFiles" = $($SQLInventory.DataFiles)
                            "SQL LogFiles" = $($SQLInventory.LogFiles)
                            "SQL DatabaseTotalSizeGB" =  $(validate -currentvalue $($SQLInventory.DatabaseTotalSize) -desiredvalue "<200" -level warning)
                            "SQL RootDirectory" = $($SQLInventory.RootDirectory)
                            "SQL ErrorLogPath" = $($SQLInventory.ErrorLogPath)
                            "SQL NumberOfLogFiles" = $(validate -currentvalue $($SQLInventory.NumberOfLogFiles) -desiredvalue "=-1" -level error)
                            "SQL DatabaseMail" = $(validate -currentvalue $($SQLInventory.DatabaseMail) -desiredvalue "=0" -level warning)
                            "SQL DefaultTrace" = $(validate -currentvalue $($SQLInventory.DefaultTrace) -desiredvalue "=1" -level error)
                            "SQL CLREnabled" = $(validate -currentvalue $($SQLInventory.CLREnabled) -desiredvalue "=0" -level warning)
                            "SQL ScanForStartupProcs" = $(validate -currentvalue $($SQLInventory.ScanForStartupProcs) -desiredvalue "=0" -level warning)
                            "SQL MaxDOP" = $(validate -currentvalue $($SQLInventory.MaxDOP) -desiredvalue ">0" -level warning)
                            "SQL CostThreshold" = $(validate -currentvalue $($SQLInventory.CostThreshold) -desiredvalue ">5" -level warning)
                            "SQL C2AuditMode" = $(validate -currentvalue $($SQLInventory.C2AuditMode) -desiredvalue "=0" -level warning)
                            "SQL NetworkPacketSize" = $(validate -currentvalue $($SQLInventory.NetworkPacketSize) -desiredvalue "=4096" -level warning)
                            "SQL EndOfMainSupportDate" = $($SQLProducData.EndOfMainSupport)
                            "SQL EndOfEXtSupportDate" = $($SQLProducData.EndOfExtendedSupport)
                            "SQL EndOfCurrentSP" = $($SQLProducData.EndOfCurrentSP)
                            "SQL IsSpSupported" = $(validate -currentvalue $($SQLProducData.IsSpSupported) -desiredvalue "=True" -level error)
                            "SQL IsProductSupported" = $(validate -currentvalue $($SQLProducData.IsProductSupported) -desiredvalue "=True" -level error)
                            "SQL UpgradePath" = $(validate -currentvalue $($SQLProducData.UpgradePath) -desiredvalue "=Not required" -level error)
                            "SQL DbsWithoutChecsum" = $(validate -currentvalue $(coalesce $SQLInventory.DbsWithoutChecsum "False") -desiredvalue "=False" -level error)
                            "SQL DbsNotOwnedBySA" = $(validate -currentvalue $(coalesce $SQLInventory.DbsNotOwnedBySA "False") -desiredvalue "=False" -level error)
                            "SQL DbsWithOldBackup" =  $(validate -currentvalue $(coalesce $SQLInventory.DbsWithOldBackup "False") -desiredvalue "=False" -level error)
                            "SQL DbsWithOldLogBackup" = $(validate -currentvalue $(coalesce $SQLInventory.DbsWithOldLogBackup "False") -desiredvalue "=False" -level error)
                            "SQL DatabaseBackups" = $($SQLInventory.DatabaseBackups)
                            "SQL Sysadmins" = $($SQLInventory.Sysadmins)
                            "SQL ServerRoles" = $($SQLInventory.ServerRoles)
                            
                            "WMI Volumes" = $($WMIInventory.Volumes)
                            "WMI Volumes64K" = $(validate -currentvalue $($WMIInventory.Volumes64K) -desiredvalue "**" -level error)
                            "WMI PowerPlan" = $(validate -currentvalue $($WMIInventory.PowerPlan) -desiredvalue "=High Performance" -level error)
                            "WMI IPAddress" = $($WMIInventory.IPAddress)
                            "WMI Sockets" = $($WMIInventory.Sockets)
                            "WMI Cores" = $($WMIInventory.Cores)
                            "WMI OS.Caption" = $($WMIInventory.OS.Caption)
                            "WMI OS.Version" = $($WMIInventory.OS.version)
                            "WMI OS.CountryCode" = $($WMIInventory.OS.CountryCode)
                            "WMI OS.CurrentTimeZone" = $($WMIInventory.OS.CurrentTimeZone)
                            "WMI OS.ServicePackMajorVersion" = $($WMIInventory.OS.ServicePackMajorVersion)
                            "WMI OS.ServicePackMinorVersion" = $($WMIInventory.OS.ServicePackMinorVersion)
                            "WMI Domain" = $($WMIInventory.System.Domain)
                            "WMI Manufacturer" = $($WMIInventory.System.Manufacturer)
                            "WMI Name" = $($WMIInventory.System.Name)

                            "SQL InventoryScan" = $(validate -currentvalue $($InventoryInfo.InventorySQL) -desiredvalue "=True" -level error)
                            "SQL ScanError" = $($InventoryInfo.InventorySQLError)

                            "WMI InventoryScan" = $(validate -currentvalue $($InventoryInfo.InventoryWMI) -desiredvalue "=True" -level error)
                            "WMI ScanError" = $($InventoryInfo.InventoryWMIError)
                    }
            }
            #----------------------------------------------------------------------------------------
            # return our inline (workflow thread) back to the main thread
            #----------------------------------------------------------------------------------------
            $configs
        }
    }

#----------------------------------------------------------------------------------------
# check if Inputlist is an array or a flat file:
#----------------------------------------------------------------------------------------
if (Test-Path "$InputList") { $InputList = Get-Content "$InputList" }
else { $InputList = $InputList.Split(",") }

# currently the only supported outputformat is html, perhaps in the future we can have different formats:
$OutputFormat='Html'
switch ($OutputFormat) {
    'Html' {
        $html.head | Out-File -FilePath $($OutputFile + ".html") -Append
        $html.pre | Out-File -FilePath $($OutputFile + ".html") -Append
        
        #----------------------------------------------------------------------------------------
        # run Inventory Function and pipe it out to HTML. by piping, we are able to instantly see
        # servers appearing in the html file so we can track the progress. This is handy for large estate
        # as otherwise, if this went into variable we would not see any results until after it has finished.
        #----------------------------------------------------------------------------------------
        Get-SQLInventory -servers $InputList -html $Html -Product $Product -maxThreads $MaxThreads -OutputPath $OutputPath -OutputFile $OutputFile -SQLProducts $SQLProducts -WindowsProducts $WindowsProducts -Environments $Environments -SimpleInventory $SimpleInventory `
            | ConvertTo-HTML -Fragment `
                | ForEach-Object {$_ -replace '(?m)\s+$', "`r`n<br>"} `
                    | ForEach-Object {$_ -replace "<td>\^error\^","<td class='error'>"} `
                        | ForEach-Object {$_ -replace "<td>\^warning\^","<td class='warning'>"} `
                            | ForEach-Object {$_ -replace "<td>\^pass\^","<td class='pass'>"} `
                                    | Out-File -FilePath $($OutputFile + ".html") -Append
        $html.post | Out-File -FilePath $($OutputFile + ".html") -Append                      
        }
    }
