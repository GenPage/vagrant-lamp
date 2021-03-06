include_recipe "apt"
include_recipe "timezone"
include_recipe "git"
include_recipe "oh-my-zsh"
include_recipe "apache2"
include_recipe "apache2::mod_rewrite"
include_recipe "apache2::mod_ssl"
include_recipe "mysql::server"
include_recipe "php"
include_recipe "apache2::mod_php5"

# Install extra system packages
%w{ debconf vim screen mc subversion curl tmux make g++ libsqlite3-dev }.each do |a_package|
	package a_package
end

# Install some more LAMP packages
%w{ drush imagemagick php5-memcache }.each do |a_package|
	package a_package
end

# Install ruby gems
%w{ rake mailcatcher }.each do |a_gem|
	gem_package a_gem
end

# Generate selfsigned ssl
execute "make-ssl-cert" do
	command "make-ssl-cert generate-default-snakeoil --force-overwrite"
	ignore_failure true
	action :nothing
end

# Install phpmyadmin
cookbook_file "/tmp/phpmyadmin.deb.conf" do
	source "phpmyadmin.deb.conf"
end
bash "debconf_for_phpmyadmin" do
	code "debconf-set-selections /tmp/phpmyadmin.deb.conf"
end
package "phpmyadmin"

# Install Xdebug
php_pear "xdebug" do
	action :install
end
template "#{node['php']['ext_conf_dir']}/xdebug.ini" do
	source "xdebug.ini.erb"
	owner "root"
	group "root"
	mode "0644"
	action :create
	notifies :restart, resources("service[apache2]"), :delayed
end

# Install Webgrind
git "/var/www/webgrind" do
	repository 'git://github.com/jokkedk/webgrind.git'
	reference "master"
	action :sync
end
template "#{node[:apache][:dir]}/conf.d/webgrind.conf" do
	source "webgrind.conf.erb"
	owner "root"
	group "root"
	mode 0644
	action :create
	notifies :restart, resources("service[apache2]"), :delayed
end

# Install php-curl
package "php5-curl" do
	action :install
end


if ( node.include?(:apc_memory) )

	# Install apc
	template "/etc/php5/conf.d/apc.ini" do
		source "apc.ini.erb"
		owner "root"
		group "root"
		mode 0644
		variables(
			:apc_memory => node[:apc_memory]
		)
		action :create
		notifies :restart, resources("service[apache2]"), :delayed
	end
	package "php-apc"

end


# Get eth1 ip
eth1_ip = node[:network][:interfaces][:eth1][:addresses].select{|key,val| val[:family] == 'inet'}.flatten[0]

# Setup MailCatcher
bash "mailcatcher" do
	code "mailcatcher --http-ip #{eth1_ip} --smtp-port 25"
	not_if "ps ax | grep -v grep | grep mailcatcher";
end
template "#{node['php']['ext_conf_dir']}/mailcatcher.ini" do
	source "mailcatcher.ini.erb"
	owner "root"
	group "root"
	mode "0644"
	action :create
end



# Disable default site
apache_site "default" do
	enable false  
end

# Add mysql vagrant user with all permissions
execute "mysql-vagrant-user" do
	command "/usr/bin/mysql -u root -p\"#{node['mysql']['server_root_password']}\" -e \"GRANT ALL PRIVILEGES ON *.* TO 'vagrant'@'%' IDENTIFIED BY 'vagrant' WITH GRANT OPTION ;\" ";
end

# Initialize sites data bag
sites = []
begin
	sites = data_bag('sites')
rescue
	puts "Sites data bag is empty"
end

