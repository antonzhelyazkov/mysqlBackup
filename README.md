# mysqlBackup

Lightweight MySQL backup script to backup all your MySQL databases every night.

It provides FTP tranfer and housekeep procedure.

You could create dump on:

1. all databases in one file.

2. backup all databases in separate files.

3. You could create backup per table.

4. Execute slave stop/start when needed

5. Use pigz if possible.


USAGE:

--local-copy

--local-copy-path

--local-copy-days

--stop-slave

--database

--password

--host

--port

--verbose

--ignore-slave-running

--exclude-table

--exclude-database

--pigz

--pigz-path

--remote-copy

--remote-copy-days

--ftp-host

--ftp-port

--ftp-user

--ftp-pass

--tmpdir

--log-file

example: /mysqlBackup.pl --password=<mysql root password> --tmpdir=/tmp/ --exclude-database=vod,c1neterraf1b,bgmedia --stop-slave --local-copy --local-copy-days=1 --local-copy-path=/var/tmp --remote-copy --remote-copy-days=1 --ftp-host=<host/ip> --ftp-port=<port> --ftp-user=<user> --ftp-pass=<password>
