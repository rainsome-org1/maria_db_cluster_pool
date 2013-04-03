module ActiveRecord
  class Base
    class << self
      def maria_db_cluster_pool_connection(config)
        pool_weights = {}

        config = config.with_indifferent_access
        default_config = {:pool_weight => 1}.merge(config.merge(:adapter => config[:pool_adapter])).with_indifferent_access
        default_config.delete(:server_pool)
        default_config.delete(:pool_adapter)

        pool_connections = []
        config[:server_pool].each do |server_config|
          server_config = default_config.merge(server_config).with_indifferent_access
          server_config[:pool_weight] = server_config[:pool_weight].to_i
          if server_config[:pool_weight] > 0
            begin
              establish_adapter(server_config[:adapter])
              conn = send("#{server_config[:adapter]}_connection".to_sym, server_config)
              conn.class.send(:include, MariaDBClusterPool::ConnectTimeout) unless conn.class.include?(MariaDBClusterPool::ConnectTimeout)
              conn.connect_timeout = server_config[:connect_timeout]
              pool_connections << conn
              pool_weights[conn] = server_config[:pool_weight]
            rescue Exception => e
              if logger
                logger.error("Error connecting to read connection #{server_config.inspect}")
                logger.error(e)
              end
            end
          end
        end if config[:server_pool]

        @maria_db_cluster_pool_classes ||= {}
        klass = @maria_db_cluster_pool_classes[pool_connections.first.class]
        unless klass
          klass = ActiveRecord::ConnectionAdapters::MariaDBClusterPoolAdapter.adapter_class(pool_connections.first)
          @maria_db_cluster_pool_classes[pool_connections.first.class] = klass
        end

        return klass.new(nil, logger, pool_connections, pool_weights)
      end

      def establish_adapter(adapter)
        raise AdapterNotSpecified.new("database configuration does not specify adapter") unless adapter
        raise AdapterNotFound.new("database pool must specify adapters") if adapter == 'MariaDB_Cluster_Pool'

        begin
          require 'rubygems'
          gem "activerecord-#{adapter}-adapter"
          require "active_record/connection_adapters/#{adapter}_adapter"
        rescue LoadError
          begin
            require "active_record/connection_adapters/#{adapter}_adapter"
          rescue LoadError
            raise "Please install the #{adapter} adapter: `gem install activerecord-#{adapter}-adapter` (#{$!})"
          end
        end

        adapter_method = "#{adapter}_connection"
        if !respond_to?(adapter_method)
          raise AdapterNotFound, "database configuration specifies nonexistent #{adapter} adapter"
        end
      end
    end
    
    module MariaDBClusterPoolBehavior
      def self.included(base)
        base.alias_method_chain(:reload, :maria_db_cluster_pool)
      end
      
      # Force reload to use the master connection since it's probably being called for a reason.
      def reload_with_MariaDB_Cluster_Pool(*args)
        reload_without_MariaDB_Cluster_Pool(*args)
      end
    end
    
    include(MariaDBClusterPoolBehavior) unless include?(MariaDBClusterPoolBehavior)
  end

  module ConnectionAdapters
    class MariaDBClusterPoolAdapter < AbstractAdapter
      
      attr_reader :connections
      
      class << self
        # Create an anonymous class that extends this one and proxies methods to the pool connections.
        def adapter_class(master_connection)
          # Define methods to proxy to the appropriate pool
          master_methods = []
          master_connection_classes = [AbstractAdapter, Quoting, DatabaseStatements, SchemaStatements]
          master_connection_classes << DatabaseLimits if const_defined?(:DatabaseLimits)
          master_connection_class = master_connection.class
          while ![Object, AbstractAdapter].include?(master_connection_class) do
            master_connection_classes << master_connection_class
            master_connection_class = master_connection_class.superclass
          end
          master_connection_classes.each do |connection_class|
            master_methods.concat(connection_class.public_instance_methods(false))
            master_methods.concat(connection_class.protected_instance_methods(false))
          end
          master_methods.uniq!
          master_methods -= public_instance_methods(false) + protected_instance_methods(false) + private_instance_methods(false)
          master_methods = master_methods.collect{|m| m.to_sym}

          klass = Class.new(self)
          master_methods.each do |method_name|
            klass.class_eval <<-EOS, __FILE__, __LINE__ + 1
              def #{method_name}(*args, &block)
                use_master_connection do
                  return proxy_connection_method(master_connection, :#{method_name}, :master, *args, &block)
                end
              end
            EOS
          end

          klass.send :protected, :select
        
          return klass
        end
      
        # Set the arel visitor on the connections.
        def visitor_for(pool)
          # This is ugly, but then again, so is the code in ActiveRecord for setting the arel
          # visitor. There is a note in the code indicating the method signatures should be updated.
          config = pool.spec.config.with_indifferent_access
          adapter = config[:master][:adapter] || config[:pool_adapter]
          MariaDBClusterPool.adapter_class_for(adapter).visitor_for(pool)
        end
      end
      
      def initialize(connection, logger, connections, pool_weights)
        super(connection, logger)
        
        @connections = connections.dup.freeze
        
        @weighted_connections = []
        pool_weights.each_pair do |conn, weight|
          weight.times{@weighted_connections << conn}
        end
        @available_connections = [AvailableConnections.new(@weighted_connections)]
      end
      
      def adapter_name #:nodoc:
        'MariaDB_Cluster_Pool'
      end
      
      # Returns an array of the master connection and the read pool connections
      def all_connections
        @connections
      end
      
      # Get the pool weight of a connection
      def pool_weight(connection)
        return @weighted_connections.select{|conn| conn == connection}.size
      end
      
      def requires_reloading?
        false
      end
      
      def visitor=(visitor)
        all_connections.each{|conn| conn.visitor = visitor}
      end
      
      def visitor
        connection.visitor
      end
      
      def active?
        active = true
        do_to_connections {|conn| active &= conn.active?}
        return active
      end

      def reconnect!
        do_to_connections {|conn| conn.reconnect!}
      end

      def disconnect!
        do_to_connections {|conn| conn.disconnect!}
      end

      def reset!
        do_to_connections {|conn| conn.reset!}
      end

      def verify!(*ignored)
        do_to_connections {|conn| conn.verify!(*ignored)}
      end

      def reset_runtime
        total = 0.0
        do_to_connections {|conn| total += conn.reset_runtime}
        total
      end

      class DatabaseConnectionError < StandardError
      end
      
      # This simple class puts an expire time on an array of connections. It is used so the a connection
      # to a down database won't try to reconnect over and over.
      class AvailableConnections
        attr_reader :connections, :failed_connection
        attr_writer :expires
        
        def initialize(connections, failed_connection = nil, expires = nil)
          @connections = connections
          @failed_connection = failed_connection
          @expires = expires
        end
        
        def expired?
          @expires ? @expires <= Time.now : false
        end

        def reconnect!
          failed_connection.reconnect!
          raise DatabaseConnectionError.new unless failed_connection.active?
        end
      end
      
      # Get the available weighted connections. When a connection is dead and cannot be reconnected, it will
      # be temporarily removed from the read pool so we don't keep trying to reconnect to a database that isn't
      # listening.
      def available_connections
        available = @available_connections.last
        if available.expired?
          begin
            @logger.info("Adding dead database connection back to the pool") if @logger
            available.reconnect!
          rescue => e
            # Couldn't reconnect so try again in a little bit
            if @logger
              @logger.warn("Failed to reconnect to database when adding connection back to the pool")
              @logger.warn(e)
            end
            available.expires = 30.seconds.from_now
            return available.connections
          end
          
          # If reconnect is successful, the connection will have been re-added to @available_connections list,
          # so let's pop this old version of the connection
          @available_connections.pop
          
          # Now we'll try again after either expiring our bad connection or re-adding our good one
          return available_connections
        else
          return available.connections
        end
      end
      
      def reset_available_connections
        @available_connections.slice!(1, @available_connections.length)
        @available_connections.first.connections.each do |connection|
          unless connection.active?
            connection.reconnect! rescue nil
          end
        end
      end
      
      # Temporarily remove a connection from the read pool.
      def suppress_connection(conn, expire)
        available = available_connections
        connections = available.reject{|c| c == conn}

        # This wasn't a read connection so don't suppress it
        return if connections.length == available.length

        if connections.empty?
          @logger.warn("All read connections are marked dead; trying them all again.") if @logger
          # No connections available so we might as well try them all again
          reset_available_connections
        else
          @logger.warn("Removing #{conn.inspect} from the connection pool for #{expire} seconds") if @logger
          # Available connections will now not include the suppressed connection for a while
          @available_connections.push(AvailableConnections.new(connections, conn, expire.seconds.from_now))
        end
      end
      
      private
      
      def proxy_connection_method(connection, method, *args, &block)
        begin
          connection.send(method, *args, &block)
        rescue => e
          # If the statement was a read statement and it wasn't forced against the master connection
          # try to reconnect if the connection is dead and then re-run the statement.
          unless connection.active?
            suppress_connection(connection, 30)
            connection = @available_connections.last
          end
          proxy_connection_method(connection, method, *args, &block)
        end
      end

      # Yield a block to each connection in the pool. If the connection is dead, ignore the error
      def do_to_connections
        all_connections.each do |conn|
          begin
            yield(conn)
          rescue => e
            if @logger
              @logger.warn("Error in do_to_connections")
              @logger.warn(e.message)
              @logger.warn(e.backtrace.inspect)
            end
          end
        end
      end
    end
  end
end
