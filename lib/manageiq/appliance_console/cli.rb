require 'optimist'
require 'pathname'

# support for appliance_console methods
unless defined?(say)
  def say(arg)
    puts(arg)
  end
end

module ManageIQ
module ApplianceConsole
  class CliError < StandardError; end

  class Cli
    attr_accessor :options

    # machine host
    def host
      options[:host] || LinuxAdmin::Hosts.new.hostname
    end

    # database hostname
    def hostname
      options[:internal] ? "localhost" : options[:hostname]
    end

    def local?(name = hostname)
      name.presence.in?(["localhost", "127.0.0.1", nil])
    end

    def set_host?
      options[:host]
    end

    def key?
      options[:key] || options[:fetch_key] || (local_database? && !key_configuration.key_exist?)
    end

    def database?
      options[:standalone] || hostname
    end

    def local_database?
      database? && (local?(hostname) || options[:standalone])
    end

    def certs?
      options[:http_cert]
    end

    def uninstall_ipa?
      options[:uninstall_ipa]
    end

    def install_ipa?
      options[:ipaserver]
    end

    def tmp_disk?
      options[:tmpdisk]
    end

    def log_disk?
      options[:logdisk]
    end

    def extauth_opts?
      options[:extauth_opts]
    end

    def set_server_state?
      options[:server]
    end

    def set_replication?
      options[:cluster_node_number] && options[:password] && replication_params?
    end

    def replication_params?
      options[:replication] == "primary" || (options[:replication] == "standby" && options[:primary_host])
    end

    def initialize(options = {})
      self.options = options
    end

    def disk_from_string(path)
      return if path.blank?
      path == "auto" ? disk : disk_by_path(path)
    end

    def disk
      LinuxAdmin::Disk.local.detect { |d| d.partitions.empty? }
    end

    def disk_by_path(path)
      LinuxAdmin::Disk.local.detect { |d| d.path == path }
    end

    def parse(args)
      args.shift if args.first == "--" # Handle when called through script/runner
      self.options = Optimist.options(args) do
        banner "Usage: appliance_console_cli [options]"

        opt :host,     "/etc/hosts name",    :type => :string,  :short => 'H'
        opt :region,   "Region Number",      :type => :integer, :short => "r"
        opt :internal, "Internal Database",                     :short => 'i'
        opt :hostname, "Database Hostname",  :type => :string,  :short => 'h'
        opt :port,     "Database Port",      :type => :integer,                :default => 5432
        opt :username, "Database Username",  :type => :string,  :short => 'U', :default => "root"
        opt :password, "Database Password",  :type => :string,  :short => "p"
        opt :dbname,   "Database Name",      :type => :string,  :short => "d", :default => "vmdb_production"
        opt :standalone, "Run this server as a standalone database server", :type => :bool, :short => 'S'
        opt :key,      "Create encryption key",  :type => :boolean, :short => "k"
        opt :fetch_key, "SSH host with encryption key", :type => :string, :short => "K"
        opt :force_key, "Forcefully create encryption key", :type => :boolean, :short => "f"
        opt :sshlogin,  "SSH login",         :type => :string,                 :default => "root"
        opt :sshpassword, "SSH password",    :type => :string
        opt :replication, "Configure database replication as primary or standby", :type => :string, :short => :none
        opt :primary_host, "Primary database host IP address", :type => :string, :short => :none
        opt :standby_host, "Standby database host IP address", :type => :string, :short => :none
        opt :auto_failover, "Configure Replication Manager (repmgrd) for automatic failover", :type => :bool, :short => :none
        opt :cluster_node_number, "Database unique cluster node number", :type => :integer, :short => :none
        opt :verbose,  "Verbose",            :type => :boolean, :short => "v"
        opt :dbdisk,   "Database Disk Path", :type => :string
        opt :logdisk,  "Log Disk Path",      :type => :string
        opt :tmpdisk,   "Temp storage Disk Path", :type => :string
        opt :uninstall_ipa, "Uninstall IPA Client", :type => :boolean,         :default => false
        opt :ipaserver,  "IPA Server FQDN",  :type => :string
        opt :ipaprincipal,  "IPA Server principal", :type => :string,          :default => "admin"
        opt :ipapassword,   "IPA Server password",  :type => :string
        opt :ipadomain,     "IPA Server domain (optional)", :type => :string
        opt :iparealm,      "IPA Server realm (optional)", :type => :string
        opt :ca,                   "CA name used for certmonger",       :type => :string,  :default => "ipa"
        opt :http_cert,            "install certs for http server",     :type => :boolean
        opt :extauth_opts,         "External Authentication Options",   :type => :string
        opt :server,               "{start|stop|restart} actions on evmserverd Server",   :type => :string
      end
      Optimist.die :region, "needed when setting up a local database" if region_number_required? && options[:region].nil?
      self
    end

    def region_number_required?
      !options[:standalone] && local_database?
    end

    def run
      Optimist.educate unless set_host? || key? || database? || tmp_disk? || log_disk? ||
                             uninstall_ipa? || install_ipa? || certs? || extauth_opts? ||
                             set_server_state? || set_replication?
      if set_host?
        system_hosts = LinuxAdmin::Hosts.new
        system_hosts.hostname = options[:host]
        system_hosts.set_loopback_hostname(options[:host])
        system_hosts.save
        LinuxAdmin::Service.new("network").restart
      end
      create_key if key?
      set_db if database?
      set_replication if set_replication?
      config_tmp_disk if tmp_disk?
      config_log_disk if log_disk?
      uninstall_ipa if uninstall_ipa?
      install_ipa if install_ipa?
      install_certs if certs?
      extauth_opts if extauth_opts?
      set_server_state if set_server_state?
    rescue CliError => e
      say(e.message)
      say("")
      exit(1)
    rescue AwesomeSpawn::CommandResultError => e
      say e.result.output
      say e.result.error
      say ""
      raise
    end

    def set_db
      raise "No encryption key (v2_key) present" unless key_configuration.key_exist?
      raise "A password is required to configure a database" unless password?
      if local?
        set_internal_db
      else
        set_external_db
      end
    end

    def password?
      options[:password] && !options[:password].strip.empty?
    end

    def set_internal_db
      say "configuring internal database"
      config = ManageIQ::ApplianceConsole::InternalDatabaseConfiguration.new({
        :database          => options[:dbname],
        :region            => options[:region],
        :username          => options[:username],
        :password          => options[:password],
        :interactive       => false,
        :disk              => disk_from_string(options[:dbdisk]),
        :run_as_evm_server => !options[:standalone]
      }.delete_if { |_n, v| v.nil? })
      config.check_disk_is_mount_point

      # create partition, pv, vg, lv, ext4, update fstab, mount disk
      # initdb, relabel log directory for selinux, update configs,
      # start pg, create user, create db update the rails configuration,
      # verify, set up the database with region. activate does it all!
      raise CliError, "Failed to configure internal database" unless config.activate

      # enable/start related services
      config.post_activation
    rescue RuntimeError => e
      raise CliError, "Failed to configure internal database #{e.message}"
    end

    def set_external_db
      say "configuring external database"
      config = ManageIQ::ApplianceConsole::ExternalDatabaseConfiguration.new({
        :host        => options[:hostname],
        :port        => options[:port],
        :database    => options[:dbname],
        :region      => options[:region],
        :username    => options[:username],
        :password    => options[:password],
        :interactive => false,
      }.delete_if { |_n, v| v.nil? })

      # call create_or_join_region (depends on region value)
      raise CliError, "Failed to configure external database" unless config.activate

      # enable/start related services
      config.post_activation
    end

    def set_replication
      if options[:replication] == "primary"
        db_replication = ManageIQ::ApplianceConsole::DatabaseReplicationPrimary.new
        say("Configuring Server as Primary")
      else
        db_replication = ManageIQ::ApplianceConsole::DatabaseReplicationStandby.new
        say("Configuring Server as Standby")
        db_replication.disk = disk_from_string(options[:dbdisk])
        db_replication.primary_host = options[:primary_host]
        db_replication.standby_host = options[:standby_host] if options[:standby_host]
        db_replication.run_repmgrd_configuration = options[:auto_failover] ? true : false
      end
      db_replication.database_name = options[:dbname] if options[:dbname]
      db_replication.database_user = options[:username] if options[:username]
      db_replication.node_number = options[:cluster_node_number]
      db_replication.database_password = options[:password]
      db_replication.activate
    end

    def key_configuration
      @key_configuration ||= KeyConfiguration.new(
        :action   => options[:fetch_key] ? :fetch : :create,
        :force    => options[:fetch_key] ? true : options[:force_key],
        :host     => options[:fetch_key],
        :login    => options[:sshlogin],
        :password => options[:sshpassword],
      )
    end

    def create_key
      say "#{key_configuration.action} encryption key"
      unless key_configuration.activate
        say("Could not create encryption key (v2_key)")
        exit(1)
      end
    end

    def install_certs
      say "creating ssl certificates"
      config = CertificateAuthority.new(
        :hostname => host,
        :realm    => options[:iparealm],
        :ca_name  => options[:ca],
        :http     => options[:http_cert],
        :verbose  => options[:verbose],
      )

      config.activate
      say "\ncertificate result: #{config.status_string}"
      unless config.complete?
        say "After the certificates are retrieved, rerun to update service configuration files"
      end
    end

    def install_ipa
      raise "please uninstall ipa before reinstalling" if ExternalHttpdAuthentication.ipa_client_configured?
      config = ExternalHttpdAuthentication.new(
        host,
        :ipaserver => options[:ipaserver],
        :domain    => options[:ipadomain],
        :realm     => options[:iparealm],
        :principal => options[:ipaprincipal],
        :password  => options[:ipapassword],
      )

      config.post_activation if config.activate
    end

    def uninstall_ipa
      say "Uninstalling IPA-client"
      config = ExternalHttpdAuthentication.new
      config.deactivate if config.ipa_client_configured?
    end

    def config_tmp_disk
      if (tmp_disk = disk_from_string(options[:tmpdisk]))
        say "creating temp disk"
        config = ManageIQ::ApplianceConsole::TempStorageConfiguration.new(:disk => tmp_disk)
        config.activate
      else
        report_disk_error(options[:tmpdisk])
      end
    end

    def config_log_disk
      if (log_disk = disk_from_string(options[:logdisk]))
        say "creating log disk"
        config = ManageIQ::ApplianceConsole::LogfileConfiguration.new(:disk => log_disk)
        config.activate
      else
        report_disk_error(options[:logdisk])
      end
    end

    def report_disk_error(missing_disk)
      choose_disk = disk.try(:path)
      if choose_disk
        say "could not find disk #{missing_disk}"
        say "if you pass auto, it will choose: #{choose_disk}"
      else
        say "no disks with a free partition"
      end
    end

    def extauth_opts
      extauthopts = ExternalAuthOptions.new
      extauthopts_hash = extauthopts.parse(options[:extauth_opts])
      raise "Must specify at least one external authentication option to set" unless extauthopts_hash.present?
      extauthopts.update_configuration(extauthopts_hash)
    end

    def set_server_state
      service = LinuxAdmin::Service.new("evmserverd")
      service_running = service.running?
      case options[:server]
      when "start"
        service.start unless service_running
      when "stop"
        service.stop if service_running
      when "restart"
        service.restart
      else
        raise "Invalid server action"
      end
    end

    def self.parse(args)
      new.parse(args).run
    end
  end
end
end
