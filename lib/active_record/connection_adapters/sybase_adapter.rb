require 'arel/visitors/sybase'
require 'arel/visitors/bind_visitor'
require 'active_record/connection_adapters/abstract_adapter'
require 'tiny_tds'

module ActiveRecord
  class Base
    # Establishes a connection to the database that's used by all Active Record objects
    def self.sybase_connection(config) # :nodoc:
      config = config.symbolize_keys

      username = config[:username] ? config[:username].to_s : 'sa'
      password = config[:password] ? config[:password].to_s : ''

      if not config.has_key?(:host) and not config.has_key?(:dataserver)
        raise ArgumentError, "No database server name specified. Missing argument: host."
      end

      if not config.has_key?(:database)
        raise ArgumentError, "No database specified. Missing argument: database."
      end

      ConnectionAdapters::SybaseAdapter.new(nil, logger, config)
    end
  end # class Base

  module ConnectionAdapters

    # ActiveRecord connection adapter for Tiny TDS
    # (see http://rubydoc.info/gems/tiny_tds/frames)
    #
    # Options:
    #
    # * <tt>:host</tt>     -- The host name of the database server. No default, must be provided.
    # * <tt>:port</tt>     -- The port number on which the server is listening on. No default.
    # * <tt>:database</tt> -- The name of the database. No default, must be provided.
    # * <tt>:username</tt> -- Defaults to "sa".
    # * <tt>:password</tt> -- Defaults to empty string.
    # * <tt>:tds_version</tt> -- Sets the TDS protocol version: 42 for 4.2 and 50 for 5.0.
    # * <tt>:prepared_statements</tt> -- Enable prepared statements support,
    #       requireds TDS version 5.0. *WARNING*: on tiny_tds, as of 0.5.1, there
    #       is no support for them: you'll get a crash if you enable this feature
    #
    class SybaseAdapter < AbstractAdapter # :nodoc:
      class SybaseColumn < Column
        attr_reader :identity

        def initialize(name, default, sql_type = nil, nullable = nil, identity = nil, primary = nil)
          super(name, default, sql_type, nullable)
          @default, @identity, @primary = type_cast(default), identity, primary
        end

        def simplified_type(field_type)
          case field_type
            when /int|bigint|smallint|tinyint/i        then :integer
            when /float|double|real/i                  then :float
            when /decimal|money|numeric|smallmoney/i   then :decimal
            when /text|ntext/i                         then :text
            when /binary|image|varbinary/i             then :binary
            when /char|nchar|nvarchar|string|varchar/i then :string
            when /bit/i                                then :boolean
            when /datetime|smalldatetime/i             then :datetime
            else                                       super
          end
        end

        def self.string_to_binary(value)
          "0x#{value.unpack("H*")[0]}"
        end
      end # class SybaseColumn

      ADAPTER_NAME = 'Sybase'

      NATIVE_DATABASE_TYPES = {
        :primary_key => "numeric(9,0) IDENTITY PRIMARY KEY",
        :string      => { :name => "varchar", :limit => 255 },
        :text        => { :name => "text" },
        :integer     => { :name => "int" },
        :float       => { :name => "float", :limit => 8 },
        :decimal     => { :name => "decimal" },
        :datetime    => { :name => "datetime" },
        :timestamp   => { :name => "timestamp" },
        :time        => { :name => "time" },
        :date        => { :name => "datetime" },
        :binary      => { :name => "image"},
        :boolean     => { :name => "bit" }
      }

      def initialize(connection, logger, config)
        super(connection, logger)
        @config = config

        connect

        @numconvert = config.has_key?(:numconvert) ? config[:numconvert] : true
        @strip_char = config.has_key?(:strip_char) ? config[:strip_char] : false
        @table_types = config[:views_as_tables] ? "'U', 'V'" : "'U'"
        @quoted_column_names = {}

        # Set the Arel visitor for this adapter.
        #
        # Disable bind variables, unless explicitly required via the
        # "prepared_statements" configuration variable.
        #
        # Please note that TDS version 5.0 is required for prepared statements,
        # and current tiny_tds version 0.5.1 does not support them (you'll get a
        # segfault).
        #
        @visitor = if config[:prepared_statements]
          Arel::Visitors::Sybase
        else
          Class.new(Arel::Visitors::Sybase) do
            include Arel::Visitors::BindVisitor
          end
        end.new(self)
      end

      # Returns 'Sybase' as adapter name for identification purposes.
      def adapter_name
        ADAPTER_NAME
      end

      def supports_migrations? #:nodoc:
        true
      end

      def supports_primary_key? #:nodoc:
        true
      end

      def native_database_types
        NATIVE_DATABASE_TYPES
      end

      # QUOTING ==================================================

      def quote(value, column = nil)
        return value.quoted_id if value.respond_to?(:quoted_id)

        case value
          when String
            if column && column.type == :binary && column.class.respond_to?(:string_to_binary)
              "#{quote_string(column.class.string_to_binary(value))}"
            elsif @numconvert && force_numeric?(column) && !column.nil?
              value = column.type == :integer ? value.to_i : value.to_f
              value.to_s
            else
              "'#{quote_string(value)}'"
            end
          when NilClass              then (column && column.type == :boolean) ? '0' : "NULL"
          when TrueClass             then '1'
          when FalseClass            then '0'
          when Float, Fixnum, Bignum then force_numeric?(column) ? value.to_s : "'#{value.to_s}'"
          else
            if value.acts_like?(:time)
              "'#{value.strftime("%Y-%m-%d %H:%M:%S")}'"
            else
              super
            end
        end
      end

      def quote_column_name(name)
        # If column name is close to max length, skip the quotes, since they
        # seem to count as part of the length.
        @quoted_column_names[name] ||=
          ((name.to_s.length + 2) <= table_alias_length) ? "[#{name}]" : name.to_s
      end

      def quote_string(s)
        s.gsub(/'/, "''") # ' (for ruby-mode)
      end

      def quoted_true
        "1"
      end

      def quoted_false
        "0"
      end


      # CONNECTION MANAGEMENT ====================================

      def active?
        @connection.active?
      end

      def reconnect!
        disconnect!
        connect
      end

      def disconnect!
        @connection.close rescue nil
      end

      def connect
        appname = @config[:appname] || Rails.application.class.name.split('::').first rescue nil
        login_timeout = @config[:login_timeout].present? ? @config[:login_timeout].to_i : nil
        timeout = @config[:timeout].present? ? @config[:timeout].to_i/1000 : nil
        encoding = @config[:encoding].present? ? @config[:encoding] : nil
        @connection = TinyTds::Client.new({
          :dataserver    => @config[:dataserver],
          :host          => @config[:host],
          :port          => @config[:port],
          :username      => @config[:username],
          :password      => @config[:password],
          :database      => @config[:database],
          :tds_version   => @config[:tds_version] || '42',
          :appname       => appname,
          :login_timeout => login_timeout,
          :timeout       => timeout,
          :encoding      => encoding,
        }).tap do |client|
            client.execute("SET ANSINULL ON").do
        end
      end

      # SCHEMA STATEMENTS ========================================

      def type_to_sql(type, limit = nil, precision = nil, scale = nil)
        return super unless type.to_s == 'integer'
        if !limit.nil? && limit < 4
          'smallint'
        else
          'integer'
        end
      end

      def table_alias_length
        30
      end

      def current_database
        select_value 'SELECT DB_NAME() AS name', 'Current DB name'
      end

      def tables(name = nil)
        name ||= 'Tables list'
        sql = "SELECT name FROM sysobjects WHERE type IN (#@table_types)"
        select(sql, name).map { |row| row['name'] }
      end

      def indexes(table_name, name = nil)
        select("exec sp_helpindex #{table_name}", name).map do |index|
          next if index["index_name"].blank? # skip index_ptn_name rows
          unique = index["index_description"] =~ /unique/
          primary = index["index_description"] =~ /^clustered/
          if !primary
            cols = index["index_keys"].split(", ").each { |col| col.strip! }
            IndexDefinition.new(table_name, index["index_name"], unique, cols)
          end
        end.compact
      end

      def columns(table_name, name = nil)
        sql = <<-sql
          SELECT col.name AS name, type.name AS type, col.prec, col.scale,
                 col.length, col.status, obj.sysstat2, def.text
          FROM sysobjects obj, syscolumns col, systypes type, syscomments def
          WHERE obj.id = col.id              AND
                col.usertype = type.usertype AND
                type.name != 'timestamp'     AND
                col.cdefault *= def.id       AND
                obj.type IN (#@table_types)  AND
                obj.name = '#{table_name}'
          ORDER BY col.colid
        sql

        result = select sql, "Columns for #{table_name}"

        result.map do | row |
          name = row['name']
          type = row['type']
          prec = row['prec']
          scale = row['scale']
          length = row['length']
          status = row['status']
          sysstat2 = row['sysstat2']
          default = row['text']
          name.sub!(/_$/o, '')
          type = normalize_type(type, prec, scale, length)
          default_value = nil
          if default =~ /DEFAULT\s+(.+)/o
            default_value = $1.strip
            default_value = default_value[1...-1] if default_value =~ /^['"]/o
          end
          nullable = (status & 8) == 8
          identity = status >= 128
          primary = (sysstat2 & 8) == 8
          SybaseColumn.new(name, default_value, type, nullable, identity, primary)
        end
      end

      def primary_key(table)
        sql = <<-sql
          SELECT index_col(usr.name || "." || obj.name, idx.indid, 1)
          FROM sysobjects obj
          INNER JOIN sysusers usr on obj.uid = usr.uid
          INNER JOIN sysindexes idx on obj.id = idx.id
          WHERE idx.status & 0x12 > 0 AND
                obj.name = #{quote table}
        sql

        select_value sql, "PK for #{table}"
      end

      def rename_table(name, new_name)
        execute "EXEC sp_rename '#{name}', '#{new_name}'"
      end

      def rename_column(table, column, new_column_name)
        execute "EXEC sp_rename '#{table}.#{column}', '#{new_column_name}', 'column'"
      end

      def change_column(table_name, column_name, type, options = {}) #:nodoc:
        begin
          execute "ALTER TABLE #{table_name} MODIFY #{column_name} #{type_to_sql(type, options[:limit])}"
        rescue StatementInvalid => e
          # Swallow exception if no-op.
          raise e unless e.message =~ /no columns to drop, add or modify/
        end

        if options.has_key?(:default)
          remove_default_constraint(table_name, column_name)
          execute "ALTER TABLE #{table_name} REPLACE #{column_name} DEFAULT #{quote options[:default]}"
        end
      end

      def remove_column(table_name, column_name)
        remove_default_constraint(table_name, column_name)
        execute "ALTER TABLE #{table_name} DROP #{column_name}"
      end

      def remove_default_constraint(table_name, column_name)
        sql = <<-sql
          SELECT def.name
          FROM sysobjects def, syscolumns col, sysobjects tab
          WHERE col.cdefault = def.id AND
                col.name = '#{column_name}' AND
                tab.name = '#{table_name}'  AND
                col.id = tab.id
        sql

        select(sql).each do |constraint|
          execute "ALTER TABLE #{table_name} DROP CONSTRAINT #{constraint["name"]}"
        end
      end

      def remove_index(table_name, options = {})
        execute "DROP INDEX #{table_name}.#{index_name(table_name, options)}"
      end

      def add_column_options!(sql, options) #:nodoc:
        sql << " DEFAULT #{quote(options[:default], options[:column])}" if options_include_default?(options)

        if check_null_for_column?(options[:column], sql)
          sql << (options[:null] == false ? " NOT NULL" : " NULL")
        end
        sql
      end

      # DATABASE STATEMENTS ======================================

      def execute(sql, name = nil)
        exec_query(sql, name)
      end

      def exec_query(sql, name = 'SQL', binds = [])
        result = nil

        log(sql, name, binds) do
          raise 'Connection is closed' unless active?

          result = @connection.execute(sql)
          return ActiveRecord::Result.new(result.fields, result.entries)
        end
      ensure
        result.cancel
      end

      # Executes the given INSERT sql and returns the new record's ID
      def insert_sql(sql, name = nil, pk = nil, id_value = nil, sequence_name = nil)
        super

        id = select_one('SELECT @@IDENTITY AS id').fetch('id').to_i
        return id if id > 0
      end

      def begin_db_transaction
        raw_execute 'BEGIN TRAN'
      end

      def commit_db_transaction
        raw_execute 'COMMIT TRAN'
      end

      def rollback_db_transaction
        raw_execute 'ROLLBACK TRAN'
      end

    private

      # True if column is explicitly declared non-numeric, or
      # if column is nil (not specified).
      def force_numeric?(column)
        (column.nil? || [:integer, :float, :decimal].include?(column.type))
      end

      def check_null_for_column?(col, sql)
        # Sybase columns are NOT NULL by default, so explicitly set NULL
        # if :null option is omitted.  Disallow NULLs for boolean.
        type = col.nil? ? "" : col[:type]

        # Ignore :null if a primary key
        return false if type =~ /PRIMARY KEY/i

        # Ignore :null if a :boolean or BIT column
        if (sql =~ /\s+bit(\s+DEFAULT)?/i) || type == :boolean
          # If no default clause found on a boolean column, add one.
          sql << " DEFAULT 0" if $1.nil?
          return false
        end
        true
      end

      def select_rows(sql, name = nil)
        select(sql, name).map!(&:values)
      end

      # If a DECLARE CURSOR statement is present in the SQL query,
      # runs it as a separate batch.
      CursorRegexp = /DECLARE [_\w\d]+ ?(?:UNIQUE|SCROLL|NO SCROLL|DYNAMIC SCROLL|INSENSITIVE) CURSOR FOR .+ (?:FOR (?:READ ONLY|UPDATE))/m

      def select(sql, name = nil, binds = [])
        if sql =~ CursorRegexp
          cursor      = $&
          sql[cursor] = ''
          raw_execute(cursor, "Cursor declaration for #{name}")
        end

        raw_execute(sql, name, :to_a).tap do |rs|
          rs.each {|row| row.each {|k,v| v.rstrip! if v.respond_to?(:rstrip!)}} if @strip_char
        end
      end

      def has_identity_column(table_name)
        !get_identity_column(table_name).nil?
      end

      def get_identity_column(table_name)
        @id_columns ||= {}
        if !@id_columns.has_key?(table_name)
          @logger.debug "Looking up identity column for table '#{table_name}'" if @logger
          col = columns(table_name).detect { |col| col.identity }
          @id_columns[table_name] = col.nil? ? nil : col.name
        end
        @id_columns[table_name]
      end

      def enable_identity_insert(table_name, enable = true)
        if has_identity_column(table_name)
          execute "SET IDENTITY_INSERT #{table_name} #{enable ? 'ON' : 'OFF'}"
        end
      end

      # Resolve all user-defined types (udt) to their fundamental types.
      # We do not use sp_help as it uses temporary tables that cannot be
      # used in transactions, that could be started e.g. when migrations
      # are run.
      #
      def resolve_type(type)
        (@udts ||= {})[type] ||= begin
          sql = <<-sql
            SELECT st.name AS storage_type
            FROM systypes s, systypes st
            WHERE s.type = st.type
              AND st.name NOT IN ('longsysname', 'nchar', 'nvarchar', 'sysname', 'timestamp')
              AND s.name = '#{type}'
          sql

          select_one(sql, "Field type for #{type}")['storage_type'].strip
        end
      end

      def normalize_type(field_type, prec, scale, length)
        has_scale = (!scale.nil? && scale > 0)
        type = if field_type =~ /numeric/i and !has_scale
          'int'
        elsif field_type =~ /money/i
          'numeric'
        else
          resolve_type(field_type.strip)
        end

        spec = if prec
          has_scale ? "(#{prec},#{scale})" : "(#{prec})"
        elsif length && !(type =~ /date|time|text/)
          "(#{length})"
        else
          ''
        end
        "#{type}#{spec}"
      end
    end # class SybaseAdapter

  end # module ConnectionAdapters
end # module ActiveRecord
