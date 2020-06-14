# rsnapshot-mysql

This is a bash script that allows to automatically pull ALL databases from MySQL/MariaDB servers, remote or local, for backup purposes, creating "One Dump File Per Table" and a convenient restore script for each database. Plus, this script is [rsnapshot](https://github.com/rsnapshot/rsnapshot)-friendly, meaning you can use it with the "backup_script" feature of *rsnapshot*.

Features:
  - Handle dumps from local or remote MySQL hosts.
  - Allows to choose compression type for dumps (none, gzip or bzip2).
  - Automatically fetches database names from mysql host and creates a directory for each database.
  - Dump each table to its own file (.sql, .sql.gz or .sql.bz2) under a directory named as the database.
  - Handle dump of mixed database tables using MyISAM AND/OR InnoDB...
  - Ready to work with "backup_script" feature of rsnapshot, an incremental snapshot utility for local and remote filesystems.
  - Creates a convenient restore script (BASH) for each database, under each dump directory.
  - Creates backup of GRANTs (mysql permissions), and info files with the list of tables and mysql version.

Modifications au script original:  
 	- Le système d'authentification est remplacé par le système intégré dans MySQL: les ogin-path. Plus sûr, car les mots de passe sont hashés
  - Réduction du nombre de paramètres du script en faveur de variables de configuration
 	- Les sauvegardes se font dans un repertoire fixe pour faire un rsync sur un serveur distant
	- suppression de l'option test run, son implementation etait incomplete (bug)
 	- modification de l'affichage pour une lecture plus simple
	- Ajout de la sauvegarde des views
	- Ajout de la sauvegarde des fonctions et procedures stockees
