
<html>
<p> Backup erfoglreich erstellt....</p>
<?php 
   exec("tar -czf /var/www/html/openWB/web/backup/backup.tar.gz /var/www/html/");
?><br> <a href="/openWB/web/backup/backup.tar.gz"> Download</a>
<br><br>
<a href="../index.php">Zurück</a>

</html>
