declare -r ONLYOFFICE_FQDN="office.example.com" #FIXME: set to fully qualified dns name for onlyoffice server
declare -r NEXTCLOUD_DB_NAME="nextcloud"
declare -r NEXTCLOUD_DB_USER="nextcloud"
declare -r NEXTCLOUD_DB_PWD=$(openssl rand -base64 15)
declare -r NEXTCLOUD_ADMIN_USER="admin"
declare -r NEXTCLOUD_ADMIN_PWD=$(openssl rand -base64 15)
declare -r NEXTCLOUD_FQDN="cloud.example.com" #FIXME: set to fully qualified dns name for nextcloud server
declare -r NEXTCLOUD_VERSION="17.0.0"
declare -r NEXTCLOUD_MEMLIMIT="512M"
declare -r CERT_PATH="/etc/letsencrypt/live/cloud.example.com/fullchain.pem" #FIXME:Path to certificate must be set
declare -r KEY_PATH="/etc/letsencrypt/live/cloud.example.com/privkey.pem" #FIXME:Path to key
declare -r CHAIN_PATH="/etc/letsencrypt/live/cloud.example.com/chain.pem" #FIXME:Path to certificate with root and intermediate CA chain
#Install extra repositories
curl -s https://packagecloud.io/install/repositories/rabbitmq/rabbitmq-server/script.rpm.sh | bash -
yum install -y https://download.onlyoffice.com/repo/centos/main/noarch/onlyoffice-repo.noarch.rpm
yum install -y epel-release
#Install packages
yum install -y \
	php-mbstring php-xmlrpc php-soap php-ldap php-gd php-xml nginx php-intl php-ldap php-zip \
	php-curl php-pgsql php-fpm php-mbstring php-xmlrpc php-soap php-ldap php-gd php-xml redis \
	rabbitmq-server php-apcu onlyoffice-documentserver unzip postgresql-server \
	patch php-cli php-json php-process php-opcache
#Configure the database
cp tmpl/disableTransparentHugePages.service /etc/systemd/system/
systemctl start disableTransparentHugePages.service
/usr/bin/postgresql-setup --initdb --unit postgresql
chkconfig postgresql on
patch -b -d /var/lib/pgsql/data/ < diff/pg_hba.conf.diff
systemctl start postgresql.service

sudo -i -u postgres psql -c "CREATE DATABASE $NEXTCLOUD_DB_NAME;"
sudo -i -u postgres psql -c "CREATE USER $NEXTCLOUD_DB_USER WITH password '$NEXTCLOUD_DB_PWD';"
sudo -i -u postgres psql -c "GRANT ALL privileges ON DATABASE $NEXTCLOUD_DB_NAME TO $NEXTCLOUD_DB_USER;"


cp tmpl/sysctl.d.redis.conf /etc/sysctl.d/redis.conf
sysctl --load
systemctl start redis
systemctl start rabbitmq-server
patch -u /usr/bin/documentserver-configure.sh --output=documentserver-configure.noninteractive.sh diff/documentserver-configure.sh.diff

chmod +x documentserver-configure.noninteractive.sh
./documentserver-configure.noninteractive.sh

#set up nextcloud
useradd -r -s /usr/sbin/nologin -U nextcloud
usermod -aG nextcloud nginx
cp /etc/php-fpm.d/www.conf /etc/php-fpm.d/nextcloud.conf
patch -u  /etc/php-fpm.d/nextcloud.conf < diff/nextcloud.conf.diff
patch -u  /etc/php.d/10-opcache.ini < diff/10-opcache.ini.diff
patch -u /etc/php.d/40-apcu.ini < diff/40-apcu.ini.diff
curl https://download.nextcloud.com/server/releases/nextcloud-$NEXTCLOUD_VERSION.zip > /tmp/nextcloud.zip
unzip /tmp/nextcloud.zip -d /var/www
chown --recursive nextcloud:nextcloud /var/www/nextcloud
chmod -R 770 /var/www/nextcloud
mkdir /var/lib/php/nextcloud
mkdir /var/lib/php/nextcloud/opcache
mkdir /var/lib/php/nextcloud/session
mkdir /var/lib/php/nextcloud/wsdlcache
chown --recursive nextcloud:nextcloud /var/lib/php/nextcloud
chmod -R 770 /var/lib/php/nextcloud
sudo -u nextcloud php /var/www/nextcloud/occ maintenance:install --database "pgsql" \
	--database-name "$NEXTCLOUD_DB_NAME" --database-user "$NEXTCLOUD_DB_USER" --database-pass "$NEXTCLOUD_DB_PWD" \
	--admin-user "$NEXTCLOUD_ADMIN_USER" --admin-pass "$NEXTCLOUD_ADMIN_PWD"
