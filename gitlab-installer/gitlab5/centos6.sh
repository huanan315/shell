#!/bin/bash
# Installer for GitLab on RHEL 6 (Red Hat Enterprise Linux and CentOS)
#
# Only run this on a clean machine. I take no responsibility for anything.

# Define the public hostname
export GL_HOSTNAME=$HOSTNAME

# Install from this GitLab branch
export GL_GITLAB_BRANCH="5-1-stable"

# Install from this GitLab-Shell branch
export GL_GITLIB_SHELL_BRANCH="v1.3.0"

# Define the version of ruby the environment that we are installing for
export RUBY_VERSION="1.9.3-p551"

# Define MySQL root password
MYSQL_ROOT_PW=$(cat /dev/urandom | tr -cd [:alnum:] | head -c ${1:-16})

# Exit on error

die()
{
  # $1 - the exit code
  # $2 $... - the message string

  retcode=$1
  shift
  printf >&2 "%s\n" "$@"
  exit $retcode
}

echo "### Check OS (we check if the kernel release contains el6)"
uname -r | grep "el6" || die 1 "Not RHEL or CentOS 6 (el6)"

# Install base packages
yum -y install git

## Install epel-release
yum -y install http://dl.fedoraproject.org/pub/epel/6/i386/epel-release-6-8.noarch.rpm

# Ruby
## packages (from rvm install message):
yum -y install patch gcc-c++ readline-devel zlib-devel libffi-devel openssl-devel make autoconf automake libtool bison libxml2-devel libxslt-devel libyaml-devel

# Import rvm key
sudo gpg2 --keyserver hkp://keys.gnupg.net --recv-keys D39DC0E3

## Install rvm (instructions from https://rvm.io)
curl -L get.rvm.io | bash -s stable

## Load RVM
source /etc/profile.d/rvm.sh

## Fix for missing psych
## *It seems your ruby installation is missing psych (for YAML output).
## *To eliminate this warning, please install libyaml and reinstall your ruby.
## Run rvm pkg and add --with-libyaml-dir
rvm pkg install libyaml

## Install Ruby (use command to force non-interactive mode)
command rvm install $RUBY_VERSION --with-libyaml-dir=/usr/local/rvm/usr
rvm --default use $RUBY_VERSION

## Install core gems
gem install bundler

# Users

## Create a git user for Gitlab
useradd --system --create-home --comment 'GitLab' git

# GitLab Shell

## Clone gitlab-shell
su - git -c "git clone https://github.com/gitlabhq/gitlab-shell.git"

## Checkout
su - git -c "cd gitlab-shell;git checkout $GL_GITLIB_SHELL_BRANCH"

## Edit configuration
su - git -c "cp gitlab-shell/config.yml.example gitlab-shell/config.yml"

## Run setup
su - git -c "gitlab-shell/bin/install"

### Fix wrong mode bits
chmod 600 /home/git/.ssh/authorized_keys
chmod 700 /home/git/.ssh

# Database

## Install redis
yum -y install redis

## Start redis
service redis start

## Automatically start redis
chkconfig redis on

## Install mysql-server
yum install -y mysql-server

## Turn on autostart
chkconfig mysqld on

## Start mysqld
service mysqld start

### Create the database
echo "CREATE DATABASE IF NOT EXISTS gitlabhq_production DEFAULT CHARACTER SET 'utf8' COLLATE 'utf8_unicode_ci';" | mysql -u root

## Set MySQL root password in MySQL
echo "UPDATE mysql.user SET Password=PASSWORD('$MYSQL_ROOT_PW') WHERE User='root'; FLUSH PRIVILEGES;" | mysql -u root

# GitLab

## Clone GitLab
su - git -c "git clone https://github.com/gitlabhq/gitlabhq.git gitlab"

## Checkout
su - git -c "cd gitlab;git checkout $GL_GITLAB_BRANCH"

## fix Gemfile and Gemfile.lock version bug
sed -i "s/\"modernizr\",        \"2.6.2\"/\"modernizr-rails\",        \"2.7.1\"/g" /home/git/gitlab/Gemfile
sed -i "s/modernizr (2.6.2)/modernizr-rails (2.7.1)/g" /home/git/gitlab/Gemfile.lock
sed -i "s/modernizr (= 2.6.2)/modernizr-rails (= 2.7.1)/g" /home/git/gitlab/Gemfile.lock