sites.each do |name|
	if name == nil
		puts "Site id is nil. Your json config file must contain an \"id\" property."
		next
	end

	# Load data bag item
	site = data_bag_item('sites', name)

	if !site.include?('host')
		puts "Site #{name} has no host defined."
		next
	end

	# Build document root path
	if site.include?('webroot')
		site_docroot = "/vagrant/sites/#{site['host']}/#{site['webroot']}"
	else
		site_docroot = "/vagrant/sites/#{site['host']}"
	end

	# Verify that aliases exists and is an array
	if site.include?('aliases') && site['aliases'].respond_to?('each')
		aliases = site['aliases']
	else
		aliases = []
	end

	# Add site to apache config
	web_app site['host'] do
		template "sites.conf.erb"
		server_name site['host']
		server_aliases aliases
		docroot site_docroot
	end

	# Add site info in /etc/hosts
	bash "hosts" do
	 code "echo 127.0.0.1 #{site['host']}  >> /etc/hosts"
	end

	if site['framework'] == 'magento'

		# Create magento settings file
		# template "#{site[:path]}/app/etc/local.xml" do
		#   source "magento.local.xml.erb"
		#   variables(
		#     :host     => 'localhost',
		#     :user     => 'vagrant',
		#     :pass     => 'vagrant',
		#     :db       => 'vagrant',
		#     :mcrypt   => '59883184cd773361656e056f88a921ef'
		#   )
		# end

		# Clear magento cache
		execute "clear-magento-cache" do
			command "rm -rfv #{site_docroot}/var/cache/*";
			only_if "test -d #{site_docroot}/var/cache/";
		end

		# Add magento cron shell script
		template "/etc/magento-cron_#{name}.sh" do
			source "magento.cron.sh.erb"
			owner "root"
			group "root"
			mode "0700"
		end

		# Add magento cron
		template "/etc/cron.d/magento_#{name}" do
			source "magento.cron.erb"
			owner "root"
			group "root"
			mode "0600"
			variables(
				:cron_sh => "/etc/magento-cron_#{name}.sh",
				:cron_php => "#{site_docroot}/cron.php"
			)
		end

	end

	# Rsync files
	if site.include?('rsync')
		site['rsync'].each do |rsync|

			# Dump and copy database using ssh
			execute "rsync files from #{rsync['ssh_host']}" do
				command \
					"rsync -rt -e 'ssh -i /vagrant/#{rsync['ssh_private_key']} -o StrictHostKeyChecking=no' " +\
					"#{rsync['ssh_user']}@#{rsync['ssh_host']}:#{rsync['remote_source_path']} " +\
					"#{site_docroot}/#{rsync['local_target_path']}"
			end

		end
	end

	# Setup database
	if site.include?('database')
		site['database'].each do |db|

			template "#{node['mysql']['conf_dir']}/grants.sql" do
				source "grants.sql.erb"
				owner "root"
				group "root"
				mode "0600"
				variables(
						:user     => db['db_user'],
						:password => db['db_pass'],
						:database => db['db_name']
				)
			end

			# Create database, if it doesn't exist
			execute "create database #{db['db_name']}" do
				command "/usr/bin/mysqladmin -u root -p\"#{node['mysql']['server_root_password']}\" create #{db['db_name']}"
				not_if "/usr/bin/mysql -u root -p\"#{node['mysql']['server_root_password']}\" -e \"SHOW DATABASES LIKE '#{db['db_name']}'\" | grep '#{site['db_name']}' ";
			end

			if db.include?('db_import_file')
				# Import database if needed
				execute "import database #{db['db_name']}" do
					command "/usr/bin/mysql -u root -p\"#{node['mysql']['server_root_password']}\" #{db['db_name']} < /vagrant/sites/#{site['host']}/#{db['db_import_file']}"
					only_if "test -f /vagrant/sites/#{site['host']}/#{db['db_import_file']}"
					action :nothing
					subscribes :run, resources("execute[create database #{db['db_name']}]"), :immediately
				end
			end

			if db.include?('db_copy')
				# Dump and copy database if needed
				execute "copy database #{db['db_name']}" do
					command \
						"ssh #{db['db_copy']['ssh_user']}@#{db['db_copy']['ssh_host']} -i /vagrant/#{db['db_copy']['ssh_private_key']} -o StrictHostKeyChecking=no " +\
						"\"mysqldump --routines -u#{db['db_copy']['mysql_user']} -p#{db['db_copy']['mysql_pass']} #{db['db_copy']['remote_database']} > ~/vagrant-dump-#{db['db_name']}.sql \" && " +\
						"scp -i /vagrant/#{db['db_copy']['ssh_private_key']} -o StrictHostKeyChecking=no " +\
						"#{db['db_copy']['ssh_user']}@#{db['db_copy']['ssh_host']}:~/vagrant-dump-#{db['db_name']}.sql /home/vagrant/vagrant-dump-#{db['db_name']}.sql"
					notifies :run, "execute[load database #{db['db_name']}]", :immediately
					subscribes :run, resources("execute[create database #{db['db_name']}]"), :immediately
					action :nothing
				end
				# Once copied, import it
				execute "load database #{db['db_name']}" do
					command "/usr/bin/mysql -u root -p\"#{node['mysql']['server_root_password']}\" #{db['db_name']} < /home/vagrant/vagrant-dump-#{db['db_name']}.sql "
					only_if "test -f /home/vagrant/vagrant-dump-#{db['db_name']}.sql"
					action :nothing
				end
			end

			if db.include?('db_prefix')
				db_prefix = "#{db['db_prefix']}_"
			else
				db_prefix = ""
			end

			# Set up magento alter to run last after new database
			execute "magento alter database #{db['db_name']}" do
				command "/usr/bin/mysql -u root -p\"#{node['mysql']['server_root_password']}\" #{db['db_name']} -e \"" +\
				"UPDATE #{db_prefix}core_config_data SET value = 'http://#{site['host']}/' WHERE path = 'web/unsecure/base_url' ; " +\
				"UPDATE #{db_prefix}core_config_data SET value = 'https://#{site['host']}/' WHERE path = 'web/secure/base_url' ; \" ";
				only_if { site['framework'] == 'magento' }
				subscribes :run, resources("execute[create database #{db['db_name']}]"), :immediately
			end

			# Set up wordpress alter to run last after new database
			execute "wordpress alter database #{db['db_name']}" do
				command "/usr/bin/mysql -u root -p\"#{node['mysql']['server_root_password']}\" #{db['db_name']} -e \"" +\
				"UPDATE #{db_prefix}options SET option_value = 'http://#{site['host']}' WHERE option_name IN ('siteurl','home');\" ";
				only_if { site['framework'] == 'wordpress' }
				subscribes :run, resources("execute[create database #{db['db_name']}]"), :immediately
			end

		end
	end

	# Clear cache using drush for drupal
	if site['framework'] == 'drupal'
		execute "drupal clear cache - #{site['host']}" do
			command "drush -r #{site_docroot} cc all";
		end
	end


end
