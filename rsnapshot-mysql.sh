#!/bin/bash
############################################################################################################################################################################
#
# rsnapshot-mysql.sh
#
# This is a rsnapshot friendly tool to pull all MySQL DBs from a host, One File Per Table.
#
############################################################################################################################################################################
#
#   By Juanga Covas 2015-2018
#
#   	with tips from http://dba.stackexchange.com/questions/20/how-can-i-optimize-a-mysqldump-of-a-large-database
############################################################################################################################################################################
#
# Features:
#
#   - Handle dumps from local or remote MySQL hosts.
#   - Allows to choose compression type for dumps (none, gzip or bzip2).
#   - Automatically fetches database names from mysql host and creates a directory for each database.
#	- Dump each table to its own file (.sql, .sql.gz or .sql.bz2) under a directory named as the database.
#   - Handle dump of mixed database tables using MyISAM AND/OR InnoDB...
#	- Ready to work with "backup_script" feature of rsnapshot, an incremental snapshot utility for local and remote filesystems.
#   - Creates a convenient restore script (BASH) for each database, under each dump directory.
#   - Creates backup of GRANTs (mysql permissions), and info files with the list of tables and mysql version.
#
############################################################################################################################################################################

# The main reason to dump tables to individual files, instead of a full file per database is to save more disk space when using incremental, link-based backup systems.
# This way more files have a chance to be 'the same than previous backup or snapshot', at the cost of a more complicated restore process which is also provided by this script.
# Having individual files per table also allows to better 'mysqldump' the tables of different engines: InnoDB (--single-transaction) or MyISAM (--lock-tables)

# Modifications du script :
# 	- Le système d'authentification est remplacé par le système intégré dans MySQL: les login-path. Plus sûr, car les mots de passe sont hashés
#   - Réduction du nombre de paramètres du script en faveur de variables de configuration
# 	- Les sauvegardes se font dans un repertoire fixe pour faire un rsync sur un serveur distant
#	- suppression de l'option test run, son implementation etait incomplete (bug)
# 	- modification de l'affichage pour une lecture plus simple
#	- Ajout de la sauvegarde des views
#	- Ajout de la sauvegarde des fonctions et procedures stockees

#################################################################################################
# VARIABLES DE CONFIGURATION
#################################################################################################

# Path where a directory <databasename> will be created for each database
BACKUP_DIR="/database-dump"

# Define which databases to exclude when fetching database names from mysql host
# Normally you always want to exclude mysql, information_schema and performance_schema
MYSQL_EXCLUDE_DB="(^mysql$|information_schema|performance_schema|sys)"

# defini la liste des tables à exclure
#MYSQL_EXCLUDE_TABLES="(\.sp_geodb_)"
MYSQL_EXCLUDE_TABLES="(\.table_a_exclure)"

# If CLEAN_DUMP_DIRS is set to 1, all files inside each databasename directory will be deleted before the dumps
CLEAN_DUMP_DIRS=1

# CHECK_TABLES="1" if you want to check all tables before trying to dump
CHECK_TABLES="1"

#################################################################################################
# normally you don't want to touch anything else beyond this point of the script
#################################################################################################

# show banner
echo "-----------------------------------------------------------------------------------------"
echo "$0 START $(date +"%d-%m-%Y %H:%M:%S")"

#################################################################################################
# Controle des variables de configuration
#################################################################################################
if [ ! -d $BACKUP_DIR ] ;then
	echo "ERROR: Backup directory don't exist BACKUP_DIR=$BACKUP_DIR"
	exit 1
fi

#################################################################################################
# Traitement des parametres de la ligne de commande
#################################################################################################
# BUG: Si le login-path indiqué n'existe pas retourne le login-path par defaut qui est 'client' et sur mes tests il deja parametré
# BUG: A re-tester plus tard
LOGIN_PATH="client"
if [ ! -z $1 ] ;then
	LOGIN_PATH=$1;
fi

COMPRESSION="none"
if [ ! -z $2 ] ;then
	COMPRESSION=$2;
fi

# Help instructions
if [[ $LOGIN_PATH == "--help" ]] ;then
	echo "Usage: $0 [login-path] [compression]"
	echo "   login-path : configuration enregistree avec mysql_config_editor (default:client)"
	echo "   compression: none|gz|bz2 (default:none)"
	exit 0;
fi

MYSQL_HOST=$(mysql_config_editor print --login-path=$LOGIN_PATH | grep host | awk -F '=' '{print $2}' | sed 's/ //g')
if [[ $MYSQL_HOST == "localhost" ]] || [[ $MYSQL_HOST == "127.0.0.1" ]] ;then
	# do not need to compress if host is localhost
	MYSQL_DUMP_FLAGS="--hex-blob --force --skip-dump-date"
else
	# common flags for mysqldump command
	MYSQL_DUMP_FLAGS="--compress --hex-blob --force --skip-dump-date"
fi

# login-path used to connnect to mysql
MYSQL_HUP="--login-path=$LOGIN_PATH"

if [[ $COMPRESSION == "gz" ]] ;then
	FILE_EXTENSION=".sql.gz"
	COMPRESS_INSTRUCTION="gzip -9"
else
	if [[ $COMPRESSION == "bz2" ]] ;then
		FILE_EXTENSION=".sql.bz2"
		COMPRESS_INSTRUCTION="bzip2 -cq9"
	else
		COMPRESSION="none"
		FILE_EXTENSION=".sql"
		COMPRESS_INSTRUCTION="grep -v ^$"		# par defaut supprime les lignes blanches
	fi
fi

# Affichage de la configuration
echo " "
echo "Configuration:"
echo "--------------"
echo "Backup directory : $BACKUP_DIR"
echo "Login-path       : $LOGIN_PATH"
echo "MySQL Host       : $MYSQL_HOST"
echo "Compression      : $COMPRESSION"
echo " "

