<html>
	<head>
		<meta http-equiv="refresh" content="90;url=../index.php" />
	</head>
<?php
	echo "Update wird durchgeführt, bitte nicht vom Strom trennen";
	exec("/var/www/html/openWB/runs/update.sh > /dev/null &");
	header( "refresh:90;url=../index.php" );
?>
<script type="text/javascript">
   setTimeout(function() { window.location.href = "../index.php"; }, 90000);
</script>
</html>
