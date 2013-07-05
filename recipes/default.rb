#
# Cookbook Name:: rails-app
# Recipe:: default
#
# Copyright 2012, Debrauw.net
#
#

# Install bundler gem
#
gem_package "bundler" do
  version node["rails-application"]["bundler-version"]
end

# Deploy identity (private key), as stored in data bag on target node
#
directory "/tmp/private_code/.ssh" do
  owner node['application']['deploy_user']
  recursive true
end

file "/tmp/private_code/.ssh/id_deploy" do
  content node['application']['deploy_key']
  owner node['application']['deploy_user']
  mode 0600
end

# Deploy ssh wrapper script to use deploy identity
#
cookbook_file "/tmp/private_code/wrap-ssh4git.sh" do
  source "wrap-ssh4git.sh"
  owner node['application']['deploy_user']
  mode 0700
end

# Create shared folders
#
%w{config log pids cached-copy bundle system uploads assets}.each do |dir|
  directory "#{node['application']['deploy_to']}/shared/#{dir}" do
    owner node['application']['deploy_user']
    group node['application']['deploy_user']
    mode '0755'
    recursive true
    action :create
  end
end

# Create the mongoid.yml file
#
template "#{node['application']['deploy_to']}/shared/config/mongoid.yml" do
  source "mongoid.yml.erb"
  mode "0644"
  owner node['application']['deploy_user']
  group node['application']['deploy_user']
end

# Deploy revision
#
deploy "#{node['application']['deploy_to']}" do
  repo node['application']['repository']
  revision node['application']['revision']
  user node['application']['deploy_user']
  enable_submodules true
  purge_before_symlink
  create_dirs_before_symlink
  symlinks({"uploads" => "public/uploads", "system" => "public/system", "pids" => "tmp/pids", "log" => "log", "assets" => "public/assets" })
  symlink_before_migrate({"config/mongoid.yml" => "config/mongoid.yml", "config/database.yml" => "config/database.yml"})
  migrate node['application']['migrate']
  migration_command node['application']['migration_command']
  environment "RAILS_ENV" => node['application']['environment']
  shallow_clone true
  action :deploy # :rollback
  restart_command "touch tmp/restart.txt"
  git_ssh_wrapper "/tmp/private_code/wrap-ssh4git.sh"

  before_restart do
    current_release_directory = release_path
    running_deploy_user = new_resource.user
    bundler_depot = new_resource.shared_path + '/bundle'
    excluded_groups = "--without #{%w(development test).join(' ')}" if node["application"]["environment"] == "production"
    environment = new_resource.environment["RAILS_ENV"]

    script 'Bundling the gems' do
      interpreter 'bash'
      cwd current_release_directory
      user running_deploy_user
      code <<-EOS
        bundle install --quiet --deployment --path #{bundler_depot} \
        #{excluded_groups}
      EOS
    end

    script 'Precompiling the assets' do
      interpreter 'bash'
      cwd current_release_directory
      user running_deploy_user
      code "bundle exec rake assets:precompile RAILS_ENV=#{environment} RAILS_GROUPS=assets"
    end

    # Deploy virtual server file for nginx
    template "#{node['application']['id']}" do
      path "/etc/nginx/sites-available/#{node['application']['id']}"
      source "virtual_server.erb"
      owner "root"
      group "root"
      mode "0644"
    end

    # Symlink it to enable it for nginx
    link "/etc/nginx/sites-enabled/#{node['application']['id']}" do
      to "/etc/nginx/sites-available/#{node['application']['id']}"
    end

    # Notify Appsingal.com
    script 'Notifying Appsignal' do
      interpreter 'bash'
      cwd current_release_directory
      user running_deploy_user
      code <<-EOS
        rev=`git describe --always`
        bundle exec appsignal notify_of_deploy --revision=$rev --repository=#{new_resource.repo} --user=#{running_deploy_user} --environment=#{environment}
      EOS
    end

  end
end

service "nginx" do
  action [ :restart ]
end