# test connection to given mysql host by using mysqlshow
RESULT=`mysqlshow $MYSQL_HUP | grep -o Databases`
if [[ ! "$RESULT" == "Databases" ]]; then
	printf "ERROR: Cannot connect to MySQL server. Aborting.\n\n"
	exit 1;
fi

# dump mysql host version info
mysql $MYSQL_HUP --skip-column-names -e"SHOW variables WHERE variable_name LIKE '%version%' AND variable_name <> 'slave_type_conversions';" > $BACKUP_DIR/mysql-version-$MYSQL_HOST.txt

# check tables?
if [[ $CHECK_TABLES == "1" ]] ;then
	echo "Doing a mysqlcheck :"
	while read line; do

	  # skip database tables that are okay
	  echo "$line"|grep -q OK$ && continue

	  echo "WARNING: $line"
	done < <(mysqlcheck $MYSQL_HUP --all-databases --check --all-in-1 --auto-repair)
	echo " "
fi

# dump grants
mysql $MYSQL_HUP --no-auto-rehash --skip-column-names -e"SELECT CONCAT('SHOW GRANTS FOR ''',user,'''@''',host,''';') FROM mysql.user WHERE user<>''" | mysql $MYSQL_HUP --no-auto-rehash --skip-column-names | sed 's/$/;/g' > $BACKUP_DIR/mysql-grants-$MYSQL_HOST.sql

# get database list
databaselist=`mysql $MYSQL_HUP --no-auto-rehash --skip-column-names -e "SHOW DATABASES;" | grep -Ev "$MYSQL_EXCLUDE_DB"`

######################################################################
# begin to dump
######################################################################

# loop all database names
for db in $databaselist; do

	# create a sub-directory using database name, no errors, recursive
	mkdir -p $BACKUP_DIR/$db

	if test $CLEAN_DUMP_DIRS -eq 1 ;then
		rm -f $BACKUP_DIR/$db/*.sql* $BACKUP_DIR/$db/*.txt
	fi

	# save the db table list
	mysql $MYSQL_HUP --no-auto-rehash --skip-column-names -e "SELECT CONCAT(table_schema,'.',table_name) FROM information_schema.tables WHERE table_type<>'VIEW' AND table_schema = '${db}'" | grep -Ev "$MYSQL_EXCLUDE_TABLES" > $BACKUP_DIR/$db/$db-tablelist.txt

	# get a list of db.table.engine
	db_table_engine_list=`mysql $MYSQL_HUP --no-auto-rehash --skip-column-names -e "SELECT CONCAT(table_schema,'.',table_name,'.',engine) FROM information_schema.tables WHERE table_type<>'VIEW' AND table_schema = '${db}'" | grep -Ev "$MYSQL_EXCLUDE_TABLES"`
	
	echo $db_table_engine_list > $BACKUP_DIR/$db/$db-engine-table-list.txt

	# loop all tables in database
	echo "Dump database $db:"
	for DBTBNG in $db_table_engine_list; do

		# handle table engine
		table=`echo ${DBTBNG} | sed 's/\./ /g' | awk '{print $2}'`
		engine=`echo ${DBTBNG} | sed 's/\./ /g' | awk '{print $3}'`

		echo $table

		# some reminders for mysqldump options
		# --skip-dump-date so dump data do NOT differ if table did not really change
		# --single-transaction for properly dumping InnoDB table. This automatically turns off --lock-tables (needed for MyISAM dump)
		# --lock-tables for properly dumping MyISAM table, which anyway is enabled by default
		# --force  Continue even if we get an SQL error.

		# use special flags for InnoDB or MyISAM
		ENGINE_OPT=""
		if [[ $engine == "InnoDB" ]] ;then
			ENGINE_OPT="--single-transaction"
		else
			if [[ $engine == "MyISAM" ]] ;then
				ENGINE_OPT="--lock-tables"
			else
				if [[ $engine == "MEMORY" ]] ;then
					printf ' NOTICE: MEMORY table. '
				else
					printf ' NOTICE: Unexpected engine: NO ENGINE_OPT SET. '
				fi
			fi
		fi

		# dump the table and add lines to restore script
		filedump="$BACKUP_DIR/$db/$db-$table$FILE_EXTENSION"
		if [ ! -f $filedump ] ;then
			mysqldump $MYSQL_HUP $MYSQL_DUMP_FLAGS $ENGINE_OPT ${db} ${table} | $COMPRESS_INSTRUCTION > $filedump
		fi
	done

	#####################################
	# Sauvegarde des views
	#####################################
	mysql $MYSQL_HUP --no-auto-rehash --skip-column-names --batch -e "select table_name from information_schema.views WHERE TABLE_SCHEMA='${db}'" > $BACKUP_DIR/$db/$db-viewlist.txt

	for db_view in `cat $BACKUP_DIR/$db/$db-viewlist.txt`; do
		echo $db_view

		# dump the view definition
		filedump="$BACKUP_DIR/$db/$db-$db_view.sql"
		if [ ! -f $filedump ] ;then
			mysqldump $MYSQL_HUP --skip-dump-date ${db} ${db_view} > $filedump
		fi
	done

	##################################################
	# Sauvegarde des fonnctions et procedures stockées
	##################################################
	mysqldump $MYSQL_HUP --routines --no-create-info --no-data --no-create-db --skip-opt ${db} > $BACKUP_DIR/$db/$db-routines.sql

done

# show footer
echo " "
echo "$0 END $(date +"%d-%m-%Y %H:%M:%S")"
echo "-----------------------------------------------------------------------------------------"