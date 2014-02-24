module Pubnub
  module Event
    def initialize(options, app)
      @app            = app
      @origin         = options[:origin]          || app.env[:origin]
      @channel        = options[:channel]
      @message        = options[:message]
      @http_sync      = options[:http_sync]
      @callback       = options[:callback]
      @error_callback = options[:error_callback]  || app.env[:error_callback]
      @ssl            = options[:ssl]             || app.env[:ssl]

      @cipher_key     = app.env[:cipher_key]
      @secret_key     = app.env[:secret_key]
      @auth_key       = options[:auth_key]        || app.env[:auth_key]
      @publish_key    = app.env[:publish_key]
      @subscribe_key  = app.env[:subscribe_key]

      @response      = nil
      @timetoken     = app.env[:timetoken] || 0
      validate!
      @original_channel = format_channels(@channel, false)
      @channel          = format_channels(@channel)
    end

    def fire(app)
      $logger.debug('Event#fire')
      setup_connection(app) unless connection_exist?(app)
      envelopes = start_event(app)
    end

    def start_event(app, count = 0)
      if count <= app.env[:max_retries]
        @response = get_connection(app).request(uri(app))
      end

      error = response_error(@response, app)

      if !error || count > app.env[:max_retries]
        handle_response(@response, app, error)
      else
        start_event(app, count + 1)
      end
    end

    def validate!
      if @allow_multiple_channels == true
        raise ArgumentError.new(:object => self), 'Invalid channel(s) format! Should be type of: String, Symbol, or Array of both' unless valid_channel?(true)
      elsif @allow_multiple_channels == false
        raise ArgumentError.new(:object => self), 'Invalid channel(s) format! Should be type of: String, Symbol' unless valid_channel?(false)
      end

      raise ArgumentError.new(:object => self), 'Callback parameter is required while using async' if !@http_sync && @callback.blank? && !@doesnt_require_callback

    end

    private

    def response_error(response, app)
      if Parser.valid_json?(response.body) && (200..206).include?(response.code.to_i)
        error = false
      elsif Parser.valid_json?(response.body) && !(200..206).include?(response.code.to_i)
        error = [:code]
      elsif !Parser.valid_json?(response.body) && (200..206).include?(response.code.to_i)
        error = [:json]
      else
        error = [:code, :json]
      end

      error
    end

    def handle_response(response, app, error)

      $logger.debug('Event#handle_response')
      envelopes = format_envelopes(response, app, error)
      fire_callbacks(envelopes,app)
      envelopes

    end

    def fire_callbacks(envelopes, app)
      envelopes.each do |envelope|
        @callback.call(envelope)       if !envelope.error && @callback && !envelope.timetoken_update
        if envelope.timetoken_update || envelope.timetoken.to_i > app.env[:timetoken].to_i
          update_timetoken(app, envelope.timetoken)
        end
      end
      @error_callback.call(envelopes.first) if envelopes.first.error

    end

    def update_timetoken(app, timetoken)
      app.update_timetoken(timetoken)
      @timetoken = timetoken
    end

    def add_common_data_to_envelopes(envelopes, response, app, error)
      $logger.debug('Event#add_common_data_to_envelopes')

      envelopes.each do |envelope|
        envelope.response      = response.body
        envelope.object        = response
        envelope.status        = response.code.to_i
      end

      envelopes.last.last   = true
      envelopes.first.first = true

      envelopes = insert_errors(envelopes, error, app) if error

      envelopes
    end

    def insert_errors(envelopes, error_symbol, app)
      case error_symbol
        when [:json]
          error_message = '[0,"Invalid JSON in response."]'
          error         = JSONParseError.new(
              :app     => app,
              :message => error_message,
              :request => self.class,
              :response => @response.body,
              :error    => error_symbol
          )
        when [:code]
          error_message = '[0,"Non 2xx server response."]'
          error         = ResponseError.new(
              :app     => app,
              :message => error_message,
              :request => self.class,
              :response => @response.body,
              :error    => error_symbol
          )
        when [:code, :json]
          error_message = '[0,"Invalid JSON in response."]'
          error         = ResponseError.new(
              :app     => app,
              :message => error_message,
              :request => self.class,
              :response => @response.body,
              :error    => error_symbol
          )
        else
          error_message = '[0, "Unknown Error."]'
          error         = Error.new(
              :app     => app,
              :message => error_message,
              :request => self.class,
              :response => @response.body,
              :error    => error_symbol
          )
      end

      envelopes.first.error   = error
      envelopes.first.message = error_message
      envelopes.first.last = true

      [envelopes.first]
    end

    def uri(app)
      $logger.debug("#{self.class}#uri #{[origin(app), path(app), '?', params_hash_to_url_params(parameters(app))].join}")
      URI [origin(app), path(app), '?', params_hash_to_url_params(parameters(app))].join
    end

    def origin(app)
      h = @ssl ? 'https://' : 'http://'
      h + @origin
    end

    def parameters(app)
      required = {
          :auth => @auth_key,
          :pnsdk => "PubNub-Ruby/#{Pubnub::VERSION}"
      }

      empty_if_blank = {
          :uuid => app.env[:uuid]
      }

      empty_if_blank.delete_if {|k, v| v.nil? }

      required.merge(empty_if_blank)
    end

  end

  module SingleEvent
    private

    def setup_connection(app)
      app.single_event_connections_pool[@origin] = new_connection(app)
    end

    def connection_exist?(app)
      !app.single_event_connections_pool[@origin].nil? && !app.single_event_connections_pool[@origin].nil?
    end

    def get_connection(app)
      app.single_event_connections_pool[@origin]
    end

    def new_connection(app)
      connection = Net::HTTP::Persistent.new "pubnub_ruby_client_v#{Pubnub::VERSION}"
      connection.idle_timeout = app.env[:timeout]
      connection.read_timeout   = app.env[:timeout]
      connection
    end
  end

  module SubscribeEvent


    def fire(app)
      $logger.debug('SubscribeEvent#fire')
      if @http_sync == true
        $logger.debug('SubscribeEvent#fire sync')
        super
      else
        $logger.debug('SubscribeEvent#fire async')
        $logger.debug("Channel: #{@channel}")
        setup_connection(app) unless connection_exist?(app)
        unless app.env[:subscriptions][@origin].blank?
          @channel.each do |channel|
            if app.env[:subscriptions][@origin].get_channels.include?(channel)
              @channel.delete(channel)
              $logger.error("Already subscribed to channel #{channel}, you have to leave that channel first")
            end
            $logger.debug('SubscribeEvent#add_channel | Adding channel')
            app.env[:subscriptions][@origin].add_channel(channel, app)
          end
        end

        if app.env[:subscriptions][@origin].nil?
          app.env[:subscriptions][@origin]        = self            if app.env[:subscriptions][@origin].nil?
          app.env[:callbacks_pool][@origin]       = Hash.new        if app.env[:callbacks_pool][@origin].nil?
          app.env[:error_callbacks_pool][@origin] = @error_callback if app.env[:error_callbacks_pool][@origin].nil?

          @channel.each do |channel|
            app.env[:callbacks_pool][@origin][channel] = Hash.new

            app.env[:callbacks_pool][@origin][channel][:callback]       = @callback       unless app.env[:callbacks_pool][@origin][:callback]
          end

        else
          @channel.each do |channel|
            app.env[:callbacks_pool][@origin][channel] = Hash.new
            app.env[:callbacks_pool][@origin][channel] = Hash.new

            app.env[:callbacks_pool][@origin][channel][:callback]       = @callback       unless app.env[:callbacks_pool][@origin][:callback]
            app.env[:callbacks_pool][@origin][channel][:error_callback] = @error_callback unless app.env[:callbacks_pool][@origin][:error_callback]
          end
        end

        app.start_subscribe

      end
    end

    def add_channel(channel, app)
      @channel = @channel + format_channels(channel)
      $logger.debug('SubscribeEvent#add_channel | Added channel')
    end

    def remove_channel(channel, app)
      @channel = @channel - format_channels(channel)
      $logger.debug('SubscribeEvent#remove_channel | Removed channel')
      begin
        shutdown_subscribe(app) if @channel.empty?
      rescue => e
        $logger.error(e.msg)
        $logger.error(e.backtrace)
      end
    end

    def get_channels
      @channel
    end

    private

    def shutdown_subscribe(app)
      app.env[:subscriptions][@origin]  = nil
      app.env[:subscriptions].delete(@origin)
      app.env[:callbacks_pool][@origin] = nil
      app.env[:callbacks_pool].delete(@origin)
      app.subscribe_event_connections_pool[@origin].shutdown_in_all_threads
      app.subscribe_event_connections_pool[@origin] = nil
      app.subscribe_event_connections_pool.delete(@origin)
    end

    def fire_callbacks(envelopes, app)
      if @http_sync == true
        super
      else
        begin
          $logger.debug('Event#fire_callbacks async')
          envelopes.each do |envelope|
            app.env[:callbacks_pool][@origin][envelope.channel][:callback].call(envelope) if !envelope.error && !envelope.timetoken_update
            if envelope.timetoken_update || envelope.timetoken.to_i > app.env[:timetoken].to_i
              update_timetoken(app, envelope.timetoken)
            end
          end
          $logger.debug('We can send next request now')
          app.env[:error_callbacks_pool][@origin].call(envelopes.first) if envelopes.first.error
        rescue => error
          $logger.error(error)
          $logger.error(error.backtrace)
        end
      end unless envelopes.nil?

    end

    def setup_connection(app)
      app.subscribe_event_connections_pool[@origin] = new_connection(app)
    end

    def connection_exist?(app)
      !app.subscribe_event_connections_pool[@origin].nil? && !app.subscribe_event_connections_pool[@origin].nil?
    end

    def get_connection(app)
      app.subscribe_event_connections_pool[@origin]
    end

    def channels_for_url(channels)
      channels.join(',')
    end

    def path(app)
      path = URI.escape("/subscribe/#{@subscribe_key}/#{channels_for_url(@channel)}/0/#{@timetoken}").gsub(/\?/,'%3F')
    end

    def timetoken(parsed_response)
      parsed_response[1] if parsed_response.is_a? Array
    end

    def message(parsed_response, i, channel, app)
      if app.env[:cipher_key].blank? || channel.index('-pnpres')
        parsed_response.first[i]
      else
        pc = Crypto.new(app.env[:cipher_key])
        pc.decrypt(parsed_response.first[i])
      end
    end

    def format_envelopes(response, app, error)

      $logger.debug('Subscribe#format_envelopes')

      parsed_response = Parser.parse_json(response.body) if Parser.valid_json?(response.body)

      $logger.debug('Subscribe#format_envelopes | Response parsed')

      envelopes = Array.new
      if error
        $logger.debug('Subscribe#format_envelopes | Error')
        envelopes << Envelope.new(
            {
                :channel           => @channel,
                :timetoken         => timetoken(parsed_response)
            },
            app
        )
      elsif parsed_response[0].empty?
        $logger.debug('Subscribe#format_envelopes | Timetoken')
        envelopes << Envelope.new(
            {
                :channel           => @channel.first,
                :response_message  => parsed_response,
                :timetoken         => timetoken(parsed_response),
                :timetoken_update  => true
            },
            app
        )
      else
        $logger.debug('Subscribe#format_envelopes | Not timetoken update')
        parsed_response[0].size.times do |i|
          if parsed_response[2].is_a? Array
            channel = parsed_response[2][i]
          elsif parsed_response[2].is_a? String
            channel = parsed_response[2]
          else
            channel = @channel.first
          end
          $logger.debug('Subscribe#format_envelopes | Channel created')

          $logger.debug("#{parsed_response}")

          envelopes << Envelope.new(
              {
                  :message           => message(parsed_response, i, channel, app),
                  :channel           => channel,
                  :response_message  => parsed_response,
                  :timetoken         => timetoken(parsed_response)
              },
              app
          )

          $logger.debug('Subscribe#format_envelopes | Envelopes created')

        end
      end

      $logger.debug('Subscribe#format_envelopes | envelopes created')

      envelopes = add_common_data_to_envelopes(envelopes, response, app, error)

      envelopes

    end

    def new_connection(app)
      connection = Net::HTTP::Persistent.new "pubnub_ruby_client_v#{Pubnub::VERSION}"
      connection.idle_timeout   = app.env[:subscribe_timeout]
      connection.read_timeout   = app.env[:subscribe_timeout]
      connection
    end
  end
end