## Configure GitLab

cd /home/git/gitlab

### Copy the example GitLab config
su git -c "cp config/gitlab.yml.example config/gitlab.yml"

### Change gitlabhq hostname to GL_HOSTNAME
sed -i "s/  host: localhost/  host: $GL_HOSTNAME/g" config/gitlab.yml

### Change the from email address
sed -i "s/from: gitlab@localhost/from: gitlab@$GL_HOSTNAME/g" config/gitlab.yml

### Copy the example Puma config
su git -c "cp config/puma.rb.example config/puma.rb"

### Copy database congiguration
su git -c "cp config/database.yml.mysql config/database.yml"

### Set MySQL root password in configuration file
sed -i "s/secure password/$MYSQL_ROOT_PW/g" config/database.yml

# Make sure GitLab can write to the log/ and tmp/ directories
chown -R git log/
chown -R git tmp/
chmod -R u+rwX log/
chmod -R u+rwX tmp/

# Create directory for satellites
su - git -c "mkdir /home/git/gitlab-satellites"

# Create directories for sockets/pids and make sure GitLab can write to them
su - git -c "cd gitlab;mkdir tmp/pids/"
su - git -c "cd gitlab;mkdir tmp/sockets/"
chmod -R u+rwX tmp/pids/
chmod -R u+rwX tmp/sockets/

# Create public/uploads directory otherwise backup will fail
su - git -c "cd gitlab;mkdir public/uploads"
chmod -R u+rwX public/uploads

### Configure git user
su git -c 'git config --global user.name  "GitLab"'
su git -c 'git config --global user.email "gitlab@$GL_HOSTNAME"'

# Install Gems

## Install Charlock holmes
yum -y install libicu-devel
gem install charlock_holmes --version '0.6.9.4'

## For MySQL
yum -y install mysql-devel
su git -c "bundle install --deployment --without development test postgres"
su git -c "bundle exec rake sidekiq:start RAILS_ENV=production"

# Initialise Database and Activate Advanced Features
# Force it to be silent (issue 31)
export force=yes
su git -c "bundle exec rake gitlab:setup RAILS_ENV=production"

## Install init script
wget --no-check-certificate -O /etc/init.d/gitlab https://raw.github.com/gitlabhq/gitlab-recipes/$GL_GITLAB_BRANCH/init.d/gitlab
chmod +x /etc/init.d/gitlab

### Enable and start
chkconfig gitlab on
service gitlab start

# Apache

## Install
yum -y install httpd
chkconfig httpd on

## Configure
cat > /etc/httpd/conf.d/gitlab.conf << EOF
<VirtualHost *:80>
  ServerName $GL_HOSTNAME
  ProxyRequests Off
    <Proxy *>
       Order deny,allow
       Allow from all
    </Proxy>
    ProxyPreserveHost On
    ProxyPass / http://localhost:3000/
    ProxyPassReverse / http://localhost:3000/

    SetEnv force-proxy-request-1.0.1
    SetEnv proxy-nokeepalive 1
</VirtualHost>
EOF

### Configure SElinux
setsebool -P httpd_can_network_connect 1

## Start
sed -i "s/#ServerName www.example.com:80/ServerName $GL_HOSTNAME:80/g" /etc/httpd/conf/httpd.conf
service httpd start

#  Configure iptables

## Open port
iptables -I INPUT -p tcp -m tcp --dport 22 -j ACCEPT
iptables -I INPUT -p tcp -m tcp --dport 80 -j ACCEPT
iptables -I INPUT -p tcp -m tcp --dport 3000 -j ACCEPT

## Save iptables
service iptables save

## Start Gitlab, default port 3000
su - git -c "cd gitlab; bundle exec rails s -e production -d"

echo "### Done ###############################################"
echo "#"
echo "# You have your MySQL root password in this file:"
echo "# /home/git/gitlab/config/database.yml"
echo "#"
echo "# Point your browser to:"
echo "# http://$GL_HOSTNAME (or: http://<host-ip>)"
echo "# Default admin username: admin@local.host"
echo "# Default admin password: 5iveL!fe"
echo "#"
echo "########################################################"