sudo -u nextcloud php /var/www/nextcloud/occ config:system:set memcache.local --value "\OC\Memcache\APCu"
echo "*/5  *  *  *  * php -f /var/www/nextcloud/cron.php" | crontab -u nextcloud -

#Configure nginx

openssl dhparam -out /etc/ssl/certs/dhparam.pem 4096
sed -e "s;{{SSL_CERTIFICATE_PATH}};${CERT_PATH//'/'/'\/'};" \
	-e "s;{{SSL_KEY_PATH}};${KEY_PATH//'/'/'\/'};" \
	-e "s/ssl_trusted_certificate .*/ssl_trusted_certificate ${CHAIN_PATH//'/'/'\/'} \;/" \
	tmpl/https-common.conf.tmpl > /etc/nginx/includes/https-common.conf
sed -e "s/{{FQDN}}/$ONLYOFFICE_FQDN/" \
	-e "s/{{FQDN_LIST}}/https:\/\/$ONLYOFFICE_FQDN https:\/\/$NEXTCLOUD_FQDN/" \
	tmpl/ds-ssl.conf.tmpl > /etc/onlyoffice/documentserver/nginx/ds.conf
sed "s/{{FQDN_LIST}}/$ONLYOFFICE_FQDN $NEXTCLOUD_FQDN/" tmpl/httpsredirect.conf.tmpl > /etc/nginx/conf.d/httpsredirect.conf
sed "s/{{FQDN}}/$NEXTCLOUD_FQDN/" tmpl/nextcloud.conf.tmpl > /etc/nginx/conf.d/nextcloud.conf

semanage fcontext -a -t httpd_sys_rw_content_t '/var/www/nextcloud/data(/.*)?'
semanage fcontext -a -t httpd_sys_rw_content_t '/var/www/nextcloud/config(/.*)?'
semanage fcontext -a -t httpd_sys_rw_content_t '/var/www/nextcloud/apps(/.*)?'
semanage fcontext -a -t httpd_sys_rw_content_t '/var/www/nextcloud/.htaccess'
semanage fcontext -a -t httpd_sys_rw_content_t '/var/www/nextcloud/.user.ini'
semanage fcontext -a -t httpd_sys_rw_content_t '/var/www/nextcloud/3rdparty/aws/aws-sdk-php/src/data/logs(/.*)?'

restorecon -Rv '/var/www/nextcloud/'

systemctl start php-fpm.service
systemctl start supervisord.service
systemctl start nginx
#Install onlyoffice connector
sudo -u nextcloud php /var/www/nextcloud/occ app:install onlyoffice
sudo -u nextcloud php /var/www/nextcloud/occ config:system:set onlyoffice DocumentServerUrl --value="https://$ONLYOFFICE_FQDN/"
sudo -u nextcloud php /var/www/nextcloud/occ config:system:set trusted_domains 2 --value=$NEXTCLOUD_FQDN

systemctl restart php-fpm.service
systemctl enable disableTransparentHugePages.service
systemctl enable postgresql.service
systemctl enable redis.service
systemctl enable rabbitmq-server.service
systemctl enable nginx.service
systemctl enable php-fpm.service
systemctl enable supervisord.service 
echo "Nextcloud has been setup to use an initial Administrative username $NEXTCLOUD_ADMIN_USER and password $NEXTCLOUD_ADMIN_PWD"
