<#
  This is a proof of concept to assess effort required to make this work with dbatools.
#>

#Store html HEAD template in the $htmlhead variable
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
</head>
<body>
    <div><input type='submit' value='transpose' id='transpose'><form><input type='text' id='search' placeholder='Type here to search' style='border:0px; margin-left:10px;'></form></div>"


#Store html POST template in $htmlpost variabl
$htmlpost = "
</body><script type='text/javascript'>
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
    post = $htmlpost
}


#Get spConfig data into variable
$SpConfig = Get-DbaSpConfigure -SqlInstance sql-test-1\sql2016,sql-test-1\sql2017,sql-test-1\sql2014,sql-test-1\sql2012

#output file definition
$OutputFile = "C:\temp\inventory.html"

#create output file with the HEAD part of the template
$html.head | Out-File -FilePath $OutputFile


#Get DbaInstance into variable and add few values from the expanded SpConfig, and output html into our output file. this will be the "body" part.
$Data= Get-DbaInstance -SqlInstance sql-test-1\sql2016,sql-test-1\sql2017,sql-test-1\sql2014,sql-test-1\sql2012 | Select-Object *, @{
        name='Databases';expression={$_.Databases.Name -join ', '}
       }, @{
        name='Logins';expression={$_.Logins.Name -join ', '}
       }, @{
        name='LinkedServers';expression={$_.LinkedServers.Name -join ', '}
       } -ExcludeProperty Databases, Logins, LinkedServers | ConvertTo-html -fragment | Out-File -FilePath $OutputFile -Append

#now final step, output the "post" part into the output file.
$html.post | Out-File -FilePath $OutputFile -Append


